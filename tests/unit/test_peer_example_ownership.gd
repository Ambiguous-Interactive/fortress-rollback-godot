extends RefCounted

# Value: protects=peer example replacement and service ownership; fails_when=reset leaves old peers live or nested controls mutate a held match;
# why_new=reset tests discard handles; seam=none
const Match = preload("res://examples/peer/match.gd")
const Fixture = preload("res://tests/unit/test_peer_example_lifecycle.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const SnapshotStatus = preload("res://addons/fortress_rollback/core/snapshot_status.gd")


class GuardedGame:
	extends Match.Game
	var hook: Callable
	var hook_kind: int = -1

	func _attempt(kind: int) -> void:
		if kind != hook_kind or not hook.is_valid():
			return
		var callback: Callable = hook
		hook = Callable()
		callback.call()

	func save_state(frame: int, writer: Match.Simulation.Writer) -> Driver.SaveResult:
		_attempt(Types.Kind.SAVE)
		return super.save_state(frame, writer)

	func load_state(frame: int, reader: Match.Reader) -> bool:
		_attempt(Types.Kind.LOAD)
		return super.load_state(frame, reader)

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		_attempt(Types.Kind.ADVANCE)
		return super.simulate_frame(frame, inputs)


func cases() -> PackedStringArray:
	return PackedStringArray(["replacement", "rejected_configuration", "completion_controls", "manual_controls", "callback_controls", "input_preflight"])


func run_case(name: String, context: RefCounted) -> void:
	call("_" + name, context)
	context.finish()


func _replacement(context: RefCounted) -> void:
	var game: Match = Fixture.new()._healthy(context)
	var previous: Array = game.sessions.duplicate()
	var old_games: Array = game.games.duplicate()
	var before: Array[PackedByteArray] = [old_games[0].canonical_bytes(), old_games[1].canonical_bytes()]
	context.equal(game.reset(), I.Code.OK, "idle reset replaces the owned match")
	for player: int in 2:
		context.equal(previous[player].status().lifecycle, Types.Lifecycle.TERMINATED, "replacement retires retained old peer")
		var frame: int = previous[player].status().current_frame
		var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(player, frame, PackedByteArray([1]))]
		context.equal(previous[player].step(3000000, samples).code, Types.Code.TERMINATED, "old handles cannot invoke old game callbacks")
		context.bytes_equal(old_games[player].canonical_bytes(), before[player], frame, "retired game state stays unchanged")
		context.equal(game.games[player].frame, 0, "replacement starts from the original state")
	for tick: int in 80:
		game.tick(PackedInt32Array([1, 4]))
	context.equal(game.games[0].frame > 40 and game.games[1].frame > 40, true, "replacement remains playable")


func _rejected_configuration(context: RefCounted) -> void:
	var game: Match = Fixture.new()._healthy(context)
	var previous: Array = game.sessions.duplicate()
	var before: Array[PackedByteArray] = [game.games[0].canonical_bytes(), game.games[1].canonical_bytes()]
	var time: int = game.now_us
	var queued: int = game.queued_packets()
	game.replay_frames = -1
	context.equal(game.reset(), I.Code.INVALID_ARGUMENT, "invalid candidate rejected before replacing live state")
	context.equal(game.now_us, time, "rejected replacement preserves service clock")
	context.equal(game.queued_packets(), queued, "rejected replacement preserves queued packets")
	for player: int in 2:
		context.equal(game.sessions.size(), 2, "rejected replacement keeps the complete roster")
		if game.sessions.size() == 2:
			context.equal(game.sessions[player] == previous[player], true, "rejected replacement preserves peer identity")
			context.equal(previous[player].status().lifecycle, Types.Lifecycle.RUNNING, "rejected replacement preserves live peer")
			context.bytes_equal(game.games[player].canonical_bytes(), before[player], game.games[player].frame, "rejected replacement preserves canonical state")
	game.replay_frames = 0
	# Continue the original graph even on the broken implementation, which discarded the public handles.
	if game.sessions.size() == 2 and game.sessions[0] == previous[0]:
		game.tick(PackedInt32Array([2, 8]))
		context.equal(game.failure, I.Code.OK, "original match continues after invalid replacement")


