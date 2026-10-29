extends RefCounted

# Value: protects=driver/expert equivalence inside real encoded P2P; fails_when=request dispatch changes network history;
# why_new=external-input parity bypasses peer publication, gossip and retransmission; seam=none
const Collector = preload("res://tests/runner/test_context.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Fixture = preload("res://tests/unit/test_peer_session.gd")
const Reference = preload("res://tests/oracle/reference_game.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
const Protocol = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const Lifecycle = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["two_peers", "multiple_local_slots", "eight_peers", "observer_controls", "partial_publication", "retained_retry", "runtime_delay"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "runtime_delay":
		_partial_publication(context, false, true, false, true)
		var collector: RefCounted = Collector.new(context.seed)
		_partial_publication(collector, false, true, false, true, true)
		context.equal(collector.failures.is_empty(), false, "omitted delayed ADVANCE is detected")
		if not collector.failures.is_empty():
			context.equal(collector.failures[0].label, "same callbacks through runtime delay correction", "omitted delayed ADVANCE fails at ordered dispatch")
		context.finish()
		return
	if name == "retained_retry":
		_partial_publication(context, false, true)
		_partial_publication(context, false, true, true)
		context.finish()
		return
	if name == "partial_publication":
		_partial_publication(context)
		context.finish()
		return
	if name == "observer_controls":
		_temporal_permutation_control(context)
		_load_control(context)
		_partial_publication_control(context)
		context.finish()
		return
	var unconfigured: RefCounted = Peer.new()
	context.equal(unconfigured.has_method("confirmed_inputs"), true, "network clients can read finalized inputs")
	if not unconfigured.has_method("confirmed_inputs"):
		context.finish()
		return
	context.equal(unconfigured.confirmed_inputs(0), null, "unconfigured peer has no finalized row")
	var count: int = 8 if name == "eight_peers" else (6 if name == "multiple_local_slots" else 2)
	var multiple: bool = name == "multiple_local_slots"
	_run(context, count, 2 if multiple else 0, multiple)
	context.finish()


func _sample(player: int, frame: int) -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray([0, 0, 0, 0])
	bytes.encode_u32(0, (frame * 7 + player * 11 + 3) % 97)
	return bytes


func _inputs(mesh: Dictionary, endpoint: int, permute: bool = false) -> Array[Driver.LocalInput]:
	var samples: Array[Driver.LocalInput] = []
	var frame: int = mesh.peers[endpoint].status().current_frame
	var sampled_frame: int = 21 - frame if permute and frame in [10, 11] else frame
	for player: int in range(mesh.owners.size()):
		if mesh.owners[player] == endpoint:
			samples.append(Driver.LocalInput.new(player, frame, _sample(player, sampled_frame)))
	return samples


func _compare(context: RefCounted, driven: Dictionary, expert: Dictionary, original: Array[PackedByteArray], checks: Array[int]) -> int:
	var event_count: int = 0
	for index: int in range(driven.peers.size()):
		var left: Peer = driven.peers[index]
		var right: Peer = expert.peers[index]
		context.equal(left.status().current_frame, right.status().current_frame, "same published frame")
		context.equal(left.status().confirmed_frame, right.status().confirmed_frame, "same mesh confirmation")
		context.equal(left.status().pending_rollback_frame, right.status().pending_rollback_frame, "same pending correction")
		var events: Array[Dictionary] = left.drain_events()
		event_count += events.size()
		context.equal(events, right.drain_events(), "same peer events")
		context.equal(left.drain_transitions(), right.drain_transitions(), "same protocol transitions")
		context.equal(driven.games[index].requests, expert.games[index].requests, "same ordered callbacks, inputs, statuses and snapshot bytes")
		context.bytes_equal(driven.games[index].game.bytes(), expert.games[index].game.bytes(), left.status().current_frame, "same canonical game state")
		var status: Types.Status = left.status()
		_compare_finalized_inputs(context, left, right, checks)
		if status.pending_rollback_frame == -1:
			var latest: Dictionary = {}
			for request: Dictionary in driven.games[index].requests:
				var boundary: int = request.frame + (1 if request.kind == "advance" else 0)
				latest[boundary] = request.state_bytes.hex_decode()
			for boundary: int in latest:
				if boundary <= status.confirmed_frame + 1:
					context.bytes_equal(latest[boundary], original[boundary], boundary, "independent finalized callback boundary")
			if status.current_frame <= status.confirmed_frame + 1:
				context.bytes_equal(driven.games[index].game.bytes(), original[status.current_frame], status.current_frame, "independent finalized current boundary")
				if status.current_frame > 0 and status.current_frame < original.size() - 1:
					checks[0] += 1
		driven.games[index].requests.clear()
		expert.games[index].requests.clear()
	return event_count


# Value: protects=network clients receive owned finalized inputs; fails_when=peer facade exposes provisional rows;
# why_new=canonical state parity does not exercise the public input export; seam=none
func _compare_finalized_inputs(context: RefCounted, left: Peer, right: Peer, checks: Array[int]) -> void:
	var status: Types.Status = left.status()
	context.equal(left.confirmed_inputs(-1), null, "negative row is unavailable")
	context.equal(left.confirmed_inputs(status.current_frame), null, "unsimulated row is unavailable")
	var delay: int = 0
	for player: int in range(left._config.player_count):
		if left.input_delay(player) >= 0:
			delay = left.input_delay(player)
			break
	for frame: int in range(maxi(0, status.current_frame - 3), status.current_frame):
		var visible: bool = frame <= status.confirmed_frame and (status.pending_rollback_frame < 0 or frame < status.pending_rollback_frame)
		var row: Types.FrameInputs = left.confirmed_inputs(frame)
		var manual: Types.FrameInputs = right.confirmed_inputs(frame)
		context.equal(row != null, visible, "only finalized corrected network rows are visible")
		context.equal(manual != null, visible, "expert facade shares finalized export gates")
		if row == null or manual == null:
			continue
		checks[1] += 1
		context.equal(row.player_count(), left._config.player_count, "owned finalized roster")
		for player: int in range(row.player_count()):
			var sample_frame: int = frame - delay
			if checks[3] == 1 and sample_frame in [10, 11]:
				sample_frame = 21 - sample_frame
			var expected: PackedByteArray = PackedByteArray([0, 0, 0, 0]) if frame < delay else _sample(player, sample_frame)
			var actual: Types.InputResult = row.read(player)
			context.equal(actual.status, Queue.Status.CONFIRMED, "finalized original input status")
			context.bytes_equal(actual.bytes, expected, frame, "network row matches independent original input")
			context.bytes_equal(manual.read(player).bytes, expected, frame, "manual network row matches independent original input")
			actual.bytes[0] ^= 255
			context.bytes_equal(left.confirmed_inputs(frame).read(player).bytes, expected, frame, "caller mutation cannot change retained network inputs")
	if status.pending_rollback_frame >= 0:
		checks[2] += 1
		context.equal(left.confirmed_inputs(status.pending_rollback_frame), null, "pending correction withholds affected row")


func _recover(context: RefCounted, driven: Dictionary, expert: Dictionary) -> void:
	for index: int in range(driven.peers.size()):
		var left: Driver.StepResult = driven.peers[index].recover(driven.now)
		var right: Driver.StepResult = _manual(expert.peers[index], expert.games[index], expert.now, [], false, expert.get("skip_load", false))
		context.equal(left.code, right.code, "same recovery outcome")
		context.equal(left.code, Types.Code.OK, "recovery remains healthy")
		context.equal(left.events, right.events, "same recovered core events")


func _collect(context: RefCounted, fixture: RefCounted, driven: Dictionary, expert: Dictionary, pending: Array[Dictionary], drop: bool = false) -> void:
	var left: Array[Dictionary] = fixture._drain(driven)
	var right: Array[Dictionary] = fixture._drain(expert)
	context.equal(left, right, "identical encoded publication and destinations")
	for packet: Dictionary in left:
		if drop and packet.bytes.decode_u16(6) == Protocol.Kind.INPUT:
			continue
		pending.append(packet)


func _deliver(context: RefCounted, fixture: RefCounted, driven: Dictionary, expert: Dictionary, pending: Array[Dictionary], duplicate: bool) -> void:
	pending.reverse()
	fixture._deliver(context, driven, pending)
	fixture._deliver(context, expert, pending)
	if duplicate:
		fixture._deliver(context, driven, pending)
		fixture._deliver(context, expert, pending)
	pending.clear()


func _temporal_permutation_control(context: RefCounted) -> void:
	var collector: RefCounted = Collector.new(context.seed)
	_run(collector, 2, 0, false, true)
	var expected: Dictionary = {
		"independent finalized callback boundary:11": 2,
		"independent finalized callback boundary:12": 4,
		"independent finalized current boundary:12": 2,
	}
	context.equal(collector.failures.size(), 8, "paired permutation rejects eight intermediate prefixes")
	for failure: Dictionary in collector.failures:
		context.equal(failure.kind, "bytes", "permutation fails a canonical byte comparison")
		var identity: String = "%s:%d" % [failure.get("label", ""), failure.get("frame", -1)]
		context.equal(expected.has(identity), true, "only intended temporal-prefix diagnostics; final state and paired comparisons stay equal")
		if expected.has(identity):
			expected[identity] -= 1
	for remaining: int in expected.values():
		context.equal(remaining, 0, "every intended intermediate prefix diagnostic observed")


func _load_control(context: RefCounted) -> void:
	var collector: RefCounted = Collector.new(context.seed)
	_run(collector, 2, 0, false, false, true)
	var first: Dictionary = collector.failures[0] if not collector.failures.is_empty() else {}
	(
		context
		. equal(
			first,
			{
				"kind": "equality",
				"label": "same recovery outcome",
				"actual": str(Types.Code.OK),
				"expected": str(Types.Code.SNAPSHOT_FAILED),
			},
			"skipped expert LOAD fails at the actual recovery acknowledgement"
		)
	)
	var has_request_divergence: bool = false
	for failure: Dictionary in collector.failures:
		if failure.get("label", "") == "same ordered callbacks, inputs, statuses and snapshot bytes":
			has_request_divergence = true
			break
	context.equal(has_request_divergence, true, "request comparator observes omitted expert LOAD")


func _original(context: RefCounted, count: int, delay: int, target: int) -> Array[PackedByteArray]:
	var game: RefCounted = Reference.new(count, 2)
	var boundaries: Array[PackedByteArray] = [game.bytes()]
	for frame: int in range(target):
		var row: Array[Dictionary] = []
		for player: int in range(count):
			var bytes: PackedByteArray = PackedByteArray([0, 0, 0, 0]) if frame < delay else _sample(player, frame - delay)
			row.append({"player": player, "bytes": bytes.hex_encode(), "status": "confirmed"})
		context.equal(game.advance(row), "", "independent original input simulation")
		boundaries.append(game.bytes())
	return boundaries


func _run(context: RefCounted, count: int, delay: int, multiple: bool, permute: bool = false, skip_load: bool = false) -> void:
	var queue_capacity: int = 10 if count == 8 else 16
	var target: int = 24 if count == 8 else 40
	context.equal(target > 2 * queue_capacity, true, "workload crosses at least two full input-ring wraps")
	var original: Array[PackedByteArray] = _original(context, count, delay, target)
	var checks: Array[int] = [0, 0, 0, int(permute)]
	var fixture: RefCounted = Fixture.new()
	var lifecycle: Lifecycle.Options = Lifecycle.Options.new()
	lifecycle.keepalive_interval_us = 20000
	lifecycle.disconnect_notify_us = 100000
	var driven: Dictionary = fixture._build(context, count, delay, multiple, 128, true, false, 4, lifecycle, 8, 0, null, queue_capacity)
	var expert: Dictionary = fixture._build(context, count, delay, multiple, 128, true, false, 4, lifecycle, 8, 0, null, queue_capacity, 0, true)
	expert.skip_load = skip_load
	var pending: Array[Dictionary] = []
	var stalls: int = 0
	var event_count: int = 0
	for tick: int in range(100):
		driven.now = (tick + 1) * 20000
		expert.now = driven.now
		for index: int in range(driven.peers.size()):
			if driven.peers[index].status().current_frame >= target:
				continue
			var left: Driver.StepResult = driven.peers[index].step(driven.now, _inputs(driven, index, permute))
			var right: Driver.StepResult = _manual(expert.peers[index], expert.games[index], expert.now, _inputs(expert, index, permute), true, skip_load)
			context.equal(left.code, right.code, "same step outcome under delivery pressure")
			context.equal(left.code in [Types.Code.OK, Types.Code.PREDICTION_STALL], true, "delivery remains recoverable")
			context.equal(left.events, right.events, "same completed core events")
			if left.code == Types.Code.PREDICTION_STALL:
				stalls += 1
		_collect(context, fixture, driven, expert, pending, tick % 7 == 0)
		if tick % 7 == 6:
			_deliver(context, fixture, driven, expert, pending, true)
			_collect(context, fixture, driven, expert, pending)
			_deliver(context, fixture, driven, expert, pending, false)
			for index: int in range(driven.peers.size()):
				_compare_finalized_inputs(context, driven.peers[index], expert.peers[index], checks)
			_recover(context, driven, expert)
			_collect(context, fixture, driven, expert, pending)
			_deliver(context, fixture, driven, expert, pending, false)
		event_count += _compare(context, driven, expert, original, checks)
		if driven.peers[0].status().current_frame == target:
			break
	context.equal(stalls > 0, true, "delivery outage actually reaches prediction limit")
	# Finish via the public recovery operation, without manufacturing another local sample.
	for iteration: int in range(8):
		driven.now += 200000
		expert.now = driven.now
		_deliver(context, fixture, driven, expert, pending, false)
		_recover(context, driven, expert)
		_collect(context, fixture, driven, expert, pending)
		event_count += _compare(context, driven, expert, original, checks)
	context.equal(event_count > 0, true, "peer control events actually observed")
	context.equal(checks[0] > 0, true, "independent intermediate finalized boundaries actually checked")
	context.equal(checks[1] > 0, true, "public finalized rows actually checked")
	context.equal(checks[2] > 0, true, "pending correction export gate actually checked")
	for index: int in range(driven.peers.size()):
		var peer: Peer = driven.peers[index]
		context.equal(peer.status().current_frame, target, "crossed queue wrap with no extra forward frame")
		context.equal(peer.status().confirmed_frame, target + delay - 1, "mesh finalized every delayed scheduled input")
		context.equal(peer.status().pending_rollback_frame, -1, "final history correction completed")
		context.equal(peer.statistics().rollback_count > 0, true, "changing late inputs caused actual rollback")
		var reports: Dictionary = peer.network_status().checksums.verified_reports
		context.equal(reports.size(), driven.peers.size() - 1, "checksum evidence names every remote endpoint")
		for verified: int in reports.values():
			context.equal(verified > 0, true, "each remote checksum was actually verified")
		context.bytes_equal(driven.games[index].game.bytes(), original[target], target, "both consumers match independent original history")


func _manual(peer: Peer, game: RefCounted, now_us: int, samples: Array[Driver.LocalInput], forward: bool, skip_load: bool = false, skip_advance: bool = false) -> Driver.StepResult:
	var before: int = peer.status().current_frame
	var opened: Types.Result = peer.begin_step(now_us, samples) if forward else peer.begin_recovery(now_us)
	var result: Driver.StepResult = Driver.StepResult.new(opened.code, before, peer.status().current_frame)
	if opened.code != Types.Code.READY:
		return result
	while true:
		var request: Types.Request = opened.batch.next_request()
		if request == null:
			break
		var ok: bool = false
		var checksum: PackedByteArray = PackedByteArray()
		match request.kind:
			Types.Kind.SAVE:
				var saved: Driver.SaveResult = game.save_state(request.frame, request.writer)
				ok = saved.ok
				checksum = saved.checksum
			Types.Kind.LOAD:
				ok = true if skip_load else game.load_state(request.frame, request.reader)
			Types.Kind.ADVANCE:
				ok = true if skip_advance and request.frame == before else game.simulate_frame(request.frame, request.inputs)
		result = peer.complete_request(request.batch_id, request.request_id, ok, checksum)
		if result.code != Types.Code.READY:
			break
	return result


# Value: protects=expert/driver parity after one link accepts a sample; fails_when=refusal loses or republishes it;
# why_new=delivery-loss parity never fills publication capacity; seam=none
func _partial_publication(
	context: RefCounted, skip_advance: bool = false, retained: bool = false, multiple: bool = false, runtime_delay: bool = false, skip_delay_advance: bool = false
) -> void:
	var fixture: RefCounted = Fixture.new()
	var count: int = 6 if multiple else 3
	var driven: Dictionary = fixture._build(context, count, 0, multiple, 1)
	var expert: Dictionary = fixture._build(context, count, 0, multiple, 1, true, false, 8, null, 60, 0, null, 128, 0, true)
	for mesh: Dictionary in [driven, expert]:
		var notices: Array[PackedInt64Array] = []
		mesh.notices = notices
		mesh.peers[0].step_completed.connect(func(code: int, before: int, after: int) -> void: notices.append(PackedInt64Array([code, before, after])))
	for index: int in range(3):
		var left: Driver.StepResult = driven.peers[index].step(1, _inputs(driven, index))
		var right: Driver.StepResult = _manual(expert.peers[index], expert.games[index], 1, _inputs(expert, index), true)
		context.equal(left.code, right.code, "initial publication consumers agree")
		context.equal(left.code, Types.Code.OK, "initial publication advances")
	var initial: Array[Dictionary] = fixture._drain(driven)
	context.equal(initial, fixture._drain(expert), "same original encoded publication")
	var first_link: Array[Dictionary] = []
	for packet: Dictionary in initial:
		if packet.from == 0 and packet.to == 1:
			first_link.append(packet)
	for mesh: Dictionary in [driven, expert]:
		mesh.now = 1
		fixture._deliver(context, mesh, first_link)
	var acks: Array[Dictionary] = fixture._drain(driven)
	context.equal(acks, fixture._drain(expert), "same capacity-releasing acknowledgement")
	for mesh: Dictionary in [driven, expert]:
		fixture._deliver(context, mesh, acks)
		context.equal(mesh.peers[0].network_status().peers[fixture._id(1).hex_encode()].pending_frames, 0, "first link has capacity")
		context.equal(mesh.peers[0].network_status().peers[fixture._id(2).hex_encode()].pending_frames, 1, "second link remains full")
	for attempt: int in range(2):
		var retry: Array[Driver.LocalInput] = _inputs(driven, 0)
		if retained and attempt > 0:
			retry.clear()
		var left: Driver.StepResult = driven.peers[0].step(100, retry)
		var right: Driver.StepResult = _manual(expert.peers[0], expert.games[0], 100, retry, true)
		context.equal(left.code, right.code, "partial publication consumers agree")
		context.equal(left.code, Types.Code.NETWORK_BACKPRESSURE, "full second link refuses publication")
		context.equal(left.events, right.events, "same refused core events")
		context.equal(driven.games[0].requests, expert.games[0].requests, "same callbacks through refusal")
		context.equal(driven.games[0].game.frame, 1, "refused publication invokes no new game callback")
		context.bytes_equal(driven.peers[0].scheduled_local_input(0).bytes, _sample(0, 1), 1, "driver retains original partially published sample")
		context.bytes_equal(expert.peers[0].scheduled_local_input(0).bytes, _sample(0, 1), 1, "expert retains original partially published sample")
		if runtime_delay:
			for mesh: Dictionary in [driven, expert]:
				context.equal(mesh.peers[0].set_input_delay(0, 1), Types.Code.NETWORK_BACKPRESSURE, "partial publication refuses a delay raise")
				context.equal(mesh.peers[0].input_delay(0), 0, "refused raise preserves scheduling")
				context.bytes_equal(mesh.peers[0].scheduled_local_input(0).bytes, _sample(0, 1), 1, "refused raise preserves staged sample")
		var published: Array[Dictionary] = fixture._drain(driven)
		context.equal(published, fixture._drain(expert), "same partial publication packet bytes and destinations")
		context.equal(published.size(), 1 if attempt == 0 else 0, "accepted link publishes once across retries")
		if attempt == 0:
			for mesh: Dictionary in [driven, expert]:
				mesh.partial = published
	for mesh: Dictionary in [driven, expert]:
		mesh.now = 100
		fixture._deliver(context, mesh, initial)
	acks = fixture._drain(driven)
	context.equal(acks, fixture._drain(expert), "same remaining capacity acknowledgement")
	for mesh: Dictionary in [driven, expert]:
		fixture._deliver(context, mesh, acks)
		fixture._deliver(context, mesh, mesh.partial)
	acks = fixture._drain(driven)
	context.equal(acks, fixture._drain(expert), "same partial sample acknowledgement")
	for mesh: Dictionary in [driven, expert]:
		fixture._deliver(context, mesh, acks)
	var retry: Array[Driver.LocalInput] = _inputs(driven, 0)
	if retained:
		retry.clear()
	if retained and multiple:
		retry.append(_inputs(driven, 0)[1])
	var left: Driver.StepResult = driven.peers[0].step(100, retry)
	var right: Driver.StepResult = _manual(expert.peers[0], expert.games[0], 100, retry, true, false, skip_advance)
	context.equal(left.code, right.code, "retry after remaining acknowledgement agrees")
	context.equal(left.code, Types.Code.OK, "retained sample advances after pressure clears")
	context.equal(driven.games[0].requests, expert.games[0].requests, "same complete callbacks and canonical states")
	context.bytes_equal(driven.games[0].game.bytes(), expert.games[0].game.bytes(), 2, "same continuing canonical state")
	context.equal(driven.peers[0].status().current_frame, 2, "resumed sample advances exactly once")
	context.equal(driven.peers[0].scheduled_local_input(0).code, Types.Code.MISSING_LOCAL_INPUT, "accepted sample released only after advance")
	var completed: Array[Dictionary] = fixture._drain(driven)
	context.equal(completed, fixture._drain(expert), "same completed retry publication")
	context.equal(completed.size(), 1, "retry publishes only to the remaining recipient")
	var limits: Protocol.Limits = Protocol.Limits.new()
	limits.player_count = count
	limits.input_width = 4
	for packet: Dictionary in completed:
		context.equal([packet.from, packet.to], [0, 2], "retry targets the previously refused link")
		var decoded: Protocol.Result = Codec.decode(packet.bytes, limits)
		context.equal(decoded.code, Protocol.Code.OK, "retry packet decodes")
		if decoded.code == Protocol.Code.OK:
			context.equal(decoded.message.kind, Protocol.Kind.INPUT, "retry publishes gameplay input")
			context.equal(decoded.message.start_frame, 1, "retry publishes the retained scheduled frame")
			context.equal(decoded.message.frame_count, 1, "retry publishes one scheduled frame")
			var players: PackedByteArray = PackedByteArray([0, 1]) if multiple else PackedByteArray([0])
			var data: PackedByteArray = _sample(0, 1)
			if multiple:
				data.append_array(_sample(1, 1))
			context.equal(decoded.message.players, players, "retry publishes only the owning local slots")
			context.bytes_equal(decoded.message.data, data, 1, "retry packet contains the original samples")
	var original: RefCounted = Reference.new(count, 2)
	for frame: int in range(2):
		var row: Array[Dictionary] = []
		for player: int in range(count):
			row.append({"player": player, "bytes": _sample(player, frame if driven.owners[player] == 0 else 0).hex_encode(), "status": "confirmed"})
		context.equal(original.advance(row), "", "independent partially delivered history")
	context.bytes_equal(driven.games[0].game.bytes(), original.bytes(), 2, "driver retry matches independent input history")
	context.bytes_equal(expert.games[0].game.bytes(), original.bytes(), 2, "expert retry matches independent input history")
	for index: int in range(3):
		context.equal(driven.peers[index].drain_events(), expert.peers[index].drain_events(), "same accumulated peer events through partial publication")
		context.equal(driven.peers[index].drain_transitions(), expert.peers[index].drain_transitions(), "same accumulated protocol transitions through partial publication")
	context.equal(driven.notices, expert.notices, "same completion notification transcript through partial publication")
	(
		context
		. equal(
			driven.notices,
			[
				PackedInt64Array([Types.Code.OK, 0, 1]),
				PackedInt64Array([Types.Code.NETWORK_BACKPRESSURE, 1, 1]),
				PackedInt64Array([Types.Code.NETWORK_BACKPRESSURE, 1, 1]),
				PackedInt64Array([Types.Code.OK, 1, 2]),
			],
			"notifications preserve the refused and resumed frontiers"
		)
	)

	if runtime_delay:
		_runtime_delay(context, fixture, driven, expert, completed, skip_delay_advance)


func _partial_publication_control(context: RefCounted) -> void:
	var collector: RefCounted = Collector.new(context.seed)
	_partial_publication(collector, true)
	context.equal(collector.failures.size(), 3, "omitted retry ADVANCE fails transcript, paired and independent state comparisons")
	var labels: Array[String] = []
	for failure: Dictionary in collector.failures:
		labels.append(failure.get("label", ""))
	context.equal(
		labels,
		["same complete callbacks and canonical states", "same continuing canonical state", "expert retry matches independent input history"],
		"only intended partial-publication comparisons fail"
	)


# Value: protects=driver/expert scheduling after a refused raise; fails_when=retained sample moves twice;
# why_new=fixed-delay parity never changes scheduling while publication is partial; seam=none
func _runtime_delay(context: RefCounted, fixture: RefCounted, driven: Dictionary, expert: Dictionary, completed: Array[Dictionary], skip_advance: bool = false) -> void:
	var pending: Array[Dictionary] = completed.duplicate()
	for mesh: Dictionary in [driven, expert]:
		mesh.now = 101
	_deliver(context, fixture, driven, expert, pending, false)
	# Finish the other endpoints' frame one and release their last pending publications.
	for index: int in range(1, 3):
		context.equal(driven.peers[index].step(101, _inputs(driven, index)).code, Types.Code.OK, "remaining driver endpoint advances")
		context.equal(_manual(expert.peers[index], expert.games[index], 101, _inputs(expert, index), true).code, Types.Code.OK, "remaining expert endpoint advances")
	for round: int in range(3):
		_collect(context, fixture, driven, expert, pending)
		_deliver(context, fixture, driven, expert, pending, false)
	_recover(context, driven, expert)
	var prior_rollbacks: Array[int] = []
	for peer: Peer in driven.peers:
		prior_rollbacks.append(peer.statistics().rollback_count)
	for mesh: Dictionary in [driven, expert]:
		context.equal(mesh.peers[0].set_input_delay(0, 1), Types.Code.OK, "raise accepted after publication pressure drains")
		context.equal(mesh.peers[0].input_delay(0), 1, "one accepted raise changes delay once")
		context.equal(mesh.peers[0].scheduled_local_input(0).code, Types.Code.MISSING_LOCAL_INPUT, "raise needs no fabricated local sample")
	_collect(context, fixture, driven, expert, pending)
	context.equal(pending.size(), 2, "one raise packet per remote")
	var limits: Protocol.Limits = Protocol.Limits.new()
	limits.player_count = 3
	limits.input_width = 4
	for packet: Dictionary in pending:
		var decoded: Protocol.Result = Codec.decode(packet.bytes, limits)
		context.equal(decoded.code, Protocol.Code.OK, "delay raise packet decodes")
		if decoded.code == Protocol.Code.OK:
			context.equal([decoded.message.start_frame, decoded.message.frame_count], [2, 1], "raise adds exactly the next scheduled row")
			context.bytes_equal(decoded.message.data, _sample(0, 1), 2, "raise repeats retained original input exactly")
	_deliver(context, fixture, driven, expert, pending, false)
	for round: int in range(2):
		_collect(context, fixture, driven, expert, pending)
		_deliver(context, fixture, driven, expert, pending, false)
	var original: RefCounted = Reference.new(3, 2)
	for frame: int in range(4):
		var row: Array[Dictionary] = []
		for player: int in range(3):
			var sample_frame: int = frame if player != 0 or frame < 2 else frame - 1
			row.append({"player": player, "bytes": _sample(player, sample_frame).hex_encode(), "status": "confirmed"})
		context.equal(original.advance(row), "", "independent raised-delay original history")
		if frame < 2:
			continue
		for mesh: Dictionary in [driven, expert]:
			mesh.now += 200000
		for index: int in range(3):
			context.equal(driven.peers[index].step(driven.now, _inputs(driven, index)).code, Types.Code.OK, "driver continues after accepted raise")
			context.equal(
				_manual(expert.peers[index], expert.games[index], expert.now, _inputs(expert, index), true, false, skip_advance and frame == 2).code,
				Types.Code.OK,
				"expert continues after accepted raise"
			)
		for round: int in range(3):
			_collect(context, fixture, driven, expert, pending)
			_deliver(context, fixture, driven, expert, pending, false)
		_recover(context, driven, expert)
		for round: int in range(2):
			for mesh: Dictionary in [driven, expert]:
				mesh.now += 200000
			_recover(context, driven, expert)
			_collect(context, fixture, driven, expert, pending)
			_deliver(context, fixture, driven, expert, pending, false)
			_recover(context, driven, expert)
		for index: int in range(3):
			context.equal(driven.peers[index].status().confirmed_frame >= frame, true, "changed-delay frame actually mesh-confirms")
			context.equal(driven.peers[index].status().pending_rollback_frame, -1, "changed-delay frame finishes correction")
			context.equal(driven.games[index].requests, expert.games[index].requests, "same callbacks through runtime delay correction")
			context.bytes_equal(driven.games[index].game.bytes(), original.bytes(), frame + 1, "driver raised-delay canonical boundary")
			context.bytes_equal(expert.games[index].game.bytes(), original.bytes(), frame + 1, "expert raised-delay canonical boundary")
			context.equal(driven.peers[index].drain_events(), expert.peers[index].drain_events(), "same events after runtime delay correction")
			context.equal(driven.peers[index].drain_transitions(), expert.peers[index].drain_transitions(), "same transitions after runtime delay correction")
	for index: int in range(3):
		context.equal(driven.peers[index].statistics().rollback_count > prior_rollbacks[index], true, "every endpoint actually corrects after the delay raise")
	context.equal(driven.notices, expert.notices, "same completion notifications through runtime delay correction")
