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
	return PackedStringArray(["golden", "negotiation", "pressure", "atomic", "ingress", "receive_budget", "fences", "overflow", "traffic",
		"addressed_plan", "addressed_wire_caps", "addressed_fences", "addressed_reentry"])


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
		"traffic":
			_traffic(context)
		"addressed_plan":
			_addressed_plan(context)
		"addressed_wire_caps":
			_addressed_wire_caps(context)
		"addressed_fences":
			_addressed_fences(context)
		"addressed_reentry":
			_addressed_reentry(context)
	context.finish()


func _build(context: RefCounted, max_received_bytes: int = 1048576) -> Dictionary:
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
	options.max_received_bytes = max_received_bytes
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
	context.equal((fixture.relay as Relay).enqueue_batch([_packet(fixture, 33)]), Relay.Code.OK, "queue output before buffered callback")
	fixture.client.transport.on_buffered = fixture.relay.detach
	context.equal(fixture.relay.poll(4).code, Relay.Code.WRONG_STATE, "buffer query teardown fails closed")
	context.equal(fixture.client.sent.size(), 2, "buffer query teardown cannot send queued output")
	context.equal(fixture.relay.status().pending_bytes, 0, "buffer query teardown releases output")
	context.equal(fixture.client.get_signal_connection_list("game_data_binary_received").size(), 0, "buffer query teardown releases observer")
	fixture.client.transport.on_buffered = Callable()
	var options: Relay.Options = Relay.Options.new()
	options.max_packet_bytes = 512
	context.equal(fixture.relay.configure(fixture.client, fixture.config, fixture.info, fixture.membership, fixture.adapter, fixture.peer, options),
		Relay.Code.OK, "reconfigure after deferred relay detach")

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
	var bad_size: PackedByteArray = good.duplicate()
	bad_size.encode_u32(53, 2)
	var oversized: PackedByteArray = good.duplicate()
	oversized.resize(570)
	var rows: Array[Dictionary] = [
		{"sender": W, "encoding": 1, "bytes": good, "code": Relay.Code.WRONG_SOURCE},
		{"sender": U, "encoding": 1, "bytes": good, "code": Relay.Code.WRONG_SOURCE},
		{"sender": V.left(35) + "A", "encoding": 1, "bytes": good, "code": Relay.Code.WRONG_SOURCE},
		{"sender": V, "encoding": 0, "bytes": good, "code": Relay.Code.INCOMPATIBLE_MODE},
		{"sender": V, "encoding": 1, "bytes": Envelope.encode(session, U, U, PackedByteArray([1])), "code": Relay.Code.WRONG_SOURCE},
		{"sender": V, "encoding": 1, "bytes": Envelope.encode(stale, U, W, PackedByteArray([1])), "code": Relay.Code.WRONG_SOURCE},
		{"sender": V, "encoding": 1, "bytes": Envelope.encode(stale, V, U, PackedByteArray([1])), "code": Relay.Code.WRONG_SESSION},
		{"sender": V, "encoding": 1, "bytes": Envelope.encode(stale, V, W, PackedByteArray([1])), "code": Relay.Code.WRONG_SESSION},
		{"sender": V, "encoding": 1, "bytes": bad_version, "code": Relay.Code.INVALID_ENVELOPE},
		{"sender": V, "encoding": 1, "bytes": bad_size, "code": Relay.Code.INVALID_ENVELOPE},
		{"sender": V, "encoding": 1, "bytes": oversized, "code": Relay.Code.TOO_LARGE},
		{"sender": V, "encoding": 1, "bytes": Envelope.encode(session, V, W, PackedByteArray([1])), "code": Relay.Code.NOT_RECIPIENT}
	]
	for row: Dictionary in rows:
		fixture.client.game_data_binary_received.emit(row.sender, row.encoding, row.bytes)
		context.equal(fixture.relay.status().last_receive_code, row.code, "specific receive refusal")
		context.equal(fixture.relay.status().received_packets, 0, "refused or unrelated broadcast never queued")
	context.equal(fixture.relay.status().ignored, 1, "only a valid unrelated broadcast is counted as ignored")
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
	context.equal(
		fixture.relay.status().get("receive_overflow"),
		{"packets": 2, "bytes": envelope.size() * 2, "packet_limit": 2, "byte_limit": 1048576, "refused_bytes": envelope.size()},
		"the first refusal identifies the exact packet and byte pressure"
	)
	context.equal(fixture.relay.poll(0).code, Relay.Code.RECEIVE_OVERFLOW, "cannot silently repair overflow")
	context.equal(fixture.client.sent.size(), 0, "overflow cannot publish new sends")
	fixture.relay.detach()
	context.equal(fixture.relay.status().get("receive_overflow"), {}, "detach releases the old receipt")
	_destroy(fixture)

	fixture = _build(context, 569)
	session = fixture.membership.handshake_message().session_id
	var payload: PackedByteArray = PackedByteArray()
	payload.resize(512)
	envelope = Envelope.encode(session, V, U, payload)
	context.equal(fixture.relay.can_receive_packet(), true, "one maximum-sized frame fits the byte budget")
	fixture.client.game_data_binary_received.emit(V, 1, envelope)
	context.equal(fixture.relay.can_receive_packet(), false, "the full byte budget admits no more SDK frames")
	fixture.client.game_data_binary_received.emit(V, 1, envelope)
	var receipt: Dictionary = fixture.relay.status().receive_overflow
	context.equal(receipt, {"packets": 1, "bytes": 569, "packet_limit": 2, "byte_limit": 569, "refused_bytes": 569}, "byte pressure is distinguishable")
	receipt.clear()
	context.equal(fixture.relay.status().receive_overflow.packets, 1, "status owns the returned overflow receipt")
	_destroy(fixture)


