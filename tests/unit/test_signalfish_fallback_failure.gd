extends RefCounted

# Value: protects=terminal direct failures fence composed output; fails_when=relay success hides a broken SDK; why_new=busy controls omit SDK errors; seam=transport methods
const U = preload("res://tests/unit/test_signalfish_fallback.gd")
const F = U.F
const M = U.M


func cases() -> PackedStringArray:
	return PackedStringArray(["send_failure", "receive_failure", "latched_failure", "busy_control", "failed_configuration", "healthy_configuration"])


func run_case(name: String, context: RefCounted) -> void:
	if name in ["failed_configuration", "healthy_configuration"]:
		_configuration(context, name == "failed_configuration")
		context.finish()
		return
	var fixture: Dictionary = U.new().build(context, true, 0, 2)
	var transport: FailedTransport = FailedTransport.new()
	fixture.direct.detach()
	fixture.mesh.transport = transport
	context.equal(fixture.direct.configure(fixture.mesh, fixture.membership, fixture.adapter, fixture.peer), F.Code.OK, "bind actual direct adapter")
	var queued: Array[U.P.Packet] = [U.new().packet(fixture, 11)]
	context.equal((fixture.fallback as F).enqueue_batch(queued), F.Code.OK, "coordinator owns original output")
	if name == "receive_failure":
		transport.incoming.append({"source": M.M.uuid_to_peer_id(M.V), "channel": 0, "mode": 0, "bytes": PackedByteArray([1])})
		transport.read_error = ERR_CONNECTION_ERROR
	elif name == "busy_control":
		transport.send_error = ERR_BUSY
	else:
		transport.send_error = ERR_CONNECTION_ERROR
	if name == "latched_failure":
		context.equal((fixture.direct as U.Direct).enqueue_batch([U.new().packet(fixture, 22)]), F.Code.OK, "stage direct failure before coordinator service")
		context.equal(fixture.direct.poll(0).code, F.Code.SDK_FAILURE, "actual adapter latches SDK failure")
		fixture.direct.reclaim_pending()
	var result: F.Result = fixture.fallback.poll(0)
	if name == "busy_control":
		context.equal(result.code, F.Code.BACKPRESSURE, "ordinary refusal remains recoverable")
		context.equal(fixture.fallback.poll(1).code, F.Code.OK, "ordinary refusal authorizes zero-grace relay fallback")
		context.equal(fixture.client.sent.size(), 1, "ordinary refusal sends retained original through relay")
		context.bytes_equal(U.E.decode(fixture.client.sent[0], 512).payload, PackedByteArray([11]), 0, "busy control retains exact original bytes")
	else:
		context.equal(result.code, F.Code.SDK_FAILURE, "terminal direct SDK failure is surfaced immediately")
		context.equal(fixture.fallback.status().code, F.Code.SDK_FAILURE, "composed status preserves terminal cause")
		context.equal(fixture.fallback.poll(1).code, F.Code.SDK_FAILURE, "elapsed grace cannot recover terminal failure")
		context.equal(fixture.client.sent.size(), 0, "terminal failure cannot publish relay traffic")
		context.equal(fixture.fallback.status().pending_packets, 1, "terminal failure retains original coordinator output")
		context.equal((fixture.fallback as F).enqueue_batch([U.new().packet(fixture, 33)]), F.Code.SDK_FAILURE, "terminal failure rejects new work")
	U.new().destroy(fixture)
	context.finish()


func _configuration(context: RefCounted, failed: bool) -> void:
	var fixture: Dictionary = U.new().build(context)
	fixture.fallback.detach()
	fixture.direct.detach()
	var transport: FailedTransport = FailedTransport.new()
	fixture.mesh.transport = transport
	context.equal(fixture.direct.configure(fixture.mesh, fixture.membership, fixture.adapter, fixture.peer), F.Code.OK, "prepare direct before composition")
	transport.send_error = ERR_CONNECTION_ERROR if failed else ERR_BUSY
	context.equal((fixture.direct as U.Direct).enqueue_batch([U.new().packet(fixture, 22)]), F.Code.OK, "direct owns its preconfiguration packet")
	context.equal(fixture.direct.poll(0).code, F.Code.SDK_FAILURE if failed else F.Code.BACKPRESSURE, "exercise actual socket before composition")
	fixture.direct.reclaim_pending()
	var candidate: F = F.new()
	var expected: int = F.Code.WRONG_STATE if failed else F.Code.OK
	context.equal(candidate.configure(fixture.direct, fixture.relay, fixture.membership, fixture.adapter, fixture.peer), expected, "refuse terminal direct at composition")
	var plan: M.Plan = M.Plan.new()
	plan.data.topology = "relay"
	plan.data.transport = "relay"
	plan.data.peers.clear()
	fixture.client.session_plan.emit(plan)
	context.equal(candidate.status().code, expected, "relay plan cannot authorize a failed configuration")
	context.equal(candidate.enqueue_batch([U.new().packet(fixture, 11)]), expected, "relay plan cannot hide failed configuration from enqueue")
	context.equal(candidate.poll(1).code, expected, "poll preserves configuration disposition")
	context.equal(fixture.client.sent.size(), 0 if failed else 1, "only healthy composition publishes relay traffic")
	candidate.detach()
	U.new().destroy(fixture)


class FailedTransport:
	extends U.SelectiveTransport
	var send_error: Error = OK
	var read_error: Error = OK

	func put_packet(bytes: PackedByteArray) -> Error:
		return send_error if send_error != OK else super.put_packet(bytes)

	func get_packet_error() -> int:
		return read_error
