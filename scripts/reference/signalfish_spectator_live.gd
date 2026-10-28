extends SceneTree

const SDK = preload("res://addons/signal_fish/signal_fish_client.gd")
const SDKConfig = preload("res://addons/signal_fish/signal_fish_config.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const S = preload("res://addons/fortress_rollback/core/session_types.gd")
const Transport = preload("res://addons/fortress_rollback/transport/signalfish_relay_types.gd")
const Stream = preload("res://addons/fortress_rollback/core/spectator_stream.gd")
const Host = preload("res://addons/fortress_rollback/transport/signalfish_spectator_host.gd")
const Relay = preload("res://addons/fortress_rollback/transport/signalfish_spectator_relay.gd")
const Game = preload("res://spectator_live_game.gd")
const FRAMES: int = 48
var clients: Array[SDK] = []
var modes: Array[SDKConfig] = []
var protocol: Dictionary = {}
var ready: Dictionary = {}
var observations: Array[Dictionary] = []
var viewer_uuid: String = ""
var errors: Array[String] = []
var runtime: Dictionary = {}
var started: int = 0
var publication: Host
var relay: Relay
var stream: Stream
var host_session: Session
var host_driver: Driver
var viewer_driver: Driver
var host_game: Game
var viewer_game: Game
var admission: Dictionary = {}
var accept_request: HTTPRequest
var accept_pending: bool = false
var accept_delivered: bool = false
var received: int = 0
var viewer_receives: int = 0
var catchup_steps: int = 0
var paused_frame: int = -1
var provisioning_controls: int = 0
var compared: int = 0
var completed: bool = false
var late_signal: String = ""
var departure: String = ""
var departure_started: bool = false
var departure_observed: bool = false


func _initialize() -> void:
	started = Time.get_ticks_usec()
	_run.call_deferred()


func _process(_delta: float) -> bool:
	for client: SDK in clients:
		client.poll()
	if not completed and Time.get_ticks_usec() - started > 60000000:
		_fail("absolute witness watchdog")
	return false


func _run() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() not in [1, 2]:
		_fail("missing private runtime configuration")
		return
	if args.size() == 2:
		if args[1] in ["host", "viewer"]:
			departure = args[1]
		else:
			late_signal = args[1]
		if departure.is_empty() and late_signal not in ["spectator_join_failed", "spectator_left", "spectator_disconnected"]:
			_fail("unknown late failure control")
			return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	if not parsed is Dictionary:
		_fail("malformed private runtime configuration")
		return
	runtime = parsed
	for index: int in 3:
		var client: SDK = SDK.new()
		clients.append(client)
		var config: SDKConfig = SDKConfig.new()
		config.app_id = "fortress-live-relay"
		config.protocol_version = 3
		config.game_data_format = "message_pack"
		config.decode_msgpack_payloads = false
		config.auto_poll = false
		modes.append(config)
		client.protocol_info.connect(func(info: RefCounted) -> void: protocol[index] = info)
		client.lobby_state_changed.connect(
			func(_state: int, _players: PackedStringArray, all_ready: bool) -> void:
				ready[index] = all_ready
				_observe({"client": index, "lobby": _state})
		)
		client.session_plan.connect(func(_plan: RefCounted) -> void: _observe({"client": index, "plan": true}))
		client.game_starting.connect(func(_peers: Array) -> void: _observe({"client": index, "starting": true}))
		client.spectator_joined.connect(func(info: RefCounted) -> void: viewer_uuid = info.spectator_id)
		for signal_name: String in [
			"protocol_error",
			"server_error",
			"room_join_failed",
			"authentication_error",
			"connection_failed",
			"reconnection_failed",
			"disconnected",
			"going_away",
			"room_left",
			"reconnected",
			"player_reconnected",
			"spectator_join_failed",
			"spectator_left"
		]:
			client.connect(signal_name, func(_a: Variant = null, _b: Variant = null, _c: Variant = null, _d: Variant = null) -> void: _error(signal_name, index))
		client.spectator_disconnected.connect(
			func(id: String, _reason: int, _spectators: Array) -> void:
				if id == viewer_uuid:
					if departure_started and departure == "viewer" and index == 0:
						departure_observed = true
					_error("spectator_disconnected", index)
		)
		client.player_left.connect(
			func(id: String) -> void:
				if departure_started and departure == "host" and index in [1, 2] and id == admission.host:
					departure_observed = departure_observed or index == 2
				else:
					_error("player_left", index)
		)
		client.game_data_binary_received.connect(
			func(_sender: String, _encoding: int, _bytes: PackedByteArray) -> void:
				received += 1
				viewer_receives += 1 if index == 2 else 0
		)
		if client.configure(config) != OK or client.connect_to_server(runtime.endpoint) != OK:
			_fail("SDK connection refused")
			return
	if not await _wait(func() -> bool: return protocol.size() == 3 and clients.all(func(c: SDK) -> bool: return c.is_authenticated()), "SDK login"):
		return
	var room: SDK.JoinRoomParams = SDK.JoinRoomParams.new()
	room.game_name = "fortress-spectator-witness"
	room.player_name = "host"
	room.max_players = 2
	room.supports_authority = false
	clients[0].join_room(room)
	if not await _wait(func() -> bool: return not clients[0].get_room_code().is_empty(), "host room"):
		return
	room = SDK.JoinRoomParams.new()
	room.game_name = "fortress-spectator-witness"
	room.player_name = "remote"
	room.room_code = clients[0].get_room_code()
	clients[1].join_room(room)
	if not await _wait(func() -> bool: return clients[0].get_players().size() == 2, "two seated players"):
		return
	clients[2].join_as_spectator(room.game_name, room.room_code, "viewer")
	if not await _wait(func() -> bool: return not viewer_uuid.is_empty(), "spectator baseline"):
		return
	clients[0].set_ready()
	clients[1].set_ready()
	if not await _wait(func() -> bool: return ready.get(0, false), "seated ready"):
		return
	clients[0].start_game()
	if not await _wait(func() -> bool: return clients[0].get_session_state() == Host.FINALIZED, "finalized host"):
		return
	if clients[2].get_session_state() != Relay.SPECTATING or not clients[2].get_player_id().is_empty() or clients[0].get_players().size() != 2:
		_fail("viewer changed seated membership")
		return
	if not await _configure_playback():
		return
	var deadline: int = Time.get_ticks_usec() + 8000000
	while stream.agreement_version() == 0 and Time.get_ticks_usec() < deadline:
		publication.poll(_now())
		relay.poll(_now(), _send_accept)
		await process_frame
	if stream.agreement_version() == 0:
		_fail("OFFER never reached the real spectator socket")
		return
	var packet: PackedByteArray = stream.encode_accept()
	var wrong: Dictionary = _accept_body(packet)
	wrong.viewer = clients[0].get_player_id()
	var refused: Dictionary = await _http("/accept", runtime.viewer_token, wrong)
	if refused.status != 403:
		_fail("control service accepted another viewer identity")
		return
	while not accept_delivered and Time.get_ticks_usec() < deadline:
		publication.poll(_now())
		relay.poll(_now(), _send_accept)
		await process_frame
	var taken: Dictionary = await _http("/take", runtime.host_token)
	if not taken.body is Dictionary or taken.body.get("viewer") != viewer_uuid:
		_fail("authenticated control acceptance was not delivered")
		return
	if publication.receive_accept(taken.body.viewer, String(taken.body.packet).hex_decode()).code != Transport.Code.OK:
		_fail("host refused authenticated acceptance")
		return
	for frame: int in FRAMES:
		if frame == 12:
			paused_frame = viewer_game.frame
		if frame == 20 and viewer_game.frame != paused_frame:
			_fail("paused viewer advanced buffered rows")
			return
		if frame == 20 and not departure.is_empty():
			await _depart()
			return
		if frame >= 3:
			host_session.receive_input(1, frame - 3, _input(frame - 3, 1))
		var inputs: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, frame, _input(frame, 0))]
		if host_driver.step(_now(), inputs).code != S.Code.OK:
			_fail("host gameplay step")
			return
		for _turn: int in 3:
			publication.poll(_now())
			relay.poll(_now())
			# Hold playback while the host continues, then catch up through actual received rows.
			if frame < 12 or frame >= 20:
				_play_viewer()
			await process_frame
	for frame: int in range(FRAMES - 3, FRAMES):
		host_session.receive_input(1, frame, _input(frame, 1))
	if host_driver.recover(_now()).code != S.Code.OK:
		_fail("host final rollback recovery")
		return
	if host_session.statistics().rollback_count < 1 or host_game.canonical_bytes() != _expected(FRAMES):
		_fail("host did not repair predicted state to original history")
		return
	if publication.finish_host().code != Transport.Code.OK:
		_fail("clean host tail refused")
		return
	deadline = Time.get_ticks_usec() + 8000000
	while not stream.playback_session().is_complete() and Time.get_ticks_usec() < deadline:
		publication.poll(_now())
		relay.poll(_now())
		_play_viewer()
		await process_frame
	if not stream.playback_session().is_complete() or viewer_game.canonical_bytes() != _expected(FRAMES) or compared != FRAMES:
		_fail("spectator canonical final prefix or clean completion")
		return
	match late_signal:
		"spectator_join_failed":
			clients[2].spectator_join_failed.emit("injected", 1)
		"spectator_left":
			clients[2].spectator_left.emit(clients[2].get_room_id(), clients[2].get_room_code(), 0, [])
		"spectator_disconnected":
			clients[0].spectator_disconnected.emit(viewer_uuid, 0, [])
	for _drain: int in 3:
		await process_frame
	var host_status: Dictionary = publication.status()
	var viewer_status: Dictionary = relay.status()
	if (
		host_status.code != Transport.Code.OK
		or viewer_status.code != Transport.Code.OK
		or clients[0].get_players().size() != 2
		or clients[2].get_players().size() != 2
		or not errors.is_empty()
		or viewer_receives < 1
		or catchup_steps < 2
		or host_session.status().confirmed_frame != FRAMES - 1
	):
		_fail("late SDK error or spectator altered host seats")
		return
	completed = true
	print(
		"FORTRESS_LIVE_SPECTATOR_RESULT ",
		JSON.stringify(
			{
				"passed": true,
				"frames": FRAMES,
				"compared": compared,
				"host_rollbacks": host_session.statistics().rollback_count,
				"binary_receives": received,
				"seated_players": 2,
				"viewer_seated": false,
				"viewer_binary_receives": viewer_receives,
				"catchup_steps": catchup_steps,
				"paused_frames": 8,
				"provisioning_controls": provisioning_controls
			}
		)
	)
	_cleanup()
	quit(0)


