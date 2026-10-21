extends RefCounted

# Value: protects=independent online handshake completion; fails_when=valid unordered early gameplay kills a synchronizing peer; seam=actual Match callers and SDK transport doubles
const Example = preload("res://tests/unit/test_online_example.gd")
const Match = preload("res://examples/online/match.gd")
const Protocol = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["asymmetric_direct", "asymmetric_relay", "early_validation"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "early_validation":
		_early_validation(context)
		context.finish()
		return
	var helper: RefCounted = Example.new()
	var fixtures: Array[Dictionary] = [helper._fixture(context, Example.U), helper._fixture(context, Example.V)]
	var held: Array[PackedByteArray] = []
	var saw_early: bool = false
	var checked_early: bool = false
	var early: Protocol.Message = null
	var now: int = 0
	for _round: int in 120:
		for fixture: Dictionary in fixtures:
			fixture.driver.tick(now, 1 if checked_early else 2)
		for source: int in 2:
			var receiver: Dictionary = fixtures[1 - source]
			for packet: Dictionary in fixtures[source].transport.routed:
				var kind: int = packet.bytes.decode_u16(6)
				var endpoint: RefCounted = receiver.driver.peer._peers.values()[0]
				if source == 0 and kind == Protocol.Kind.SYNC_REPLY and endpoint._handshake.status().remaining == 1 and not saw_early:
					held.append(packet.bytes.duplicate())
					continue
				if source == 0 and kind == Protocol.Kind.INPUT and receiver.driver.peer.network_status().state == "synchronizing":
					if early == null:
						var decoded: Protocol.Result = Codec.decode(packet.bytes, Protocol.Limits.new())
						context.equal(decoded.code, Protocol.Code.OK, "capture original early encoded INPUT through production decoder")
						early = decoded.message
					saw_early = true
					context.equal(receiver.driver.game.frame, 0, "early packet arrives before receiver completes its own handshake")
				_deliver(receiver, fixtures[source].client.local, packet.bytes, name == "asymmetric_relay")
			fixtures[source].transport.routed.clear()
		if saw_early and not checked_early:
			checked_early = true
			fixtures[1].driver.tick(now, 2)
			context.equal(fixtures[1].driver.failure, "", "valid early input does not terminate independent synchronization")
			for bytes: PackedByteArray in held:
				_deliver(fixtures[1], Example.U, bytes, name == "asymmetric_relay")
			held.clear()
			helper._deliver(fixtures)
		now += 16667
	context.equal(saw_early, true, "fixture actually reorders final handshake reply behind gameplay")
	for _round: int in 80:
		helper._deliver(fixtures)
		for fixture: Dictionary in fixtures:
			fixture.driver.tick(now, 1)
		now += 16667
	for fixture: Dictionary in fixtures:
		context.equal(fixture.driver.failure, "", "both original sessions remain healthy")
		context.equal(fixture.driver.peer.status().confirmed_frame > 20, true, "retransmission recovers gameplay dropped before synchronization")
		if early != null:
			var observed: Example.ObservedGame = fixture.driver.game
			context.equal(early.data[0], 2, "captured early input differs from subsequent keyboard state")
			for offset: int in early.frame_count:
				var frame: int = early.start_frame + offset
				context.equal(fixture.driver.peer.status().confirmed_frame >= frame, true, "recovered original early input is confirmed")
				for index: int in early.players.size():
					context.equal(observed.samples[frame][early.players[index]], early.data[offset * early.players.size() + index],
						"corrected simulation retains original early packet bytes on both peers frame=%d slot=%d" % [frame, early.players[index]])
			var later: int = early.start_frame + early.frame_count + 2
			context.equal(observed.samples[later][early.players[0]], 1, "later keyboard change remains distinct from recovered early input")
		fixture.driver.detach()
		fixture.mesh.free()
		fixture.client.free()
	context.finish()


func _deliver(receiver: Dictionary, uuid: String, bytes: PackedByteArray, relay: bool) -> void:
	if relay:
		var envelope: PackedByteArray = Match.Relay.Envelope.encode(receiver.driver.membership.handshake_message().session_id, uuid, receiver.client.local, bytes)
		receiver.client.game_data_binary_received.emit(uuid, 1, envelope)
	else:
		receiver.transport.incoming.append({"source": Match.Membership.uuid_to_peer_id(uuid), "channel": 0, "mode": 0, "bytes": bytes.duplicate()})


func _early_validation(context: RefCounted) -> void:
	var helper: RefCounted = Example.new()
	var fixtures: Array[Dictionary] = [helper._fixture(context, Example.U), helper._fixture(context, Example.V)]
	for round_index: int in 2:
		for fixture: Dictionary in fixtures:
			fixture.driver.tick(round_index, 0)
		helper._deliver(fixtures)
	# Receive the first valid reply so the transport connection identity is frozen.
	fixtures[1].driver.tick(2, 0)
	var receiver: Match = fixtures[1].driver
	var endpoint: RefCounted = receiver.peer._peers.values()[0]
	context.equal(endpoint._handshake.status().state, "synchronizing", "validation exercises unfinished local handshake")
	context.equal(endpoint._handshake.status().remote_connection.is_empty(), false, "received first reply freezes expected remote incarnation")
	var profile: Protocol.Message = fixtures[0].driver.membership.handshake_message()
	var kinds: Array[int] = [Protocol.Kind.INPUT_ACK, Protocol.Kind.QUALITY_REPORT, Protocol.Kind.QUALITY_REPLY,
		Protocol.Kind.CHECKSUM_REPORT, Protocol.Kind.KEEP_ALIVE, Protocol.Kind.GOODBYE, Protocol.Kind.FLOOR_REQUEST, Protocol.Kind.FLOOR_REPLY,
		Protocol.Kind.DROP_BARRIER]
	for kind: int in kinds:
		var message: Protocol.Message = fixtures[0].driver.membership.handshake_message()
		message.kind = kind
		message.frame = 0
		message.floors = PackedInt32Array([-1, -1])
		if kind == Protocol.Kind.DROP_BARRIER:
			message.phase = 1
			message.operation = 1
			message.cut = 0
			message.bound = 0
			message.data = PackedByteArray([0, 0, 0])
		var encoded: Protocol.Result = Codec.encode(message, Protocol.Limits.new())
		context.equal(encoded.code, Protocol.Code.OK, "control fixture valid kind=%d" % kind)
		context.equal(receiver.peer.receive(encoded.bytes, profile.sender_id, 3), Match.Inputs.Code.OK, "valid early control discarded without handshake barrier kind=%d" % kind)
	context.equal(receiver.game.frame, 0, "ignored control cannot advance gameplay")
	var message: Protocol.Message = fixtures[0].driver.membership.handshake_message()
	message.kind = Protocol.Kind.INPUT
	message.start_frame = 2
	message.frame_count = 1
	message.players = PackedByteArray([0])
	message.statuses = [Protocol.Status.new(), Protocol.Status.new()]
	message.data = PackedByteArray([2])
	var valid: PackedByteArray = Codec.encode(message, Protocol.Limits.new()).bytes
	context.equal(receiver.peer.receive(valid, profile.sender_id, 3), Match.Inputs.Code.OK, "valid original early INPUT discarded before retention")
	context.equal(endpoint.status().last_received_frame, -1, "early input cannot invent receipt or confirmation")
	for field: String in ["connection", "sender", "session", "ownership", "truncated"]:
		var hostile: PackedByteArray = valid.duplicate()
		var expected: int = Match.Inputs.Code.INVALID_PACKET
		match field:
			"connection":
				hostile[36] ^= 1
				expected = Match.Inputs.Code.WRONG_CONNECTION
			"sender":
				hostile[28] ^= 1
				expected = Match.Inputs.Code.WRONG_SOURCE
			"session":
				hostile[12] ^= 1
				expected = Match.Inputs.Code.WRONG_SOURCE
			"ownership":
				message.players = PackedByteArray([1])
				hostile = Codec.encode(message, Protocol.Limits.new()).bytes
			"truncated":
				hostile.resize(43)
		context.equal(receiver.peer.receive(hostile, profile.sender_id, 3), expected, "hostile early packet still rejected before synchronization: " + field)
	for fixture: Dictionary in fixtures:
		fixture.driver.detach()
		fixture.mesh.free()
		fixture.client.free()
