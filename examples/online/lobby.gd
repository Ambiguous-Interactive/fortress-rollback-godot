class_name FortressOnlineLobby
extends RefCounted

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
var _deadline: int = -1
var _epoch: int = 0
var _last_now: int = -1


func connect_room(endpoint: String, player_name: String, room: String, now_us: int) -> Error:
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
	all_ready = false
	has_readied = false
	_joined = false
	_info = null
	_epoch = now_us
	_last_now = now_us
	_deadline = now_us + 30000000
	client.connect("protocol_info", _on_info)
	client.connect("room_joined", _on_room)
	client.connect("lobby_state_changed", _on_lobby)
	client.connect("protocol_error", _on_protocol_error)
	for signal_name: String in ["connection_failed", "authentication_error", "room_join_failed", "server_error", "reconnection_failed",
		"disconnected", "going_away", "room_left", "reconnected"]:
		client.connect(signal_name, _on_failure)
	var configured: Error = client.call("configure", _config)
	if configured != OK:
		_fail("SDK configuration failed (%d)." % configured)
		return configured
	var connected: Error = client.call("connect_to_server")
	if connected != OK:
		_fail("Connection failed (%d)." % connected)
		return connected
	state = "connecting"
	message = "Connecting to SignalFish…"
	return OK


func room_code() -> String:
	return client.call("get_room_code") if client != null else ""


func ready() -> Error:
	if state != "lobby" or has_readied or client.call("get_players").size() != 2:
		return ERR_UNAVAILABLE
	var roster: PackedStringArray = PackedStringArray()
	for player: RefCounted in client.call("get_players"):
		roster.append(player.get("id"))
	# Host entropy belongs to the transport lifetime, never to simulation state.
	var incarnation: PackedByteArray = Crypto.new().generate_random_bytes(8)
	var frozen: Error = game_match.freeze(client, mesh, roster, incarnation)
	if frozen != OK:
		_fail("Could not freeze the two-player room (%d)." % frozen)
		return frozen
	var code: Error = client.call("set_ready")
	if code != OK:
		_fail("Ready failed (%d)." % code)
		return code
	has_readied = true
	message = "Ready. The room creator can start when both players are ready."
	return OK


func start() -> Error:
	if not is_creator or not has_readied or not all_ready or state != "lobby":
		return ERR_UNAVAILABLE
	state = "starting"
	_deadline = _last_now + 30000000
	var code: Error = client.call("start_game")
	if code != OK:
		_fail("Start failed (%d)." % code)
	return code


## Monotonic host time services networking; gameplay advances only whole fixed ticks.
func tick(now_us: int, buttons: int) -> void:
	if client == null or state == "failed":
		return
	if now_us < _last_now:
		_fail("Host clock moved backwards.")
		return
	_last_now = now_us
	client.call("poll")
	if state == "failed":
		return
	mesh.call("poll")
	if state == "connecting" and client.call("is_authenticated") and _info != null:
		var params: RefCounted = _sdk.JoinRoomParams.new()
		params.set("game_name", "fortress-online-integer")
		params.set("player_name", _name)
		params.set("room_code", _room)
		params.set("max_players", 2)
		params.set("supports_authority", false)
		state = "joining"
		var code: Error = client.call("join_room", params)
		if code != OK:
			_fail("Room join failed (%d)." % code)
	if state in ["connecting", "joining"] and now_us >= _deadline:
		_fail("Connection or room join timed out.")
	if has_readied:
		var route: String = game_match.adapter.status().route
		if route in ["blocked", "restart_required"]:
			_fail("Room membership or transport lifetime changed.")
		elif route in ["relay", "relay_required"] and not game_match.has_started:
			_fail("This example needs an initial WebRTC mesh plan with standby relay.")
		elif route == "mesh" and not game_match.has_started:
			if state == "lobby":
				state = "starting"
				_deadline = now_us + 30000000
			var transport: Object = mesh.call("get_multiplayer_peer")
			if transport != null:
				transport.call("poll")
				var peers: Dictionary = transport.call("get_peers")
				if peers.size() == 1 and peers.values()[0].get("connected", false):
					var started: Error = game_match.start_transport(client, mesh, _config, _info, now_us - _epoch)
					if started != OK:
						_fail("Transport setup failed (%d)." % started)
					else:
						state = "playing"
						message = "Move with WASD or arrow keys. Leave to start a fresh room."
		if state == "starting" and now_us >= _deadline:
			_fail("WebRTC connection timed out. Check your endpoint and ICE configuration.")
	if state == "playing":
		game_match.tick(now_us - _epoch, buttons)
		if not game_match.failure.is_empty():
			_fail(game_match.failure)


func disconnect_room() -> void:
	_closing = true
	game_match.detach()
	if mesh != null:
		mesh.free()
		mesh = null
	if client != null:
		client.call("close", 1000, "Leaving example room")
		client.free()
		client = null
	_config = null
	_info = null
	state = "offline"
	message = "Left the room. Create a new room and share its new code to restart."
	has_readied = false
	all_ready = false
	_closing = false


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
	game_match.detach()