func _depart() -> void:
	var viewer: RefCounted = stream.playback_session()
	var before: PackedByteArray = viewer_game.canonical_bytes()
	var boundary: int = viewer_game.frame
	var buffered: int = viewer.host_frontier() - boundary + 1
	if buffered < 2 or boundary < 1 or before != _expected(boundary):
		_fail("departure needs real paused canonical buffered history")
		return
	departure_started = true
	var selected: int = 0 if departure == "host" else 2
	clients[selected].close()
	if not await _wait(func() -> bool: return departure_observed, "physical selected participant departure"):
		return
	if clients[selected].get_connection_state() == Relay.CONNECTED:
		_fail("selected socket stayed connected")
		return
	var observed: RefCounted = relay.poll(_now())
	var empty: Array[Driver.LocalInput] = []
	var stopped: RefCounted = viewer_driver.step(_now(), empty)
	if (
		observed.code != Transport.Code.WRONG_STATE
		or viewer.status().lifecycle != S.Lifecycle.TERMINATED
		or viewer.status().reason != S.Code.PROTOCOL_FAILED
		or stopped.code != S.Code.TERMINATED
		or viewer_game.canonical_bytes() != before
		or viewer.status().current_frame != boundary
		or publication.status().code != Transport.Code.WRONG_STATE
		or not errors.is_empty()
	):
		_fail("physical departure allowed buffered playback or publication")
		return
	if departure == "viewer":
		for frame: int in range(17, 20):
			host_session.receive_input(1, frame, _input(frame, 1))
		host_session.receive_input(1, 20, _input(20, 1))
		var inputs: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, 20, _input(20, 0))]
		if host_driver.step(_now(), inputs).code != S.Code.OK or host_game.canonical_bytes() != _expected(21):
			_fail("viewer departure interrupted original host gameplay")
			return
	for _drain: int in 3:
		await process_frame
	if not errors.is_empty() or viewer_game.canonical_bytes() != before or (departure == "viewer" and clients[0].get_players().size() != 2):
		_fail("late SDK failure after physical departure")
		return
	completed = true
	print(
		"FORTRESS_LIVE_SPECTATOR_DEPARTURE ",
		JSON.stringify(
			{
				"passed": true,
				"departure": departure,
				"remote_departure": departure_observed,
				"socket_closed": clients[selected].get_connection_state() != Relay.CONNECTED,
				"buffered_rows": buffered,
				"viewer_frame": boundary,
				"compared": compared,
				"host_frame": host_game.frame,
				"host_continued": departure == "viewer",
				"viewer_binary_receives": viewer_receives
			}
		)
	)
	_cleanup()
	quit(0)


