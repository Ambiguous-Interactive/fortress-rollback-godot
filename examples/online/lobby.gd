class_name FortressOnlineLobby
extends RefCounted

const Callbacks = preload("res://examples/online/callbacks.gd")
const Match = preload("res://examples/online/match.gd")
const Multiplayer = preload("res://addons/fortress_rollback/transport/signalfish_webrtc_multiplayer_peer.gd")
const SDK_PATH: String = "res://addons/signal_fish/signal_fish_client.gd"
const CONFIG_PATH: String = "res://addons/signal_fish/signal_fish_config.gd"
const MESH_PATH: String = "res://addons/signal_fish/webrtc/sf_webrtc_mesh.gd"

var game_match: Match = Match.new()
var client: Node
var mesh: Node
var state: String = "offline"
var message: String = "Install the optional SignalFish SDK, then create or join a room."
var all_ready: bool = false
var is_creator: bool = false
var has_readied: bool = false
var _config: RefCounted
var _info: RefCounted
var _sdk: Script
var _name: String = ""
var _room: String = ""
var _joined: bool = false
var _closing: bool = false
var _cleanup_pending: bool = false
var _deadline: int = -1
var _epoch: int = 0
var _last_now: int = -1
var _connection_revision: int = 0
var _is_servicing: bool = false
var _callbacks: Callbacks


func connect_room(endpoint: String, player_name: String, room: String, now_us: int) -> Error:
	if _is_busy():
		return ERR_BUSY
	_is_servicing = true
	var code: Error = _connect_room(endpoint, player_name, room, now_us)
	_is_servicing = false
	return code


func _connect_room(endpoint: String, player_name: String, room: String, now_us: int) -> Error:
	if client != null:
		return ERR_ALREADY_IN_USE
	if now_us < 0 or not (endpoint.begins_with("ws://") or endpoint.begins_with("wss://")) or player_name.strip_edges().is_empty():
		message = "Enter a ws:// or wss:// endpoint and a player name."
		return ERR_INVALID_PARAMETER
	for path: String in [SDK_PATH, CONFIG_PATH, MESH_PATH]:
		if not ResourceLoader.exists(path):
			message = "SignalFish SDK is missing. See docs/online-example.md for installation."
			return ERR_UNAVAILABLE
	_sdk = load(SDK_PATH)
	var config_script: Script = load(CONFIG_PATH)
	var mesh_script: Script = load(MESH_PATH)
	client = _sdk.new()
	mesh = mesh_script.new()
	_config = config_script.new()
	_config.set("app_id", "fortress-live-webrtc")
	_config.set("endpoint_url", endpoint)
	_config.set("protocol_version", 3)
	_config.set("supported_transports", PackedStringArray(["relay", "webrtc"]))
	_config.set("supported_topologies", PackedStringArray(["relay", "mesh"]))
	_config.set("game_data_format", "message_pack")
	_config.set("decode_msgpack_payloads", false)
	_config.set("auto_poll", false)
	mesh.set("multiplayer_peer_factory", Multiplayer.create)
	var connection_script: Script = load("res://addons/fortress_rollback/transport/signalfish_webrtc_connection.gd")
	mesh.set("peer_connection_factory", Callable(connection_script, "create"))
	client.call("set_auto_reconnect", false)
	_name = player_name.strip_edges()
	_room = room.strip_edges()
	is_creator = _room.is_empty()
	game_match = Match.new()
	_cleanup_pending = false
	all_ready = false
	has_readied = false
	_joined = false
	_info = null
	_epoch = now_us
	_last_now = now_us
	_deadline = now_us + 30000000
	_connect_callbacks()
	var revision: int = _connection_revision
	state = "connecting"
	message = "Connecting to SignalFish…"
	var configured: Error = client.call("configure", _config)
	if revision != _connection_revision:
		return ERR_UNAVAILABLE
	if configured != OK:
		_fail("SDK configuration failed (%d)." % configured)
		return configured
	if state == "failed":
		return ERR_UNAVAILABLE
	var connected: Error = client.call("connect_to_server")
	if revision != _connection_revision:
		return ERR_UNAVAILABLE
	if connected != OK:
		_fail("Connection failed (%d)." % connected)
		return connected
	if state == "failed":
		return ERR_UNAVAILABLE
	return OK