func _completion_controls(context: RefCounted) -> void:
	for active: int in 2:
		for action: String in ["reset", "tick", "desync", "delay"]:
			var game: Match = Fixture.new()._healthy(context)
			var previous: Array = game.sessions.duplicate()
			var observations: Array[int] = []
			previous[active].step_completed.connect(
				func(_code: int, _before: int, _after: int) -> void:
					var state: PackedInt64Array = _controls(game)
					if action == "reset":
						observations.append(game.reset())
					elif action == "delay":
						observations.append(game.raise_input_delay(0))
						observations.append(game.raise_input_delay(1))
					elif action == "tick":
						game.tick(PackedInt32Array([1, 4]))
					else:
						game.inject_desync()
					context.equal(_controls(game), state, "nested " + action + " preserves clock, packets, counters and game rules"),
				CONNECT_ONE_SHOT
			)
			var frame: int = previous[active].status().current_frame
			var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(active, frame, PackedByteArray([2 if active == 0 else 8]))]
			var result: RefCounted = previous[active].step(game.now_us, samples)
			context.equal(result.code, Types.Code.OK, "outer step completes during rejected " + action)
			if action == "reset":
				context.equal(observations, [I.Code.BUSY], "either owned peer blocks reset throughout completion")
			if action == "delay":
				context.equal(observations, [Types.Code.BUSY, Types.Code.BUSY], "active peer blocks both delay controls")
			context.equal(game.sessions.size(), 2, "nested control preserves roster")
			if game.sessions.size() == 2:
				context.equal(game.sessions[0] == previous[0], true, "nested control preserves first peer")
				context.equal(game.sessions[1] == previous[1], true, "nested control preserves second peer")


func _manual_controls(context: RefCounted) -> void:
	for active: int in 2:
		var game: Match = Fixture.new()._healthy(context)
		var old_game: RefCounted = game.games[active]
		var session: RefCounted = game.sessions[active]._core
		var frame: int = session.status().current_frame
		context.equal(session.submit_local_input(active, frame, PackedByteArray([2 if active == 0 else 8])).code, Types.Code.OK, "expert stages current local sample")
		var opened: RefCounted = session.begin_advance()
		context.equal(opened.code, Types.Code.READY, "expert owns shared core batch")
		var request: RefCounted = opened.batch.next_request()
		context.equal(request.kind, Types.Kind.SAVE, "expert retains bounded writer")
		var state: PackedInt64Array = _controls(game)
		context.equal(game.reset(), I.Code.BUSY, "manual batch blocks replacement on either peer")
		game.tick(PackedInt32Array([1, 4]))
		game.inject_desync()
		context.equal(game.raise_input_delay(0), Types.Code.BUSY, "manual ownership blocks first delay control")
		context.equal(game.raise_input_delay(1), Types.Code.BUSY, "manual ownership blocks second delay control")
		context.equal(_controls(game), state, "manual ownership preserves all outer control state")
		context.equal(request.writer.status(), SnapshotStatus.Code.OK, "rejected controls preserve expert writer")
		var saved: Driver.SaveResult = old_game.save_state(request.frame, request.writer)
		context.equal(session.complete_request(request.batch_id, request.request_id, saved.ok, saved.checksum).code, Types.Code.OK, "expert keeps original SAVE ownership")
		while true:
			request = opened.batch.next_request()
			if request == null:
				break
			var ok: bool = old_game.simulate_frame(request.frame, request.inputs)
			context.equal(session.complete_request(request.batch_id, request.request_id, ok).code, Types.Code.OK, "expert completes unchanged original batch")
		context.equal(game.reset(), I.Code.OK, "replacement works after expert batch releases")


func _callback_controls(context: RefCounted) -> void:
	for active: int in 2:
		for kind: int in [Types.Kind.SAVE, Types.Kind.LOAD, Types.Kind.ADVANCE]:
			var game: Match = Fixture.new()._healthy(context)
			var control: Match = Fixture.new()._healthy(context)
			var observed: GuardedGame = GuardedGame.new()
			var frame: int = game.games[active].frame
			context.equal(observed.load_state(frame, Match.Reader.new(game.games[active].canonical_bytes(), true)), true, "callback game restores original canonical state")
			context.equal(game.sessions[active]._driver.configure(game.sessions[active]._core, observed), Types.Code.OK, "callback game attaches while idle")
			game.games[active] = observed
			var owner: WeakRef = weakref(game)
			var calls: Array[int] = []
			observed.hook_kind = kind
			observed.hook = func() -> void:
				var target: Match = owner.get_ref()
				var before: PackedInt64Array = _controls(target)
				calls.append(kind)
				context.equal(target.reset(), I.Code.BUSY, "callback rejects replacement")
				context.equal(target.raise_input_delay(0), Types.Code.BUSY, "callback rejects first peer delay")
				context.equal(target.raise_input_delay(1), Types.Code.BUSY, "callback rejects second peer delay")
				target.tick(PackedInt32Array([1, 4]))
				target.inject_desync()
				context.equal(_controls(target), before, "callback controls preserve composed state before returning")
			game.latency_ticks = 3
			control.latency_ticks = 3
			for tick: int in 30:
				var buttons: PackedInt32Array = PackedInt32Array([1 if tick % 2 == 0 else 2, 4 if tick % 3 == 0 else 8])
				game.tick(buttons)
				control.tick(buttons)
			context.equal(calls, [kind], "requested callback boundary executes exactly once")
			for player: int in 2:
				context.bytes_equal(
					game.games[player].canonical_bytes(),
					control.games[player].canonical_bytes(),
					game.games[player].frame,
					"rejected callback controls preserve original canonical continuation"
				)


