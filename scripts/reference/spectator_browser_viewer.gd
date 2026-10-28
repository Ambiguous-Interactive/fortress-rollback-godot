extends Node

const SDK = preload("res://addons/signal_fish/signal_fish_client.gd")
const SDKConfig = preload("res://addons/signal_fish/signal_fish_config.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const S = preload("res://addons/fortress_rollback/core/session_types.gd")
const T = preload("res://addons/fortress_rollback/transport/signalfish_relay_types.gd")
const Stream = preload("res://addons/fortress_rollback/core/spectator_stream.gd")
const Relay = preload("res://addons/fortress_rollback/transport/signalfish_spectator_relay.gd")
const Game = preload("res://spectator_live_game.gd")
var client: SDK
var config: SDKConfig
var protocol: RefCounted
var stream: Stream
var relay: Relay
var driver: Driver
var game: Game
var runtime: Dictionary
var admission: Dictionary
var errors: Array[String] = []
var viewer_uuid: String = ""
var started: int = 0
var completed: bool = false
var receives: int = 0
var compared: int = 0
var accept_pending: bool = false
var accept_delivered: bool = false
var catchup: int = 0
var paused_turns: int = 0
var paused_frame: int = -1
var paused_rows: int = 0


func _ready() -> void:
	started = Time.get_ticks_usec()
	runtime = JSON.parse_string(JavaScriptBridge.eval("JSON.stringify(window.fortressSpectatorRuntime)"))
	_run()


func _process(_delta: float) -> void:
	if client != null:
		client.poll()
	if not completed and Time.get_ticks_usec() - started >= 55000000:
		_fail("browser absolute watchdog")


func _run() -> void:
	client = SDK.new()
	config = SDKConfig.new()
	config.app_id = "fortress-live-relay"
	config.protocol_version = 3
	config.game_data_format = "message_pack"
	config.decode_msgpack_payloads = false
	config.auto_poll = false
	client.protocol_info.connect(func(info: RefCounted) -> void: protocol = info)
	client.spectator_joined.connect(func(info: RefCounted) -> void: viewer_uuid = info.spectator_id)
	client.game_data_binary_received.connect(func(_sender: String, _encoding: int, _bytes: PackedByteArray) -> void: receives += 1)
	for name: String in [
		"protocol_error",
		"server_error",
		"authentication_error",
		"connection_failed",
		"disconnected",
		"spectator_join_failed",
		"spectator_left",
		"going_away",
		"reconnection_failed",
		"reconnected",
		"room_left",
		"room_join_failed"
	]:
		client.connect(name, func(_a: Variant = null, _b: Variant = null, _c: Variant = null, _d: Variant = null) -> void: _error(name))
	if client.configure(config) != OK or client.connect_to_server(runtime.endpoint) != OK:
		_fail("browser SDK configuration")
		return
	if not await _wait(func() -> bool: return protocol != null and client.is_authenticated()):
		return
	var response: Dictionary = await _until("/room")
	if response.status != 200:
		return
	client.join_as_spectator(response.body.game, response.body.code, "exported-viewer")
	if not await _wait(func() -> bool: return not viewer_uuid.is_empty()):
		return
	response = await _http("/viewer", {"viewer": viewer_uuid})
	if response.status != 200:
		_fail("browser viewer registration")
		return
	response = await _until("/admission")
	if response.status != 200:
		return
	admission = response.body
	var playback: Config = Config.new()
	playback.spectator = true
	playback.sync_test = false
	playback.input_delay = 0
	playback.local_players = PackedInt32Array()
	playback.max_prediction_frames = 0
	playback.check_distance = 0
	playback.queue_capacity = 64
	playback.history_slots = 1
	playback.max_snapshot_bytes = 24
	playback.storage_budget_bytes = playback.required_storage_bytes()
	var digest: PackedByteArray = Stream.configuration_digest_with_state(playback, "1701", "live-spectator-v1", _expected(0))
	if (
		admission.viewer != viewer_uuid
		or admission.room != client.get_room_id()
		or admission.initial_state != _expected(0).hex_encode()
		or admission.digest != digest.hex_encode()
		or admission.players != 2
		or admission.width != 1
		or admission.neutral != "00"
		or admission.seed != "1701"
		or admission.rules != "live-spectator-v1"
		or client.get_player_id() != ""
		or client.get_players().size() != 2
	):
		_fail("browser original-state or membership binding")
		return
	stream = Stream.new()
	if stream.configure(playback, String(admission.identity).hex_decode(), String(admission.key).hex_decode(), digest, _now(), 10000000, 1024) != S.Code.OK:
		_fail("browser stream configuration")
		return
	stream.playback_session().set_playback(2, 3, 4)
	game = Game.new()
	driver = Driver.new(stream.playback_session(), game)
	relay = Relay.new()
	var options: Relay.Options = Relay.Options.new()
	options.max_packet_bytes = 1024
	if relay.configure(client, config, protocol, stream, admission.host, options) != T.Code.OK:
		_fail("browser relay configuration")
		return
	while not stream.playback_session().is_complete() and errors.is_empty():
		var polled: RefCounted = relay.poll(_now(), _accept)
		if polled.code not in [T.Code.OK, T.Code.BACKPRESSURE]:
			_fail("browser relay poll")
			return
		# Hold a real buffered tail, then resume through bounded catch-up.
		if game.frame >= 8 and paused_turns < 12:
			if paused_frame < 0:
				paused_frame = game.frame
			if paused_frame != game.frame:
				_fail("browser paused history advanced")
				return
			paused_rows = maxi(paused_rows, stream.playback_session().host_frontier() - game.frame + 1)
			paused_turns += 1
		else:
			var steps: int = stream.playback_session().recommended_steps()
			catchup = maxi(catchup, steps)
			for _step: int in steps:
				var empty: Array[Driver.LocalInput] = []
				var result: RefCounted = driver.step(_now(), empty)
				if result.code not in [S.Code.OK, S.Code.TERMINATED]:
					_fail("browser playback step")
					return
				if result.code == S.Code.OK:
					compared += 1
					if game.canonical_bytes() != _expected(game.frame):
						_fail("browser original canonical history")
						return
		await get_tree().process_frame
	for _drain: int in 3:
		await get_tree().process_frame
	if (
		not errors.is_empty()
		or relay.status().code != T.Code.OK
		or compared != 48
		or game.frame != 48
		or receives < 1
		or catchup < 2
		or paused_turns != 12
		or paused_rows < 2
		or game.canonical_bytes() != _expected(48)
	):
		_fail("browser final audit")
		return
	response = await _http("/done", {"complete": true})
	if response.status != 200 or not errors.is_empty() or relay.status().code != T.Code.OK:
		_fail("browser completion acknowledgment")
		return
	completed = true
	JavaScriptBridge.eval(
		(
			"window.fortressSpectatorResult="
			+ JSON.stringify(
				{
					"passed": true,
					"frames": game.frame,
					"compared": compared,
					"viewer_binary_receives": receives,
					"catchup_steps": catchup,
					"paused_turns": paused_turns,
					"paused_rows": paused_rows,
					"viewer_seated": false
				}
			)
		)
	)
	_cleanup()


func _accept(packet: PackedByteArray) -> Error:
	if accept_delivered:
		return OK
	if not accept_pending:
		accept_pending = true
		_post_accept(packet)
	return ERR_BUSY


func _post_accept(packet: PackedByteArray) -> void:
	var response: Dictionary = await _http("/accept", {"viewer": viewer_uuid, "room": admission.room, "identity": admission.identity, "packet": packet.hex_encode()})
	accept_delivered = response.status == 200
	if not accept_delivered:
		errors.append("browser control ACCEPT failure")


func _until(path: String) -> Dictionary:
	var deadline: int = _now() + 15000000
	while _now() < deadline and errors.is_empty():
		var response: Dictionary = await _http(path)
		if response.status == 200:
			return response
		if response.status != 404:
			break
		await get_tree().process_frame
	_fail("browser provisioning deadline " + path)
	return {"status": 0}


func _http(path: String, body: Dictionary = {}) -> Dictionary:
	var request: HTTPRequest = HTTPRequest.new()
	add_child(request)
	request.timeout = 3.0
	var code: Error = request.request(
		runtime.control + path,
		PackedStringArray(["Authorization: Bearer " + runtime.viewer_token, "Content-Type: application/json"]),
		HTTPClient.METHOD_GET if body.is_empty() else HTTPClient.METHOD_POST,
		"" if body.is_empty() else JSON.stringify(body)
	)
	if code != OK:
		request.queue_free()
		return {"status": 0}
	var response: Array = await request.request_completed
	request.queue_free()
	return {"status": response[1], "body": JSON.parse_string(response[3].get_string_from_utf8())}


func _wait(condition: Callable) -> bool:
	var deadline: int = _now() + 15000000
	while _now() < deadline and errors.is_empty():
		if condition.call():
			return true
		await get_tree().process_frame
	_fail("browser SDK deadline")
	return false


func _expected(frame: int) -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(24)
	bytes.encode_s64(0, frame)
	for player: int in 2:
		var total: int = 0
		for tick: int in frame:
			total += (((tick * (3 if player == 0 else 7)) % 8) + 1) * (tick + 1)
		bytes.encode_s64(8 + player * 8, total)
	return bytes


func _now() -> int:
	return Time.get_ticks_usec() - started


func _fail(reason: String) -> void:
	if completed:
		return
	completed = true
	JavaScriptBridge.eval("window.fortressSpectatorResult=" + JSON.stringify({"passed": false, "reason": reason, "errors": errors}))
	_cleanup()


func _cleanup() -> void:
	if relay != null:
		relay.detach()
	if client != null:
		client.close()
		client.free()
		client = null


func _error(reason: String) -> void:
	if not completed and errors.size() < 8:
		errors.append(reason)
