extends RefCounted

# Value: protects=manual/driver lifecycle parity through interrupted corrected gameplay and expiry;
# fails_when=both consumers omit lifecycle evidence; why_new=peer parity counts arbitrary events; seam=none
const Fixture = preload("res://tests/unit/test_peer_session.gd")
const Parity = preload("res://tests/unit/test_driver_peer_parity.gd")
const Collector = preload("res://tests/runner/test_context.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const Reference = preload("res://tests/oracle/reference_game.gd")
const Lifecycle = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["interrupted_recovery_expiry", "missing_resume_control", "stale_retained_sample_control"])


func run_case(name: String, context: RefCounted) -> void:
	if name in ["missing_resume_control", "stale_retained_sample_control"]:
		var control: RefCounted = Collector.new(context.seed)
		var stale: bool = name == "stale_retained_sample_control"
		_run(control, not stale, stale)
		context.equal(control.failures.size(), 2, "both equally incorrect consumer histories are rejected")
		for failure: Dictionary in control.failures:
			context.equal(
				failure.label,
				"independent canonical continuation after resumed retained input" if stale else "independently expected lifecycle phase: resumed",
				"shared error fails the independent contract"
			)
			if stale:
				context.equal(failure.frame, 9, "stale retained sample diverges exactly after its application")
	else:
		_run(context)
	context.finish()


