extends RefCounted

# Value: protects=callback/expert equality through coordinated departure and frozen-history repair;
# fails_when=manual dispatch skips repair or either facade loses drop statuses; why_new=ordinary P2P parity never departs; seam=none
const Fixture = preload("res://tests/unit/test_peer_session.gd")
const Parity = preload("res://tests/unit/test_driver_peer_parity.gd")
const Collector = preload("res://tests/runner/test_context.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Lifecycle = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")
const EndpointTypes = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
const Protocol = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const Drop = preload("res://addons/fortress_rollback/core/peer_drop_barrier.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const Reference = preload("res://tests/oracle/reference_game.gd")

const ROUND_US: int = 50000
const TARGET: int = 24


func cases() -> PackedStringArray:
	return PackedStringArray(["confirmed_departure", "predicted_departure", "repair_control", "certification_control", "withheld_certificate"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "withheld_certificate":
		_run(context, false, false, "withhold_ready")
	elif name == "certification_control":
		for mutation: String in ["follower", "proposer"]:
			var control: RefCounted = Collector.new(context.seed)
			_run(control, false, false, mutation)
			context.equal(control.failures.size(), 1, "removing actual certification fails its agreement assertion")
			if control.failures.size() == 1:
				var label: String = "follower certified the agreed value" if mutation == "follower" else "proposer retains every remote survivor certificate"
				context.equal(control.failures[0].get("label", ""), label, "certification control fails at the intended agreement boundary")
	elif name == "repair_control":
		var control: RefCounted = Collector.new(context.seed)
		_run(control, true, true)
		context.equal(control.failures.size(), 1, "omitted manual LOAD fails the repair outcome comparison")
		if control.failures.size() == 1:
			context.equal(control.failures[0].get("label", ""), "same drop repair outcome", "negative control fails at the intended repair boundary")
	else:
		_run(context, name == "predicted_departure")
	context.finish()


func _exchange(context: RefCounted, fixture: RefCounted, driven: Dictionary, expert: Dictionary, departed: bool, hold_ready: bool = false, held: Array[Dictionary] = []) -> void:
	for iteration: int in range(4):
		var packets: Array[Dictionary] = fixture._drain(driven)
		context.equal(packets, fixture._drain(expert), "same encoded drop traffic and destinations")
		for packet: Dictionary in packets:
			if departed and (packet.from == 2 or packet.to == 2):
				continue
			if hold_ready:
				var limits: Protocol.Limits = Protocol.Limits.new()
				limits.player_count = 3
				limits.input_width = 4
				var decoded: Protocol.Result = Codec.decode(packet.bytes, limits)
				context.equal(decoded.code, Protocol.Code.OK, "certificate control decodes actual traffic")
				if decoded.code == Protocol.Code.OK and decoded.message.kind == Protocol.Kind.DROP_BARRIER \
					and decoded.message.phase == Drop.Phase.REPORT and decoded.message.stage == Drop.Stage.READY:
					held.append(packet)
					continue
			for mesh: Dictionary in [driven, expert]:
				context.equal(mesh.peers[packet.to].receive(packet.bytes, fixture._id(packet.from), mesh.now), EndpointTypes.Code.OK, "deliver actual encoded survivor traffic")


func _observe(context: RefCounted, driven: Dictionary, expert: Dictionary, events: Array[Array]) -> void:
	for index: int in range(2):
		var left: Array[Dictionary] = driven.peers[index].drain_events()
		context.equal(left, expert.peers[index].drain_events(), "same departure and lifecycle events")
		events[index].append_array(left)
		context.equal(driven.peers[index].drain_transitions(), expert.peers[index].drain_transitions(), "same departure protocol transitions")
		context.equal(driven.peers[index].status().current_frame, expert.peers[index].status().current_frame, "same exposed drop boundary")
		context.equal(driven.peers[index].status().confirmed_frame, expert.peers[index].status().confirmed_frame, "same drop confirmation")
		context.equal(driven.peers[index].status().pending_rollback_frame, expert.peers[index].status().pending_rollback_frame, "same frozen-history correction")
		context.equal(driven.games[index].requests, expert.games[index].requests, "same drop callbacks, statuses and state bytes")


func _advance(context: RefCounted, parity: RefCounted, driven: Dictionary, expert: Dictionary, active: int) -> void:
	for index: int in range(active):
		var left: Driver.StepResult = driven.peers[index].step(driven.now, parity._inputs(driven, index))
		var right: Driver.StepResult = parity._manual(expert.peers[index], expert.games[index], expert.now, parity._inputs(expert, index), true)
		context.equal(left.code, right.code, "same coordinated-drop advance outcome")
		context.equal(left.code, Types.Code.OK, "departure workload advances")
		context.equal(left.events, right.events, "same completed drop core events")


func _run(context: RefCounted, predicted: bool, skip_load: bool = false, certification_mutation: String = "") -> void:
	var fixture: RefCounted = Fixture.new()
	var parity: RefCounted = Parity.new()
	var controls: Lifecycle.Options = Lifecycle.Options.new()
	controls.disconnect_behavior = Lifecycle.Disconnect.CONTINUE
	controls.disconnect_notify_us = 100000
	controls.disconnect_timeout_us = 800000
	controls.drop_barrier_timeout_us = 700000
	controls.keepalive_interval_us = 1000
	controls.quality_report_interval_us = 1000
	var driven: Dictionary = fixture._build(context, 3, 0, false, 128, true, false, 8, controls, 60, 0, null, 128, TARGET)
	var expert: Dictionary = fixture._build(context, 3, 0, false, 128, true, false, 8, controls, 60, 0, null, 128, TARGET, true)
	var empty: Array[Driver.LocalInput] = []
	var events: Array[Array] = [[], []]
	var notices: Array[Array] = [[], []]
	for mesh_index: int in range(2):
		var mesh: Dictionary = driven if mesh_index == 0 else expert
		var transcript: Array = notices[mesh_index]
		for index: int in range(2):
			mesh.peers[index].step_completed.connect(func(code: int, before: int, after: int) -> void: transcript.append([index, code, before, after]))
	for frame: int in range(6):
		driven.now += ROUND_US
		expert.now = driven.now
		_advance(context, parity, driven, expert, 3)
		_exchange(context, fixture, driven, expert, false)
		_observe(context, driven, expert, events)
	for index: int in range(2):
		context.equal(driven.peers[index].recover(driven.now).code, Types.Code.OK, "finalize original confirmed prefix")
		context.equal(parity._manual(expert.peers[index], expert.games[index], expert.now, empty, false).code, Types.Code.OK, "expert finalizes original confirmed prefix")
	_observe(context, driven, expert, events)
	if predicted:
		for frame: int in range(3):
			driven.now += ROUND_US
			expert.now = driven.now
			_advance(context, parity, driven, expert, 2)
			_exchange(context, fixture, driven, expert, true)
			_observe(context, driven, expert, events)
	var held: Array[Dictionary] = []
	for iteration: int in range(24):
		driven.now += ROUND_US
		expert.now = driven.now
		for index: int in range(2):
			context.equal(driven.peers[index].poll(driven.now), EndpointTypes.Code.OK, "callback peer services survivor agreement")
			context.equal(expert.peers[index].poll(expert.now), EndpointTypes.Code.OK, "expert peer services survivor agreement")
		_exchange(context, fixture, driven, expert, true, certification_mutation == "withhold_ready", held)
		_observe(context, driven, expert, events)
	if certification_mutation == "withhold_ready":
		context.equal(held.is_empty(), false, "control withholds actual READY certificates")
		for mesh: Dictionary in [driven, expert]:
			for index: int in range(2):
				var barrier: Drop.Barrier = mesh.peers[index]._drops.barrier(fixture._id(2).hex_encode())
				context.equal(barrier != null, true, "withheld certificate leaves a real agreement")
				if barrier != null:
					context.equal(barrier.state, Drop.PENDING, "equal local frontiers cannot commit without the certificate")
				context.equal(mesh.peers[index]._core.frozen_frame(2), -1, "missing certificate prevents independent survivor freeze")
			context.equal(mesh.peers[0]._drops.barrier(fixture._id(2).hex_encode()).certificates.is_empty(), true, "coordinator has no withheld certificate")
			context.equal(mesh.peers[1]._drops.barrier(fixture._id(2).hex_encode()).certified, true, "follower actually certified the withheld value")
			for packet: Dictionary in held:
				context.equal(mesh.peers[packet.to].receive(packet.bytes, fixture._id(packet.from), mesh.now), EndpointTypes.Code.OK, "release the original READY bytes")
		for iteration: int in range(4):
			for mesh: Dictionary in [driven, expert]:
				for index: int in range(2):
					context.equal(mesh.peers[index].poll(mesh.now), EndpointTypes.Code.OK, "commit after certificate delivery")
			_exchange(context, fixture, driven, expert, true)
		_validate_agreement(context, fixture, parity, driven, expert)
		return
	if not certification_mutation.is_empty():
		var barrier: Drop.Barrier = driven.peers[1 if certification_mutation == "follower" else 0]._drops.barrier(fixture._id(2).hex_encode())
		context.equal(barrier != null, true, "certification control has a real retained operation")
		if barrier == null:
			return
		if certification_mutation == "follower":
			barrier.certified = false
		else:
			barrier.certificates.clear()
	_validate_agreement(context, fixture, parity, driven, expert)
	if not certification_mutation.is_empty():
		return
	var cuts: PackedInt64Array = PackedInt64Array()
	for index: int in range(2):
		var drops: Array[Dictionary] = []
		var pending: int = 0
		for event: Dictionary in events[index]:
			if event.kind == "peer_dropped":
				drops.append(event)
			elif event.kind == "peer_drop_pending":
				pending += 1
		context.equal(pending, 1, "each survivor enters one coordinated agreement")
		context.equal(drops.size(), 1, "each survivor commits exactly one drop")
		if drops.size() != 1:
			return
		cuts.append(drops[0].frame)
		context.equal(driven.peers[index].status().pending_rollback_frame, 6 if predicted else -1, "only simulated frozen suffix requires repair")
	context.equal(cuts, PackedInt64Array([5, 5]), "both facades and survivors preserve the full exposed original prefix")
	for index: int in range(2):
		var repaired_before: int = driven.peers[index].statistics().resimulated_frames
		var left: Driver.StepResult = driven.peers[index].recover(driven.now)
		var right: Driver.StepResult = parity._manual(expert.peers[index], expert.games[index], expert.now, empty, false, skip_load)
		context.equal(left.code, right.code, "same drop repair outcome")
		if skip_load:
			return
		context.equal(left.code, Types.Code.OK, "frozen suffix repair succeeds without a new sample")
		context.equal(driven.peers[index].statistics().resimulated_frames - repaired_before, 3 if predicted else 0, "departure repairs exactly its simulated suffix")
		context.equal(left.events, right.events, "same repair completion events")
		context.equal(driven.peers[index].status().pending_rollback_frame, -1, "drop suffix repair finishes")
	_observe(context, driven, expert, events)
	for iteration: int in range(TARGET - driven.peers[0].status().current_frame):
		driven.now += ROUND_US
		expert.now = driven.now
		_advance(context, parity, driven, expert, 2)
		_exchange(context, fixture, driven, expert, true)
		_observe(context, driven, expert, events)
	for iteration: int in range(4):
		driven.now += ROUND_US
		expert.now = driven.now
		for index: int in range(2):
			context.equal(driven.peers[index].recover(driven.now).code, Types.Code.OK, "callback final history recovery")
			context.equal(parity._manual(expert.peers[index], expert.games[index], expert.now, empty, false).code, Types.Code.OK, "expert final history recovery")
		_exchange(context, fixture, driven, expert, true)
		_observe(context, driven, expert, events)
	context.equal(notices[0], notices[1], "same completion transcript before, during and after departure")
	_validate_history(context, parity, driven, expert)


# The outcome alone cannot distinguish agreement from two independent local freezes.
func _validate_agreement(context: RefCounted, fixture: RefCounted, parity: RefCounted, driven: Dictionary, expert: Dictionary) -> void:
	var operation: int = -1
	var digest: int = 0
	for mesh: Dictionary in [driven, expert]:
		for index: int in range(2):
			var barrier: Drop.Barrier = mesh.peers[index]._drops.barrier(fixture._id(2).hex_encode())
			context.equal(barrier != null, true, "every facade and survivor retains the coordinated operation")
			if barrier == null:
				continue
			if operation < 0:
				operation = barrier.operation
				digest = barrier.digest
			context.equal(barrier.operation > 0, true, "departure has a valid operation identity")
			context.equal(barrier.operation, operation, "all survivors certify the same operation")
			context.equal(barrier.state, Drop.COMMITTED, "the coordinated operation commits")
			context.equal(barrier.coordinator, 0, "the lowest surviving slot coordinates the operation")
			context.equal(barrier.slots, PackedInt32Array([2]), "the agreement targets only the departed slot")
			context.equal(barrier.participants, PackedStringArray([fixture._id(1 - index).hex_encode()]), "the operation retains its exact remote survivor membership")
			context.equal(barrier.cut, 5, "the agreement certifies the full original prefix")
			context.equal(barrier.value, parity._sample(2, 5), "the agreement certifies the original cut sample")
			context.equal(barrier.digest > 0, true, "the certified sample has a nonzero digest")
			context.equal(barrier.digest, digest, "all survivors certify the same value digest")
			if index == 0:
				context.equal(barrier.role, Drop.Role.PROPOSER, "survivor zero collects the all-survivor certificate")
				context.equal(barrier.certificates.keys(), [fixture._id(1).hex_encode()], "proposer retains every remote survivor certificate")
				for identity: String in barrier.certificates:
					context.equal(barrier.certificates[identity], {"cut": 5, "digest": digest}, "the survivor certificate binds the agreed cut and original value")
			else:
				context.equal(barrier.role, Drop.Role.FOLLOWER, "survivor one certifies the coordinator value")
				context.equal(barrier.certified, true, "follower certified the agreed value")


func _validate_history(context: RefCounted, parity: RefCounted, driven: Dictionary, expert: Dictionary) -> void:
	var original: RefCounted = Reference.new(3, 2)
	var prefixes: Array[PackedByteArray] = [original.bytes()]
	for frame: int in range(TARGET):
		var row: Array[Dictionary] = []
		for player: int in range(3):
			var frozen: bool = player == 2 and frame > 5
			row.append({"player": player, "bytes": parity._sample(player, 5 if frozen else frame).hex_encode(), "status": "disconnected" if frozen else "confirmed"})
		context.equal(original.advance(row), "", "independent agreed frozen-input history")
		prefixes.append(original.bytes())
	for index: int in range(2):
		context.equal(driven.peers[index].status().current_frame, TARGET, "survivor continues beyond two prediction windows")
		context.equal(driven.peers[index].status().confirmed_frame, TARGET - 1, "survivors finalize the exact tail")
		context.bytes_equal(driven.games[index].game.bytes(), prefixes[TARGET], TARGET, "callback survivor matches independent frozen history")
		context.bytes_equal(expert.games[index].game.bytes(), prefixes[TARGET], TARGET, "expert survivor matches independent frozen history")
		var recording: RefCounted = driven.peers[index].replay()
		context.equal(recording.frame_count(), TARGET, "recording preserves all finalized survivor history")
		context.bytes_equal(recording.to_bytes(), expert.peers[index].replay().to_bytes(), TARGET, "same portable finalized recording")
		for frame: int in range(TARGET):
			var row: Types.FrameInputs = recording.inputs(frame)
			for player: int in range(3):
				var frozen: bool = player == 2 and frame > 5
				context.bytes_equal(row.read(player).bytes, parity._sample(player, 5 if frozen else frame), frame, "recorded original or frozen sample")
				context.equal(row.read(player).status, Queue.Status.DISCONNECTED if frozen else Queue.Status.CONFIRMED, "recorded finalized drop status")
		var latest: Dictionary = {}
		for request: Dictionary in driven.games[index].requests:
			if request.kind == "advance":
				latest[request.frame + 1] = request.state_bytes.hex_decode()
		for boundary: int in range(1, TARGET + 1):
			context.equal(latest.has(boundary), true, "every corrected canonical boundary was observed")
			if latest.has(boundary):
				context.bytes_equal(latest[boundary], prefixes[boundary], boundary, "every corrected callback prefix matches independent history")