func _configure_playback() -> bool:
	if not clients[0].get_spectators().any(func(info: RefCounted) -> bool: return info.id == viewer_uuid):
		_fail("selected viewer is not in the host SDK spectator roster")
		return false
	var config: Config = _config(false)
	host_session = Session.new()
	host_game = Game.new()
	if host_session.configure(config) != S.Code.OK:
		_fail("host configuration")
		return false
	host_driver = Driver.new(host_session, host_game)
	var viewer_config: Config = _config(true)
	var initial: PackedByteArray = host_game.canonical_bytes()
	var digest: PackedByteArray = Stream.configuration_digest_with_state(viewer_config, "1701", "live-spectator-v1", initial)
	admission = {
		"viewer": viewer_uuid,
		"host": clients[0].get_player_id(),
		"room": clients[0].get_room_id(),
		"identity": runtime.identity,
		"key": runtime.key,
		"digest": digest.hex_encode(),
		"initial_state": initial.hex_encode(),
		"players": 2,
		"width": 1,
		"neutral": "00",
		"seed": "1701",
		"rules": "live-spectator-v1"
	}
	var response: Dictionary = await _http("/admit", runtime.host_token, admission)
	if response.status != 200:
		_fail("authenticated admission refused")
		return false
	response = await _http("/admission", "wrong-capability")
	if response.status != 403:
		_fail("control service leaked admission to foreign capability")
		return false
	response = await _http("/admission", runtime.viewer_token)
	if response.status != 200 or not response.body is Dictionary:
		_fail("authenticated initial-state provisioning")
		return false
	admission = response.body
	if not _valid_admission(viewer_config):
		_fail("incompatible admitted initial state or configuration")
		return false
	var healthy: Dictionary = admission.duplicate(true)
	for fault: Dictionary in [
		{"initial_state": "ff".repeat(24)}, {"seed": "1702"}, {"rules": "another-game"}, {"neutral": "01"}, {"players": 3}, {"width": 2}, {"digest": "00".repeat(16)}
	]:
		admission = healthy.duplicate(true)
		admission.merge(fault, true)
		if _valid_admission(viewer_config):
			_fail("altered admitted configuration was accepted")
			return false
		provisioning_controls += 1
	admission = healthy
	digest = String(admission.digest).hex_decode()
	stream = Stream.new()
	if stream.configure(viewer_config, String(admission.identity).hex_decode(), String(admission.key).hex_decode(), digest, _now(), 10000000, 1024) != S.Code.OK:
		_fail("spectator stream configuration")
		return false
	stream.playback_session().set_playback(2, 3, 4)
	viewer_game = Game.new()
	viewer_driver = Driver.new(stream.playback_session(), viewer_game)
	publication = Host.new()
	var outgoing: Host.Options = Host.Options.new()
	outgoing.max_packet_bytes = 1024
	var publication_code: int = publication.configure(
		clients[0], modes[0], protocol[0], host_session, viewer_uuid, String(admission.identity).hex_decode(), String(admission.key).hex_decode(), digest, outgoing
	)
	if publication_code != Transport.Code.OK:
		_observe({"publication_code": publication_code, "protocol": protocol[0].to_dict()})
		_fail("actual SDK host publication configuration")
		return false
	relay = Relay.new()
	var incoming: Relay.Options = Relay.Options.new()
	incoming.max_packet_bytes = 1024
	if relay.configure(clients[2], modes[2], protocol[2], stream, clients[0].get_player_id(), incoming) != Transport.Code.OK:
		_fail("actual SDK spectator relay configuration")
		return false
	return true


