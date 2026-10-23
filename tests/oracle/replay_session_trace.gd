extends SceneTree

const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
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

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		if frame != state[0]:
			return false
		var observed: Array[Dictionary] = []
		for slot: int in range(inputs.size().value):
			var input: Types.InputResult = inputs.read(slot)
			if input.code != Types.Code.OK or input.bytes.size() != 4:
				return false
			var value: int = input.bytes.decode_u32(0)
			observed.append({"value": value, "status": "confirmed" if input.status == Queue.Status.CONFIRMED else "unexpected"})
			state[1] = (state[1] * 33 + value + slot) & 0xffffffff
			state[2] = (state[2] * 1664525 + 1013904223) & 0xffffffff
			state[3] = ((state[3] + state[1]) & 0xffffffff) ^ state[2]
		state[0] += 1
		records.append({"kind": "advance", "frame": frame, "bytes": bytes().hex_encode(), "inputs": observed})
		return true


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() != 2 or args[0] != "--bundle":
		_fail("expected --bundle PATH")
		return
	var file: FileAccess = FileAccess.open(args[1], FileAccess.READ)
	if file == null or file.get_length() > 2097152:
		_fail("invalid bundle file")
		return
	var parser: JSON = JSON.new()
	if parser.parse(file.get_as_text()) != OK or not parser.data is Array or parser.data.is_empty() or parser.data.size() > 64:
		_fail("invalid bundle")
		return
	var results: Array[Dictionary] = []
	for value: Variant in parser.data:  # JSON input is checked before constructing production objects.
		if not value is Dictionary or value.size() != 4:
			_fail("invalid case")
			return
		if not value.get("name") is String or not value.get("validate") is bool or not value.get("replay") is String:
			_fail("invalid case fields")
			return
		if not value.get("seed") is float or value.seed != floor(value.seed) or value.seed < 0 or value.seed > 0xffffffff:
			_fail("invalid seed")
			return
		if value.replay.length() % 2 != 0 or value.replay.length() > 1048576 or value.replay != value.replay.hex_decode().hex_encode():
			_fail("invalid replay hex")
			return
		var replay: Replay = Replay.new()
		if replay.decode(value.replay.hex_decode()) != Replay.DecodeCode.OK or replay.frame_count() > 64 or replay.input_width() != 4:
			_fail("invalid replay")
			return
		for expert: bool in [false, true]:
			var result: Dictionary = _play(replay, int(value.seed), value.validate, expert)
			if result.is_empty():
				_fail("configure failed")
				return
			result.name = value.name + ("-expert" if expert else "")
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
	for attempt: int in range(replay.frame_count() + 1):
		code = _expert_step(player, game) if expert else player.step()
		if code != Types.Code.OK:
			break
	return {"initial_frame": 0, "current_frame": player.current_frame(),
		"complete": player.is_complete(), "code": code, "failure_frame": player.failure_frame(),
		"records": game.records, "bytes": game.bytes().hex_encode()}


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
