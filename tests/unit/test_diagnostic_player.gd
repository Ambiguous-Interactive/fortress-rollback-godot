extends RefCounted

# Value: protects=offline captured-window reproduction; fails_when=consumer skips canonical prefixes, accepts malformed gaps or retains callback views;
# why_new=trace tests manually replay fixture bytes without a shipped consumer; seam=none
const Player = preload("res://addons/fortress_rollback/core/diagnostic_player.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const SnapshotStatus = preload("res://addons/fortress_rollback/core/snapshot_status.gd")
const Game = preload("res://examples/offline/simulation.gd")


class ObservedGame:
	extends Game
	var observed: PackedInt32Array = PackedInt32Array()

	func simulate_frame(frame_number: int, inputs: Types.FrameInputs) -> bool:
		for slot: int in range(inputs.size().value):
			observed.append(inputs.read(slot).status)
		return super.simulate_frame(frame_number, inputs)


class ChangedRules:
	extends Game

	func simulate_frame(frame_number: int, inputs: Types.FrameInputs) -> bool:
		var ok: bool = super.simulate_frame(frame_number, inputs)
		if frame_number == 5:
			x[0] += 1
		return ok


class HostileCallback:
	extends Game
	var mode: String = ""
	var player: WeakRef
	var view: RefCounted
	var reentry: Array[int] = []

	func _reenter() -> void:
		if player != null:
			reentry.append(player.get_ref().step())
			reentry.append(player.get_ref().configure({}, self, SNAPSHOT_BYTES))

	func load_state(frame_number: int, reader: RefCounted) -> bool:
		_reenter()
		view = reader
		if mode == "load_trailing":
			return true
		if mode == "load_underflow":
			reader.read_bytes(SNAPSHOT_BYTES + 1)
			return true
		return mode != "load_failed" and super.load_state(frame_number, reader)

	func save_state(frame_number: int, writer: RefCounted) -> Driver.SaveResult:
		_reenter()
		view = writer
		if mode == "save_overflow":
			var bytes: PackedByteArray = canonical_bytes()
			bytes.append(0)
			writer.write_bytes(bytes)
			return Driver.SaveResult.new()
		var saved: Driver.SaveResult = super.save_state(frame_number, writer) if mode != "save_failed" else Driver.SaveResult.new(false)
		if mode in ["save_empty_checksum", "save_wide_checksum"]:
			saved.checksum.resize(0 if mode == "save_empty_checksum" else 17)
		return saved

	func simulate_frame(frame_number: int, inputs: Types.FrameInputs) -> bool:
		_reenter()
		view = inputs
		return mode != "advance_failed" and super.simulate_frame(frame_number, inputs)


func cases() -> PackedStringArray:
	return PackedStringArray(["captured_window", "canonical_mismatch", "malformed", "callbacks", "bounds"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"captured_window":
			_captured(context)
		"canonical_mismatch":
			_mismatch(context)
		"malformed":
			_malformed(context)
		"callbacks":
			_callbacks(context)
		"bounds":
			_bounds(context)
	context.finish()


func _capture(limit: int = 8, count: int = 10) -> Dictionary:
	var config: Config = Config.new()
	config.max_snapshot_bytes = Game.SNAPSHOT_BYTES
	config.storage_budget_bytes = 1048576
	config.diagnostic_trace_frames = limit
	config.diagnostic_version = "fortress-online-integer-v1"
	var session: Session = Session.new()
	session.configure(config)
	var driver: Driver = Driver.new(session, Game.new())
	for frame: int in range(count):
		var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, frame, PackedByteArray([2 if frame % 2 else 8])), Driver.LocalInput.new(1, frame, PackedByteArray([1]))]
		driver.step(frame, samples)
	return session.diagnostic_trace()


func _captured(context: RefCounted) -> void:
	var trace: Dictionary = _capture()
	# Exercise the real browser download/JSON numeric conversion boundary.
	trace = JSON.parse_string(JSON.stringify(trace))
	trace.frames[0].inputs[0].status = 2
	var game: ObservedGame = ObservedGame.new()
	var player: Player = Player.new()
	context.equal(player.configure(trace, game, Game.SNAPSHOT_BYTES), Types.Code.OK, "configure captured rolling window")
	context.equal(trace.frames[0].frame, 2, "begins after initial state")
	var expected: PackedByteArray = trace.frames[1].state.hex_decode()
	trace.frames[1].state = "00"
	context.equal(player.step(), Types.Code.OK, "restore initial captured boundary and advance")
	context.equal(game.observed, PackedInt32Array([2, 1]), "captured prediction statuses preserved")
	context.bytes_equal(game.canonical_bytes(), expected, 3, "reproduces independently captured next boundary")
	while not player.is_complete():
		if player.step() != Types.Code.OK:
			break
	context.equal(player.is_complete(), true, "bounded capture reproduced")
	context.equal(player.report().validated_states, 8, "every canonical prefix checked")
	context.equal(player.report().advanced_frames, 8, "every recorded input applied")
	context.equal(player.step(), Types.Code.FRAME_EXHAUSTED, "completion is stable")
	context.state(game.frame, game.canonical_bytes())
	trace = _capture()
	trace.frames[1].state_available = false
	trace.frames[1].state = ""
	trace.frames[1].checksum = ""
	trace.frames[-1].inputs = []
	context.equal(player.configure(trace, Game.new(), Game.SNAPSHOT_BYTES), Types.Code.OK, "intermediate input-only and terminal SAVE supported")
	for index: int in range(8):
		context.equal(player.step(), Types.Code.OK, "reproduce across missing SAVE without skipping input")
	context.equal(player.report().validated_states, 7, "only actual retained states counted")
	context.equal(player.report().advanced_frames, 7, "terminal SAVE without successful ADVANCE is not applied")


func _mismatch(context: RefCounted) -> void:
	var trace: Dictionary = _capture()
	var player: Player = Player.new()
	context.equal(player.configure(trace, ChangedRules.new(), Game.SNAPSHOT_BYTES), Types.Code.OK, "changed game accepted for diagnosis")
	for frame: int in range(2, 6):
		context.equal(player.step(), Types.Code.OK, "matching prefix before changed rule")
	context.equal(player.step(), Types.Code.DESYNC, "localizes first changed canonical boundary")
	context.equal(player.report().failure, {"frame": 6, "kind": "state", "byte": 24, "expected_bytes": 136, "actual_bytes": 136}, "reports first differing byte")
	context.equal(player.step(), Types.Code.DESYNC, "failure latched")
	trace.frames[2].checksum = "00".repeat(16)
	context.equal(player.configure(trace, Game.new(), Game.SNAPSHOT_BYTES), Types.Code.OK, "configure checksum disagreement")
	player.step()
	player.step()
	context.equal(player.step(), Types.Code.DESYNC, "equal canonical bytes cannot hide checksum mismatch")
	context.equal(player.report().failure.kind, "checksum", "checksum mismatch distinguished")
	trace = _capture()
	trace.frames[2].state = trace.frames[2].state.left(48) + "ff" + trace.frames[2].state.substr(50)
	context.equal(player.configure(trace, Game.new(), Game.SNAPSHOT_BYTES), Types.Code.OK, "same-checksum corrupted state capture accepted for comparison")
	player.step()
	player.step()
	context.equal(player.step(), Types.Code.DESYNC, "full bytes checked independently of checksum")
	context.equal(player.report().failure.frame, 4, "corrupt intermediate prefix localized")


func _malformed(context: RefCounted) -> void:
	var valid: Dictionary = _capture()
	var mutations: Array[Dictionary] = []
	for field: String in ["frame", "state", "state_available", "inputs", "checksum"]:
		var trace: Dictionary = valid.duplicate(true)
		trace.frames[1].erase(field)
		mutations.append(trace)
	var paths: Array[Array] = [
		["frame", 2],
		["frame", 3.5],
		["frame", true],
		["frame", 2147483648],
		["state", "zz"],
		["state", "f"],
		["checksum", "00"],
		["state_available", "true"],
		["inputs", []],
		["inputs", [null]],
	]
	for change: Array in paths:
		var trace: Dictionary = valid.duplicate(true)
		trace.frames[1][change[0]] = change[1]
		mutations.append(trace)
	for field: String in ["player", "status", "bytes"]:
		var trace: Dictionary = valid.duplicate(true)
		trace.frames[1].inputs[0][field] = -1
		mutations.append(trace)
	var missing: Dictionary = valid.duplicate(true)
	missing.frames[0].state_available = false
	missing.frames[0].state = ""
	missing.frames[0].checksum = ""
	mutations.append(missing)
	mutations.append({"schema": valid.schema, "frames": [valid.frames[0]]})
	for trace: Dictionary in mutations:
		var game: Game = Game.new()
		context.equal(Player.new().configure(trace, game, Game.SNAPSHOT_BYTES), Types.Code.INVALID_CONFIGURATION, "malformed trace rejected before callbacks")
		context.equal(game.frame, 0, "invalid capture leaves game unchanged")


func _callbacks(context: RefCounted) -> void:
	for mode: String in [
		"load_trailing", "load_underflow", "load_failed", "save_overflow", "save_failed", "save_empty_checksum", "save_wide_checksum", "advance_failed", "healthy"
	]:
		var game: HostileCallback = HostileCallback.new()
		game.mode = mode
		var player: Player = Player.new()
		game.player = weakref(player)
		context.equal(player.configure(_capture(), game, Game.SNAPSHOT_BYTES), Types.Code.OK, "configure callback control")
		var expected: int = Types.Code.OK if mode == "healthy" else Types.Code.CALLBACK_FAILED
		if mode in ["load_trailing", "load_underflow", "save_overflow", "save_empty_checksum", "save_wide_checksum"]:
			expected = Types.Code.SNAPSHOT_FAILED
		context.equal(player.step(), expected, mode)
		for code: int in game.reentry:
			context.equal(code, Types.Code.BUSY, "all game callbacks fence reentry")
		context.equal(
			game.view.size().code if game.view.has_method("size") else game.view.status(),
			Types.Code.EXPIRED_VIEW if mode in ["advance_failed", "healthy"] else SnapshotStatus.Code.EXPIRED_VIEW,
			"callback view expires"
		)


func _bounds(context: RefCounted) -> void:
	var trace: Dictionary = _capture(128, 130)
	var player: Player = Player.new()
	context.equal(trace.frames.size(), 128, "producer hard window")
	context.equal(player.configure(trace, Game.new(), Game.SNAPSHOT_BYTES), Types.Code.OK, "maximum retained window")
	for index: int in range(128):
		context.equal(player.step(), Types.Code.OK, "bounded maximum playback")
	context.equal(player.report().validated_states, 128, "non-vacuous maximum comparisons")
	context.equal(player.configure(trace, Game.new(), Game.SNAPSHOT_BYTES - 1), Types.Code.INVALID_CONFIGURATION, "application snapshot bound enforced")
	trace.frames.append(trace.frames.back().duplicate(true))
	context.equal(player.configure(trace, Game.new(), Game.SNAPSHOT_BYTES), Types.Code.INVALID_CONFIGURATION, "129 frames rejected")
	context.equal(player.is_complete(), true, "rejected configure preserves prior completed playback")