func _valid_admission(config: Config) -> bool:
	for field: String in ["viewer", "host", "room", "identity", "key", "digest", "initial_state", "neutral", "seed", "rules"]:
		if not admission.get(field) is String:
			return false
	if admission.get("players") != 2 or admission.get("width") != 1 or admission.neutral != "00":
		return false
	if admission.viewer != viewer_uuid or admission.host != clients[0].get_player_id() or admission.room != clients[2].get_room_id():
		return false
	if admission.seed != "1701" or admission.rules != "live-spectator-v1" or admission.initial_state != _expected(0).hex_encode():
		return false
	var digest: PackedByteArray = Stream.configuration_digest_with_state(config, admission.seed, admission.rules, String(admission.initial_state).hex_decode())
	return digest.hex_encode() == admission.digest


func _config(spectator: bool) -> Config:
	var config: Config = Config.new()
	config.spectator = spectator
	config.sync_test = false
	config.input_delay = 0
	config.local_players = PackedInt32Array() if spectator else PackedInt32Array([0])
	config.max_prediction_frames = 0 if spectator else 8
	config.check_distance = 0
	config.queue_capacity = 64
	config.history_slots = 1 if spectator else 12
	config.max_snapshot_bytes = 24
	config.storage_budget_bytes = config.required_storage_bytes()
	return config


