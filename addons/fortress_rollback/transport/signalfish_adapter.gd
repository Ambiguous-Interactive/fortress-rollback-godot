class_name FortressSignalFishAdapter
extends RefCounted

# gdlint: disable=max-returns
const Membership = preload("res://addons/fortress_rollback/transport/signalfish_membership.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const LIFETIME_SIGNALS: Array[String] = ["room_left", "disconnected", "connection_failed", "reconnected", "room_joined", "player_left", "player_joined",
	"authentication_error", "reconnection_failed", "spectator_joined"]

var _client: WeakRef = null
var _mesh: WeakRef = null
var _membership: Membership = null
var _mesh_attached: bool = false
var _restart_required: bool = false
var _room_id: String = ""
var _lifetime_revision: int = 0
var _state: Dictionary = {"route": "unconfigured", "generation": "", "offerers": {}, "error": OK, "byte_delivery_implemented": false}


## Supply installed SDK objects. No SDK class names or resources are loaded here.
## Attach after joining the room, before its first session plan. Keep both Nodes alive.
func attach(client: Object, mesh: Object, membership: Membership) -> Error:
	if _client != null:
		return ERR_ALREADY_IN_USE
	if client == null or mesh == null or membership == null or membership.local_uuid().is_empty():
		return ERR_INVALID_PARAMETER
	if not client.has_signal("session_plan") or not client.has_method("get_player_id") or not mesh.has_method("attach") or not mesh.has_method("detach"):
		return ERR_INVALID_PARAMETER
	if client.call("get_player_id") != membership.local_uuid():
		return ERR_INVALID_DATA
	_lifetime_revision += 1
	_client = weakref(client)
	_mesh = weakref(mesh)
	_membership = membership
	_room_id = client.call("get_room_id") if client.has_method("get_room_id") else ""
	# Validate before the mesh listener can observe an unsupported plan.
	client.connect("session_plan", _on_plan)
	if client.has_signal("new_peer"):
		client.connect("new_peer", _on_new_peer)
	if client.has_signal("player_reconnected"):
		client.connect("player_reconnected", _on_player_reconnected)
	for signal_name: String in LIFETIME_SIGNALS:
		if client.has_signal(signal_name):
			client.connect(signal_name, _on_transport_ended)
	var code: Error = mesh.call("attach", client)
	if code != OK:
		detach()
		return code
	_mesh_attached = true
	_state = {"route": "awaiting_plan", "generation": "", "offerers": {}, "error": OK, "byte_delivery_implemented": false}
	return OK


func detach() -> void:
	_lifetime_revision += 1
	_stop_mesh()
	var client: Object = _client.get_ref() if _client != null else null
	if is_instance_valid(client) and client.is_connected("session_plan", _on_plan):
		client.disconnect("session_plan", _on_plan)
	if is_instance_valid(client):
		if client.has_signal("new_peer") and client.is_connected("new_peer", _on_new_peer):
			client.disconnect("new_peer", _on_new_peer)
		if client.has_signal("player_reconnected") and client.is_connected("player_reconnected", _on_player_reconnected):
			client.disconnect("player_reconnected", _on_player_reconnected)
		for signal_name: String in LIFETIME_SIGNALS:
			if client.has_signal(signal_name) and client.is_connected(signal_name, _on_transport_ended):
				client.disconnect(signal_name, _on_transport_ended)
	_restart_required = false
	_client = null
	_mesh = null
	_membership = null
	_room_id = ""
	_state = {"route": "unconfigured", "generation": "", "offerers": {}, "error": OK, "byte_delivery_implemented": false}