func room_code() -> String:
	return client.call("get_room_code") if client != null else ""


func ready() -> Error:
	if _is_busy():
		return ERR_BUSY
	_is_servicing = true
	var code: Error = _ready()
	_is_servicing = false
	return code


func _ready() -> Error:
	if state != "lobby" or has_readied:
		return ERR_UNAVAILABLE
	var revision: int = _connection_revision
	var players: Array = client.call("get_players")
	if revision != _connection_revision or players.size() != 2:
		return ERR_UNAVAILABLE
	var roster: PackedStringArray = PackedStringArray()
	for player: RefCounted in players:
		roster.append(player.get("id"))
	# Host entropy belongs to the transport lifetime, never to simulation state.
	var incarnation: PackedByteArray = Crypto.new().generate_random_bytes(8)
	var frozen: Error = game_match.freeze(client, mesh, roster, incarnation)
	if revision != _connection_revision:
		return ERR_UNAVAILABLE
	if frozen != OK:
		_fail("Could not freeze the two-player room (%d)." % frozen)
		return frozen
	if state == "failed":
		return ERR_UNAVAILABLE
	var code: Error = client.call("set_ready")
	if revision != _connection_revision:
		return ERR_UNAVAILABLE
	if code != OK:
		_fail("Ready failed (%d)." % code)
		return code
	if state == "failed":
		return ERR_UNAVAILABLE
	has_readied = true
	message = "Ready. The room creator can start when both players are ready."
	return OK


func start() -> Error:
	if _is_busy():
		return ERR_BUSY
	_is_servicing = true
	var code: Error = _start()
	_is_servicing = false
	return code


func _start() -> Error:
	if not is_creator or not has_readied or not all_ready or state != "lobby":
		return ERR_UNAVAILABLE
	var revision: int = _connection_revision
	state = "starting"
	_deadline = _last_now + 30000000
	var code: Error = client.call("start_game")
	if revision != _connection_revision:
		return ERR_UNAVAILABLE
	if code != OK:
		_fail("Start failed (%d)." % code)
	elif state == "failed":
		return ERR_UNAVAILABLE
	return code


## Monotonic host time services networking; gameplay advances only whole fixed ticks.
func tick(now_us: int, buttons: int) -> void:
	if _is_busy():
		return
	_is_servicing = true
	_tick(now_us, buttons)
	_is_servicing = false


func _tick(now_us: int, buttons: int) -> void:
	if client == null:
		return
	if state == "failed":
		# The SDK needs polling to finish its WebSocket close handshake.
		_finish_cleanup()
		client.call("poll")
		return
	if now_us < _last_now:
		_fail("Host clock moved backwards.")
		return
	_last_now = now_us
	if state == "playing" and not game_match.poll_protocol_time(now_us - _epoch):
		_fail(game_match.failure)
		_finish_cleanup()
		return
	var revision: int = _connection_revision
	client.call("poll")
	if revision != _connection_revision or state == "failed":
		return
	mesh.call("poll")
	if revision != _connection_revision or state == "failed":
		return
	var authenticated: bool = false
	if state == "connecting":
		authenticated = client.call("is_authenticated")
		if revision != _connection_revision:
			return
	if state == "connecting" and authenticated and _info != null:
		var params: RefCounted = _sdk.JoinRoomParams.new()
		params.set("game_name", "fortress-online-integer")
		params.set("player_name", _name)
		params.set("room_code", _room)
		params.set("max_players", 2)
		params.set("supports_authority", false)
		state = "joining"
		var code: Error = client.call("join_room", params)
		if revision != _connection_revision:
			return
		if code != OK:
			_fail("Room join failed (%d)." % code)
		if state == "failed":
			return
	if state in ["connecting", "joining"] and now_us >= _deadline:
		_fail("Connection or room join timed out.")
		return
	if has_readied:
		var route: String = game_match.adapter.status().route
		if revision != _connection_revision:
			return
		if route in ["blocked", "restart_required"]:
			_fail("Room membership or transport lifetime changed.")
		elif route in ["relay", "relay_required"] and not game_match.has_started:
			_fail("This example needs an initial WebRTC mesh plan with standby relay.")
		elif route == "mesh" and not game_match.has_started:
			if state == "lobby":
				state = "starting"
				_deadline = now_us + 30000000
			var transport: Object = mesh.call("get_multiplayer_peer")
			if revision != _connection_revision:
				return
			if transport != null:
				transport.call("poll")
				if revision != _connection_revision or state == "failed":
					return
				var peers: Dictionary = transport.call("get_peers")
				if revision != _connection_revision:
					return
				if peers.size() == 1 and peers.values()[0].get("connected", false):
					var started: Error = game_match.start_transport(client, mesh, _config, _info, now_us - _epoch)
					if revision != _connection_revision:
						return
					if started != OK:
						_fail("Transport setup failed (%d)." % started)
					elif state != "failed":
						state = "playing"
						message = "Move with WASD or arrow keys. Leave to start a fresh room."
		if state == "starting" and now_us >= _deadline:
			_fail("WebRTC connection timed out. Check your endpoint and ICE configuration.")
	if state == "playing":
		game_match.tick(now_us - _epoch, buttons)
		if not game_match.failure.is_empty():
			_fail(game_match.failure)
		_finish_cleanup()