func _send_accept(packet: PackedByteArray) -> Error:
	if accept_delivered:
		return OK
	if not accept_pending:
		accept_pending = true
		accept_request = HTTPRequest.new()
		accept_request.timeout = 3.0
		root.add_child(accept_request)
		accept_request.request_completed.connect(
			func(_result: int, status: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
				accept_delivered = status == 200
				if not accept_delivered:
					_error("control acceptance HTTP failure")
				accept_request.queue_free()
		)
		var code: Error = accept_request.request(
			runtime.control + "/accept", PackedStringArray(["Authorization: Bearer " + runtime.viewer_token]), HTTPClient.METHOD_POST, JSON.stringify(_accept_body(packet))
		)
		if code != OK:
			return code
	return ERR_BUSY


func _accept_body(packet: PackedByteArray) -> Dictionary:
	return {"viewer": viewer_uuid, "room": admission.room, "identity": admission.identity, "packet": packet.hex_encode()}


func _http(path: String, token: String, body: Dictionary = {}) -> Dictionary:
	var request: HTTPRequest = HTTPRequest.new()
	root.add_child(request)
	request.timeout = 3.0
	var code: Error = request.request(
		runtime.control + path,
		PackedStringArray(["Authorization: Bearer " + token, "Content-Type: application/json"]),
		HTTPClient.METHOD_GET if body.is_empty() else HTTPClient.METHOD_POST,
		"" if body.is_empty() else JSON.stringify(body)
	)
	if code != OK:
		request.queue_free()
		return {"status": 0, "body": {}}
	var result: Array = await request.request_completed
	request.queue_free()
	return {"status": result[1], "body": JSON.parse_string(result[3].get_string_from_utf8())}


func _play_viewer() -> void:
	var empty: Array[Driver.LocalInput] = []
	var steps: int = stream.playback_session().recommended_steps()
	catchup_steps = maxi(catchup_steps, steps)
	for _index: int in steps:
		var result: RefCounted = viewer_driver.step(_now(), empty)
		if result.code not in [S.Code.OK, S.Code.TERMINATED]:
			_error("viewer driver failure")
			return
		if result.code == S.Code.OK:
			compared += 1
			if viewer_game.canonical_bytes() != _expected(viewer_game.frame):
				_error("viewer changed original confirmed history")


func _input(frame: int, player: int) -> PackedByteArray:
	return PackedByteArray([((frame * (3 if player == 0 else 7)) % 8) + 1])


func _expected(frame: int) -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(24)
	bytes.encode_s64(0, frame)
	for player: int in 2:
		var total: int = 0
		for tick: int in frame:
			total += _input(tick, player)[0] * (tick + 1)
		bytes.encode_s64(8 + player * 8, total)
	return bytes


func _now() -> int:
	return Time.get_ticks_usec() - started


func _wait(condition: Callable, label: String) -> bool:
	var deadline: int = Time.get_ticks_usec() + 8000000
	while Time.get_ticks_usec() < deadline and errors.is_empty():
		if condition.call():
			return true
		await process_frame
	_fail("timed out: " + label)
	return false


func _observe(value: Dictionary) -> void:
	if observations.size() < 32:
		observations.append(value)
	else:
		_error("SDK event inventory overflow")


func _error(reason: String, index: int = -1) -> void:
	if departure_started:
		if reason == "disconnected" and index == (0 if departure == "host" else 2):
			return
		if departure == "viewer" and reason == "spectator_disconnected" and index in [0, 1]:
			return
	if not completed and errors.size() < 8:
		errors.append(reason)


func _fail(reason: String) -> void:
	if completed:
		return
	completed = true
	print(
		"FORTRESS_LIVE_SPECTATOR_FAILED ",
		JSON.stringify({"reason": reason, "errors": errors, "observations": observations, "states": clients.map(func(c: SDK) -> int: return c.get_session_state())})
	)
	_cleanup()
	quit(1)


func _cleanup() -> void:
	if relay != null:
		relay.detach()
	if publication != null:
		publication.detach()
	for client: SDK in clients:
		client.close()
		client.free()
	clients.clear()