# Value: protects=idle relay service batches; fails_when=refused frames look like an empty wire; why_new=the SDK hands frames over between polls; seam=SDK public signal
func _traffic(context: RefCounted) -> void:
	var fixture: Dictionary = _build(context)
	context.equal(fixture.relay.idle(), true, "a fresh relay transport is idle")
	context.equal(fixture.relay.poll(0).activity, 0, "an empty wire moves no traffic")
	context.equal(fixture.relay.idle(), true, "an empty wire keeps the transport idle")
	var helpers: RefCounted = Fixtures.new()
	var remote_membership: Membership = helpers._membership(context, V, PackedStringArray([U, V]))
	var remote: Peer = helpers._peer(context, remote_membership)
	var packet: PackedByteArray = remote.drain_outbox()[0].bytes
	var session: PackedByteArray = fixture.membership.handshake_message().session_id
	var envelope: PackedByteArray = Envelope.encode(session, V, U, packet)
	fixture.client.game_data_binary_received.emit(V, 1, envelope)
	context.equal(fixture.relay.status().received_packets, 1, "a delivered frame waits for the next poll")
	context.equal(fixture.relay.idle(), false, "a queued frame keeps the transport busy")
	var delivered: Relay.Result = fixture.relay.poll(1)
	context.equal(delivered.activity, 1, "a delivered frame is traffic")
	context.equal(delivered.received, 1, "a delivered frame reaches the peer")
	context.equal(fixture.relay.poll(2).activity, 0, "a drained wire moves no traffic")
	context.equal(fixture.relay.idle(), true, "a drained wire is idle again")
	fixture.client.game_data_binary_received.emit(W, 1, envelope)
	var refused: Relay.Result = fixture.relay.poll(3)
	context.equal(refused.activity, 1, "a refused frame is still traffic")
	context.equal(refused.received, 0, "a refused frame delivers no input")
	context.equal(fixture.relay.idle(), false, "refused traffic keeps a service batch alive")
	context.equal(fixture.relay.poll(4).activity, 0, "refused traffic is reported once")
	context.equal(fixture.relay.idle(), true, "a refused wire is idle again")
	_destroy(fixture)


func _addressed_fixture(context: RefCounted, client: Client, entries: Variant, controls: Relay.Options) -> Dictionary:
	var fixture: RefCounted = Fixtures.new()
	var membership: Membership = fixture._membership(context, U, PackedStringArray([U, V, W]))
	var mesh: Fixtures.FakeMesh = Fixtures.FakeMesh.new()
	var adapter: Adapter = Adapter.new()
	context.equal(adapter.attach(client, mesh, membership), OK, "three frozen relay seats")
	var plan: Fixtures.Plan = Fixtures.Plan.new()
	plan.data.topology = "relay"
	plan.data.transport = "relay"
	plan.data.peers.clear()
	if entries != null:
		plan.data.addressed_binary_peers = entries
	client.session_plan.emit(plan)
	var config: SDKConfig = SDKConfig.new()
	var info: Info = Info.new()
	var relay: Relay = Relay.new()
	context.equal(relay.configure_packet_receiver(client, config, info, membership, adapter, _receive_native, controls), Relay.Code.OK, "native relay setup")
	return {"relay": relay, "client": client, "mesh": mesh, "adapter": adapter, "membership": membership, "config": config, "info": info, "plan": plan}


