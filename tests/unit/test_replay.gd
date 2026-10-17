extends RefCounted

# Value: protects=match recording and playback; fails_when=recorded inputs follow predictions, frames drop at discard, or corrupt files load; why_new=no replay support; seam=none
const Game = preload("res://examples/integration/game.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const FRAMES: int = 90


## Diverges from frame 40, as a game build with different rules would.
class ChangedRules:
	extends Game

	func simulate_frame(input_frame: int, inputs: Types.FrameInputs) -> bool:
		var ok: bool = super.simulate_frame(input_frame, inputs)
		if input_frame == 40:
			x[0] += 1
		return ok


class FailingGame:
	extends Game

	func simulate_frame(input_frame: int, inputs: Types.FrameInputs) -> bool:
		return input_frame != 5 and super.simulate_frame(input_frame, inputs)


func cases() -> PackedStringArray:
	return PackedStringArray(["records_corrected_match", "detects_changed_rules", "rejects_malformed_files", "bounds_recording"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"records_corrected_match":
			_records_corrected_match(context)
		"detects_changed_rules":
			_detects_changed_rules(context)
		"rejects_malformed_files":
			_rejects_malformed_files(context)
		"bounds_recording":
			_bounds_recording(context)
	context.finish()


static func _local(frame: int) -> int:
	return (Game.RIGHT | Game.FIRE) if frame % 11 < 8 else Game.LEFT


static func _remote(frame: int) -> int:
	return (Game.FIRE if frame % 8 < 4 else 0) | (Game.LEFT if frame % 7 < 3 else Game.RIGHT)


static func _config(sync_test: bool, max_frames: int) -> Config:
	var config: Config = Config.new()
	config.sync_test = sync_test
	config.local_players = PackedInt32Array([0, 1] if sync_test else [0])
	config.check_distance = 4 if sync_test else 0
	config.max_snapshot_bytes = Game.SNAPSHOT_BYTES
	config.replay_max_frames = max_frames
	config.storage_budget_bytes = config.required_storage_bytes()
	return config


## Plays one match where remote input arrives `lag` ticks late in bursts, then delivers the rest.
## Returns the session after a final tick that confirms every simulated frame.
func _match(context: RefCounted, row: Dictionary, max_frames: int) -> Session:
	var session: Session = Session.new()
	var sync_test: bool = row.get("sync_test", false)
	context.equal(session.configure(_config(sync_test, max_frames)), Types.Code.OK, "configures")
	var driver: Driver = Driver.new(session, Game.new())
	var delivered: int = 0
	var tick: int = 0
	var sample_frame: int = -1
	var sample: PackedByteArray = PackedByteArray()
	while session.status().current_frame < FRAMES and tick < FRAMES * 4:
		if not sync_test and tick % row.burst == 0:
			while delivered <= tick - row.lag:
				session.receive_input(1, delivered, PackedByteArray([_remote(delivered)]))
				delivered += 1
		var frame: int = session.status().current_frame
		if sample_frame != frame:
			sample_frame = frame
			sample = PackedByteArray([_local(frame)])
		var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, frame, sample)]
		if sync_test:
			samples.append(Driver.LocalInput.new(1, frame, PackedByteArray([_remote(frame)])))
		var code: int = driver.step(tick, samples).code
		if code != Types.Code.OK and code != Types.Code.PREDICTION_STALL:
			context.equal(code, Types.Code.OK, "match keeps running")
			return session
		tick += 1
	if not sync_test:
		while delivered <= session.status().current_frame:
			session.receive_input(1, delivered, PackedByteArray([_remote(delivered)]))
			delivered += 1
		var frame: int = session.status().current_frame
		context.equal(driver.step(tick, [Driver.LocalInput.new(0, frame, PackedByteArray([_local(frame)]))]).code, Types.Code.OK, "final tick")
	return session


static func _decode(bytes: PackedByteArray, max_bytes: int = Replay.MAX_BYTES) -> Replay:
	var replay: Replay = Replay.new()
	return replay if replay.decode(bytes, max_bytes) else null


## Straight simulation of the actual inputs: canonical state before each frame.
func _reference(frames: int) -> Array[PackedByteArray]:
	var game: Game = Game.new()
	var states: Array[PackedByteArray] = [game.canonical_bytes()]
	for frame: int in range(frames):
		game.simulate_frame(frame, Types.FrameInputs.new([PackedByteArray([_local(frame)]), PackedByteArray([_remote(frame)])], PackedInt32Array([1, 1])))
		states.append(game.canonical_bytes())
	return states


func _records_corrected_match(context: RefCounted) -> void:
	var rows: Array[Dictionary] = [
		{"label": "on time", "lag": 0, "burst": 1},
		{"label": "late corrections", "lag": 3, "burst": 1},
		{"label": "bursts and stalls", "lag": 3, "burst": 6},
		{"label": "beyond the prediction window", "lag": 12, "burst": 1},
		{"label": "sync-test", "sync_test": true},
	]
	for row: Dictionary in rows:
		var label: String = row.label
		var session: Session = _match(context, row, FRAMES * 2)
		var replay: Replay = session.replay()
		var frames: int = session.status().current_frame
		context.equal(replay.frame_count(), frames, label + " records every simulated confirmed frame")
		context.equal(replay.skipped_frames(), 0, label + " skips nothing")
		var wrong_inputs: int = 0
		var checksums: int = 0
		for frame: int in range(replay.frame_count()):
			var inputs: Types.FrameInputs = replay.inputs(frame)
			if inputs.read(0).bytes != PackedByteArray([_local(frame)]) or inputs.read(1).bytes != PackedByteArray([_remote(frame)]):
				wrong_inputs += 1
			checksums += int(not replay.checksum(frame).is_empty())
		context.equal(wrong_inputs, 0, label + " records actual inputs, never predictions")
		context.equal(checksums > frames / 2, true, label + " records state checksums")
		var decoded: Replay = _decode(replay.to_bytes())
		context.equal(decoded != null and decoded.to_bytes() == replay.to_bytes(), true, label + " round-trips bytes")
		var expected: Array[PackedByteArray] = _reference(frames)
		var game: Game = Game.new()
		var player: Player = Player.new()
		context.equal(player.configure(decoded, game, Game.SNAPSHOT_BYTES), Types.Code.OK, label + " player configures")
		var code: int = Types.Code.OK
		while code == Types.Code.OK:
			code = player.step()
		context.equal(code, Types.Code.FRAME_EXHAUSTED, label + " validates every checksum and finishes")
		context.equal(player.is_complete(), true, label + " is complete")
		context.bytes_equal(game.canonical_bytes(), expected[frames], frames, label + " replays the corrected final state")


func _detects_changed_rules(context: RefCounted) -> void:
	var replay: Replay = _match(context, {"lag": 3, "burst": 1}, FRAMES * 2).replay()
	# Validation stops at the first saved checksum after the divergence; frame 41's state differs.
	var rows: Array[Dictionary] = [
		{"label": "validated", "game": ChangedRules.new(), "bytes": Game.SNAPSHOT_BYTES, "code": Types.Code.DESYNC, "frame": 41},
		{"label": "inputs only", "game": ChangedRules.new(), "bytes": 0, "code": Types.Code.FRAME_EXHAUSTED, "frame": -1},
		{"label": "callback failure", "game": FailingGame.new(), "bytes": Game.SNAPSHOT_BYTES, "code": Types.Code.CALLBACK_FAILED, "frame": 5},
	]
	for row: Dictionary in rows:
		var player: Player = Player.new()
		context.equal(player.configure(replay, row.game, row.bytes), Types.Code.OK, row.label + " configures")
		var code: int = Types.Code.OK
		while code == Types.Code.OK:
			code = player.step()
		context.equal(code, row.code, row.label + " result")
		context.equal(player.failure_frame(), row.frame, row.label + " failure frame")
		context.equal(player.step(), row.code, row.label + " stays stopped")
	context.equal(Player.new().configure(replay, RefCounted.new()), Types.Code.INVALID_CONFIGURATION, "rejects a game without callbacks")
	context.equal(Player.new().step(), Types.Code.NOT_CONFIGURED, "unconfigured player refuses to step")


func _rejects_malformed_files(context: RefCounted) -> void:
	var valid: PackedByteArray = _match(context, {"lag": 2, "burst": 1}, 6).replay().to_bytes()
	context.equal(_decode(valid) != null, true, "accepts the original")
	var truncated: int = 0
	for size: int in range(valid.size()):
		truncated += int(_decode(valid.slice(0, size)) != null)
	context.equal(truncated, 0, "rejects every truncation")
	# Each row patches one header field: [offset, encoder width, value].
	var rows: Array[Dictionary] = [
		{"label": "magic", "patch": [0, 1, 0x58]},
		{"label": "future version", "patch": [4, 2, 2]},
		{"label": "one player", "patch": [6, 1, 1]},
		{"label": "nine players", "patch": [6, 1, 9]},
		{"label": "zero width", "patch": [7, 4, 0]},
		{"label": "extra frame", "patch": [11, 4, 7]},
		{"label": "frame-count bomb", "patch": [11, 4, Replay.MAX_FRAMES]},
		{"label": "skipped beyond frames", "patch": [15, 4, 7]},
		{"label": "checksum flag", "patch": [Replay.HEADER_BYTES + 2, 1, 2]},
	]
	for row: Dictionary in rows:
		var bytes: PackedByteArray = valid.duplicate()
		match int(row.patch[1]):
			1:
				bytes.encode_u8(row.patch[0], row.patch[2])
			2:
				bytes.encode_u16(row.patch[0], row.patch[2])
			4:
				bytes.encode_u32(row.patch[0], row.patch[2])
		context.equal(_decode(bytes), null, "rejects " + row.label)
	var trailing: PackedByteArray = valid.duplicate()
	trailing.append(0)
	context.equal(_decode(trailing), null, "rejects trailing bytes")
	context.equal(_decode(valid, valid.size() - 1), null, "honors the caller's size limit")
	var kept: Replay = _decode(valid)
	context.equal(kept.decode(trailing), false, "a failed decode reports failure")
	context.equal(kept.to_bytes(), valid, "a failed decode keeps the previous replay")


func _bounds_recording(context: RefCounted) -> void:
	var session: Session = _match(context, {"lag": 3, "burst": 6}, 10)
	var replay: Replay = session.replay()
	context.equal(replay.frame_count(), 10, "keeps only the first configured frames")
	replay._append(PackedByteArray([0, 0]), PackedByteArray(), false)
	context.equal(session.replay().frame_count(), 10, "returns caller-owned copies")
	var disabled: Session = Session.new()
	context.equal(disabled.configure(_config(true, 0)), Types.Code.OK, "recording is optional")
	context.equal(disabled.replay(), null, "no replay when disabled")
	for max_frames: int in [-1, Replay.MAX_FRAMES + 1]:
		context.equal(_config(true, max_frames).validate(), Types.Code.INVALID_CONFIGURATION, "rejects replay limit %d" % max_frames)
	var wide: Config = _config(true, Replay.MAX_FRAMES)
	wide.input_width = 65536
	wide.neutral_input.resize(65536)
	context.equal(wide.validate(), Types.Code.INVALID_CONFIGURATION, "rejects recordings larger than the byte limit")
