extends RefCounted

# Value: protects=fresh online games; fails_when=old-room bytes terminate new direct or relay sessions; seam=actual Match and byte adapters
const Example = preload("res://tests/unit/test_online_example.gd")
const Startup = preload("res://tests/unit/test_online_startup.gd")
const Protocol = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
const Inputs = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["direct_session", "relay_session", "direct_sender", "relay_sender", "direct_connection", "relay_connection", "direct_malformed", "relay_malformed"])


func run_case(name: String, context: RefCounted) -> void:
	var helper: RefCounted = Example.new()
	var delivery: RefCounted = Startup.new()
	var fixtures: Array[Dictionary] = [helper._fixture(context, Example.U), helper._fixture(context, Example.V)]
	var original: PackedByteArray = PackedByteArray()
	var now: int = 0
	for _round: int in 40:
		for fixture: Dictionary in fixtures:
			fixture.driver.tick(now, 2)
		for packet: Dictionary in fixtures[0].transport.routed:
			if packet.bytes.decode_u16(6) == Protocol.Kind.INPUT:
				original = packet.bytes.duplicate()
		helper._deliver(fixtures)
		now += 16667
	context.equal(original.is_empty(), false, "capture an actual gameplay packet from a running match")
	var receiver: RefCounted = fixtures[1].driver
	# Drain valid ingress before taking the rejection boundary observation.
	receiver.fallback.poll(now, receiver.next_token)
	var confirmed_before: int = receiver.peer.status().confirmed_frame
	var before: PackedByteArray = receiver.game.canonical_bytes()
	var network: Dictionary = receiver.peer.network_status().duplicate(true)
	var endpoint: RefCounted = receiver.peer._peers.values()[0]
	var endpoint_before: Dictionary = endpoint.status().duplicate(true)
	var decoded: Protocol.Result = Codec.decode(original, Protocol.Limits.new())
	context.equal(decoded.code, Protocol.Code.OK, "captured packet passes the complete production decoder")
	var message: Protocol.Message = decoded.message
	var expected: int = Inputs.Code.WRONG_SOURCE
	if name.ends_with("session"):
		message.session_id[0] ^= 1
	elif name.ends_with("sender"):
		message.sender_id[0] ^= 1
	elif name.ends_with("connection"):
		message.connection_id[0] ^= 1
		expected = Inputs.Code.WRONG_CONNECTION
	var encoded: Protocol.Result = Codec.encode(message, Protocol.Limits.new())
	context.equal(encoded.code, Protocol.Code.OK, "foreign identity still has a valid complete packet body")
	var bytes: PackedByteArray = encoded.bytes
	if name.ends_with("malformed"):
		bytes = bytes.slice(0, bytes.size() - 1)
		expected = Inputs.Code.INVALID_PACKET
		network.last_now_us = now + 1
	delivery._deliver(fixtures[1], Example.U, bytes, name.begins_with("relay"))
	var adapter: RefCounted = receiver.relay if name.begins_with("relay") else receiver.direct
	var result: RefCounted = adapter.poll(now + 1, receiver.next_token)
	context.equal(result.peer_code, expected, "rejection preserves the exact peer diagnostic")
	context.equal(receiver.peer.status().confirmed_frame, confirmed_before, "rejected packet cannot publish confirmation")
	context.equal(receiver.game.canonical_bytes(), before, "rejected packet cannot mutate game state")
	context.equal(receiver.peer.network_status(), network, "rejected packet cannot refresh liveness or confirmation")
	context.equal(endpoint.status(), endpoint_before, "rejected packet leaves endpoint receipts and incarnation unchanged")
	if name.ends_with("malformed"):
		context.equal(result.code, Example.Match.Fallback.Code.PEER_FAILURE, "malformed traffic retains the existing fatal policy")
	else:
		context.equal(result.code, Example.Match.Fallback.Code.OK, "foreign session, sender or incarnation is inert to the live transport")
		context.equal(receiver.direct.status().received_bytes, 0, "direct FIFO releases rejected bytes")
		context.equal(receiver.relay.status().received_packets, 0, "relay FIFO releases rejected bytes")
		context.equal(adapter.status().rejected, 1, "foreign identity rejection is counted once")
		now += 1
		for _round: int in 20:
			helper._deliver(fixtures)
			for fixture: Dictionary in fixtures:
				fixture.driver.tick(now, 1)
			now += 16667
		context.equal(receiver.failure, "", "new match keeps playing after foreign traffic")
		context.equal(receiver.peer.status().confirmed_frame > 45, true, "new match confirms subsequent original input")
	for fixture: Dictionary in fixtures:
		fixture.driver.detach()
		fixture.mesh.free()
		fixture.client.free()
	context.finish()
