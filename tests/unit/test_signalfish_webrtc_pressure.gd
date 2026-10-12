extends RefCounted

# Value: protects=direct inbound retry/lifetime; fails_when=pressure drops input or remints token; why_new=real direct receive path; seam=real bounded peer
const F = preload("res://tests/unit/test_signalfish_webrtc.gd")
const R = preload("res://tests/unit/test_signalfish_relay_pressure.gd")
const RF = preload("res://tests/unit/test_signalfish_relay.gd")
const P = preload("res://addons/fortress_rollback/core/peer_session.gd")
const D = preload("res://addons/fortress_rollback/core/driver.gd")
const W = preload("res://addons/fortress_rollback/transport/signalfish_webrtc.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["recoverable", "terminal", "handshake", "inbound_lifetime", "invalid_tokens", "receive_tail"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "invalid_tokens":
		_invalid_tokens(context)
		context.finish()
		return
	var helper: RefCounted = F.new()
	var fixture: Dictionary = helper.build(context)
	var real: Dictionary = R.new()._build(context, name == "terminal", name != "handshake")
	fixture.direct.detach()
	fixture.peer = real.peer
	var options: W.Options = W.Options.new()
	options.max_packet_bytes = 512
	options.max_receives_per_poll = 2
	options.max_sends_per_poll = 1
	context.equal(fixture.direct.configure(fixture.mesh, fixture.membership, fixture.adapter, fixture.peer, options), W.Code.OK, "bind direct to real bounded peer")
	if name == "handshake":
		_handshake(context, fixture, real)
	else:
		_inputs(context, fixture, real, name)
	helper.destroy(fixture)
	RF.new()._destroy(real)
	context.finish()


func _queue(fixture: Dictionary, bytes: PackedByteArray) -> void:
	fixture.mesh.transport.incoming.append({"source": fixture.membership.uuid_to_peer_id(F.V), "channel": 0, "mode": 0, "bytes": bytes})


func _input(fixture: Dictionary, real: Dictionary, frame: int) -> void:
	real.remote.step((frame + 1) * 10, [D.LocalInput.new(1, frame, PackedByteArray([frame + 1, 0, 0, 0]))])
	_queue(fixture, real.remote.drain_outbox()[0].bytes)


func _inputs(context: RefCounted, fixture: Dictionary, real: Dictionary, name: String) -> void:
	if name == "terminal":
		fixture.peer.poll(200)
		fixture.peer.drain_outbox()
	_input(fixture, real, 0)
	if name == "inbound_lifetime":
		fixture.client.room_left.emit()
		context.equal(fixture.direct.poll(10).code, W.Code.WRONG_STATE, "queued incoming valid bytes fenced")
		context.equal(fixture.mesh.transport.incoming.size(), 1, "no packet consumed after transport lifetime")
		return
	if name in ["recoverable", "receive_tail"]:
		_input(fixture, real, 1)
		var packets: Array[P.Packet] = [F.new().packet(fixture, 91)]
		if name == "receive_tail":
			packets.append(F.new().packet(fixture, 92))
		fixture.direct.enqueue_batch(packets)
	var tokens: R.TokenFactory = R.TokenFactory.new()
	var result: W.Result = fixture.direct.poll(201 if name == "terminal" else 20, tokens.next)
	context.equal(result.peer_code, I.Code.BACKPRESSURE, "real peer refuses publication")
	context.equal(result.code, W.Code.PEER_FAILURE if name == "terminal" else W.Code.BACKPRESSURE, "terminal distinction")
	if name == "terminal":
		context.equal(fixture.direct.poll(202).code, W.Code.PEER_FAILURE, "terminal failure stays latched")
		return
	context.equal(result.received, 1, "one committed incoming head")
	context.equal(result.sent, 1, "outgoing service continues during ACK pressure")
	if name == "receive_tail":
		context.equal(fixture.direct.status().pending_packets, 1, "send-work budget retains healthy direct tail")
		context.equal(fixture.direct.refused_destination().is_empty(), true, "real inbound pressure cannot report send refusal")
	context.equal(fixture.direct.status().received_packets, 1, "exact refused head retained")
	context.equal(tokens.calls, 2, "token once per head")
	tokens.token.clear()
	fixture.peer.drain_outbox()
	context.equal(fixture.direct.poll(20, tokens.next).received, 1, "retained input retry accepted")
	context.equal(tokens.calls, 2, "no token reminted on retry")
	context.equal(fixture.peer.network_status().peers.values()[0].last_received_frame, 1, "retained FIFO advances real frame")


func _handshake(context: RefCounted, fixture: Dictionary, real: Dictionary) -> void:
	var initial: Array[P.Packet] = fixture.peer.drain_outbox()
	context.equal(real.remote_membership.receive(real.remote, initial[0].bytes, F.U, 0), I.Code.OK, "remote replies")
	var remote: Array[P.Packet] = real.remote.drain_outbox()
	context.equal(fixture.membership.receive(fixture.peer, remote[0].bytes, F.V, 0), I.Code.OK, "fill reply capacity")
	_queue(fixture, remote[1].bytes)
	var tokens: R.TokenFactory = R.TokenFactory.new()
	context.equal(fixture.direct.poll(0, tokens.next).code, W.Code.BACKPRESSURE, "next-round request waits")
	tokens.token.clear()
	fixture.peer.drain_outbox()
	context.equal(fixture.direct.poll(0, tokens.next).received, 1, "owned unique token reused")
	context.equal(tokens.calls, 1, "one minted token over both attempts")


func _invalid_tokens(context: RefCounted) -> void:
	for size: int in [-3, -2, -1, 0, 15, 17, 16777216]:
		var fixture: Dictionary = F.new().build(context)
		var real: Dictionary = R.new()._build(context, false)
		fixture.direct.detach()
		fixture.peer = real.peer
		var options: W.Options = W.Options.new()
		options.max_packet_bytes = 512
		options.max_receives_per_poll = 2
		context.equal(fixture.direct.configure(fixture.mesh, fixture.membership, fixture.adapter, fixture.peer, options), W.Code.OK, "bind token refusal fixture")
		_input(fixture, real, 0)
		_input(fixture, real, 1)
		var tokens: R.InvalidTokenFactory = R.InvalidTokenFactory.new(size)
		tokens.on_call = fixture.direct.detach if size in [-3, -2] else Callable()
		var expected: int = W.Code.WRONG_STATE if size in [-3, -2] else W.Code.INVALID_ARGUMENT
		var result: W.Result = fixture.direct.poll(20, tokens.next)
		context.equal(result.code, expected, "reject malformed token before peer pressure " + str(size))
		context.equal(result.received, 0, "invalid token never advances peer")
		context.equal(fixture.direct.get("_token") == null, true, "invalid token never retained")
		context.equal(fixture.direct.poll(20).code, expected, "callback failure latched")
		F.new().destroy(fixture)
		RF.new()._destroy(real)
