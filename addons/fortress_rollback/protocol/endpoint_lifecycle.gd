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
		"average_frame_advantage": 0, "quality_pending": {}, "local_advantages": local, "remote_advantages": local.duplicate(),
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

static func poll(plan: Dictionary, options: L.Options, packet: Callable, encode: Callable) -> int:
	var state: Dictionary = plan.state
	if state.now_us - state.last_quality_us > options.quality_report_interval_us:
		var millis: int = (state.now_us - state.clock_origin_us) / 1000
		var key: String = token(millis).hex_encode()
		if not state.quality_pending.has(key) and state.quality_pending.size() >= options.max_pending_quality:
			# Expired pings do not prevent liveness traffic during a long partition.
			state.quality_pending.erase(state.quality_pending.keys()[0])
		state.quality_pending[key] = millis
		var report: T.Message = packet.call(T.Kind.QUALITY_REPORT)
		report.token = token(millis)
		report.frame_advantage = clampi(state.local_frame_advantage, -32768, 32767)
		plan.outbox.append(encode.call(report))
		state.last_quality_us = state.now_us
		state.last_send_us = state.now_us
	if state.now_us - state.last_send_us > options.keepalive_interval_us:
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
			var key: String = message.token.hex_encode()
			if plan.state.quality_pending.has(key):
				var millis: int = (plan.state.now_us - plan.state.clock_origin_us) / 1000
				plan.state.round_trip_time_ms = maxi(0, millis - plan.state.quality_pending[key])
				plan.state.quality_pending.erase(key)
		T.Kind.CHECKSUM_REPORT:
			plan.events.append({"kind": "checksum_received", "frame": message.frame, "checksum": message.checksum.duplicate()})
		T.Kind.GOODBYE:
			plan.state.terminated = true
			plan.events.append({"kind": "disconnected", "reason": message.reason})
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
