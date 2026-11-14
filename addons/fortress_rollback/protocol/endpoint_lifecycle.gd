class_name FortressEndpointLifecycle
extends RefCounted

const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const L = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")

static func initial(options: L.Options) -> Dictionary:
	var local: Array[int] = []
	local.resize(options.time_sync_window)
	local.fill(0)
	return {"last_recv_us": -1, "last_send_us": -1, "last_quality_us": -1, "clock_origin_us": -1,
		"interrupted": false, "round_trip_time_ms": 0, "local_frame_advantage": 0, "remote_frame_advantage": 0,
		"average_frame_advantage": 0, "local_advantages": local, "remote_advantages": local.duplicate(),
		"local_advantage_sum": 0, "remote_advantage_sum": 0}

static func start(state: Dictionary, now_us: int) -> void:
	if state.clock_origin_us == -1:
		state.clock_origin_us = now_us
		state.last_recv_us = now_us
		state.last_send_us = now_us
		state.last_quality_us = now_us

static func token(millis: int) -> PackedByteArray:
	var result: PackedByteArray = PackedByteArray()
	result.resize(16)
	result.encode_s64(0, millis)
	return result

static func poll(plan: Dictionary, options: L.Options, packet: Callable, encode: Callable, can_send_control: bool = true) -> int:
	var state: Dictionary = plan.state
	if can_send_control and state.now_us - state.last_quality_us > options.quality_report_interval_us:
		# The ping token is this endpoint's own elapsed integer milliseconds; the
		# peer echoes it verbatim and only this clock resolves it, so probes stay
		# stateless across lost, reordered and duplicated replies.
		var millis: int = (state.now_us - state.clock_origin_us) / 1000
		var report: T.Message = packet.call(T.Kind.QUALITY_REPORT)
		report.token = token(millis)
		report.frame_advantage = clampi(state.local_frame_advantage, -32768, 32767)
		plan.outbox.append(encode.call(report))
		state.last_quality_us = state.now_us
		state.last_send_us = state.now_us
	if can_send_control and state.now_us - state.last_send_us > options.keepalive_interval_us:
		plan.outbox.append(encode.call(packet.call(T.Kind.KEEP_ALIVE)))
		state.last_send_us = state.now_us
	var elapsed: int = state.now_us - state.last_recv_us
	if elapsed > options.disconnect_notify_us and not state.interrupted:
		state.interrupted = true
		plan.events.append({"kind": "network_interrupted", "disconnect_timeout_ms": (options.disconnect_timeout_us - options.disconnect_notify_us) / 1000})
	if elapsed > options.disconnect_timeout_us:
		state.terminated = true
		plan.events.append({"kind": "disconnected", "reason": "timeout"})
	return I.Code.OK

static func received(plan: Dictionary) -> void:
	plan.state.last_recv_us = plan.state.now_us
	if plan.state.interrupted:
		plan.state.interrupted = false
		plan.events.append({"kind": "network_resumed"})

static func receive_control(plan: Dictionary, message: T.Message, packet: Callable, encode: Callable) -> int:
	received(plan)
	match message.kind:
		T.Kind.QUALITY_REPORT:
			plan.state.remote_frame_advantage = message.frame_advantage
			var reply: T.Message = packet.call(T.Kind.QUALITY_REPLY)
			reply.token = message.token.duplicate()
			plan.outbox.append(encode.call(reply))
		T.Kind.QUALITY_REPLY:
			# Upstream resolves every echo statelessly with a saturating
			# subtraction, so a lost, reordered, duplicated or stale-era token
			# re-measures the same sample instead of freezing the gauge at an
			# earlier reply; a pong wider than the clock range is a harmless
			# zero that the next report corrects.
			var millis: int = (plan.state.now_us - plan.state.clock_origin_us) / 1000
			var pong: int = message.token.decode_u64(0)
			if message.token.decode_u64(8) != 0 or pong < 0:
				pong = millis + 1
			plan.state.round_trip_time_ms = maxi(0, millis - pong)
		T.Kind.CHECKSUM_REPORT:
			plan.events.append({"kind": "checksum_received", "frame": message.frame, "checksum": message.checksum.duplicate()})
		T.Kind.GOODBYE:
			plan.state.terminated = true
			plan.events.append({"kind": "disconnected", "reason": message.reason})
		T.Kind.DROP_BARRIER:
			plan.events.append({
				"kind": "drop_barrier",
				"phase": message.phase,
				"stage": message.stage,
				"reason": message.reason,
				"operation": message.operation,
				"coordinator": message.coordinator,
				"coordinator_generation": message.coordinator_generation,
				"target_set_digest": message.target_set_digest,
				"cut": message.cut,
				"bound": message.bound,
				"available_through": message.available_through,
				"cut_digest": message.cut_digest,
				"chunk_index": message.chunk_index,
				"chunk_count": message.chunk_count,
				"witnessed": message.witnessed,
				"slots": message.data.duplicate(),
				"bytes": message.bytes.duplicate(),
			})
		T.Kind.KEEP_ALIVE:
			pass
		_:
			return I.Code.UNSUPPORTED_KIND
	return I.Code.OK

static func sample(state: Dictionary, frame: int, options: L.Options) -> void:
	var index: int = frame % options.time_sync_window
	state.local_advantage_sum += state.local_frame_advantage - state.local_advantages[index]
	state.remote_advantage_sum += state.remote_frame_advantage - state.remote_advantages[index]
	state.local_advantages[index] = state.local_frame_advantage
	state.remote_advantages[index] = state.remote_frame_advantage
	state.average_frame_advantage = (state.remote_advantage_sum - state.local_advantage_sum) / (2 * options.time_sync_window)