func _receive_native(_player: String, _bytes: PackedByteArray) -> int:
	return 0


func _addressed_controls() -> Relay.Options:
	var controls: Relay.Options = Relay.Options.new()
	controls.max_packet_bytes = 44
	return controls


func _addressed_plan(context: RefCounted) -> void:
	var complete: Array = [{"player_id": W, "epoch": 4294967295}, {"player_id": V, "epoch": 1.0}]
	var alternatives: Array = [null, {}, [], [complete[0]], [complete[0], complete[0]], [complete[0], {"player_id": U, "epoch": 1}],
		[complete[0], {"player_id": "bad", "epoch": 1}], [complete[0], {"player_id": V}], [complete[0], {"player_id": V, "epoch": true}],
		[complete[0], {"player_id": V, "epoch": 0}], [complete[0], {"player_id": V, "epoch": 1.25}],
		[complete[0], {"player_id": V, "epoch": 4294967296}], [complete[0], {"player_id": V, "epoch": NAN}],
		[complete[0], {"player_id": V, "epoch": "1"}], [complete[0], false], complete]
	for index: int in alternatives.size():
		var client: AddressedClient = AddressedClient.new()
		var fixture: Dictionary = _addressed_fixture(context, client, alternatives[index], _addressed_controls())
		var packets: Array[Peer.Packet] = [_packet(fixture, 7)]
		context.equal(fixture.relay.enqueue_batch(packets), Relay.Code.OK, "accepted native input")
		context.equal(fixture.relay.poll(0).sent, 1, "one addressed envelope sent")
		var is_private: bool = index == alternatives.size() - 1
		context.equal(client.attempts.size(), int(is_private), "private API requires the complete exact frozen roster")
		context.equal(client.sent.size(), int(not is_private), "malformed and mixed rosters use ordinary relay")
		_destroy(fixture)
	for negotiated: bool in [false, true]:
		var client: AddressedClient = AddressedClient.new()
		client.negotiated = negotiated
		var fixture: Dictionary = _addressed_fixture(context, client, [complete[0]] if negotiated else complete, _addressed_controls())
		var packets: Array[Peer.Packet] = [_packet(fixture, 7)]
		context.equal(fixture.relay.enqueue_batch(packets), Relay.Code.OK, "ordinary lane owns bytes before plan or SDK changes")
		fixture.plan.data.addressed_binary_peers = complete
		client.session_plan.emit(fixture.plan)
		context.equal(fixture.relay.poll(0).sent, 1, "ordinary lane completes after an optional plan refresh")
		context.equal(client.sent.size(), 1, "unnegotiated or originally mixed room stays ordinary")
		context.equal(client.attempts.size(), 0, "server metadata does not upgrade an owned broadcast")
		_destroy(fixture)


func _addressed_wire_caps(context: RefCounted) -> void:
	var complete: Array = [{"player_id": V, "epoch": 2}, {"player_id": W, "epoch": 3}]
	for overhead: int in [0, 1, 17]:
		var client: Client = Client.new()
		if overhead != 0:
			client.free()
			client = NegotiatedOnlyClient.new() if overhead == 1 else AddressedClient.new()
		var controls: Relay.Options = _addressed_controls()
		var frame: int = controls.max_packet_bytes + Envelope.HEADER_BYTES + overhead
		controls.max_pending_bytes = frame
		controls.max_socket_buffered_bytes = frame
		var fixture: Dictionary = _addressed_fixture(context, client, complete, controls)
		fixture.relay.detach()
		fixture.config.max_outbound_frame_bytes = frame - 1
		context.equal(fixture.relay.configure_packet_receiver(client, fixture.config, fixture.info, fixture.membership, fixture.adapter, _receive_native, controls),
			Relay.Code.TOO_LARGE, "SDK outbound cap includes lane overhead")
		fixture.config.max_outbound_frame_bytes = frame
		fixture.config.max_buffered_bytes = frame - 1
		context.equal(fixture.relay.configure_packet_receiver(client, fixture.config, fixture.info, fixture.membership, fixture.adapter, _receive_native, controls),
			Relay.Code.TOO_LARGE, "SDK socket cap includes lane overhead")
		fixture.config.max_buffered_bytes = frame
		if overhead > 0:
			controls.max_pending_bytes = frame - 1
			context.equal(fixture.relay.configure_packet_receiver(client, fixture.config, fixture.info, fixture.membership, fixture.adapter, _receive_native, controls),
				Relay.Code.TOO_LARGE, "relay queue cap includes lane overhead")
			controls.max_pending_bytes = frame
			controls.max_socket_buffered_bytes = frame - 1
			context.equal(fixture.relay.configure_packet_receiver(client, fixture.config, fixture.info, fixture.membership, fixture.adapter, _receive_native, controls),
				Relay.Code.TOO_LARGE, "relay socket cap includes lane overhead")
			controls.max_socket_buffered_bytes = frame
		context.equal(fixture.relay.configure_packet_receiver(client, fixture.config, fixture.info, fixture.membership, fixture.adapter, _receive_native, controls),
			Relay.Code.OK, "exact lane cap accepted")
		var packets: Array[Peer.Packet] = [_packet(fixture, 9)]
		packets[0].bytes.resize(44)
		context.equal(fixture.relay.enqueue_batch(packets), Relay.Code.OK, "queue owns exact wire cap")
		context.equal(fixture.relay.status().pending_bytes, frame, "queued wire occupancy")
		context.equal(fixture.relay.enqueue_batch(packets), Relay.Code.BACKPRESSURE, "no queue growth after full wire cap")
		client.transport.buffered = 1
		context.equal(fixture.relay.poll(0).code, Relay.Code.BACKPRESSURE, "one extra buffered byte blocks send")
		client.transport.buffered = 0
		context.equal(fixture.relay.poll(1).sent, 1, "exact buffered cap sends")
		context.equal(fixture.relay.status().pending_bytes, 0, "drain returns exact wire occupancy")
		_destroy(fixture)


