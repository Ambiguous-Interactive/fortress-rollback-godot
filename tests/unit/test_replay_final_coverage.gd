extends RefCounted

# Value: protects=final-state validation stays distinct from input and pre-input coverage; fails_when=historical or restored playback claims a verified final state;
# why_new=the public checksum count does not identify which boundary was validated; seam=none
const Fixture = preload("res://tests/unit/test_replay_viewer.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Viewer = preload("res://examples/online/replay_viewer.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


class ObservedGame:
	extends Simulation
	var owner: WeakRef
	var observations: Array[bool] = []
	var completion_observations: Array[bool] = []
	var selected_observations: Array[bool] = []

	func save_state(frame: int, writer: RefCounted) -> Driver.SaveResult:
		observations.append(owner.get_ref().is_final_state_validated())
		selected_observations.append(owner.get_ref().is_current_state_validated())
		completion_observations.append(owner.get_ref().is_complete())
		return super.save_state(frame, writer)


func cases() -> PackedStringArray:
	return PackedStringArray(["final_state_coverage", "viewer_final_coverage", "selected_state_coverage"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "selected_state_coverage":
		_selected_state_coverage(context)
	elif name == "final_state_coverage":
		_final_state_coverage(context)
	else:
		_viewer_final_coverage(context)
	context.finish()


func _recording(frames: int, terminal: bool, mismatch: bool = false) -> Replay:
	var replay: Replay = Fixture.recording(frames)
	if terminal:
		var game: Simulation = Simulation.new()
		for frame: int in frames:
			game.simulate_frame(frame, replay.inputs(frame))
		replay._format_version = Replay.TERMINAL_VERSION
		replay._terminal_checksum = Simulation.checksum(game.canonical_bytes())
		if mismatch:
			replay._terminal_checksum[0] ^= 1
	return replay


func _dispatch(player: Player, game: Simulation) -> int:
	var result: Types.Result = player.begin_advance()
	if result.code != Types.Code.READY:
		return result.code
	while true:
		var request: Types.Request = result.batch.next_request()
		if request == null:
			return Types.Code.OK
		var checksum: PackedByteArray = PackedByteArray()
		var ok: bool = true
		if request.kind == Types.Kind.SAVE:
			var saved: Driver.SaveResult = game.save_state(request.frame, request.writer)
			ok = saved.ok
			checksum = saved.checksum
		else:
			ok = game.simulate_frame(request.frame, request.inputs)
		var code: int = player.complete_request(request.batch_id, request.request_id, ok, checksum).code
		if code != Types.Code.OK:
			return code
	return Types.Code.OK


func _final_state_coverage(context: RefCounted) -> void:
	var probe: Player = Player.new()
	context.equal(probe.has_method("is_final_state_validated"), true, "public coverage distinguishes the final boundary")
	if not probe.has_method("is_final_state_validated"):
		return
	context.equal(probe.call("is_final_state_validated"), false, "unconfigured playback claims no final validation")
	for frames: int in [0, 1, 4]:
		for expert: bool in [false, true]:
			for coverage: String in ["historical", "terminal", "input only", "mismatch"]:
				var replay: Replay = _recording(frames, coverage != "historical", coverage == "mismatch")
				var player: Player = Player.new()
				var game: Simulation = Simulation.new()
				var bound: int = 0 if coverage == "input only" else Simulation.SNAPSHOT_BYTES
				var code: int = (
					player.configure_expert(replay, bound, null, 1 if bound > 0 else 0, 5 if bound > 0 else 0)
					if expert
					else player.configure(replay, game, bound, 1 if bound > 0 else 0, 5 if bound > 0 else 0)
				)
				context.equal(code, Types.Code.OK, "coverage fixture configures")
				context.equal(player.call("is_final_state_validated"), false, "import alone never validates the final state")
				for frame: int in frames:
					context.equal(_dispatch(player, game) if expert else player.step(), Types.Code.OK, "plays canonical input")
				context.equal(player.call("is_final_state_validated"), false, "pre-input checksums do not establish the final state")
				code = _dispatch(player, game) if expert else player.step()
				var expected: int = Types.Code.DESYNC if coverage == "mismatch" else (Types.Code.OK if coverage == "terminal" else Types.Code.FRAME_EXHAUSTED)
				context.equal(code, expected, "terminal comparison has its own outcome")
				context.equal(player.call("is_final_state_validated"), coverage == "terminal", "only matching final evidence qualifies")
				if coverage in ["historical", "terminal"] and frames > 0:
					context.equal(player.is_complete(), true, "finished playback is complete before navigation")
					var restoration: Types.Result = player.begin_restore_before(0)
					context.equal(restoration.code, Types.Code.READY, "validated playback can inspect an earlier checkpoint")
					context.equal(player.is_complete(), false, "open navigation suspends playback completion")
					context.equal(player.call("is_final_state_validated"), false, "open restoration suspends final validation")
					var request: Types.Request = restoration.batch.next_request()
					context.equal(game.load_state(request.frame, request.reader), true, "loads initial state")
					context.equal(player.complete_request(request.batch_id, request.request_id, true).code, Types.Code.OK, "acknowledges checkpoint load")
					context.equal(player.call("is_final_state_validated"), false, "loaded earlier state cannot retain a final-state claim")
					context.equal(player.is_complete(), false, "loaded state awaits verification before navigation completes")
					request = restoration.batch.next_request()
					var saved: Driver.SaveResult = game.save_state(request.frame, request.writer)
					context.equal(player.complete_request(request.batch_id, request.request_id, saved.ok, saved.checksum).code, Types.Code.OK, "verifies restored checkpoint")
					context.equal(player.call("is_final_state_validated"), false, "an earlier displayed boundary is not the final validated state")
					context.equal(player.is_complete(), false, "restored earlier boundary requires replaying inputs")
				player.terminate()
				context.equal(player.call("is_final_state_validated"), false, "terminated playback claims no current validation")
				context.equal(player.configure_expert(replay), Types.Code.OK, "explicit replacement starts a new lifetime")
				context.equal(player.call("is_final_state_validated"), false, "replacement clears final coverage")
	var observed: ObservedGame = ObservedGame.new()
	observed.owner = weakref(probe)
	context.equal(probe.configure(_recording(0, true), observed, Simulation.SNAPSHOT_BYTES), Types.Code.OK, "initial-only callback playback configures")
	for attempt: int in 2:
		context.equal(probe.validate_current_frame(), Types.Code.OK, "paused final validation succeeds")
		context.equal(probe.call("is_final_state_validated"), true, "successful callback publishes final validation")
	context.equal(observed.selected_observations, [false, false], "callback work suspends selected-state validation")
	context.equal(observed.observations, [false, false], "callbacks cannot claim final validation while their state save is incomplete")
	context.equal(observed.completion_observations, [false, false], "callbacks cannot report completion while their state save is incomplete")
	var validation: Types.Result = probe.begin_validate_current_frame()
	context.equal(validation.code, Types.Code.READY, "manual final revalidation opens a SAVE")
	context.equal(probe.call("is_current_state_validated"), false, "open revalidation suspends an earlier selected-state match")
	context.equal(probe.call("is_final_state_validated"), false, "an open final SAVE suspends the completion claim")
	context.equal(probe.is_complete(), false, "an open final SAVE cannot report completed playback")
	probe.terminate()


func _viewer_final_coverage(context: RefCounted) -> void:
	for coverage: String in ["historical", "terminal", "none", "mismatch"]:
		var replay: Replay = _recording(2, coverage in ["terminal", "mismatch"], coverage == "mismatch")
		if coverage == "none":
			replay._flags.fill(0)
		var viewer: Viewer = Viewer.new()
		context.equal(viewer.open_bytes(replay.to_bytes()), true, "viewer opens supported coverage")
		viewer.seek(2)
		while viewer.is_seeking():
			viewer.tick()
		context.equal(viewer.has_failure(), coverage == "mismatch", "final mismatch remains a failure")
		if coverage == "terminal":
			context.equal(viewer.message.contains("including the final state"), true, "completion names verified final state")
		elif coverage == "historical":
			context.equal(viewer.message.contains("final state has no recorded checksum"), true, "historical completion names missing final evidence")
		elif coverage == "none":
			context.equal(viewer.message.contains("no checksums"), true, "checksum-free completion remains explicitly unverified")
		else:
			context.equal(viewer.message.contains("Replay complete"), false, "failed final state is never presented as complete")


# Value: protects=selected-state coverage cannot inherit a lifetime checksum count; fails_when=unchecked boundaries or cache-only snapshots claim recorded validation;
# why_new=final-state and lifetime counters do not cover intermediate displayed states; seam=none
func _selected_state_coverage(context: RefCounted) -> void:
	var probe: Player = Player.new()
	context.equal(probe.has_method("is_current_state_validated"), true, "selected boundary exposes its own checksum coverage")
	if not probe.has_method("is_current_state_validated"):
		return
	context.equal(probe.call("is_current_state_validated"), false, "unconfigured state is unverified")
	for expert: bool in [false, true]:
		for validates: bool in [false, true]:
			var replay: Replay = _recording(4, true)
			replay._flags[1] = 0
			var game: Simulation = Simulation.new()
			var player: Player = Player.new()
			var bound: int = Simulation.SNAPSHOT_BYTES if validates else 0
			var interval: int = 1 if validates else 0
			var capacity: int = 5 if validates else 0
			var configured: int = player.configure_expert(replay, bound, null, interval, capacity) if expert else player.configure(replay, game, bound, interval, capacity)
			context.equal(configured, Types.Code.OK, "configure selected-boundary coverage")
			for frame: int in 4:
				context.equal(player.call("is_current_state_validated"), false, "advance does not validate the resulting state")
				var validation: Types.Result = player.begin_validate_current_frame()
				context.equal(player.call("is_current_state_validated"), false, "open validation cannot publish a matching checksum")
				if validation.code == Types.Code.READY:
					var request: Types.Request = validation.batch.next_request()
					var saved: Driver.SaveResult = game.save_state(request.frame, request.writer)
					context.equal(player.complete_request(request.batch_id, request.request_id, saved.ok, saved.checksum).code, Types.Code.OK, "validate selected state")
				else:
					context.equal(validation.code, Types.Code.OK, "input-only validation needs no SAVE")
				context.equal(player.call("is_current_state_validated"), validates and frame != 1, "only a present matching recorded checksum qualifies")
				context.equal(_dispatch(player, game) if expert else player.step(), Types.Code.OK, "advance verified input")
			context.equal(player.call("is_current_state_validated"), false, "terminal evidence remains unchecked after the last input")
			context.equal(_dispatch(player, game) if expert else player.step(), Types.Code.OK if validates else Types.Code.FRAME_EXHAUSTED, "check optional terminal state")
			context.equal(player.call("is_current_state_validated"), validates, "terminal SAVE qualifies the selected final state")
			if validates:
				for target: int in [1, 2]:
					var restore: Types.Result = player.begin_restore_before(target)
					context.equal(restore.code, Types.Code.READY, "restore selected cached state")
					context.equal(player.call("is_current_state_validated"), false, "restoration suspends selected-state validation")
					var request: Types.Request = restore.batch.next_request()
					context.equal(game.load_state(request.frame, request.reader), true, "load cached state")
					context.equal(player.complete_request(request.batch_id, request.request_id, true).code, Types.Code.OK, "acknowledge load")
					context.equal(player.call("is_current_state_validated"), false, "LOAD alone does not validate restored state")
					request = restore.batch.next_request()
					var saved: Driver.SaveResult = game.save_state(request.frame, request.writer)
					context.equal(player.complete_request(request.batch_id, request.request_id, saved.ok, saved.checksum).code, Types.Code.OK, "compare restored state")
					context.equal(player.call("is_current_state_validated"), target == 2, "cache-only comparison cannot invent a recorded checksum")
			var previous: bool = player.call("is_current_state_validated")
			context.equal(player.configure(Replay.new(), Simulation.new()), Types.Code.INVALID_CONFIGURATION, "refuse malformed replacement")
			context.equal(player.call("is_current_state_validated"), previous, "refused replacement preserves selected-state coverage")
			player.terminate()
			context.equal(player.call("is_current_state_validated"), false, "termination removes selected-state claim")
			context.equal(player.configure(replay, Simulation.new(), bound), Types.Code.OK, "replace playback lifetime")
			context.equal(player.call("is_current_state_validated"), false, "replacement has no validated boundary")
			context.state(game.frame, game.canonical_bytes())
