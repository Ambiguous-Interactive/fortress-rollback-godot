extends RefCounted

# Value: protects=terminal evidence binds corrected inputs and disconnect statuses; fails_when=provisional or stale state is certified;
# why_new=terminal capture coverage otherwise uses matching receipts and unchanged statuses; seam=none
const Game = preload("res://examples/integration/game.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const FRAMES: int = 4
const CUT: int = 1


class StatusGame:
	extends Game

	func simulate_frame(input_frame: int, inputs: Types.FrameInputs) -> bool:
		if not super.simulate_frame(input_frame, inputs):
			return false
		if inputs.read(1).status == Queue.Status.DISCONNECTED:
			x[0] += 1
		return true


func cases() -> PackedStringArray:
	return PackedStringArray(["corrected_terminal", "retained_drop_terminal", "certified_drop_terminal"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "corrected_terminal":
		_corrected(context)
	else:
		_drop(context, name == "certified_drop_terminal")
	context.finish()


func _config() -> Config:
	var config: Config = Config.new()
	config.sync_test = false
	config.check_distance = 0
	config.local_players = PackedInt32Array([0])
	config.max_snapshot_bytes = Game.SNAPSHOT_BYTES
	config.replay_max_frames = FRAMES
	config.storage_budget_bytes = config.required_storage_bytes()
	return config


func _step(context: RefCounted, driver: Driver, frame: int) -> void:
	var inputs: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, frame, PackedByteArray([Game.RIGHT]))]
	context.equal(driver.step(frame, inputs).code, Types.Code.OK, "advance scripted local input")


func _corrected(context: RefCounted) -> void:
	var session: Session = Session.new()
	context.equal(session.configure(_config()), Types.Code.OK, "configure correction recording")
	var game: StatusGame = StatusGame.new()
	var driver: Driver = Driver.new(session, game)
	context.equal(session.receive_input(1, 0, PackedByteArray([Game.RIGHT])).code, Types.Code.OK, "receive initial actual input")
	_step(context, driver, 0)
	context.equal(driver.capture_replay_boundary().code, Types.Code.OK, "capture the initial finalized prefix")
	var initial: Replay = session.replay()
	for frame: int in range(1, FRAMES):
		_step(context, driver, frame)
	context.equal(driver.capture_replay_boundary().code, Types.Code.PREDICTION_STALL, "predicted tail cannot be certified")
	var predicted: PackedByteArray = game.canonical_bytes()
	for frame: int in range(1, FRAMES):
		context.equal(session.receive_input(1, frame, PackedByteArray([Game.LEFT])).code, Types.Code.OK, "correct the predicted remote input")
	context.equal(session.status().pending_rollback_frame, 1, "correction requires rollback of the first predicted input")
	context.equal(session.replay().frame_count(), 1, "unrepaired history remains behind the correction fence")
	context.equal(driver.capture_replay_boundary().code, Types.Code.PREDICTION_STALL, "actual receipts do not certify an unrepaired game")
	context.equal(session.replay().checksum(FRAMES).is_empty(), true, "no stale terminal evidence exists for the corrected tail")
	context.equal(driver.recover(FRAMES).code, Types.Code.OK, "repair without another local sample")
	context.equal(game.canonical_bytes() != predicted, true, "correction changes the actual final state")
	context.equal(session.statistics().resimulated_frames, FRAMES - 1, "repair executes every affected input")
	var expected: StatusGame = StatusGame.new()
	for frame: int in FRAMES:
		_simulate_expected(context, expected, frame, Game.RIGHT if frame == 0 else Game.LEFT, false)
	context.equal(initial.checksum(1).size(), Replay.CHECKSUM_BYTES, "the earlier owned prefix keeps its own terminal evidence")
	_validate_capture(context, session, driver, game, expected)


func _drop(context: RefCounted, certified: bool) -> void:
	var session: Session = Session.new()
	context.equal(session.configure(_config()), Types.Code.OK, "configure coordinated drop recording")
	context.equal(session.set_confirmation_limit(-1).code, Types.Code.OK, "enable mesh confirmation")
	var game: StatusGame = StatusGame.new()
	var driver: Driver = Driver.new(session, game)
	for frame: int in FRAMES:
		context.equal(session.receive_input(1, frame, PackedByteArray([Game.RIGHT])).code, Types.Code.OK, "stage actual remote receipt")
		_step(context, driver, frame)
		if frame == CUT:
			context.equal(session.set_confirmation_limit(CUT).code, Types.Code.OK, "agree the prefix before the dropped tail")
			context.equal(driver.capture_replay_boundary().code, Types.Code.OK, "capture the agreed prefix before later receipts")
	var frozen: int = Game.LEFT if certified else Game.RIGHT
	var code: int = session.freeze_player_with_value(1, CUT, PackedByteArray([frozen])) if certified else session.freeze_player(1, CUT)
	context.equal(code, Types.Code.OK, "apply the coordinated freeze at the agreed cut")
	context.equal(session.set_confirmation_limit(FRAMES - 1).code, Types.Code.OK, "survivors finalize the tail")
	context.equal(session.status().pending_rollback_frame, CUT + 1, "disconnect semantics require repair even when bytes match")
	context.equal(session.replay().frame_count(), CUT + 1, "rewritten tail remains private before recovery")
	context.equal(driver.capture_replay_boundary().code, Types.Code.PREDICTION_STALL, "cannot certify pre-drop live state after the freeze")
	context.equal(session.replay().checksum(FRAMES).is_empty(), true, "pre-drop evidence cannot migrate to the rewritten tail")
	context.equal(driver.recover(FRAMES).code, Types.Code.OK, "resimulate the frozen tail")
	context.equal(session.statistics().resimulated_frames, FRAMES - CUT - 1, "drop recovery executes every changed-status input")
	var expected: StatusGame = StatusGame.new()
	for frame: int in FRAMES:
		var disconnected: bool = frame > CUT
		_simulate_expected(context, expected, frame, frozen if disconnected else Game.RIGHT, disconnected)
		context.equal(session.replay().inputs(frame).read(1).status, Queue.Status.DISCONNECTED if disconnected else Queue.Status.CONFIRMED, "record canonical frozen statuses")
	_validate_capture(context, session, driver, game, expected)


func _simulate_expected(context: RefCounted, game: StatusGame, frame: int, remote: int, disconnected: bool) -> void:
	var statuses: PackedInt32Array = PackedInt32Array([Queue.Status.CONFIRMED, Queue.Status.DISCONNECTED if disconnected else Queue.Status.CONFIRMED])
	var inputs: Array[PackedByteArray] = [PackedByteArray([Game.RIGHT]), PackedByteArray([remote])]
	context.equal(game.simulate_frame(frame, Types.FrameInputs.new(inputs, statuses)), true, "simulate independent canonical history")


func _validate_capture(context: RefCounted, session: Session, driver: Driver, live: StatusGame, expected: StatusGame) -> void:
	context.bytes_equal(live.canonical_bytes(), expected.canonical_bytes(), FRAMES, "recovered state equals independent canonical history")
	context.equal(session.replay().checksum(FRAMES).is_empty(), true, "recovery alone does not fabricate terminal evidence")
	context.equal(driver.capture_replay_boundary().code, Types.Code.OK, "capture the repaired finalized boundary")
	context.equal(session.status().current_frame, FRAMES, "capture preserves the exact live prefix")
	var recording: Replay = session.replay()
	var hashing: HashingContext = HashingContext.new()
	hashing.start(HashingContext.HASH_MD5)
	hashing.update(expected.canonical_bytes())
	var expected_checksum: PackedByteArray = hashing.finish()
	context.equal(recording.checksum(FRAMES), expected_checksum, "terminal checksum binds independently calculated final state")
	var decoded: Replay = Replay.new()
	context.equal(decoded.decode(recording.to_bytes()), Replay.DecodeCode.OK, "round trip repaired terminal recording")
	var playback: StatusGame = StatusGame.new()
	var player: Player = Player.new()
	context.equal(player.configure(decoded, playback, Game.SNAPSHOT_BYTES), Types.Code.OK, "configure repaired terminal playback")
	for frame: int in FRAMES:
		context.equal(player.step(), Types.Code.OK, "play the canonical repaired input")
	context.equal(player.is_complete(), false, "final input still requires terminal verification")
	context.equal(player.step(), Types.Code.OK, "validate repaired terminal through an actual SAVE")
	context.equal(player.is_complete(), true, "matching terminal validation completes playback")
	context.bytes_equal(playback.canonical_bytes(), expected.canonical_bytes(), FRAMES, "playback reproduces canonical corrected state")
	context.equal(player.begin_advance().code, Types.Code.FRAME_EXHAUSTED, "terminal validation consumes no extra input")
	context.state(FRAMES, playback.canonical_bytes())