func _addressed_fences(context: RefCounted) -> void:
	var complete: Array = [{"player_id": V, "epoch": 2}, {"player_id": W, "epoch": 3}]
	var client: AddressedClient = AddressedClient.new()
	var fixture: Dictionary = _addressed_fixture(context, client, complete, _addressed_controls())
	var packets: Array[Peer.Packet] = [_packet(fixture, 7), Peer.Packet.new(fixture.membership.identity(W), PackedByteArray([8]))]
	context.equal(fixture.relay.enqueue_batch(packets), Relay.Code.OK, "queue both private seats")
	var envelope: PackedByteArray = Envelope.encode(fixture.membership.handshake_message().session_id, U, V, PackedByteArray([7]))
	packets[0].bytes[0] = 99
	client.private_code = ERR_BUSY
	context.equal(fixture.relay.poll(0).code, Relay.Code.BACKPRESSURE, "private refusal is retryable")
	context.equal(fixture.relay.status().pending_packets, 2, "private refusal keeps the exact head")
	context.equal(client.sent.size(), 0, "private refusal cannot become broadcast")
	context.equal(client.attempts, [{"recipient": V, "bytes": envelope}], "private uses the frozen UUID and byte-identical envelope")
	client.private_code = OK
	context.equal(fixture.relay.poll(1).sent, 2, "retry preserves FIFO")
	context.equal(client.attempts[1], client.attempts[0], "private retry descriptor is unchanged")
	context.equal(client.attempts[2].recipient, W, "the next peer remains behind the retry")
	context.equal(fixture.relay.enqueue_batch(packets), Relay.Code.OK, "queue before changed-negotiation fence")
	fixture.plan.data.addressed_binary_peers = [{"player_id": V, "epoch": 4}, complete[1]]
	client.session_plan.emit(fixture.plan)
	fixture.plan.data.addressed_binary_peers = complete
	client.session_plan.emit(fixture.plan)
	context.equal(fixture.relay.poll(2).code, Relay.Code.WRONG_STATE, "same UUID changing epoch and returning leaves a fence")
	context.equal(client.attempts.size(), 3, "old-lifetime private packets cannot send")
	context.equal(client.sent.size(), 0, "old-lifetime private packets cannot broadcast")
	_destroy(fixture)


