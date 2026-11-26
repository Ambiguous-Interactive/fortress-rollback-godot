class_name FortressSignalFishAdapter
extends RefCounted

signal mesh_departed

# gdlint: disable=max-returns
const Membership = preload("res://addons/fortress_rollback/transport/signalfish_membership.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const LIFETIME_SIGNALS: Array[String] = [
	"room_left",
	"disconnected",
	"connection_failed",
	"reconnected",
	"room_joined",
	"player_joined",
	"authentication_error",
	"reconnection_failed",
	"spectator_joined"
]

## Opt in when the room owner will explicitly detach after a remote departure.
var retain_mesh_on_player_departure: bool = false

var _client: WeakRef = null
var _mesh: WeakRef = null
var _membership: Membership = null
var _mesh_attached: bool = false
var _is_detaching: bool = false
var _is_attaching: bool = false
var _is_checking_lifetime: bool = false
var _is_stopping_mesh: bool = false
var _restart_required: bool = false
var _room_id: String = ""
var _lifetime_revision: int = 0
var _addressed_peers: Dictionary = {}
var _is_applying_plan: bool = false
var _state: Dictionary = {"route": "unconfigured", "generation": "", "offerers": {}, "error": OK, "byte_delivery_implemented": false}


## Supply installed SDK objects. No SDK class names or resources are loaded here.
## Attach after joining the room, before its first session plan. Keep both Nodes alive.
func attach(client: Object, mesh: Object, membership: Membership) -> Error:
	if _client != null or _is_attaching or _is_detaching or _is_stopping_mesh or _is_checking_lifetime or _is_applying_plan:
		return ERR_ALREADY_IN_USE
	if client == null or mesh == null or membership == null or membership.local_uuid().is_empty():
		return ERR_INVALID_PARAMETER
	if not client.has_signal("session_plan") or not client.has_method("get_player_id") or not mesh.has_method("attach") or not mesh.has_method("detach"):
		return ERR_INVALID_PARAMETER
	_is_attaching = true
	var code: Error = _attach(client, mesh, membership)
	_is_attaching = false
	return code


func _attach(client: Object, mesh: Object, membership: Membership) -> Error:
	_lifetime_revision += 1
	var revision: int = _lifetime_revision
	_client = weakref(client)
	_mesh = weakref(mesh)
	_membership = membership
	_state = {"route": "awaiting_plan", "generation": "", "offerers": {}, "error": OK, "byte_delivery_implemented": false}
	for signal_name: String in LIFETIME_SIGNALS:
		if client.has_signal(signal_name):
			client.connect(signal_name, _on_transport_ended)
	if client.has_signal("player_left"):
		client.connect("player_left", _on_player_left)
	if client.has_signal("player_reconnected"):
		client.connect("player_reconnected", _on_player_reconnected)
	var player: String = client.call("get_player_id")
	if revision != _lifetime_revision:
		return ERR_UNAVAILABLE
	if player != membership.local_uuid():
		detach()
		return ERR_INVALID_DATA
	var room: String = client.call("get_room_id") if client.has_method("get_room_id") else ""
	if revision != _lifetime_revision:
		return ERR_UNAVAILABLE
	_room_id = room
	# Validate before the mesh listener can observe an unsupported plan.
	client.connect("session_plan", _on_plan)
	if client.has_signal("new_peer"):
		client.connect("new_peer", _on_new_peer)
	var attached_client: WeakRef = _client
	_mesh_attached = true
	var code: Error = mesh.call("attach", client)
	if _client != attached_client or _restart_required or _state.route == "blocked":
		return ERR_UNAVAILABLE
	if code != OK:
		detach()
		return code
	return OK