func _run(context: RefCounted, omit_resume: bool = false, stale_sample: bool = false) -> void:
	var fixture: RefCounted = Fixture.new()
	var parity: RefCounted = Parity.new()
	var options: Lifecycle.Options = Lifecycle.Options.new()
	var driven: Dictionary = fixture._build(context, 2, 0, false, 128, true, false, 8, options, 0)
	var expert: Dictionary = fixture._build(context, 2, 0, false, 128, true, false, 8, options, 0, 0, null, 128, 0, true)
	var pending: Array[Dictionary] = []
	var empty: Array[Driver.LocalInput] = []
	for mesh: Dictionary in [driven, expert]:
		var notices: Array[PackedInt64Array] = []
		mesh.notices = notices
		for index: int in 2:
			mesh.peers[index].step_completed.connect(func(code: int, before: int, after: int) -> void: notices.append(PackedInt64Array([index, code, before, after])))
	for frame: int in 8:
		for index: int in 2:
			var left: Driver.StepResult = driven.peers[index].step(frame + 1, parity._inputs(driven, index))
			var right: Driver.StepResult = parity._manual(expert.peers[index], expert.games[index], frame + 1, parity._inputs(expert, index), true)
			context.equal(left.code, Types.Code.OK, "real changing inputs predict during delivery gap")
			context.equal(right.code, left.code, "manual prediction matches callback result")
		context.equal(fixture._drain(driven), fixture._drain(expert), "identical real encoded gap traffic")
	for index: int in 2:
		var driven_samples: Array[Driver.LocalInput] = parity._inputs(driven, index)
		var expert_samples: Array[Driver.LocalInput] = parity._inputs(expert, index)
		if stale_sample:
			driven_samples[0].bytes = parity._sample(index, 7)
			expert_samples[0].bytes = parity._sample(index, 7)
		context.equal(driven.peers[index].step(9, driven_samples).code, Types.Code.PREDICTION_STALL, "outage retains input at prediction bound")
		context.equal(
			parity._manual(expert.peers[index], expert.games[index], 9, expert_samples, true).code, Types.Code.PREDICTION_STALL, "manual outage reaches same prediction bound"
		)
		context.equal(driven.peers[index].scheduled_local_input(index).bytes, driven_samples[0].bytes, "stalled submitted sample stays owned")
	context.equal(fixture._drain(driven), fixture._drain(expert), "discard original stalled publication equally")
	# Fresh publication retries carry every original input, so no discarded packet is injected locally.
	for mesh: Dictionary in [driven, expert]:
		for peer: RefCounted in mesh.peers:
			peer.drain_transitions()
	_phase(context, driven, expert, "predicting", [])
	_poll(context, driven, expert, 500000)
	_phase(context, driven, expert, "exact interruption boundary", [])
	_collect(context, fixture, driven, expert, pending)
	_poll(context, driven, expert, 500001)
	_phase(context, driven, expert, "interrupted", ["network_interrupted"])
	_collect(context, fixture, driven, expert, pending)
	for mesh: Dictionary in [driven, expert]:
		mesh.now = 500002
	fixture._deliver(context, driven, pending)
	fixture._deliver(context, expert, pending)
	pending.clear()
	_collect(context, fixture, driven, expert, pending)
	fixture._deliver(context, driven, pending)
	fixture._deliver(context, expert, pending)
	pending.clear()
	_phase(context, driven, expert, "resumed", ["network_resumed"], omit_resume)
	for index: int in 2:
		context.equal(driven.peers[index].status().pending_rollback_frame, 0, "actual retry receipt opens historical correction")
		var left: Driver.StepResult = driven.peers[index].recover(500002)
		var right: Driver.StepResult = parity._manual(expert.peers[index], expert.games[index], 500002, empty, false)
		context.equal(left.code, Types.Code.OK, "resumed callback recovery completes")
		context.equal(right.code, left.code, "resumed manual recovery completes")
		context.equal(left.frame_after, 8, "recovery consumes no forward frame")
		context.equal(driven.peers[index].statistics().rollback_count, 1, "one real rollback serviced at each endpoint")
		context.equal(driven.peers[index].statistics().resimulated_frames, 8, "complete original prefix resimulated")
		context.bytes_equal(driven.games[index].game.bytes(), _original(8), 8, "independent original canonical history after resumed recovery")
	_phase(context, driven, expert, "corrected", [])
	for index: int in 2:
		context.equal(driven.peers[index].step(500002, empty).code, Types.Code.OK, "resumed callback consumes retained input without resampling")
		context.equal(
			parity._manual(expert.peers[index], expert.games[index], 500002, empty, true).code, Types.Code.OK, "resumed manual consumer advances the same retained sample"
		)
	_collect(context, fixture, driven, expert, pending)
	fixture._deliver(context, driven, pending)
	fixture._deliver(context, expert, pending)
	pending.clear()
	for index: int in 2:
		context.equal(driven.peers[index].recover(500002).code, Types.Code.OK, "continued callback repairs final original input")
		context.equal(parity._manual(expert.peers[index], expert.games[index], 500002, empty, false).code, Types.Code.OK, "continued manual consumer repairs final original input")
		context.bytes_equal(driven.games[index].game.bytes(), _original(9), 9, "independent canonical continuation after resumed retained input")
	_phase(context, driven, expert, "continued", [])
	_poll(context, driven, expert, 1000003)
	_phase(context, driven, expert, "second interruption", ["network_interrupted"])
	_poll(context, driven, expert, 2500002)
	_phase(context, driven, expert, "exact timeout boundary", [])
	for mesh: Dictionary in [driven, expert]:
		for peer: RefCounted in mesh.peers:
			context.equal(peer.status().lifecycle, Types.Lifecycle.RUNNING, "exact renewed timeout remains live")
	_poll(context, driven, expert, 2500003)
	_phase(context, driven, expert, "expired", ["disconnected"])
	for index: int in 2:
		var calls: int = driven.games[index].requests.size()
		var expert_calls: int = expert.games[index].requests.size()
		context.equal(driven.peers[index].recover(2500003).code, Types.Code.TERMINATED, "expired callback recovery rejects work")
		context.equal(parity._manual(expert.peers[index], expert.games[index], 2500003, empty, false).code, Types.Code.TERMINATED, "expired manual recovery rejects work")
		context.equal(driven.games[index].requests.size(), calls, "expiry invokes no further game callback")
		context.equal(expert.games[index].requests.size(), expert_calls, "expiry invokes no further manual game work")
		context.equal(driven.peers[index].status().reason, Types.Code.PROTOCOL_FAILED, "expiry has explicit protocol terminal cause")
		context.equal(expert.peers[index].status().reason, Types.Code.PROTOCOL_FAILED, "manual expiry preserves explicit protocol terminal cause")
	context.equal(driven.notices, expert.notices, "same ordered prediction, recovery and terminal completion notifications")
	var expected_notices: Array[PackedInt64Array] = []
	for frame: int in 8:
		for index: int in 2:
			expected_notices.append(PackedInt64Array([index, Types.Code.OK, frame, frame + 1]))
	for operation: PackedInt64Array in [
		PackedInt64Array([Types.Code.PREDICTION_STALL, 8, 8]),
		PackedInt64Array([Types.Code.OK, 8, 8]),
		PackedInt64Array([Types.Code.OK, 8, 9]),
		PackedInt64Array([Types.Code.OK, 9, 9]),
		PackedInt64Array([Types.Code.TERMINATED, 9, 9])
	]:
		for index: int in 2:
			expected_notices.append(PackedInt64Array([index, operation[0], operation[1], operation[2]]))
	context.equal(driven.notices, expected_notices, "independent ordered completion codes and committed frame boundaries")


