extends SceneTree

const Tokens = preload("res://tests/oracle/replay_json_tokens.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Reader = preload("res://addons/fortress_rollback/core/snapshot_reader.gd")
const Writer = preload("res://addons/fortress_rollback/core/snapshot_writer.gd")


class Game:
	extends RefCounted
	var state: PackedInt64Array = PackedInt64Array([0, 0, 0, 0])
	var records: Array[Dictionary] = []

	func bytes() -> PackedByteArray:
		var result: PackedByteArray = PackedByteArray()
		result.resize(16)
		for index: int in range(4):
			result.encode_u32(index * 4, state[index])
		return result

	func save_state(frame: int, writer: Writer) -> Driver.SaveResult:
		records.append({"kind": "save", "frame": frame, "bytes": bytes().hex_encode(), "inputs": []})
		writer.write_bytes(bytes())
		return Driver.SaveResult.new(true, bytes())

	func load_state(_frame: int, reader: Reader) -> bool:
		var loaded: Reader.ReadResult = reader.read_bytes(16)
		if loaded.code != Reader.Code.OK:
			return false
		for index: int in 4:
			state[index] = loaded.bytes.decode_u32(index * 4)
		return true

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		if frame != state[0]:
			return false
		var observed: Array[Dictionary] = []
		for slot: int in range(inputs.size().value):
			var input: Types.InputResult = inputs.read(slot)
			if input.code != Types.Code.OK or input.bytes.size() != 4:
				return false
			var value: int = input.bytes.decode_u32(0)
			var status: String = "unknown:%d" % input.status
			match input.status:
				Queue.Status.CONFIRMED:
					status = "confirmed"
				Queue.Status.PREDICTED:
					status = "predicted"
				Queue.Status.DISCONNECTED:
					status = "disconnected"
			observed.append({"value": value, "status": status})
			state[1] = (state[1] * 33 + value + slot) & 0xffffffff
			state[2] = (state[2] * 1664525 + 1013904223) & 0xffffffff
			state[3] = ((state[3] + state[1]) & 0xffffffff) ^ state[2]
		state[0] += 1
		records.append({"kind": "advance", "frame": frame, "bytes": bytes().hex_encode(), "inputs": observed})
		return true


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() != 2 or args[0] not in ["--bundle", "--recording"]:
		_fail("expected --bundle PATH")
		return
	var file: FileAccess = FileAccess.open(args[1], FileAccess.READ)
	if file == null or file.get_length() > 2097152:
		_fail("invalid bundle file")
		return
	var bundle_text: String = file.get_as_text()
	var token_error: String = Tokens.validate(bundle_text, true)
	if not token_error.is_empty():
		_fail(token_error)
		return
	var parser: JSON = JSON.new()
	if parser.parse(bundle_text) != OK or not parser.data is Array or parser.data.is_empty() or parser.data.size() > 64:
		_fail("invalid bundle")
		return
	if args[0] == "--recording":
		var recorded: Array[Dictionary] = []
		for value: Variant in parser.data:  # Checked recording-only schema precedes every conversion.
			if not _valid_recording_case(value):
				_fail("invalid recording case")
				return
			var result: Dictionary = _record(value)
			if result.is_empty():
				_fail("recording failed")
				return
			recorded.append(result)
		print("FORTRESS_REPLAY_RESULT " + JSON.stringify({"format": 1, "cases": recorded}))
		quit(0)
		return
	var results: Array[Dictionary] = []
	for value: Variant in parser.data:  # JSON input is checked before constructing production objects.
		if not value is Dictionary or value.size() != 6:
			_fail("invalid case")
			return
		if (
			not value.get("name") is String
			or not value.get("validate") is bool
			or not value.get("replay") is String
			or not value.get("replay_v4") is String
			or not value.get("replay_v6") is String
		):
			_fail("invalid case fields")
			return
		if not value.get("seed") is float or value.seed != floor(value.seed) or value.seed < 0 or value.seed > 0xffffffff:
			_fail("invalid seed")
			return
		for version: int in [5, 4, 6]:
			var text: String = value.replay if version == 5 else (value.replay_v4 if version == 4 else value.replay_v6)
			if text.length() % 2 != 0 or text.length() > 1048576 or text != text.hex_decode().hex_encode():
				_fail("invalid replay hex")
				return
			var replay: Replay = Replay.new()
			if replay.decode(text.hex_decode()) != Replay.DecodeCode.OK or replay.frame_count() > 64 or replay.input_width() != 4:
				_fail("invalid replay")
				return
			if replay._format_version != version:
				_fail("invalid replay version")
				return
			for expert: bool in [false, true]:
				var result: Dictionary = _play(replay, int(value.seed), value.validate, expert)
				if result.is_empty():
					_fail("configure failed")
					return
				result.name = value.name + ("-v%d" % version if version != 5 else "") + ("-expert" if expert else "")
				results.append(result)
	print("FORTRESS_REPLAY_RESULT " + JSON.stringify({"format": 1, "cases": results}))
	quit(0)


func _play(replay: Replay, seed: int, validate: bool, expert: bool) -> Dictionary:
	var game: Game = Game.new()
	game.state[1] = seed
	game.state[2] = seed
	var player: Player = Player.new()
	var bound: int = 16 if validate else 0
	var code: int = player.configure_expert(replay, bound) if expert else player.configure(replay, game, bound)
	if code != Types.Code.OK:
		return {}
	for attempt: int in range(replay.frame_count() + (2 if replay._format_version == 6 else 1)):
		code = _expert_step(player, game) if expert else player.step()
		if code != Types.Code.OK:
			break
	return {
		"initial_frame": 0,
		"current_frame": player.current_frame(),
		"complete": player.is_complete(),
		"format_version": replay._format_version,
		"code": code,
		"failure_frame": player.failure_frame(),
		"records": game.records,
		"bytes": game.bytes().hex_encode()
	}


func _expert_step(player: Player, game: Game) -> int:
	var result: Types.Result = player.begin_advance()
	if result.code != Types.Code.READY:
		return result.code
	while true:
		var request: Types.Request = result.batch.next_request()
		if request == null:
			return Types.Code.OK
		var checksum: PackedByteArray = PackedByteArray()
		var ok: bool = false
		match request.kind:
			Types.Kind.SAVE:
				var saved: Driver.SaveResult = game.save_state(request.frame, request.writer)
				ok = saved.ok
				checksum = saved.checksum
			Types.Kind.ADVANCE:
				ok = game.simulate_frame(request.frame, request.inputs)
			_:
				return Types.Code.UNSUPPORTED
		var completed: Types.Result = player.complete_request(request.batch_id, request.request_id, ok, checksum)
		if completed.code != Types.Code.OK:
			return completed.code
	return Types.Code.OK


func _fail(message: String) -> void:
	printerr(message)
	quit(1)


func _valid_recording_case(value: Variant) -> bool:  # External JSON can contain arbitrary types.
	if not value is Dictionary or value.size() != 6 or not value.get("name") is String:
		return false
	for field: String in ["players", "count", "delay", "prediction", "seed"]:
		if not value.get(field) is float or value[field] != floor(value[field]):
			return false
	return (
		value.players >= 2 and value.players <= 8 and value.count >= 0 and value.count <= 64
		and value.delay >= 0 and value.delay <= 2 and value.prediction in [0.0, 2.0] and value.seed >= 0 and value.seed <= 0xffffffff
	)


func _record(value: Dictionary) -> Dictionary:
	var config: Config = Config.new()
	config.player_count = int(value.players)
	config.input_width = 4
	config.neutral_input = PackedByteArray([0, 0, 0, 0])
	config.sync_test = false
	config.check_distance = 0
	config.input_delay = int(value.delay)
	config.max_prediction_frames = int(value.prediction)
	config.max_snapshot_bytes = 16
	config.replay_max_frames = 66
	config.diagnostic_seed = str(int(value.seed))
	config.diagnostic_version = "recording-parity-v1"
	config.local_players.clear()
	for slot: int in config.player_count:
		config.local_players.append(slot)
	config.storage_budget_bytes = config.required_storage_bytes()
	var session: Session = Session.new()
	if session.configure(config) != Types.Code.OK:
		return {}
	var game: Game = Game.new()
	game.state[1] = int(value.seed)
	game.state[2] = int(value.seed)
	var driver: Driver = Driver.new(session, game)
	for frame: int in int(value.count):
		var samples: Array[Driver.LocalInput] = []
		for slot: int in config.player_count:
			var bytes: PackedByteArray = PackedByteArray([0, 0, 0, 0])
			bytes.encode_u32(0, (int(value.seed) + frame * 1234567 + slot * 0x1020304) & 0xffffffff)
			samples.append(Driver.LocalInput.new(slot, frame, bytes))
		if driver.step(frame, samples).code != Types.Code.OK:
			return {}
	var replay: Replay = session.replay()
	var decoded: Replay = Replay.new()
	if decoded.decode(replay.to_bytes()) != Replay.DecodeCode.OK or decoded.to_bytes() != replay.to_bytes():
		return {}
	var rows: Array[Array] = []
	var checksums: Array = []  # JSON checksum evidence is null or a hexadecimal string.
	for frame: int in decoded.frame_count():
		var row: Array[int] = []
		var inputs: Types.FrameInputs = decoded.inputs(frame)
		for slot: int in decoded.player_count():
			var input: Types.InputResult = inputs.read(slot)
			if input.status != Queue.Status.CONFIRMED:
				return {}
			row.append(input.bytes.decode_u32(0))
		rows.append(row)
		var checksum: PackedByteArray = decoded.checksum(frame)
		checksums.append(null if checksum.is_empty() else checksum.hex_encode())
	var advances: Array[String] = []
	var saves: Array[int] = []
	for record: Dictionary in game.records:
		if record.kind == "save":
			saves.append(int(record.frame))
		else:
			advances.append(record.bytes)
	var played: Dictionary = _play(decoded, int(value.seed), true, false)
	played.name = value.name
	return {"name": value.name, "frames": rows, "checksums": checksums, "skipped": decoded.skipped_frames(),
		"players": decoded.player_count(), "total_frames": decoded.frame_count(), "records": game.records, "advances": advances, "saves": saves, "playback": played}
