extends RefCounted

# Value: protects=owned bounded direct byte delivery; fails_when=wrong channel, shifted attribution or pressure loses FIFO; why_new=direct seam; seam=SDK public API
const W = preload("res://addons/fortress_rollback/transport/signalfish_webrtc.gd")
const M = preload("res://tests/unit/test_signalfish_membership.gd")
const A = preload("res://addons/fortress_rollback/transport/signalfish_adapter.gd")
const P = preload("res://addons/fortress_rollback/core/peer_session.gd")
const U: String = M.U
const V: String = M.V


func cases() -> PackedStringArray:
	return PackedStringArray(["send", "atomic", "channel", "receive", "fences", "reentry", "plan_cycle", "plan_roles", "plan_repeat", "plan_detach", "configuration"])


func run_case(name: String, context: RefCounted) -> void:
	var fixture: Dictionary = build(context)
	match name:
		"configuration":
			_configuration(context, fixture)
		"send":
			_send(context, fixture)
		"atomic":
			_atomic(context, fixture)
		"channel":
			_channel(context, fixture)
		"receive":
			_receive(context, fixture)
		"fences":
			_fences(context, fixture)
		"plan_cycle", "plan_roles", "plan_repeat", "plan_detach":
			_plan_revision(context, fixture, name)
		"reentry":
			_reentry(context, fixture)
	destroy(fixture)
	context.finish()


func build(context: RefCounted) -> Dictionary:
	var helper: RefCounted = M.new()
	var membership: RefCounted = helper._membership(context, U, PackedStringArray([U, V]))
	var peer: P = helper._peer(context, membership)
	var client: M.FakeClient = M.FakeClient.new()
	var mesh: FakeMesh = FakeMesh.new()
	var adapter: A = A.new()
	context.equal(adapter.attach(client, mesh, membership), OK, "plan attached")
	client.session_plan.emit(M.Plan.new())
	var options: W.Options = W.Options.new()
	options.max_packet_bytes = 512
	options.max_pending_packets = 2
	options.max_sends_per_poll = 1
	options.max_receives_per_poll = 1
	var direct: W = W.new()
	context.equal(direct.configure(mesh, membership, adapter, peer, options), W.Code.OK, "direct configured")
	return {"direct": direct, "membership": membership, "peer": peer, "client": client, "mesh": mesh, "adapter": adapter}


func destroy(fixture: Dictionary) -> void:
	fixture.direct.detach()
	fixture.adapter.detach()
	fixture.client.free()
	fixture.mesh.free()


func packet(fixture: Dictionary, value: int) -> P.Packet:
	return P.Packet.new(fixture.membership.identity(V), PackedByteArray([value]))


func _configuration(context: RefCounted, fixture: Dictionary) -> void:
	fixture.direct.detach()
	var options: W.Options = W.Options.new()
	options.max_packet_bytes = 1201
	context.equal(fixture.direct.configure(fixture.mesh, fixture.membership, fixture.adapter, fixture.peer, options), W.Code.INVALID_ARGUMENT, "reject oversized configured datagram")
	context.equal(fixture.direct.configure(fixture.mesh, fixture.membership, fixture.adapter, fixture.peer), W.Code.OK, "default direct options fit actual engine")


func _send(context: RefCounted, fixture: Dictionary) -> void:
	var transport: Transport = fixture.mesh.transport
	var packets: Array[P.Packet] = [packet(fixture, 11), packet(fixture, 22)]
	context.equal(fixture.direct.enqueue_batch(packets), W.Code.OK, "accept whole batch")
	packets[0].bytes[0] = 99
	packets[1].to[0] ^= 1
	transport.busy = true
	context.equal(fixture.direct.poll(0).code, W.Code.BACKPRESSURE, "retain SDK busy head")
	transport.busy = false
	transport.channel.buffered = 262144
	context.equal(fixture.direct.poll(1).code, W.Code.BACKPRESSURE, "bound channel backlog")
	transport.channel.buffered = 0
	context.equal(fixture.direct.poll(2).sent, 1, "bounded send work")
	context.equal(fixture.direct.poll(3).sent, 1, "send retained tail")
	context.equal(transport.sent, [PackedByteArray([11]), PackedByteArray([22])], "owned original FIFO bytes")
	context.equal(transport.target, fixture.membership.uuid_to_peer_id(V), "target uses frozen UUID mapping")
	context.equal(transport.mode, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE, "unordered transfer")
	context.equal(transport.channel_number, 0, "built-in unreliable channel")
	context.equal(fixture.direct.status().pending_bytes, 0, "accepted work fully accounted")


