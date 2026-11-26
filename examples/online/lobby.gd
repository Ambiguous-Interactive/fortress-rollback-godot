class_name FortressOnlineLobby
extends RefCounted

const Callbacks = preload("res://examples/online/callbacks.gd")
const Match = preload("res://examples/online/match.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Multiplayer = preload("res://addons/fortress_rollback/transport/signalfish_webrtc_multiplayer_peer.gd")
const NativeTransport = preload("res://examples/online/native_socket_transport.gd")
const SDK_PATH: String = "res://addons/signal_fish/signal_fish_client.gd"
const CONFIG_PATH: String = "res://addons/signal_fish/signal_fish_config.gd"
const MESH_PATH: String = "res://addons/signal_fish/webrtc/sf_webrtc_mesh.gd"
const START_TIMEOUT_US: int = 30_000_000
const NATIVE_MESH_GRACE_US: int = 3_000_000

var game_match: Match = Match.new()
var client: Node
var mesh: Node
var state: String = "offline"
var message: String = "Install the optional SignalFish SDK, then create or join a room."
var all_ready: bool = false
var is_creator: bool = false
var has_readied: bool = false
var player_count: int = 2
var backend: String = "legacy"
var _native_name: String = ""
var _requested_route: String = "mesh"
var _config: RefCounted
var _info: RefCounted
var _sdk: Script
var _name: String = ""
var _room: String = ""
var _joined: bool = false
var _closing: bool = false
var _cleanup_pending: bool = false
var _deadline: int = -1
var _mesh_start_after: int = -1
var _epoch: int = 0
var _last_now: int = -1
var _connection_revision: int = 0
var _is_servicing: bool = false
var _callbacks: Callbacks


func connect_room(endpoint: String, player_name: String, room: String, now_us: int) -> Error:
	return _connect_selected(endpoint, player_name, room, now_us, "legacy", 2, "mesh")


func connect_native_room(endpoint: String, player_name: String, room: String, now_us: int, slots: int, route: String) -> Error:
	return _connect_selected(endpoint, player_name, room, now_us, "native", slots, route)


func _connect_selected(endpoint: String, player_name: String, room: String, now_us: int, backend_choice: String, slots: int, route: String) -> Error:
	if _is_busy():
		return ERR_BUSY
	_is_servicing = true
	var code: Error = _connect_room(endpoint, player_name, room, now_us, backend_choice, slots, route)
	_is_servicing = false
	return code


func _connect_room(endpoint: String, player_name: String, room: String, now_us: int, backend_choice: String, slots: int, route: String) -> Error:
	if client != null:
		return ERR_ALREADY_IN_USE
	if now_us < 0 or not (endpoint.begins_with("ws://") or endpoint.begins_with("wss://")) or player_name.strip_edges().is_empty():
		message = "Enter a ws:// or wss:// endpoint and a player name."
		return ERR_INVALID_PARAMETER
	if slots < 2 or slots > 8 or route not in ["mesh", "relay"]:
		message = "Choose a supported backend, room size and transport."
		return ERR_INVALID_PARAMETER
	if backend_choice == "native" and not Match.Driver.Native.available():
		message = "Install the native addon to use upstream Fortress Rollback."
		return ERR_UNAVAILABLE
	for path: String in [SDK_PATH, CONFIG_PATH, MESH_PATH]:
		if not ResourceLoader.exists(path):
			message = "SignalFish SDK is missing. See docs/online-example.md for installation."
			return ERR_UNAVAILABLE
	var native_transport: RefCounted
	if backend_choice == "native":
		if not NativeTransport.is_available():
			message = "The SignalFish SDK is missing its WebSocket transport."
			return ERR_UNAVAILABLE
		native_transport = NativeTransport.create()
		if native_transport == null:
			message = "The SignalFish SDK could not configure the native WebSocket transport."
			return ERR_UNAVAILABLE
	_sdk = load(SDK_PATH)
	var config_script: Script = load(CONFIG_PATH)
	var mesh_script: Script = load(MESH_PATH)
	client = _sdk.new()
	if native_transport != null:
		client.set("transport", native_transport)
	mesh = mesh_script.new()
	if backend_choice == "native" and route == "mesh" and "pair_recovery_enabled" in mesh:
		mesh.set("pair_recovery_enabled", true)
	_config = config_script.new()
	_config.set("app_id", "fortress-live-webrtc")
	_config.set("endpoint_url", endpoint)
	_config.set("protocol_version", 3)
	_config.set("supported_transports", PackedStringArray(["relay", "webrtc"]))
	_config.set("supported_topologies", PackedStringArray(["relay", "mesh"]))
	if route == "relay":
		_config.set("supported_transports", PackedStringArray(["relay"]))
		_config.set("supported_topologies", PackedStringArray(["relay"]))
		if backend_choice == "native" and "requested_capabilities" in _config \
			and client.has_method("has_addressed_binary_game_data") and client.has_method("send_game_data_binary_to"):
			var capabilities: PackedStringArray = _config.get("requested_capabilities")
			if not capabilities.has(Match.Relay.ADDRESSED_BINARY_GAME_DATA_CAPABILITY):
				capabilities.append(Match.Relay.ADDRESSED_BINARY_GAME_DATA_CAPABILITY)
				_config.set("requested_capabilities", capabilities)
	_config.set("game_data_format", "message_pack")
	_config.set("decode_msgpack_payloads", false)
	_config.set("auto_poll", false)
	if backend_choice == "native":
		# Budget for room-wide copies when a room uses the broadcast path.
		_config.set("max_inbound_packets_per_poll", 256)
	mesh.set("multiplayer_peer_factory", Multiplayer.create)
	var connection_script: Script = load("res://addons/fortress_rollback/transport/signalfish_webrtc_connection.gd")
	mesh.set("peer_connection_factory", Callable(connection_script, "create"))
	client.call("set_auto_reconnect", false)
	_name = player_name.strip_edges()
	_room = room.strip_edges()
	is_creator = _room.is_empty()
	game_match = Match.new()
	backend = backend_choice
	player_count = slots
	_requested_route = route
	_native_name = ""
	if backend == "native":
		_native_name = "%s-%d-%s" % [Match.Driver.Native.WIRE_PROFILE, slots, route]
		game_match.game = Simulation.new(slots, Match.Driver.Native.INPUT_BYTES)
	_cleanup_pending = false
	all_ready = false
	has_readied = false
	_joined = false
	_info = null
	_epoch = now_us
	_last_now = now_us
	_deadline = now_us + 30000000
	_mesh_start_after = -1
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
	if revision != _connection_revision or players.size() != player_count:
		return ERR_UNAVAILABLE
	var roster: PackedStringArray = PackedStringArray()
	for player: RefCounted in players:
		roster.append(player.get("id"))
	# Host entropy belongs to the transport lifetime, never to simulation state.
	var incarnation: PackedByteArray = Crypto.new().generate_random_bytes(8)
	var frozen: Error = (
		game_match.freeze(client, mesh, roster, incarnation) if _native_name.is_empty() else (game_match.freeze_native(client, mesh, roster, incarnation, _native_name))
	)
	if revision != _connection_revision:
		return ERR_UNAVAILABLE
	if frozen != OK:
		_fail("Could not freeze the room (%d)." % frozen)
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
	message = "Ready. The room creator can start when all players are ready."
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
	_deadline = _last_now + START_TIMEOUT_US
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
		# Service WebSocket control traffic and let any close handshake finish.
		_finish_cleanup()
		client.call("poll")
		return
	if now_us < _last_now:
		_fail("Host clock moved backwards.")
		return
	if state == "playing" and game_match._local_input_code(buttons) == Match.Types.Code.INPUT_ALREADY_SUBMITTED:
		return
	_last_now = now_us
	if state == "playing" and not game_match.poll_protocol_time(now_us - _epoch):
		_fail(game_match.failure)
		_finish_cleanup()
		return
	var revision: int = _connection_revision
	_poll_client()
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
		params.set("game_name", "fortress-online-integer" if _native_name.is_empty() else _native_name)
		params.set("player_name", _name)
		params.set("room_code", _room)
		params.set("max_players", player_count)
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
		elif not game_match.has_started and route in ["mesh", "relay", "relay_required"]:
			_maybe_start_transport(route, now_us, revision)
		if revision != _connection_revision:
			return
		if state == "starting" and now_us >= _deadline:
			_fail("Transport connection timed out. Check your endpoint and ICE configuration.")
	if state == "playing":
		game_match.tick(now_us - _epoch, buttons)
		if not game_match.failure.is_empty():
			_fail(game_match.failure)
		_finish_cleanup()


func _poll_client() -> int:
	if backend != "native" or state != "playing":
		client.call("poll")
		return -1
	var transport: RefCounted = client.get("transport")
	var budget: int = transport.get("max_packets_per_poll")
	var previous_guard: Callable = transport.get("can_receive_packet")
	transport.set("can_receive_packet", game_match.relay.can_receive_packet)
	client.call("poll")
	transport.set("can_receive_packet", previous_guard)
	return budget


func _maybe_start_transport(route: String, now_us: int, revision: int) -> void:
	var relay_fallback: bool = backend == "native" and _requested_route == "relay" and route == "relay_required"
	if route != _requested_route and not relay_fallback:
		_fail("The server did not select the room's requested transport.")
		return
	if state == "lobby":
		state = "starting"
		_deadline = now_us + START_TIMEOUT_US
	if route == "mesh":
		# Give direct links time to connect after the accepted mesh plan arrives.
		if _mesh_start_after < 0:
			_mesh_start_after = now_us + NATIVE_MESH_GRACE_US
		if not _mesh_can_start(revision, backend == "native" and now_us >= _mesh_start_after):
			return
	var started: Error = game_match.start_transport(client, mesh, _config, _info, now_us - _epoch)
	if revision != _connection_revision:
		return
	if started != OK:
		_fail("Transport setup failed (%d)." % started)
	elif state != "failed":
		state = "playing"
		message = "Move with WASD or arrow keys. Leave to start a fresh room."


func _mesh_can_start(revision: int, allow_missing_links: bool) -> bool:
	var transport: Object = mesh.call("get_multiplayer_peer")
	if revision != _connection_revision or transport == null:
		return false
	transport.call("poll")
	if revision != _connection_revision or state == "failed":
		return false
	if allow_missing_links:
		return true
	var peers: Dictionary = transport.call("get_peers")
	if revision != _connection_revision or peers.size() != player_count - 1:
		return false
	for peer: Dictionary in peers.values():
		if not peer.get("connected", false):
			return false
	return true


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
	if backend == "native":
		game_match.adapter.retain_mesh_on_player_departure = true
		game_match.adapter.mesh_departed.connect(_callbacks.on_mesh_departure)
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


func _on_room(info_value: RefCounted) -> void:
	if state == "failed" or _closing:
		return
	if _joined:
		_fail("Room baseline changed.")
		return
	if not _native_name.is_empty() and (info_value == null or info_value.get("game_name") != _native_name):
		_fail("This room uses a different backend, input schema, player count or transport.")
		return
	_joined = true
	state = "lobby"
	message = "Share the room code. Each player presses Ready, then the creator presses Start."


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


func _on_mesh_departure() -> void:
	_fail("Room membership or transport lifetime changed.")


func _fail(reason: String) -> void:
	if state == "failed":
		return
	var keep_mesh: bool = game_match.adapter.has_retained_mesh()
	state = "failed"
	message = reason + " Leave, then create or join a fresh room."
	_cleanup_pending = true
	game_match.detach(keep_mesh)
	if client == null:
		return
	if keep_mesh:
		# The current departure reaches the SDK mesh. Mute later callbacks while polling the socket.
		client.set_block_signals(true)
	else:
		client.call("close", 1000, "Online example failed")


func _finish_cleanup() -> void:
	if _cleanup_pending:
		# Busy adapters fence callbacks immediately and release owned queues after unwind.
		game_match.detach(game_match.adapter.has_retained_mesh())
		_cleanup_pending = false


func _is_busy() -> bool:
	return _closing or _is_servicing or game_match._is_busy()