func disconnect_room() -> void:
	if _closing:
		return
	var defer_release: bool = _is_servicing or game_match._is_busy()
	_connection_revision += 1
	_closing = true
	var previous_mesh: Node = mesh
	var previous_client: Node = client
	mesh = null
	client = null
	_config = null
	_info = null
	state = "offline"
	message = "Left the room. Create a new room and share its new code to restart."
	has_readied = false
	all_ready = false
	game_match.detach()
	_cleanup_pending = false
	_release_node(previous_mesh, defer_release)
	if previous_client != null:
		previous_client.call("close", 1000, "Leaving example room")
		_release_node(previous_client, defer_release)
	_closing = false


func _release_node(node: Node, defer_release: bool) -> void:
	if not is_instance_valid(node):
		return
	if defer_release:
		node.queue_free()
	else:
		node.free()


func _connect_callbacks() -> void:
	_connection_revision += 1
	_callbacks = Callbacks.new(self, _connection_revision)
	client.connect("protocol_info", _callbacks.on_info)
	client.connect("room_joined", _callbacks.on_room)
	client.connect("lobby_state_changed", _callbacks.on_lobby)
	client.connect("protocol_error", _callbacks.on_protocol_error)
	for signal_name: String in [
		"connection_failed", "authentication_error", "room_join_failed", "server_error", "reconnection_failed", "disconnected", "going_away", "room_left", "reconnected"
	]:
		client.connect(signal_name, _callbacks.on_failure)


func _on_info(info: RefCounted) -> void:
	if state != "failed" and not _closing:
		_info = info


func _on_room(_info_value: RefCounted) -> void:
	if state == "failed" or _closing:
		return
	if _joined:
		_fail("Room baseline changed.")
		return
	_joined = true
	state = "lobby"
	message = "Share the room code. Both players press Ready, then the creator presses Start."


func _on_lobby(_value: int, _players: PackedStringArray, ready_value: bool) -> void:
	if state != "failed" and not _closing:
		all_ready = ready_value


# Variant arguments accommodate the optional SDK signals' different public payloads.
func _on_failure(_first: Variant = null, _second: Variant = null, _third: Variant = null) -> void:
	if not _closing:
		_fail("SignalFish connection or room operation failed.")


func _on_protocol_error(reason: String) -> void:
	if not _closing:
		_fail("SignalFish: " + reason.left(256))


func _fail(reason: String) -> void:
	if state == "failed":
		return
	state = "failed"
	message = reason + " Leave, then create or join a fresh room."
	_cleanup_pending = true
	game_match.detach()
	if client != null:
		client.call("close", 1000, "Online example failed")


func _finish_cleanup() -> void:
	if _cleanup_pending:
		# Busy adapters fence callbacks immediately and release owned queues after unwind.
		game_match.detach()
		_cleanup_pending = false


func _is_busy() -> bool:
	return _closing or _is_servicing or game_match._is_busy()