func detach() -> void:
	if _is_detaching:
		return
	_is_detaching = true
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
		if client.has_signal("player_left") and client.is_connected("player_left", _on_player_left):
			client.disconnect("player_left", _on_player_left)
		for signal_name: String in LIFETIME_SIGNALS:
			if client.has_signal(signal_name) and client.is_connected(signal_name, _on_transport_ended):
				client.disconnect(signal_name, _on_transport_ended)
	_restart_required = false
	_client = null
	_mesh = null
	_membership = null
	_room_id = ""
	_addressed_peers.clear()
	_state = {"route": "unconfigured", "generation": "", "offerers": {}, "error": OK, "byte_delivery_implemented": false}
	_is_detaching = false


## Plans replace routing and offerer roles without changing player slots or session IDs.
## Relay selection requires the separate byte-delivery adapter; it does not send bytes.
func _apply_plan(plan: Object) -> Error:
	if _is_detaching or _is_stopping_mesh or _restart_required:
		return ERR_UNAVAILABLE
	if _is_checking_lifetime or _is_applying_plan:
		# The SDK consumes this signal synchronously; detach before its listener runs.
		_restart_required = true
		return _refuse(ERR_UNAVAILABLE)
	_is_applying_plan = true
	var code: Error = _apply_checked_plan(plan)
	_is_applying_plan = false
	return code


func _apply_checked_plan(plan: Object) -> Error:
	if _is_detaching or _is_stopping_mesh:
		return ERR_UNAVAILABLE
	var revision: int = _lifetime_revision
	_check_lifetime()
	if revision != _lifetime_revision:
		return ERR_UNAVAILABLE
	if _restart_required:
		return _refuse(ERR_UNAVAILABLE)
	if _membership == null or not is_instance_valid(plan) or not plan.has_method("to_dict"):
		return _refuse(ERR_INVALID_PARAMETER)
	# Variant is the optional SDK's public, JSON-shaped value-object boundary.
	var value: Variant = plan.call("to_dict")
	if revision != _lifetime_revision:
		return ERR_UNAVAILABLE
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
		if revision != _lifetime_revision:
			return ERR_UNAVAILABLE
	elif not _mesh_attached:
		_restart_required = true
		return _refuse(ERR_UNAVAILABLE)
	var addressed_peers: Dictionary = _validated_addressed_peers(data.get("addressed_binary_peers")) if route in ["relay", "relay_required"] else {}
	if _state.route != route or _state.generation != data.generation or _state.offerers != offerers or _addressed_peers != addressed_peers:
		_lifetime_revision += 1
	_addressed_peers = addressed_peers
	_state = {"route": route, "generation": data.generation, "offerers": offerers.duplicate(), "error": OK, "byte_delivery_implemented": false}
	return OK


## Return the current relay lifetime only when its plan covers every frozen remote seat.
func addressed_binary_revision(client: Object, membership: Membership) -> int:
	_check_lifetime()
	if _addressed_peers.is_empty() or _client == null or _client.get_ref() != client or _membership != membership:
		return -1
	return _lifetime_revision


func _validated_addressed_peers(value: Variant) -> Dictionary:
	if not value is Array or value.size() != _membership.roster().size() - 1:
		return {}
	var remotes: Dictionary = {}
	for entry: Variant in value:
		if not entry is Dictionary or not entry.get("player_id") is String:
			return {}
		var uuid: String = entry.player_id
		if not Membership.valid_uuid(uuid) or uuid == _membership.local_uuid() or _membership.slot(uuid) < 0 or remotes.has(uuid):
			return {}
		# Godot JSON numbers may be floats. Every u32 value has an exact float representation.
		var epoch: Variant = entry.get("epoch")
		if not (epoch is int or epoch is float) or not is_finite(float(epoch)) or epoch < 1 or epoch > 4294967295 or epoch != floorf(float(epoch)):
			return {}
		remotes[uuid] = int(epoch)
	return remotes


func status() -> Dictionary:
	_check_lifetime()
	var result: Dictionary = _state.duplicate(true)
	result["lifetime_revision"] = _lifetime_revision
	return result


