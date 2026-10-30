extends RefCounted

# Value: protects=viewer controls preserve an executing replay lifetime and retire replaced players;
# fails_when=reentrant controls replace the game or leave old playback usable; why_new=ordinary viewer controls run only between callbacks; seam=none
const Viewer = preload("res://examples/online/replay_viewer.gd")
const Fixture = preload("res://tests/unit/test_replay_viewer.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")


class ReentrantGame:
	extends RefCounted
	var original: Simulation = Simulation.new()
	var viewer: WeakRef
	var operation: String = ""
	var boundary: int = -1
	var attempts: int = 0
	var accepted: bool = false
	var terminate_first: bool = false

	func _attempt(kind: int) -> void:
		if kind != boundary:
			return
		boundary = -1
		attempts += 1
		var owner: RefCounted = viewer.get_ref()
		if terminate_first:
			owner._player.terminate()
		match operation:
			"open":
				accepted = owner.open_bytes(Fixture.recording(3).to_bytes())
			"restart":
				owner.restart()
			"seek":
				accepted = owner.seek(0)
			"speed":
				accepted = owner.set_playback_speed(16)
			"play":
				owner.toggle_play()
			"step":
				owner.step()
			"back":
				accepted = owner.step_back()
			"tick":
				owner.tick()
			"cancel":
				owner.cancel_seek()

	func save_state(frame: int, writer: RefCounted) -> Driver.SaveResult:
		_attempt(Types.Kind.SAVE)
		return original.save_state(frame, writer)

	func load_state(frame: int, reader: RefCounted) -> bool:
		_attempt(Types.Kind.LOAD)
		return original.load_state(frame, reader)

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		_attempt(Types.Kind.ADVANCE)
		return original.simulate_frame(frame, inputs)