func _controls(game: Match) -> PackedInt64Array:
	return PackedInt64Array(
		[
			game.now_us,
			game.sent,
			game.dropped,
			game.delivered,
			game.failure,
			game.queued_packets(),
			game._tokens,
			int(game.games.size() == 2 and game.games[0].is_divergent),
			game.sessions[0].input_delay(0) if game.sessions.size() == 2 else -1,
			game.sessions[1].input_delay(1) if game.sessions.size() == 2 else -1
		]
	)


# Value: protects=retryable composed input rejection; fails_when=invalid buttons or expert conflicts poison live peers; why_new=ownership cases hold batches only; seam=none
func _input_preflight(context: RefCounted) -> void:
	for active: int in 2:
		var startup: Match = Match.new()
		startup.drop_every = 0
		startup.reorder = false
		startup.latency_ticks = 0
		context.equal(startup.reset(), I.Code.OK, "fresh peers begin synchronization")
		context.equal(
			startup.sessions[active]._core.submit_local_input(active, 0, PackedByteArray([2])).code,
			Types.Code.OK, "expert stages input before handshake")
		var before_start: PackedInt64Array = _controls(startup)
		context.equal(
			startup.tick(PackedInt32Array([1, 1])), Types.Code.INPUT_ALREADY_SUBMITTED,
			"synchronizing peer rejects conflict before delivery starts gameplay")
		context.equal(_controls(startup), before_start, "startup rejection preserves handshakes, clocks and queues")
		for tick: int in 40:
			startup.tick(PackedInt32Array([2, 2]))
		context.equal(startup.failure, I.Code.OK, "corrected startup input completes actual handshake")
		context.equal(startup.games[0].frame > 20 and startup.games[1].frame > 20, true, "both peers play after corrected startup")
	for active: int in 2:
		for rejection: String in ["conflict", "buttons", "faults"]:
			var game: Match = Fixture.new()._healthy(context)
			var expected: Match = Fixture.new()._healthy(context)
			var buttons: PackedInt32Array = PackedInt32Array([2, 8])
			var frame: int = game.sessions[active].status().current_frame
			if rejection == "conflict":
				var original: PackedByteArray = PackedByteArray([buttons[active]])
				context.equal(game.sessions[active]._core.submit_local_input(active, frame, original).code, Types.Code.OK, "expert stages input without holding a batch")
				buttons[active] = 1 if active == 0 else 4
			elif rejection == "buttons":
				buttons[active] = 256
			else:
				game.latency_ticks = -1
			var before: PackedInt64Array = _controls(game)
			var held: PackedInt32Array = game._held.duplicate()
			var canonical: Array[PackedByteArray] = [game.games[0].canonical_bytes(), game.games[1].canonical_bytes()]
			var rejected: int = Types.Code.INPUT_ALREADY_SUBMITTED if rejection == "conflict" else I.Code.INVALID_ARGUMENT
			context.equal(game.tick(buttons), rejected, "preflight reports the rejected control")
			context.equal(_controls(game), before, "rejected " + rejection + " preserves composed clock, packets and failure")
			context.equal(game._held, held, "rejected input preserves retained buttons on both peers")
			for player: int in 2:
				context.bytes_equal(game.games[player].canonical_bytes(), canonical[player], game.games[player].frame, "rejected attempt invokes no game callback")
			game.latency_ticks = 0
			for tick: int in 40:
				var valid: PackedInt32Array = PackedInt32Array([2, 8])
				game.tick(valid)
				expected.tick(valid)
			context.equal(game.failure, I.Code.OK, "corrected retry preserves playable match")
			context.equal(game.now_us, expected.now_us, "rejected attempt does not consume a service tick")
			for player: int in 2:
				context.bytes_equal(
					game.games[player].canonical_bytes(), expected.games[player].canonical_bytes(),
					game.games[player].frame, "corrected retry keeps original canonical continuation")

	var stalled: Match = Fixture.new()._healthy(context)
	stalled.is_partitioned = true
	for tick: int in 16:
		stalled.tick(PackedInt32Array([2, 8]))
	context.equal(stalled._held, PackedInt32Array([2, 8]), "prediction stalls retain both original samples")
	context.equal(stalled.tick(PackedInt32Array([1, 4])), I.Code.OK, "changed keyboard state services the held samples")
	context.equal(stalled._held, PackedInt32Array([2, 8]), "new buttons cannot replace stalled inputs")
	stalled.is_partitioned = false
	for tick: int in 80:
		stalled.tick(PackedInt32Array([1, 4]))
	context.equal(stalled.failure, I.Code.OK, "held samples recover after actual packet delivery resumes")
	context.equal(stalled.games[0].frame > 140 and stalled.games[1].frame > 140, true, "both peers resume beyond the stalled frame")