func has_retained_mesh() -> bool:
	return _restart_required and _mesh_attached


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
	if _membership == null or _state.route not in ["mesh", "relay", "relay_required"]:
		return I.Code.WRONG_STATE
	return _membership.receive(peer, packet, attributed_uuid, now_us, next_token)


func _on_plan(plan: Object) -> void:
	_apply_plan(plan)


func _on_new_peer(peer_uuid: String, you_initiate: bool) -> void:
	# NewPeer lacks a generation: accept only identities and roles authorized by the current plan.
	if _is_detaching or _is_stopping_mesh or _restart_required:
		return
	if _is_checking_lifetime or _is_applying_plan:
		_restart_required = true
		_refuse(ERR_UNAVAILABLE)
		return
	var revision: int = _lifetime_revision
	_check_lifetime()
	if revision != _lifetime_revision:
		return
	if _membership != null and _state.route == "mesh" and _state.offerers.has(peer_uuid) and _state.offerers[peer_uuid] == you_initiate:
		return
	_restart_required = true
	_refuse(ERR_INVALID_DATA)


func _stop_mesh() -> void:
	var mesh: Object = _mesh.get_ref() if _mesh != null else null
	var was_attached: bool = _mesh_attached
	_mesh_attached = false
	if was_attached and is_instance_valid(mesh):
		_is_stopping_mesh = true
		mesh.call("detach")
		_is_stopping_mesh = false


func _refuse(code: Error, retain_mesh: bool = false) -> Error:
	_lifetime_revision += 1
	_addressed_peers.clear()
	_state = {"route": "restart_required" if _restart_required else "blocked", "generation": "", "offerers": {}, "error": code, "byte_delivery_implemented": false}
	if not retain_mesh:
		_stop_mesh()
	return code


func _on_transport_ended(_first: Variant = null, _second: Variant = null) -> void:
	# SDK lifecycle signals carry different optional event payloads.
	if _restart_required:
		return
	_restart_required = true
	_refuse(ERR_UNAVAILABLE)


func _on_player_left(uuid: String = "") -> void:
	if _restart_required:
		return
	var retain_mesh: bool = retain_mesh_on_player_departure and _state.route == "mesh" and _membership != null \
		and uuid != _membership.local_uuid() and _membership.slot(uuid) >= 0
	_restart_required = true
	_refuse(ERR_UNAVAILABLE, retain_mesh)
	if retain_mesh:
		mesh_departed.emit()


func _on_player_reconnected(uuid: String) -> void:
	# The server explicitly announces a new remote incarnation; S4 owns safe reactivation.
	if _membership != null and uuid != _membership.local_uuid() and _membership.slot(uuid) >= 0:
		_on_transport_ended()


func _check_lifetime() -> void:
	if _is_checking_lifetime or _client == null or _restart_required:
		return
	_is_checking_lifetime = true
	_check_current_lifetime()
	_is_checking_lifetime = false


func _check_current_lifetime() -> void:
	if not is_instance_valid(_client.get_ref()) or _mesh == null or not is_instance_valid(_mesh.get_ref()):
		_restart_required = true
		_refuse(ERR_UNAVAILABLE)
		return
	var client: Object = _client.get_ref()
	var revision: int = _lifetime_revision
	var local: String = _membership.local_uuid()
	var room: String = _room_id
	var connected: bool = not client.has_method("is_connected_to_server") or client.call("is_connected_to_server")
	if revision != _lifetime_revision:
		return
	var authenticated: bool = not client.has_method("is_authenticated") or client.call("is_authenticated")
	if revision != _lifetime_revision:
		return
	var player: String = client.call("get_player_id")
	if revision != _lifetime_revision:
		return
	var current_room: String = client.call("get_room_id") if not room.is_empty() else ""
	if revision != _lifetime_revision:
		return
	if not connected or not authenticated or player != local or current_room != room:
		_restart_required = true
		_refuse(ERR_UNAVAILABLE)