func cases() -> PackedStringArray:
	return PackedStringArray(["replacement", "callback_controls", "callback_termination", "expert_controls"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "replacement":
		_replacement(context)
	elif name == "callback_controls":
		_callback_controls(context)
	elif name == "callback_termination":
		_callback_termination(context)
	else:
		_expert_controls(context)
	context.finish()


func _replacement(context: RefCounted) -> void:
	for operation: String in ["restart", "open"]:
		var viewer: Viewer = Viewer.new()
		context.equal(viewer.open_bytes(Fixture.recording(4).to_bytes()), true, "initial recording imports")
		viewer.step()
		var retired: Player = viewer._player
		var prior_game: RefCounted = viewer.game
		var prior_bytes: PackedByteArray = prior_game.canonical_bytes()
		context.equal(viewer.open_bytes(PackedByteArray([0])), false, "malformed replacement leaves player active")
		context.equal(retired.failure_code(), Types.Code.OK, "refused import preserves original lifetime")
		if operation == "restart":
			viewer.restart()
		else:
			context.equal(viewer.open_bytes(Fixture.recording(3).to_bytes()), true, "valid replacement imports")
		context.equal(retired.failure_code(), Types.Code.TERMINATED, "replaced player retires explicitly")
		context.equal(retired.step(), Types.Code.TERMINATED, "old player cannot run its retained game")
		context.bytes_equal(prior_game.canonical_bytes(), prior_bytes, 1, "retired callbacks cannot change old state")
		context.equal(viewer.current_frame(), 0, "replacement starts a fresh paused lifetime")
		viewer.step()
		context.equal(viewer.current_frame(), 1, "new lifetime remains usable")
		context.state(viewer.current_frame(), viewer.game.canonical_bytes())


func _callback_controls(context: RefCounted) -> void:
	for kind: int in [Types.Kind.SAVE, Types.Kind.LOAD, Types.Kind.ADVANCE]:
		for operation: String in ["open", "restart", "seek", "speed", "play", "step", "back", "tick", "cancel"]:
			var viewer: Viewer = Viewer.new()
			var recording: Replay = Fixture.recording(8)
			context.equal(viewer.open_bytes(recording.to_bytes()), true, "callback fixture imports")
			var game: ReentrantGame = ReentrantGame.new()
			game.viewer = weakref(viewer)
			viewer.game = game
			var player: Player = viewer._player
			context.equal(player.configure(recording, game, Simulation.SNAPSHOT_BYTES, 1, 8), Types.Code.OK, "game callback fixture configures")
			for frame: int in 4:
				viewer.step()
			game.operation = operation
			game.boundary = kind
			viewer.seek(7 if kind != Types.Kind.LOAD else 1)
			if viewer.is_seeking():
				viewer.tick()
			context.equal(game.attempts, 1, "requested callback actually exercises reentrant control")
			context.equal(game.accepted, false, "busy boolean controls refuse reentry")
			context.equal(viewer._player, player, "callback cannot replace owned player")
			context.equal(viewer.game, game, "callback cannot replace game state")
			context.equal(viewer.playback_speed_quarters(), 4, "callback cannot change playback cadence")
			var target: int = 1 if kind == Types.Kind.LOAD else 7
			context.equal(viewer.current_frame(), target, "outer navigation reaches its original target")
			context.equal(viewer.is_seeking(), false, "outer navigation finishes")
			context.equal(viewer.is_playing, false, "navigation remains paused")
			context.equal(player.failure_code(), Types.Code.OK, "busy control preserves healthy callback dispatch")
			var expected: Simulation = Simulation.new()
			for frame: int in target:
				expected.simulate_frame(frame, recording.inputs(frame))
			context.bytes_equal(game.original.canonical_bytes(), expected.canonical_bytes(), target, "reentry preserves canonical selected state")
			context.state(target, game.original.canonical_bytes())


func _expert_controls(context: RefCounted) -> void:
	var viewer: Viewer = Viewer.new()
	context.equal(viewer.open_bytes(Fixture.recording(8).to_bytes()), true, "expert fixture imports")
	viewer.step()
	viewer.seek(7)
	var player: Player = viewer._player
	var game: RefCounted = viewer.game
	var message: String = viewer.message
	var result: Types.Result = player.begin_advance()
	context.equal(result.code, Types.Code.READY, "expert batch owns replay work")
	var request: Types.Request = result.batch.next_request()
	context.equal(request.kind, Types.Kind.SAVE, "retained writer is open")
	context.equal(viewer.open_bytes(Fixture.recording(3).to_bytes()), false, "retained work refuses import")
	viewer.restart()
	viewer.toggle_play()
	context.equal(viewer.set_playback_speed(16), false, "retained work refuses cadence changes")
	context.equal(viewer.seek(0), false, "retained work refuses navigation")
	viewer.cancel_seek()
	viewer.step()
	viewer.tick()
	context.equal(viewer._player, player, "retained batch preserves player ownership")
	context.equal(viewer.game, game, "retained batch preserves game ownership")
	context.equal(viewer.message, message, "busy controls preserve visible pending navigation")
	context.equal(viewer.is_seeking(), true, "busy cancellation cannot cancel pending navigation")
	context.equal(viewer.current_frame(), 1, "busy controls do not commit input")
	var saved: Driver.SaveResult = game.save_state(request.frame, request.writer)
	context.equal(player.complete_request(request.batch_id, request.request_id, saved.ok, saved.checksum).code, Types.Code.OK, "original writer stays usable")
	request = result.batch.next_request()
	var ok: bool = game.simulate_frame(request.frame, request.inputs)
	context.equal(player.complete_request(request.batch_id, request.request_id, ok).code, Types.Code.OK, "original advance completes")
	viewer.tick()
	context.equal(viewer.current_frame(), 7, "navigation resumes after exact retained work completes")
	context.equal(viewer.is_seeking(), false, "resumed navigation finishes")
	context.state(viewer.current_frame(), game.canonical_bytes())


func _callback_termination(context: RefCounted) -> void:
	for kind: int in [Types.Kind.SAVE, Types.Kind.LOAD, Types.Kind.ADVANCE]:
		for operation: String in ["open", "restart", "seek", "speed", "play", "step", "back", "tick", "cancel"]:
			var viewer: Viewer = Viewer.new()
			var recording: Replay = Fixture.recording(8)
			context.equal(viewer.open_bytes(recording.to_bytes()), true, "termination fixture imports")
			var game: ReentrantGame = ReentrantGame.new()
			game.viewer = weakref(viewer)
			viewer.game = game
			var player: Player = viewer._player
			context.equal(player.configure(recording, game, Simulation.SNAPSHOT_BYTES, 1, 8), Types.Code.OK, "termination callback configures")
			for frame: int in 4:
				viewer.step()
			game.operation = operation
			game.boundary = kind
			game.terminate_first = true
			viewer.seek(7 if kind != Types.Kind.LOAD else 1)
			if viewer.is_seeking():
				viewer.tick()
			context.equal(game.attempts, 1, "callback terminates before attempting reentry")
			context.equal(game.accepted, false, "callback still owns player after termination clears its batch")
			context.equal(viewer._player, player, "terminated callback cannot replace player before returning")
			context.equal(viewer.game, game, "terminated callback cannot replace game before returning")
			context.equal(viewer.playback_speed_quarters(), 4, "terminated callback cannot change cadence")
			context.equal(player.failure_code(), Types.Code.TERMINATED, "original cancellation remains first cause")
			context.equal(viewer.current_frame(), 4, "cancelled work preserves exposed player boundary")
			context.equal([viewer.is_seeking(), viewer.is_playing], [false, false], "cancelled work stops outer navigation")
			viewer.restart()
			viewer.step()
			context.equal(viewer.current_frame(), 1, "fresh playback is allowed after callback unwinds")
			context.state(viewer.current_frame(), viewer.game.canonical_bytes())
