extends RefCounted

# Value: protects=owned bounded binary relay delivery; fails_when=refused sends drop or broadcast misattributes; why_new=first relay queue; seam=SDK public API
const Relay = preload("res://addons/fortress_rollback/transport/signalfish_relay.gd")
const Envelope = preload("res://addons/fortress_rollback/transport/signalfish_relay_envelope.gd")
const Fixtures = preload("res://tests/unit/test_signalfish_membership.gd")
const Membership = preload("res://addons/fortress_rollback/transport/signalfish_membership.gd")
const Adapter = preload("res://addons/fortress_rollback/transport/signalfish_adapter.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const U: String = Fixtures.U
const V: String = Fixtures.V
const W: String = Fixtures.W


func cases() -> PackedStringArray:
	return PackedStringArray(["golden", "negotiation", "pressure", "atomic", "ingress", "receive_budget", "fences", "overflow"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"golden":
			_golden(context)
		"negotiation":
			_negotiation(context)
		"pressure":
			_pressure(context)
		"atomic":
			_atomic(context)
		"ingress":
			_ingress(context)
		"receive_budget":
			_receive_budget(context)
		"fences":
			_fences(context)
		"overflow":
			_overflow(context)
	context.finish()


func _build(context: RefCounted) -> Dictionary:
	var fixture: RefCounted = Fixtures.new()
	var membership: Membership = fixture._membership(context, U, PackedStringArray([U, V]))
	var peer: Peer = fixture._peer(context, membership)
	var client: Client = Client.new()
	var mesh: Fixtures.FakeMesh = Fixtures.FakeMesh.new()
	var adapter: Adapter = Adapter.new()
	context.equal(adapter.attach(client, mesh, membership), OK, "relay plan attachment")
	var plan: Fixtures.Plan = Fixtures.Plan.new()
	plan.data.topology = "relay"
	plan.data.transport = "relay"
	plan.data.peers.clear()
	client.session_plan.emit(plan)
	var config: SDKConfig = SDKConfig.new()
	var info: Info = Info.new()
	var options: Relay.Options = Relay.Options.new()
	options.max_packet_bytes = 512
	options.max_pending_packets = 2
	options.max_received_packets = 2
	options.max_sends_per_poll = 1
	options.max_receives_per_poll = 1
	options.max_socket_buffered_bytes = 1024
	var relay: Relay = Relay.new()
	context.equal(relay.configure(client, config, info, membership, adapter, peer, options), Relay.Code.OK, "binary relay configured")
	return {"relay": relay, "client": client, "mesh": mesh, "adapter": adapter, "membership": membership, "peer": peer, "config": config, "info": info}


func _destroy(fixture: Dictionary) -> void:
	fixture.relay.detach()
	fixture.adapter.detach()
	fixture.client.free()
	fixture.mesh.free()


func _packet(fixture: Dictionary, value: int) -> Peer.Packet:
	return Peer.Packet.new(fixture.membership.identity(V), PackedByteArray([value]))


func _golden(context: RefCounted) -> void:
	var session: PackedByteArray = PackedByteArray([7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
	var expected: PackedByteArray = (
		"4653523101070000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000001030000000001ff"
	).hex_decode()
	var encoded: PackedByteArray = Envelope.encode(session, V, U, PackedByteArray([0, 1, 255]))
	context.bytes_equal(encoded, expected, 0, "independent fixed-width envelope")
	var decoded: Envelope.Decoded = Envelope.decode(encoded, 512)
	context.equal(decoded.code, Relay.Code.OK, "decode envelope")
	context.equal(decoded.sender, V, "full sender UUID")
	context.equal(decoded.recipient, U, "full recipient UUID")
	context.equal(decoded.payload, PackedByteArray([0, 1, 255]), "opaque payload")


func _negotiation(context: RefCounted) -> void:
	var fixture: Dictionary = _build(context)
	fixture.relay.detach()
	var options: Relay.Options = Relay.Options.new()
	options.max_packet_bytes = 512
	for field: String in ["game_data_format", "decode_msgpack_payloads", "formats", "version", "server_cap"]:
		fixture.config.game_data_format = "json" if field == "game_data_format" else "message_pack"
		fixture.config.decode_msgpack_payloads = field == "decode_msgpack_payloads"
		fixture.info.protocol_version = 2 if field == "version" else 3
		fixture.info.max_outbound_message_size = 512 if field == "server_cap" else 4096
		fixture.info.formats.clear()
		fixture.info.formats.append("json" if field == "formats" else "message_pack")
		var result: int = fixture.relay.configure(fixture.client, fixture.config, fixture.info, fixture.membership, fixture.adapter, fixture.peer, options)
		context.equal(result, Relay.Code.TOO_LARGE if field == "server_cap" else Relay.Code.INCOMPATIBLE_MODE, "unsupported negotiation refused")
	_destroy(fixture)


func _pressure(context: RefCounted) -> void:
	var fixture: Dictionary = _build(context)
	var packets: Array[Peer.Packet] = [_packet(fixture, 11), _packet(fixture, 22)]
	context.equal(fixture.relay.enqueue_batch(packets), Relay.Code.OK, "own whole batch")
	packets[0].bytes[0] = 99
	packets[1].to[0] ^= 1
	fixture.client.busy = true
	context.equal(fixture.relay.poll(0).code, Relay.Code.BACKPRESSURE, "SDK pressure surfaced")
	context.equal(fixture.relay.status().pending_packets, 2, "refused head retained")
	fixture.client.busy = false
	fixture.client.transport.buffered = 1024
	context.equal(fixture.relay.poll(1).code, Relay.Code.BACKPRESSURE, "bounded socket backlog")
	fixture.client.transport.buffered = 0
	context.equal(fixture.relay.poll(2).sent, 1, "send work bounded")
	context.equal(fixture.relay.status().pending_packets, 1, "tail remains owned")
	context.equal(Envelope.decode(fixture.client.sent[0], 512).payload, PackedByteArray([11]), "accepted bytes cannot alias caller")
	context.equal(fixture.relay.poll(3).sent, 1, "retained FIFO tail sent")
	context.equal(fixture.client.sent.size(), 2, "every accepted packet eventually sent")
	if fixture.client.sent.size() == 2:
		context.equal(Envelope.decode(fixture.client.sent[1], 512).payload, PackedByteArray([22]), "FIFO order")
	context.equal(fixture.relay.status().pending_bytes, 0, "queue fully accounted")
	_destroy(fixture)


func _atomic(context: RefCounted) -> void:
	var fixture: Dictionary = _build(context)
	var invalid: Peer.Packet = Peer.Packet.new(PackedByteArray([1]), PackedByteArray([9]))
	var packets: Array[Peer.Packet] = [_packet(fixture, 1), invalid]
	context.equal(fixture.relay.enqueue_batch(packets), Relay.Code.WRONG_SOURCE, "batch refuses invalid destination")
	context.equal(fixture.relay.status().pending_packets, 0, "validation never partially consumes")
	packets = [_packet(fixture, 1), _packet(fixture, 2)]
	context.equal(fixture.relay.enqueue_batch(packets), Relay.Code.OK, "fill pending capacity")
	var retry: Array[Peer.Packet] = [_packet(fixture, 3)]
	context.equal(fixture.relay.enqueue_batch(retry), Relay.Code.BACKPRESSURE, "caller retains refused batch")
	context.equal(retry[0].bytes, PackedByteArray([3]), "retry ownership preserved")
	_destroy(fixture)


func _ingress(context: RefCounted) -> void:
	var fixture: Dictionary = _build(context)
	var session: PackedByteArray = fixture.membership.handshake_message().session_id
	var good: PackedByteArray = Envelope.encode(session, V, U, PackedByteArray([1]))
	var stale: PackedByteArray = session.duplicate()
	stale[0] ^= 1
	var bad_version: PackedByteArray = good.duplicate()
	bad_version[4] = 2
	var oversized: PackedByteArray = good.duplicate()
	oversized.resize(570)
	var rows: Array[Dictionary] = [
		{"sender": W, "encoding": 1, "bytes": good, "code": Relay.Code.WRONG_SOURCE},
		{"sender": V, "encoding": 0, "bytes": good, "code": Relay.Code.INCOMPATIBLE_MODE},
		{"sender": V, "encoding": 1, "bytes": Envelope.encode(session, U, U, PackedByteArray([1])), "code": Relay.Code.WRONG_SOURCE},
		{"sender": V, "encoding": 1, "bytes": Envelope.encode(stale, V, U, PackedByteArray([1])), "code": Relay.Code.WRONG_SESSION},
		{"sender": V, "encoding": 1, "bytes": bad_version, "code": Relay.Code.INVALID_ENVELOPE},
		{"sender": V, "encoding": 1, "bytes": oversized, "code": Relay.Code.TOO_LARGE},
		{"sender": V, "encoding": 1, "bytes": Envelope.encode(session, V, W, PackedByteArray([1])), "code": Relay.Code.NOT_RECIPIENT}
	]
	for row: Dictionary in rows:
		fixture.client.game_data_binary_received.emit(row.sender, row.encoding, row.bytes)
		context.equal(fixture.relay.status().last_receive_code, row.code, "specific receive refusal")
		context.equal(fixture.relay.status().received_packets, 0, "refused or unrelated broadcast never queued")
	_destroy(fixture)


func _receive_budget(context: RefCounted) -> void:
	var fixture: Dictionary = _build(context)
	var helpers: RefCounted = Fixtures.new()
	var remote_membership: Membership = helpers._membership(context, V, PackedStringArray([U, V]))
	var remote: Peer = helpers._peer(context, remote_membership)
	var packet: PackedByteArray = remote.drain_outbox()[0].bytes
	var envelope: PackedByteArray = Envelope.encode(remote_membership.handshake_message().session_id, V, U, packet)
	fixture.client.game_data_binary_received.emit(V, 1, envelope)
	fixture.client.game_data_binary_received.emit(V, 1, envelope)
	envelope[57] ^= 1
	context.equal(fixture.relay.poll(0).received, 1, "receive service work bounded")
	context.equal(fixture.relay.status().received_packets, 1, "remaining input retained")
	context.equal(fixture.relay.poll(1).received, 1, "received bytes owned against later mutation")
	_destroy(fixture)


func _fences(context: RefCounted) -> void:
	var fixture: Dictionary = _build(context)
	var packets: Array[Peer.Packet] = [_packet(fixture, 1)]
	fixture.relay.enqueue_batch(packets)
	fixture.client.room_left.emit()
	context.equal(fixture.relay.poll(0).code, Relay.Code.WRONG_STATE, "old session cannot send")
	context.equal(fixture.relay.status().pending_packets, 1, "restart refusal retains accepted output")
	context.equal(fixture.client.sent.size(), 0, "no SDK send after lifecycle fence")
	_destroy(fixture)


func _overflow(context: RefCounted) -> void:
	var fixture: Dictionary = _build(context)
	var session: PackedByteArray = fixture.membership.handshake_message().session_id
	var envelope: PackedByteArray = Envelope.encode(session, V, U, PackedByteArray([1]))
	for _index: int in 3:
		fixture.client.game_data_binary_received.emit(V, 1, envelope)
	context.equal(fixture.relay.status().code, Relay.Code.RECEIVE_OVERFLOW, "receive overflow fails closed")
	context.equal(fixture.relay.status().received_packets, 2, "bounded receive occupancy")
	context.equal(fixture.relay.poll(0).code, Relay.Code.RECEIVE_OVERFLOW, "cannot silently repair overflow")
	context.equal(fixture.client.sent.size(), 0, "overflow cannot publish new sends")
	_destroy(fixture)


class Client:
	extends Fixtures.FakeClient
	signal game_data_binary_received(from_uuid: String, encoding: int, bytes: PackedByteArray)
	var transport: Transport = Transport.new()
	var busy: bool = false
	var sent: Array[PackedByteArray] = []

	func send_game_data_binary(bytes: PackedByteArray) -> Error:
		if busy:
			return ERR_BUSY
		sent.append(bytes.duplicate())
		return OK


class Transport:
	extends RefCounted
	var buffered: int = 0

	func get_buffered_amount() -> int:
		return buffered


class SDKConfig:
	extends RefCounted
	var game_data_format: String = "message_pack"
	var decode_msgpack_payloads: bool = false
	var max_inbound_packets_per_poll: int = 2
	var max_buffered_bytes: int = 1024
	var max_outbound_frame_bytes: int = 1024
	var max_inbound_frame_bytes: int = 4096


class Info:
	extends RefCounted
	var protocol_version: int = 3
	var max_outbound_message_size: int = 4096
	var formats: Array[String] = ["message_pack"]

	func to_dict() -> Dictionary:
		return {"game_data_formats": formats, "protocol_version": protocol_version, "max_outbound_message_size": max_outbound_message_size}
