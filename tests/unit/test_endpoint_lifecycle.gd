extends RefCounted

# Value: protects=running controls and strict liveness; fails_when=controls are ignored; why_new=P4 lifecycle; seam=none
const E = preload("res://addons/fortress_rollback/protocol/input_endpoint.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
const L = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")
const H = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const Fixture = preload("res://tests/unit/test_input_endpoint.gd")

func cases() -> PackedStringArray:
	return PackedStringArray(["control_receive", "strict_timers", "liveness", "quality", "checksum_goodbye", "capacity", "pacing", "long_running", "retention_failure"])

func run_case(_name: String, context: RefCounted) -> void:
	if _name != "control_receive":
		call("_" + _name, context)
		context.finish()
		return
	var fixture: RefCounted = Fixture.new()
	var sink: RefCounted = Fixture.Sink.new()
	var endpoint: E = _ready(fixture, sink)
	var message: T.Message = fixture._local(2)
	message.kind = T.Kind.QUALITY_REPORT
	message.frame_advantage = 7
	message.token[15] = 255
	context.equal(endpoint.receive(fixture._encode(message), fixture._id(2), 2), I.Code.OK, "running quality reports are accepted")
	var packets: Array[PackedByteArray] = endpoint.drain_outbox()
	context.equal(packets.size(), 1, "report echoes full timestamp")
	if not packets.is_empty():
		context.equal(fixture._decoded(packets[0]).token, message.token, "wide echo preserved")
	context.finish()

func _ready(fixture: RefCounted, sink: RefCounted, options: L.Options = null, inputs: I.Options = null) -> E:
	var endpoint: E = E.new()
	var handshake: H.Options = H.Options.new()
	handshake.roundtrips = 1
	endpoint.configure(fixture._local(), fixture._id(2), handshake, inputs if inputs != null else I.Options.new(), sink.accept,
		options if options != null else L.Options.new())
	endpoint.begin(0, fixture._id(1, 16))
	endpoint.drain_outbox()
	var reply: T.Message = fixture._local(2)
	reply.kind = T.Kind.SYNC_REPLY
	reply.token = fixture._id(1, 16)
	endpoint.receive(fixture._encode(reply), fixture._id(2), 1)
	endpoint.drain_events()
	endpoint.drain_transitions()
	return endpoint

func _message(fixture: RefCounted, kind: int) -> T.Message:
	var result: T.Message = fixture._local(2)
	result.kind = kind
	return result

func _strict_timers(context: RefCounted) -> void:
	var f: RefCounted = Fixture.new()
	var options: L.Options = L.Options.new()
	var endpoint: E = _ready(f, Fixture.Sink.new(), options)
	context.equal(endpoint.poll(200000), I.Code.OK, "quality equality does not fire")
	context.equal(endpoint.drain_outbox().size(), 0, "strict timer equality")
	context.equal(endpoint.poll(200001), I.Code.OK, "quality strict boundary")
	var packets: Array[PackedByteArray] = endpoint.drain_outbox()
	context.equal(packets.size(), 1, "quality suppresses keepalive")
	context.equal(f._decoded(packets[0]).kind, T.Kind.QUALITY_REPORT, "quality before keepalive")
	context.equal(f._decoded(packets[0]).token.decode_s64(0), 200, "own elapsed integer milliseconds")
	endpoint.drain_events()
	context.equal(endpoint.poll(500001), I.Code.OK, "notify exact boundary")
	context.equal(endpoint.drain_events().size(), 0, "no interruption at equality")
	endpoint.drain_outbox()
	endpoint.poll(500002)
	context.equal(endpoint.drain_events(), [{"kind": "network_interrupted", "disconnect_timeout_ms": 1500}], "notify remaining constant")
	endpoint.drain_outbox()
	endpoint.poll(2000001)
	context.equal(endpoint.status().state, "running", "timeout equality still runs")
	endpoint.drain_outbox()
	context.equal(endpoint.poll(2000002), I.Code.OK, "timeout strict boundary")
	context.equal(endpoint.drain_events(), [{"kind": "disconnected", "reason": "timeout"}], "timeout emits once")
	context.equal(endpoint.status().state, "terminated", "fixed membership closes on timeout")
	context.equal(endpoint.poll(2000003), I.Code.TERMINATED, "terminal cannot resurrect")
	options.quality_report_interval_us = 1000000
	endpoint = _ready(f, Fixture.Sink.new(), options)
	endpoint.poll(200001)
	context.equal(f._decoded(endpoint.drain_outbox()[0]).kind, T.Kind.KEEP_ALIVE, "independent keepalive cadence")
	var sink: RefCounted = Fixture.Sink.new()
	endpoint = _ready(f, sink, options)
	endpoint.submit(0, PackedByteArray([1]), f._statuses(), 2)
	endpoint.drain_outbox()
	for now: int in [200003, 400004]:
		endpoint.poll(now)
		var retry: Array[PackedByteArray] = endpoint.drain_outbox()
		context.equal(retry.size(), 1, "input retry suppresses keepalive in same service")
		context.equal(f._decoded(retry[0]).kind, T.Kind.INPUT, "input retry is the sent message")
	endpoint = _ready(f, sink, options)
	var request: T.Message = f._local(2)
	context.equal(endpoint.receive(f._encode(request), f._id(2), 200000), I.Code.OK, "running handshake request is accepted")
	context.equal(endpoint.drain_outbox().size(), 1, "running handshake request sends its reply")
	context.equal(endpoint.poll(200001), I.Code.OK, "service immediately after handshake reply")
	context.equal(endpoint.drain_outbox().size(), 0, "handshake reply postpones keepalive")

func _liveness(context: RefCounted) -> void:
	var f: RefCounted = Fixture.new()
	var endpoint: E = _ready(f, Fixture.Sink.new())
	endpoint.poll(500002)
	endpoint.drain_outbox()
	endpoint.drain_events()
	var before: Dictionary = endpoint.status()
	var message: T.Message = _message(f, T.Kind.KEEP_ALIVE)
	message.connection_id[0] += 1
	context.equal(endpoint.receive(f._encode(message), f._id(2), 600000), I.Code.WRONG_CONNECTION, "wrong era cannot refresh liveness")
	context.equal(endpoint.status(), before, "rejected era preserves clock")
	context.equal(endpoint.receive(PackedByteArray([1]), f._id(2), 600000), I.Code.INVALID_PACKET, "invalid body")
	context.equal(endpoint.status(), before, "invalid body preserves clocks")
	message.connection_id = f._id(20)
	context.equal(endpoint.receive(f._encode(message), f._id(2), 600000), I.Code.OK, "keepalive resumes")
	context.equal(endpoint.drain_events(), [{"kind": "network_resumed"}], "resume once")
	context.equal(endpoint.status().last_recv_us, 600000, "accepted packet refreshes liveness")
	endpoint.receive(f._encode(message), f._id(2), 600001)
	context.equal(endpoint.drain_events().size(), 0, "duplicate connected traffic emits no resume")
	var ack: T.Message = _message(f, T.Kind.INPUT_ACK)
	ack.ack_frame = 2147483647
	endpoint.receive(f._encode(ack), f._id(2), 700000)
	context.equal(endpoint.status().last_recv_us, 700000, "valid future ACK is ignored but remains liveness evidence")
	context.equal(endpoint.status().last_acked_frame, -1, "future ACK cannot consume input")

func _quality(context: RefCounted) -> void:
	var f: RefCounted = Fixture.new()
	var endpoint: E = _ready(f, Fixture.Sink.new())
	endpoint.poll(200001)
	var sent: T.Message = f._decoded(endpoint.drain_outbox()[0])
	var reply: T.Message = _message(f, T.Kind.QUALITY_REPLY)
	reply.token = sent.token
	context.equal(endpoint.receive(f._encode(reply), f._id(2), 250001), I.Code.OK, "known quality echo")
	context.equal(endpoint.status().round_trip_time_ms, 50, "RTT uses own echoed timestamp")
	reply.token[15] = 255
	endpoint.receive(f._encode(reply), f._id(2), 260001)
	context.equal(endpoint.status().round_trip_time_ms, 50, "unknown wide/future pong cannot poison RTT")
	context.equal(endpoint.status().quality_pending.size(), 0, "matched echo removes bounded pending key")
	var options: L.Options = L.Options.new()
	options.max_pending_quality = 1
	endpoint = _ready(f, Fixture.Sink.new(), options)
	for now: int in [200001, 400002, 600003]:
		endpoint.poll(now)
		endpoint.drain_outbox()
		endpoint.drain_events()
	context.equal(endpoint.status().quality_pending.size(), 1, "lost pongs cannot grow or stop probes")
	context.equal(endpoint.poll(600003.0), I.Code.INVALID_ARGUMENT, "float time rejected")
	context.equal(endpoint.poll(600002), I.Code.INVALID_ARGUMENT, "clock cannot rewind")

func _checksum_goodbye(context: RefCounted) -> void:
	var f: RefCounted = Fixture.new()
	var endpoint: E = _ready(f, Fixture.Sink.new())
	var bytes: PackedByteArray = f._id(99, 16)
	context.equal(endpoint.send_checksum(123, bytes, 2), I.Code.OK, "send bounded confirmed checksum")
	bytes.fill(0)
	var report: T.Message = f._decoded(endpoint.drain_outbox()[0])
	context.equal(report.frame, 123, "checksum frame preserved")
	context.equal(report.checksum[0], 99, "checksum bytes owned")
	report.sender_id = f._id(2)
	report.connection_id = f._id(20)
	context.equal(endpoint.receive(f._encode(report), f._id(2), 3), I.Code.OK, "receive checksum report")
	var events: Array[Dictionary] = endpoint.drain_events()
	context.equal(events, [{"kind": "checksum_received", "frame": 123, "checksum": report.checksum}], "checksum publication owned")
	context.equal(endpoint.close(4, 7), I.Code.OK, "explicit close")
	var packets: Array[PackedByteArray] = endpoint.drain_outbox()
	context.equal(packets.size(), 3, "source three best effort goodbyes")
	for packet: PackedByteArray in packets:
		context.equal(f._decoded(packet).reason, 7, "closure reason retained")
	context.equal(endpoint.status().state, "terminated", "close is terminal")
	context.equal(endpoint.close(5), I.Code.TERMINATED, "close cannot queue duplicates")
	endpoint = _ready(f, Fixture.Sink.new())
	var goodbye: T.Message = _message(f, T.Kind.GOODBYE)
	goodbye.reason = 5
	endpoint.poll(500002)
	endpoint.drain_outbox()
	endpoint.drain_events()
	endpoint.receive(f._encode(goodbye), f._id(2), 600000)
	context.equal(endpoint.drain_events(), [{"kind": "network_resumed"}, {"kind": "disconnected", "reason": 5}], "resume precedes remote closure event")
	context.equal(endpoint.status().state, "terminated", "remote goodbye stops fixed membership")

func _capacity(context: RefCounted) -> void:
	var f: RefCounted = Fixture.new()
	var inputs: I.Options = I.Options.new()
	inputs.max_events = 1
	var endpoint: E = _ready(f, Fixture.Sink.new(), null, inputs)
	var report: T.Message = _message(f, T.Kind.CHECKSUM_REPORT)
	endpoint.receive(f._encode(report), f._id(2), 2)
	context.equal(endpoint.receive(f._encode(report), f._id(2), 3), I.Code.BACKPRESSURE, "undrained diagnostics fail explicitly")
	context.equal(endpoint.status().state, "terminated", "event overflow cannot silently lose diagnostics")
	var events: Array[Dictionary] = endpoint.drain_events()
	context.equal(events.size(), 2, "reserved fatal slot bypasses ordinary queue bound")
	context.equal(events[-1].kind, "event_capacity_exceeded", "fatal capacity reason retained")
	context.equal(endpoint.drain_events().size(), 0, "fatal drains once")
	inputs.max_events = 128
	inputs.max_outbox = 1
	endpoint = _ready(f, Fixture.Sink.new(), null, inputs)
	endpoint.send_checksum(0, f._id(1,16), 2)
	var before: Dictionary = endpoint.status()
	var quality: T.Message = _message(f, T.Kind.QUALITY_REPORT)
	quality.frame_advantage = 9
	context.equal(endpoint.receive(f._encode(quality), f._id(2), 3), I.Code.BACKPRESSURE, "reply reserve fails atomically")
	context.equal(endpoint.status(), before, "reply backpressure preserves advantage and receive time")
	endpoint.drain_outbox()
	context.equal(endpoint.receive(f._encode(quality), f._id(2), 3), I.Code.OK, "draining allows valid control retry")

# Value: protects=resume before terminal retention failure; fails_when=committed resume event is discarded; why_new=existing refusal coverage lacks interrupted input; seam=none
func _retention_failure(context: RefCounted) -> void:
	var f: RefCounted = Fixture.new()
	for fail_frame: int in [0, 1]:
		var sink: RefCounted = Fixture.Sink.new()
		sink.fail_frame = fail_frame
		var inputs: I.Options = I.Options.new()
		inputs.max_events = 2
		var endpoint: E = _ready(f, sink, null, inputs)
		endpoint.poll(500002)
		endpoint.drain_events()
		endpoint.drain_outbox()
		context.equal(endpoint.receive(f._encode(f._input(0, PackedByteArray([1, 2]))), f._id(2), 600000), I.Code.INPUT_FAILED, "retention refusal terminates")
		context.equal(endpoint.drain_events(), [{"kind": "network_resumed"}, {"kind": "input_failed", "frame": fail_frame}], "resume precedes failure without success event")
		context.equal(endpoint.status().last_received_frame, fail_frame - 1, "only admitted prefix retained")
		context.equal(endpoint.status().interrupted, false, "published resume matches state")
		context.equal(endpoint.drain_outbox().size(), 0, "failure never acknowledges speculative input")
		context.equal(endpoint.drain_events().size(), 0, "terminal events drain once")
	var sink: RefCounted = Fixture.Sink.new()
	var inputs: I.Options = I.Options.new()
	inputs.max_events = 1
	var endpoint: E = _ready(f, sink, null, inputs)
	endpoint.poll(500002)
	endpoint.drain_events()
	endpoint.drain_outbox()
	context.equal(endpoint.receive(f._encode(f._input(0, PackedByteArray([1]))), f._id(2), 600000), I.Code.BACKPRESSURE, "resume and retention publication reserved together")
	context.equal(sink.frames.size(), 0, "capacity failure precedes irreversible sink")
	context.equal(endpoint.drain_events()[0].kind, "event_capacity_exceeded", "fatal capacity remains observable")

func _pacing(context: RefCounted) -> void:
	var f: RefCounted = Fixture.new()
	var options: L.Options = L.Options.new()
	options.time_sync_window = 2
	var sink: RefCounted = Fixture.Sink.new()
	var endpoint: E = _ready(f, sink, options)
	context.equal(endpoint.update_local_frame_advantage(10), I.Code.OK, "unknown remote frame preserves advantage")
	context.equal(endpoint.status().local_frame_advantage, 0, "NULL remote estimate")
	endpoint.receive(f._encode(f._input(0, PackedByteArray([1]))), f._id(2), 2)
	endpoint.drain_outbox()
	endpoint.drain_events()
	endpoint.update_local_frame_advantage(4)
	context.equal(endpoint.status().local_frame_advantage, -4, "integer remote minus local advantage")
	var quality: T.Message = _message(f, T.Kind.QUALITY_REPORT)
	quality.frame_advantage = 4
	endpoint.receive(f._encode(quality), f._id(2), 3)
	endpoint.drain_outbox()
	endpoint.submit(0, PackedByteArray([1]), f._statuses(), 4)
	endpoint.drain_outbox()
	context.equal(endpoint.status().average_frame_advantage, 2, "zero initialized full window average")
	endpoint.submit(0, PackedByteArray([1]), f._statuses(), 5)
	context.equal(endpoint.status().average_frame_advantage, 2, "duplicate submit never samples twice")
	endpoint.submit(1, PackedByteArray([1]), f._statuses(), 6)
	context.equal(endpoint.status().average_frame_advantage, 4, "ring average after full window")
	endpoint.update_local_frame_advantage(2147483647)
	context.equal(endpoint.status().local_frame_advantage, -2147483647, "frame arithmetic bounded at exhaustion")
	context.equal(endpoint.update_local_frame_advantage(true), I.Code.INVALID_FRAME, "bool frame rejected")
	options.time_sync_window = 4097
	context.equal(L.valid_options(options), false, "window allocation hard cap")

func _long_running(context: RefCounted) -> void:
	var f: RefCounted = Fixture.new()
	var endpoint: E = _ready(f, Fixture.Sink.new())
	for step: int in range(1000):
		var now: int = 200001 * (step + 1)
		context.equal(endpoint.poll(now), I.Code.OK, "healthy repeated quality service")
		var packets: Array[PackedByteArray] = endpoint.drain_outbox()
		context.equal(packets.size(), 1, "bounded periodic output")
		var reply: T.Message = _message(f, T.Kind.QUALITY_REPLY)
		reply.token = f._decoded(packets[0]).token
		context.equal(endpoint.receive(f._encode(reply), f._id(2), now + 1), I.Code.OK, "quality echo keeps idle mesh live")
		endpoint.drain_events()
		endpoint.drain_transitions()
	context.equal(endpoint.status().quality_pending.size(), 0, "long healthy run leaves no pending pings")
	context.equal(endpoint.status().state, "running", "healthy idle link never times out")
	var before: Dictionary = endpoint.status()
	context.equal(endpoint.poll(9223372036854775807), I.Code.OK, "maximum injected clock cannot overflow timer arithmetic")
	context.equal(endpoint.status().state, "terminated", "maximum elapsed time closes link")
	context.equal(before.state, "running", "owned earlier state remains running")