func _atomic(context: RefCounted, fixture: Dictionary) -> void:
	var packets: Array[P.Packet] = [packet(fixture, 1), P.Packet.new(PackedByteArray([1]), PackedByteArray([2]))]
	context.equal(fixture.direct.enqueue_batch(packets), W.Code.WRONG_SOURCE, "invalid destination refuses whole batch")
	context.equal(fixture.direct.status().pending_packets, 0, "no partial ownership")
	packets = [packet(fixture, 1), packet(fixture, 2)]
	context.equal(fixture.direct.enqueue_batch(packets), W.Code.OK, "fill capacity")
	packets = [packet(fixture, 3)]
	context.equal(fixture.direct.enqueue_batch(packets), W.Code.BACKPRESSURE, "bounded queue")
	context.equal(packets[0].bytes, PackedByteArray([3]), "refused caller batch unchanged")


func _channel(context: RefCounted, fixture: Dictionary) -> void:
	var packets: Array[P.Packet] = [packet(fixture, 1)]
	fixture.direct.enqueue_batch(packets)
	var transport: Transport = fixture.mesh.transport
	for field: String in ["connected", "state", "ordered", "write_mode", "lifetime"]:
		transport.connected = field != "connected"
		transport.channel.state = 0 if field == "state" else 1
		transport.channel.ordered = field == "ordered"
		transport.channel.write_mode = 0 if field == "write_mode" else 1
		transport.channel.lifetime = 65535 if field == "lifetime" else 1
		var expected: int = W.Code.BACKPRESSURE if field in ["connected", "state"] else W.Code.INCOMPATIBLE_MODE
		context.equal(fixture.direct.poll(0).code, expected, "channel contract " + field)
		context.equal(transport.sent.size(), 0, "unready/incompatible channel never sends")
		context.equal(fixture.direct.status().pending_packets, 1, "channel refusal retains head")


func _receive(context: RefCounted, fixture: Dictionary) -> void:
	var helper: RefCounted = M.new()
	var remote_membership: RefCounted = helper._membership(context, V, PackedStringArray([U, V]))
	var remote: P = helper._peer(context, remote_membership)
	var bytes: PackedByteArray = remote.drain_outbox()[0].bytes
	var transport: Transport = fixture.mesh.transport
	transport.incoming.append({"source": 987, "channel": 0, "mode": 0, "bytes": bytes})
	transport.incoming.append({"source": remote_membership.uuid_to_peer_id(V), "channel": 0, "mode": 0, "bytes": bytes})
	context.equal(fixture.direct.poll(0).received, 0, "unknown peer refused before decoding")
	context.equal(transport.incoming.size(), 1, "bad ingress also consumes bounded work")
	context.equal(fixture.direct.poll(1).received, 1, "attribution captured before PacketPeer advances")
	context.equal(fixture.direct.status().rejected, 1, "one rejected identity")
	for row: Dictionary in [{"source": remote_membership.uuid_to_peer_id(V), "channel": 1, "mode": 0, "bytes": bytes},
		{"source": remote_membership.uuid_to_peer_id(V), "channel": 0, "mode": 2, "bytes": bytes}]:
		transport.incoming.append(row)
		context.equal(fixture.direct.poll(2).received, 0, "wrong channel or reliability ignored")
	context.equal(fixture.direct.status().rejected, 3, "all incompatible ingress counted")


func _fences(context: RefCounted, fixture: Dictionary) -> void:
	var packets: Array[P.Packet] = [packet(fixture, 1)]
	fixture.direct.enqueue_batch(packets)
	var plan: M.Plan = M.Plan.new()
	plan.data.generation = V
	fixture.client.session_plan.emit(plan)
	context.equal(fixture.direct.poll(0).code, W.Code.WRONG_STATE, "generation fence refuses old bytes")
	context.equal(fixture.mesh.transport.sent.size(), 0, "no sends after generation replacement")
	context.equal(fixture.direct.status().pending_packets, 1, "accepted bytes retained for inspection")
	fixture.direct.detach()
	context.equal(fixture.direct.configure(fixture.mesh, fixture.membership, fixture.adapter, fixture.peer), W.Code.OK, "new direct lifetime")
	fixture.mesh.transport = Transport.new()
	context.equal(fixture.direct.poll(0).code, W.Code.WRONG_STATE, "transport replacement fenced")