func _addressed_reentry(context: RefCounted) -> void:
	var complete: Array = [{"player_id": V, "epoch": 2}, {"player_id": W, "epoch": 3}]
	var client: AddressedClient = AddressedClient.new()
	var fixture: Dictionary = _addressed_fixture(context, client, complete, _addressed_controls())
	var packets: Array[Peer.Packet] = [_packet(fixture, 7)]
	context.equal(fixture.relay.enqueue_batch(packets), Relay.Code.OK, "own a packet before the buffer read")
	client.transport.on_buffered = func() -> void: client.on_identity = fixture.relay.detach
	var detached: Relay.Result = fixture.relay.poll(0)
	context.equal(detached.code, Relay.Code.WRONG_STATE, "deferred detach stops the poll")
	context.equal(detached.sent, 0, "identity callback detaches before the SDK call")
	context.equal(client.attempts.size(), 0, "detach in the dynamic gate prevents private emission")
	context.equal(fixture.relay.status().pending_packets, 0, "deferred detach clears queue after unwind")
	_destroy(fixture)

	client = AddressedClient.new()
	fixture = _addressed_fixture(context, client, complete, _addressed_controls())
	packets = [_packet(fixture, 8)]
	context.equal(fixture.relay.enqueue_batch(packets), Relay.Code.OK, "own a packet before the transport replacement")
	var replacement: Transport = Transport.new()
	replacement.buffered = 262144
	client.transport.on_buffered = func() -> void: client.transport = replacement
	var replaced: Relay.Result = fixture.relay.poll(0)
	context.equal(replaced.code, Relay.Code.SDK_FAILURE, "new transport requires a new measured lifetime")
	context.equal(client.attempts.size(), 0, "a different physical socket cannot use the old socket budget")
	context.equal(fixture.relay.status().pending_packets, 1, "the unsent packet remains owned")
	_destroy(fixture)

	for send_result: Error in [OK, ERR_BUSY]:
		client = AddressedClient.new()
		client.private_code = send_result
		fixture = _addressed_fixture(context, client, complete, _addressed_controls())
		packets = [_packet(fixture, 9)]
		context.equal(fixture.relay.enqueue_batch(packets), Relay.Code.OK, "own one packet before send reentry")
		client.on_send = func() -> void:
			fixture.plan.data.addressed_binary_peers = [{"player_id": V, "epoch": 4}, complete[1]]
			client.session_plan.emit(fixture.plan)
		var fenced: Relay.Result = fixture.relay.poll(0)
		context.equal(fenced.code, Relay.Code.WRONG_STATE, "send callback publishes the expired plan immediately")
		context.equal(fenced.sent, int(send_result == OK), "account for an accepted send before the fence")
		context.equal(fixture.relay.status().pending_packets, int(send_result == ERR_BUSY), "retain only an unaccepted send")
		context.equal(client.attempts.size(), 1, "an expired plan cannot dispatch a second send")
		context.equal(client.sent.size(), 0, "a refused or invalidated private send cannot broadcast")
		_destroy(fixture)

	client = AddressedClient.new()
	fixture = _addressed_fixture(context, client, complete, _addressed_controls())
	packets = [_packet(fixture, 10), _packet(fixture, 11)]
	context.equal(fixture.relay.enqueue_batch(packets), Relay.Code.OK, "own a head and tail before synchronous detach")
	client.on_send = func() -> void:
		context.equal(fixture.relay.poll(0).code, Relay.Code.INVALID_ARGUMENT, "nested poll cannot start a send")
		context.equal(fixture.relay.enqueue_batch(packets), Relay.Code.WRONG_STATE, "nested enqueue cannot take ownership")
		fixture.relay.detach()
		context.equal(fixture.relay.status().pending_packets, 2, "active send owns data until its SDK call returns")
	var stopped: Relay.Result = fixture.relay.poll(0)
	context.equal(stopped.code, Relay.Code.WRONG_STATE, "synchronous send detach is surfaced")
	context.equal(stopped.sent, 1, "SDK accepted the head before deferred cleanup")
	context.equal(client.attempts.size(), 1, "detaching send cannot dispatch the tail")
	context.equal(fixture.relay.status().pending_packets, 0, "deferred cleanup releases the queue")
	context.equal(client.get_signal_connection_list("game_data_binary_received").size(), 0, "deferred cleanup releases the signal")
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


class NegotiatedOnlyClient:
	extends Client

	var negotiated: bool = true

	func has_addressed_binary_game_data() -> bool:
		return negotiated


class AddressedClient:
	extends NegotiatedOnlyClient

	var private_code: Error = OK
	var attempts: Array[Dictionary] = []
	var on_identity: Callable
	var on_send: Callable

	func get_player_id() -> String:
		if on_identity.is_valid():
			var callback: Callable = on_identity
			on_identity = Callable()
			callback.call()
		return super.get_player_id()

	func send_game_data_binary_to(recipient: String, bytes: PackedByteArray) -> Error:
		attempts.append({"recipient": recipient, "bytes": bytes.duplicate()})
		if on_send.is_valid():
			on_send.call()
		return private_code


class Transport:
	extends RefCounted
	var buffered: int = 0
	var max_packets_per_poll: int = 256
	var can_receive_packet: Callable
	var on_buffered: Callable = Callable()

	func get_buffered_amount() -> int:
		if on_buffered.is_valid():
			on_buffered.call()
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
