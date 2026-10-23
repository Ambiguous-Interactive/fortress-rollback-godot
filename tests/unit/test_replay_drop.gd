extends RefCounted

const Game = preload("res://examples/integration/game.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const FRAMES: int = 6
const CUT: int = 1


## A game that acts on a disconnect as well as the departed player's buttons.
class StatusGame:
	extends Game
	var owner: WeakRef
	var exported_during_repair: Array[int] = []

	func _observe_export() -> void:
		if owner != null:
			exported_during_repair.append(owner.get_ref().replay().frame_count())

	func load_state(saved_frame: int, reader: Reader) -> bool:
		_observe_export()
		return super.load_state(saved_frame, reader)

	func simulate_frame(input_frame: int, inputs: Types.FrameInputs) -> bool:
		_observe_export()
		if not super.simulate_frame(input_frame, inputs):
			return false
		if inputs.read(1).status == Queue.Status.DISCONNECTED:
			x[0] += 1
		return true


func cases() -> PackedStringArray:
	return PackedStringArray(["retained_freeze", "certified_freeze", "predicted_retained_freeze", "predicted_certified_freeze", "failed_recovery_fence"])


func run_case(name: String, context: RefCounted) -> void:
	_staged_drop(context, name.ends_with("certified_freeze"), name.begins_with("predicted_"), name == "failed_recovery_fence")
	context.finish()


func _remote(frame: int) -> PackedByteArray:
	return PackedByteArray([Game.RIGHT if frame % 2 else Game.LEFT])


# Value: protects=only finalized drop history is exported; fails_when=receipt staging leaks or freezes leave old rows/checksums;
# why_new=ordinary recording never freezes below its staged prefix; seam=none
func _staged_drop(context: RefCounted, certified: bool, predicted: bool, failed_recovery: bool) -> void:
	var config: Config = Config.new()
	config.sync_test = false
	config.check_distance = 0
	config.local_players = PackedInt32Array([0])
	config.max_snapshot_bytes = Game.SNAPSHOT_BYTES
	config.replay_max_frames = FRAMES
	config.storage_budget_bytes = config.required_storage_bytes()
	var session: Session = Session.new()
	context.equal(session.configure(config), Types.Code.OK, "configure a bounded recorded session")
	context.equal(session.set_confirmation_limit(-1).code, Types.Code.OK, "enable mesh confirmation before simulation")
	var game: StatusGame = StatusGame.new()
	var driver: Driver = Driver.new(session, game)
	for frame: int in range(FRAMES):
		if not predicted or frame <= CUT:
			context.equal(session.receive_input(1, frame, _remote(frame)).code, Types.Code.OK, "deliver varying remote actual input")
		context.equal(driver.step(frame, [Driver.LocalInput.new(0, frame, PackedByteArray([Game.RIGHT]))]).code, Types.Code.OK, "simulate actual receipts")
		if frame == CUT:
			context.equal(session.set_confirmation_limit(CUT).code, Types.Code.OK, "hold mesh agreement below later receipts")
	var before: Replay = session.replay()
	context.equal(before.frame_count(), CUT + 1, "private receipt staging does not expose unconfirmed rows")
	var frozen_value: PackedByteArray = _remote(CUT - 1 if certified else CUT)
	var freeze: int = session.freeze_player_with_value(1, CUT, frozen_value) if certified else session.freeze_player(1, CUT)
	context.equal(freeze, Types.Code.OK, "freeze the departed slot below the receipt-staged prefix")
	context.equal(session.set_confirmation_limit(FRAMES - 1).code, Types.Code.OK, "survivors agree the final frontier")
	context.equal(session.status().pending_rollback_frame, CUT + 1, "the changed tail still needs simulation repair")
	context.equal(session.replay().frame_count(), CUT + 1, "unrepaired rows remain private despite mesh confirmation")
	if failed_recovery:
		_failed_recovery(context, session, config)
		return
	game.owner = weakref(session)
	context.equal(driver.recover(FRAMES).code, Types.Code.OK, "correct the tail without a forward sample")
	game.owner = null
	context.equal(game.exported_during_repair.is_empty(), false, "actual recovery callbacks inspect the public replay")
	for frames: int in game.exported_during_repair:
		context.equal(frames, CUT + 1, "reentrant exports exclude the tail until every repair callback succeeds")
	context.equal(session.status().current_frame, FRAMES, "recovery preserves the exact last frame")
	var recording: Replay = session.replay()
	context.equal(recording.frame_count(), FRAMES, "recovery publishes the complete retained tail")
	context.equal(recording.skipped_frames(), 0, "staged history survives without neutral substitution")
	var expected: StatusGame = StatusGame.new()
	for frame: int in range(FRAMES):
		var disconnected: bool = frame > CUT
		var remote: PackedByteArray = frozen_value if disconnected else _remote(frame)
		var statuses: PackedInt32Array = PackedInt32Array([Queue.Status.CONFIRMED, Queue.Status.DISCONNECTED if disconnected else Queue.Status.CONFIRMED])
		var inputs: Types.FrameInputs = recording.inputs(frame)
		context.equal(inputs.read(1).bytes, remote, "the replay tail repeats the certified value")
		context.equal(inputs.read(1).status, statuses[1], "the replay carries disconnect semantics")
		context.equal(expected.simulate_frame(frame, Types.FrameInputs.new([PackedByteArray([Game.RIGHT]), remote], statuses)), true, "advance independent frozen history")
	context.bytes_equal(game.canonical_bytes(), expected.canonical_bytes(), FRAMES, "live recovery matches independent status-sensitive history")
	context.equal(before.frame_count(), CUT + 1, "the earlier exported prefix remains caller owned")
	var decoded: Replay = Replay.new()
	context.equal(decoded.decode(recording.to_bytes()), Replay.DecodeCode.OK, "the corrected recording round-trips")
	var playback: StatusGame = StatusGame.new()
	var player: Player = Player.new()
	context.equal(player.configure(decoded, playback, Game.SNAPSHOT_BYTES), Types.Code.OK, "configure checksum-validated playback")
	var code: int = Types.Code.OK
	while code == Types.Code.OK:
		code = player.step()
	context.equal(code, Types.Code.FRAME_EXHAUSTED, "no stale pre-drop checksum survives playback")
	context.bytes_equal(playback.canonical_bytes(), expected.canonical_bytes(), FRAMES, "replay matches independent status-sensitive history")
	_expert_playback(context, decoded, expected)
	context.state(FRAMES, playback.canonical_bytes())


# Value: protects=replay finalization waits for successful repair; fails_when=reset prediction exposes unrepaired or failed tail; why_new=export during LOAD; seam=none
func _failed_recovery(context: RefCounted, session: Session, config: Config) -> void:
	var opened: Types.Result = session.begin_recovery()
	context.equal(opened.code, Types.Code.READY, "expert recovery opens the repair batch")
	if opened.code != Types.Code.READY:
		return
	var request: Types.Request = opened.batch.next_request()
	context.equal(request.kind, Types.Kind.LOAD, "recovery starts by restoring the correction boundary")
	context.equal(session.replay().frame_count(), CUT + 1, "active LOAD cannot expose the unrepaired tail")
	context.equal(session.complete_request(request.batch_id, request.request_id, false).code, Types.Code.CALLBACK_FAILED, "a failed restore ends repair")
	context.equal(session.replay().frame_count(), CUT + 1, "terminal callback failure keeps the unrepaired tail private")
	context.equal(session.configure(config), Types.Code.OK, "fresh configuration replaces the failed lifetime")
	context.equal(session.replay().frame_count(), 0, "fresh configuration clears the replay repair fence")
	var driver: Driver = Driver.new(session, StatusGame.new())
	for frame: int in range(CUT + 2):
		context.equal(session.receive_input(1, frame, _remote(frame)).code, Types.Code.OK, "fresh lifetime receives actual inputs")
		context.equal(driver.step(frame, [Driver.LocalInput.new(0, frame, PackedByteArray([Game.RIGHT]))]).code, Types.Code.OK, "fresh lifetime advances")
	context.equal(session.replay().frame_count(), CUT + 2, "the prior repair fence cannot cap a fresh lifetime")


func _expert_playback(context: RefCounted, recording: Replay, expected: StatusGame) -> void:
	var player: Player = Player.new()
	var game: StatusGame = StatusGame.new()
	context.equal(player.configure_expert(recording, Game.SNAPSHOT_BYTES), Types.Code.OK, "configure expert replay with checksum validation")
	for frame: int in range(FRAMES):
		var opened: Types.Result = player.begin_advance()
		context.equal(opened.code, Types.Code.READY, "expert opens the next recorded frame")
		if opened.code != Types.Code.READY:
			return
		while true:
			var request: Types.Request = opened.batch.next_request()
			if request == null:
				break
			var checksum: PackedByteArray = PackedByteArray()
			var ok: bool = false
			if request.kind == Types.Kind.SAVE:
				var saved: Driver.SaveResult = game.save_state(request.frame, request.writer)
				ok = saved.ok
				checksum = saved.checksum
			else:
				ok = game.simulate_frame(request.frame, request.inputs)
			var completed: Types.Result = player.complete_request(request.batch_id, request.request_id, ok, checksum)
			context.equal(completed.code, Types.Code.OK, "expert applies the recorded statuses and validates checksums")
			if completed.code != Types.Code.OK:
				return
	context.equal(player.begin_advance().code, Types.Code.FRAME_EXHAUSTED, "expert finishes exactly at the recorded tail")
	context.bytes_equal(game.canonical_bytes(), expected.canonical_bytes(), FRAMES, "expert matches independent status-sensitive history")