func _plan_revision(context: RefCounted, fixture: Dictionary, name: String) -> void:
	var packets: Array[P.Packet] = [packet(fixture, 1)]
	fixture.direct.enqueue_batch(packets)
	var plan: M.Plan = M.Plan.new()
	if name == "plan_cycle":
		plan.data.generation = V
		fixture.client.session_plan.emit(plan)
		plan.data.generation = U
	elif name == "plan_roles":
		plan.data.peers[0].initiate = true
		fixture.client.session_plan.emit(plan)
		plan.data.peers[0].initiate = false
	elif name == "plan_detach":
		fixture.adapter.detach()
		context.equal(fixture.adapter.attach(fixture.client, fixture.mesh, fixture.membership), OK, "reattach same SDK objects")
	fixture.client.session_plan.emit(plan)
	context.equal(fixture.direct.poll(0).code, W.Code.OK if name == "plan_repeat" else W.Code.WRONG_STATE, "plan lifetime history fenced " + name)
	context.equal(fixture.mesh.transport.sent.size(), 1 if name == "plan_repeat" else 0, "transient plan mutation never publishes old bytes")


func _reentry(context: RefCounted, fixture: Dictionary) -> void:
	fixture.mesh.transport.on_poll = fixture.direct.detach
	context.equal(fixture.direct.poll(0).code, W.Code.WRONG_STATE, "callback teardown fails closed")
	context.equal(fixture.direct.status().code, W.Code.WRONG_STATE, "reentry failure latched")


class FakeMesh:
	extends M.FakeMesh
	var transport: Transport = Transport.new()

	func get_multiplayer_peer() -> Object:
		return transport


class Channel:
	extends RefCounted
	var buffered: int = 0
	var ordered: bool = false
	var write_mode: int = 1
	var state: int = 1
	var maximum: int = 512
	var lifetime: int = 1
	var retransmits: int = 65535

	func get_max_packet_life_time() -> int:
		return lifetime

	func get_max_retransmits() -> int:
		return retransmits

	func get_ready_state() -> int:
		return state

	func is_ordered() -> bool:
		return ordered

	func get_buffered_amount() -> int:
		return buffered


class Transport:
	extends RefCounted
	var channel: Channel = Channel.new()
	var connected: bool = true
	var busy: bool = false
	var target: int = 0
	var mode: int = -1
	var channel_number: int = -1
	var incoming: Array[Dictionary] = []
	var sent: Array[PackedByteArray] = []
	var on_poll: Callable = Callable()
	var maximum: int = 1200

	func poll() -> void:
		if on_poll.is_valid():
			on_poll.call()

	func get_connection_status() -> int:
		return MultiplayerPeer.CONNECTION_CONNECTED

	func get_unique_id() -> int:
		return M.M.uuid_to_peer_id(U)

	func has_peer(_id: int) -> bool:
		return true

	func get_peer(_id: int) -> Dictionary:
		return {"connected": connected, "channels": [channel, channel, channel]}

	func get_packet_peer() -> int:
		return incoming[0].source if not incoming.is_empty() else 0

	func get_packet_channel() -> int:
		return incoming[0].channel if not incoming.is_empty() else 0

	func get_packet_mode() -> int:
		return incoming[0].mode if not incoming.is_empty() else 2

	func get_available_packet_count() -> int:
		return incoming.size()

	func get_packet() -> PackedByteArray:
		return incoming.pop_front().bytes

	func get_packet_error() -> int:
		return OK

	func set_target_peer(value: int) -> void:
		target = value

	func set_transfer_mode(value: int) -> void:
		mode = value

	func set_transfer_channel(value: int) -> void:
		channel_number = value

	func put_packet(bytes: PackedByteArray) -> Error:
		if busy:
			return ERR_BUSY
		sent.append(bytes.duplicate())
		return OK