## Plans replace routing and offerer roles without changing player slots or session IDs.
## Relay selection requires the separate byte-delivery adapter; it does not send bytes.
func _apply_plan(plan: Object) -> Error:
	_check_lifetime()
	if _restart_required:
		return _refuse(ERR_UNAVAILABLE)
	if _membership == null or plan == null or not plan.has_method("to_dict"):
		return _refuse(ERR_INVALID_PARAMETER)
	# Variant is the optional SDK's public, JSON-shaped value-object boundary.
	var value: Variant = plan.call("to_dict")
	if not value is Dictionary:
		return _refuse(ERR_INVALID_DATA)
	var data: Dictionary = value
	if not data.get("generation") is String or not Membership.valid_uuid(data.generation):
		return _refuse(ERR_INVALID_DATA)
	if not data.get("peers") is Array or data.peers.size() > _membership.roster().size() - 1:
		return _refuse(ERR_INVALID_DATA)
	var offerers: Dictionary = {}
	for entry: Variant in data.peers:
		if not entry is Dictionary or not entry.get("player_id") is String or not entry.get("initiate") is bool:
			return _refuse(ERR_INVALID_DATA)
		var uuid: String = entry.player_id
		if _membership.slot(uuid) < 0 or uuid == _membership.local_uuid() or offerers.has(uuid):
			return _refuse(ERR_INVALID_DATA)
		offerers[uuid] = entry.initiate
	var route: String = "blocked"
	if data.get("topology") == "mesh" and data.get("transport") == "webrtc":
		if offerers.size() != _membership.roster().size() - 1:
			return _refuse(ERR_INVALID_DATA)
		route = "mesh"
	elif data.get("topology") == "relay" and data.get("transport") == "relay":
		route = "relay"
	elif data.get("fallback") == "relay":
		route = "relay_required"
	else:
		return _refuse(ERR_UNAVAILABLE)
	if route != "mesh":
		_stop_mesh()
	elif not _mesh_attached:
		_restart_required = true
		return _refuse(ERR_UNAVAILABLE)
	if _state.route != route or _state.generation != data.generation or _state.offerers != offerers:
		_lifetime_revision += 1
	_state = {"route": route, "generation": data.generation, "offerers": offerers.duplicate(), "error": OK, "byte_delivery_implemented": false}
	return OK


func status() -> Dictionary:
	_check_lifetime()
	var result: Dictionary = _state.duplicate(true)
	result["lifetime_revision"] = _lifetime_revision
	return result


## Caller owns byte consumption; unknown and local Godot IDs fail before decoding.
func receive_mesh(peer: Peer, packet: PackedByteArray, attributed_peer_id: int, now_us: int, next_token: Variant = null) -> int:
	# next_token carries the core protocol's nullable handshake token.
	_check_lifetime()
	if _membership == null or _state.route != "mesh":
		return I.Code.WRONG_STATE
	return _membership.receive(peer, packet, _membership.uuid_for_peer_id(attributed_peer_id), now_us, next_token)


## Relay sender UUID comes from SDK attribution, never an envelope's claimed sender.
func receive_relay(peer: Peer, packet: PackedByteArray, attributed_uuid: String, now_us: int, next_token: Variant = null) -> int:
	# next_token carries the core protocol's nullable handshake token.
	_check_lifetime()
	if _membership == null or _state.route not in ["relay", "relay_required"]:
		return I.Code.WRONG_STATE
	return _membership.receive(peer, packet, attributed_uuid, now_us, next_token)


func _on_plan(plan: Object) -> void:
	_apply_plan(plan)


func _on_new_peer(peer_uuid: String, you_initiate: bool) -> void:
	# NewPeer lacks a generation: accept only identities and roles authorized by the current plan.
	_check_lifetime()
	if _membership != null and _state.route == "mesh" and _state.offerers.has(peer_uuid) and _state.offerers[peer_uuid] == you_initiate:
		return
	_restart_required = true
	_refuse(ERR_INVALID_DATA)


func _stop_mesh() -> void:
	var mesh: Object = _mesh.get_ref() if _mesh != null else null
	if _mesh_attached and is_instance_valid(mesh):
		mesh.call("detach")
	_mesh_attached = false


func _refuse(code: Error) -> Error:
	_lifetime_revision += 1
	_stop_mesh()
	_state = {"route": "restart_required" if _restart_required else "blocked", "generation": "", "offerers": {}, "error": code, "byte_delivery_implemented": false}
	return code


func _on_transport_ended(_first: Variant = null, _second: Variant = null) -> void:
	# SDK lifecycle signals carry different optional event payloads.
	_restart_required = true
	_refuse(ERR_UNAVAILABLE)


func _on_player_reconnected(uuid: String) -> void:
	# The server explicitly announces a new remote incarnation; S4 owns safe reactivation.
	if _membership != null and uuid != _membership.local_uuid() and _membership.slot(uuid) >= 0:
		_on_transport_ended()


func _check_lifetime() -> void:
	if _client == null:
		return
	if not is_instance_valid(_client.get_ref()) or _mesh == null or not is_instance_valid(_mesh.get_ref()):
		_restart_required = true
		_refuse(ERR_UNAVAILABLE)
		return
	var client: Object = _client.get_ref()
	# Closing can precede disconnected; AuthenticationError clears the room without closing.
	if (client.has_method("is_connected_to_server") and not client.call("is_connected_to_server")) \
		or (client.has_method("is_authenticated") and not client.call("is_authenticated")) \
		or client.call("get_player_id") != _membership.local_uuid() \
		or (not _room_id.is_empty() and client.call("get_room_id") != _room_id):
		_restart_required = true
		_refuse(ERR_UNAVAILABLE)