func _poll(context: RefCounted, driven: Dictionary, expert: Dictionary, now_us: int) -> void:
	for index: int in 2:
		var left: int = driven.peers[index].poll(now_us)
		context.equal(left, expert.peers[index].poll(now_us), "same elapsed-time poll result")
		context.equal(left, I.Code.OK, "bounded lifecycle polling succeeds")


func _collect(context: RefCounted, fixture: RefCounted, driven: Dictionary, expert: Dictionary, pending: Array[Dictionary]) -> void:
	var packets: Array[Dictionary] = fixture._drain(driven)
	context.equal(packets, fixture._drain(expert), "same actual lifecycle and retransmission bytes")
	pending.append_array(packets)


func _phase(context: RefCounted, driven: Dictionary, expert: Dictionary, phase: String, expected: Array, omit_resume: bool = false) -> void:
	for index: int in 2:
		var left: Array[Dictionary] = driven.peers[index].drain_events()
		var right: Array[Dictionary] = expert.peers[index].drain_events()
		if omit_resume:
			left = left.filter(func(event: Dictionary) -> bool: return event.kind != "network_resumed")
			right = right.filter(func(event: Dictionary) -> bool: return event.kind != "network_resumed")
		context.equal(left, right, "same complete peer events: " + phase)
		var lifecycle: Array[String] = []
		for event: Dictionary in left:
			if event.kind in ["network_interrupted", "network_resumed", "disconnected"]:
				lifecycle.append(event.kind)
				context.equal(event.peer, Fixture.new()._id(1 - index), "lifecycle event names actual remote endpoint")
		context.equal(lifecycle, expected, "independently expected lifecycle phase: " + phase)
		context.equal(driven.peers[index].drain_transitions(), expert.peers[index].drain_transitions(), "same protocol transitions: " + phase)
		context.equal(driven.peers[index].network_status(), expert.peers[index].network_status(), "same protocol observation: " + phase)
		context.equal(driven.games[index].requests, expert.games[index].requests, "same ordered callbacks and input statuses: " + phase)
		context.bytes_equal(
			driven.games[index].game.bytes(), expert.games[index].game.bytes(), driven.peers[index].status().current_frame, "same displayed canonical state: " + phase
		)


func _original(frames: int) -> PackedByteArray:
	var game: Reference = Reference.new(2, 2)
	for frame: int in frames:
		var row: Array[Dictionary] = []
		for player: int in 2:
			var bytes: PackedByteArray = PackedByteArray([0, 0, 0, 0])
			bytes.encode_u32(0, (frame * 7 + player * 11 + 3) % 97)
			row.append({"player": player, "bytes": bytes.hex_encode(), "status": "confirmed"})
		game.advance(row)
	return game.bytes()
