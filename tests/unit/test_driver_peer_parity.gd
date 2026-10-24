extends RefCounted

# Value: protects=driver/expert equivalence inside real encoded P2P; fails_when=request dispatch changes network history;
# why_new=external-input parity bypasses peer publication, gossip and retransmission; seam=existing peer driver field
const Collector = preload("res://tests/runner/test_context.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Fixture = preload("res://tests/unit/test_peer_session.gd")
const Reference = preload("res://tests/oracle/reference_game.gd")
const Protocol = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const Lifecycle = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")


class ExpertConsumer:
	extends Driver
	var skips_load: bool = false

	func step(now_us: int, samples: Array[Driver.LocalInput]) -> Driver.StepResult:
		return _consume(now_us, samples, true)

	func recover(now_us: int) -> Driver.StepResult:
		var empty: Array[Driver.LocalInput] = []
		return _consume(now_us, empty, false)

	func _consume(now_us: int, samples: Array[Driver.LocalInput], forward: bool) -> Driver.StepResult:
		var before: int = _session.status().current_frame
		var code: int = _session.poll(now_us).code
		if code != Types.Code.OK:
			return Driver.StepResult.new(code, before, before)
		for sample: Driver.LocalInput in samples:
			code = _session.submit_local_input(sample.player, sample.sample_frame, sample.bytes).code
			if code != Types.Code.OK:
				return Driver.StepResult.new(code, before, before)
		var opened: Types.Result = _session.begin_advance() if forward else _session.begin_recovery()
		code = opened.code
		if code == Types.Code.READY:
			while true:
				var request: Types.Request = opened.batch.next_request()
				if request == null:
					break
				var ok: bool = false
				var checksum: PackedByteArray = PackedByteArray()
				match request.kind:
					Types.Kind.SAVE:
						var saved: Driver.SaveResult = _game.save_state(request.frame, request.writer)
						ok = saved.ok
						checksum = saved.checksum
					Types.Kind.LOAD:
						ok = true if skips_load else _game.load_state(request.frame, request.reader)
					Types.Kind.ADVANCE:
						ok = _game.simulate_frame(request.frame, request.inputs)
				code = _session.complete_request(request.batch_id, request.request_id, ok, checksum).code
				if code not in [Types.Code.OK, Types.Code.PREDICTION_STALL]:
					break
		var result: Driver.StepResult = Driver.StepResult.new(code, before, _session.status().current_frame)
		result.events = _session.drain_events()
		return result


func cases() -> PackedStringArray:
	return PackedStringArray(["two_peers", "multiple_local_slots", "eight_peers", "observer_controls"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "observer_controls":
		_temporal_permutation_control(context)
		_load_control(context)
		context.finish()
		return
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


func _recover(context: RefCounted, driven: Dictionary, expert: Dictionary) -> void:
	for index: int in range(driven.peers.size()):
		var left: Driver.StepResult = driven.peers[index].recover(driven.now)
		var right: Driver.StepResult = expert.peers[index].recover(expert.now)
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
	context.equal(first, {
		"kind": "equality", "label": "same recovery outcome",
		"actual": str(Types.Code.OK), "expected": str(Types.Code.SNAPSHOT_FAILED),
	}, "skipped expert LOAD fails at the actual recovery acknowledgement")
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
	var target: int = 40
	var original: Array[PackedByteArray] = _original(context, count, delay, target)
	var checks: Array[int] = [0]
	var fixture: RefCounted = Fixture.new()
	var lifecycle: Lifecycle.Options = Lifecycle.Options.new()
	lifecycle.keepalive_interval_us = 20000
	lifecycle.disconnect_notify_us = 100000
	var driven: Dictionary = fixture._build(context, count, delay, multiple, 128, true, false, 4, lifecycle, 8, 0, null, 16)
	var expert: Dictionary = fixture._build(context, count, delay, multiple, 128, true, false, 4, lifecycle, 8, 0, null, 16)
	for index: int in range(expert.peers.size()):
		# Only the request consumer differs; handshake, endpoints and game callbacks remain production code.
		var consumer: ExpertConsumer = ExpertConsumer.new(expert.peers[index]._core, expert.games[index])
		consumer.skips_load = skip_load
		expert.peers[index]._driver = consumer
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
			var right: Driver.StepResult = expert.peers[index].step(expert.now, _inputs(expert, index, permute))
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
