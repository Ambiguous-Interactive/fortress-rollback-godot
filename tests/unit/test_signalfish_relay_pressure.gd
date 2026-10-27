extends RefCounted

# Value: protects=receive retry ownership; fails_when=temporary ACK pressure drops inputs; seam=real peer endpoint publication capacity
# gdlint: disable=constant-name
const F = preload("res://tests/unit/test_signalfish_relay.gd")
const M = preload("res://tests/unit/test_signalfish_membership.gd")
const C = preload("res://addons/fortress_rollback/core/config.gd")
const H = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const L = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")
const P = preload("res://addons/fortress_rollback/core/peer_session.gd")
const S = preload("res://addons/fortress_rollback/core/session_types.gd")
const D = preload("res://addons/fortress_rollback/core/driver.gd")
const E = preload("res://addons/fortress_rollback/transport/signalfish_relay_envelope.gd")
const R = preload("res://addons/fortress_rollback/transport/signalfish_relay.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["recoverable", "terminal", "handshake", "invalid_tokens"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "recoverable":
		_recoverable(context)
	elif name == "terminal":
		_terminal(context)
	elif name == "invalid_tokens":
		_invalid_tokens(context)
	else:
		_handshake(context)
	context.finish()


func _build(context: RefCounted, terminal: bool, synchronize: bool = true) -> Dictionary:
	var helper: RefCounted = M.new()
	var fixture: Dictionary = F.new()._build(context)
	var config: C = C.new()
	config.sync_test = false
	config.check_distance = 0
	config.input_width = 4
	config.neutral_input = PackedByteArray([0, 0, 0, 0])
	config.max_snapshot_bytes = 20
	config.storage_budget_bytes = 1048576
	var handshake: H.Options = H.Options.new()
	handshake.roundtrips = 1 if synchronize else 2
	handshake.max_outbox = 1
	var input: I.Options = I.Options.new()
	input.max_outbox = 1
	input.max_events = 1 if terminal else 128
	var lifecycle: L.Options = L.Options.new()
	lifecycle.enabled = terminal
	lifecycle.disconnect_notify_us = 100
	var peer: P = P.new()
	context.equal(fixture.membership.configure_peer(peer, config, M.Game.new(2), handshake, input, lifecycle), OK, "real peer configured")
	context.equal(peer.begin(0, [helper._bytes(33, 16)]), I.Code.OK, "real peer begins")
	var remote_membership: RefCounted = helper._membership(context, F.V, PackedStringArray([F.U, F.V]))
	var remote: P = helper._peer(context, remote_membership)
	for tick: int in (6 if synchronize else 0):
		for packet: P.Packet in peer.drain_outbox():
			context.equal(remote_membership.receive(remote, packet.bytes, F.U, tick), I.Code.OK, "remote handshake")
		for packet: P.Packet in remote.drain_outbox():
			context.equal(fixture.membership.receive(peer, packet.bytes, F.V, tick), I.Code.OK, "local handshake")
	if synchronize:
		peer.drain_outbox()
	context.equal(peer.network_status().state, "running" if synchronize else "synchronizing", "actual handshake state")
	fixture.relay.detach()
	var options: R.Options = R.Options.new()
	options.max_packet_bytes = 512
	options.max_receives_per_poll = 2
	context.equal(fixture.relay.configure(fixture.client, fixture.config, fixture.info, fixture.membership, fixture.adapter, peer, options), R.Code.OK, "relay binds real peer")
	fixture.peer = peer
	fixture.remote = remote
	fixture.remote_membership = remote_membership
	return fixture


func _queue(context: RefCounted, fixture: Dictionary, frame: int) -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray([frame + 1, 0, 0, 0])
	fixture.remote.step((frame + 1) * 10, [D.LocalInput.new(1, frame, bytes)])
	var packets: Array[P.Packet] = fixture.remote.drain_outbox()
	context.equal(packets.size(), 1, "actual remote input packet")
	var envelope: PackedByteArray = E.encode(fixture.remote_membership.handshake_message().session_id, F.V, F.U, packets[0].bytes)
	fixture.client.game_data_binary_received.emit(F.V, 1, envelope)
	return envelope


func _recoverable(context: RefCounted) -> void:
	var fixture: Dictionary = _build(context, false)
	_queue(context, fixture, 0)
	var second: PackedByteArray = _queue(context, fixture, 1)
	var outgoing: Array[P.Packet] = [P.Packet.new(fixture.membership.identity(F.V), PackedByteArray([91]))]
	context.equal(fixture.relay.enqueue_batch(outgoing), R.Code.OK, "own outgoing work before receive pressure")
	var tokens: TokenFactory = TokenFactory.new()
	var result: R.Result = fixture.relay.poll(20, tokens.next)
	context.equal(result.code, R.Code.BACKPRESSURE, "recoverable ACK publication pressure")
	context.equal(result.peer_code, I.Code.BACKPRESSURE, "peer refusal retained")
	context.equal(result.received, 1, "count only accepted inputs")
	context.equal(result.sent, 1, "receive pressure still services bounded outgoing work")
	if fixture.client.sent.size() == 1:
		context.equal(E.decode(fixture.client.sent[0], 512).payload, PackedByteArray([91]), "outgoing head delivered during receive pressure")
	context.equal(fixture.peer.status().lifecycle, S.Lifecycle.RUNNING, "temporary refusal keeps peer running")
	context.equal(fixture.peer.network_status().peers.values()[0].last_received_frame, 0, "refused second input never committed")
	context.equal(fixture.relay.status().code, R.Code.OK, "temporary refusal never latched")
	context.equal(fixture.relay.status().received_packets, 1, "exact refused FIFO head retained")
	context.equal(fixture.relay.status().received_bytes, second.size(), "retained bytes accounted")
	context.equal(tokens.calls, 2, "one token request per incoming head")
	context.equal(fixture.peer.drain_outbox().size(), 1, "free ACK publication capacity")
	result = fixture.relay.poll(20, tokens.next)
	context.equal(result.code, R.Code.OK, "retry accepts exact retained head")
	context.equal(result.received, 1, "retry acceptance counted once")
	context.equal(tokens.calls, 2, "retry never consumes another unique token")
	context.equal(fixture.peer.network_status().peers.values()[0].last_received_frame, 1, "FIFO retry advances to second frame")
	context.equal(fixture.relay.status().received_bytes, 0, "accepted input releases queue bytes")
	F.new()._destroy(fixture)


func _terminal(context: RefCounted) -> void:
	var fixture: Dictionary = _build(context, true)
	context.equal(fixture.peer.poll(200), I.Code.OK, "actual lifecycle interruption")
	fixture.peer.drain_outbox()
	_queue(context, fixture, 0)
	var result: R.Result = fixture.relay.poll(201)
	context.equal(result.peer_code, I.Code.BACKPRESSURE, "resume plus input exceeds event capacity")
	context.equal(fixture.peer.status().lifecycle, S.Lifecycle.TERMINATED, "event capacity failure commits termination")
	context.equal(result.code, R.Code.PEER_FAILURE, "terminal pressure remains terminal relay failure")
	context.equal(fixture.relay.poll(202).code, R.Code.PEER_FAILURE, "terminal failure stays latched")
	F.new()._destroy(fixture)


class TokenFactory:
	extends RefCounted
	var calls: int = 0
	var token: PackedByteArray = PackedByteArray()

	func next(_sender: String) -> PackedByteArray:
		calls += 1
		token = PackedByteArray()
		token.resize(16)
		token[0] = calls + 40
		return token


func _handshake(context: RefCounted) -> void:
	var fixture: Dictionary = _build(context, false, false)
	var initial: Array[P.Packet] = fixture.peer.drain_outbox()
	context.equal(fixture.remote_membership.receive(fixture.remote, initial[0].bytes, F.U, 0), I.Code.OK, "remote replies to initial token")
	var remote_packets: Array[P.Packet] = fixture.remote.drain_outbox()
	context.equal(remote_packets.size(), 2, "actual request and reply")
	context.equal(fixture.membership.receive(fixture.peer, remote_packets[0].bytes, F.V, 0), I.Code.OK, "fill local handshake reply capacity")
	var envelope: PackedByteArray = E.encode(fixture.remote_membership.handshake_message().session_id, F.V, F.U, remote_packets[1].bytes)
	fixture.client.game_data_binary_received.emit(F.V, 1, envelope)
	var tokens: TokenFactory = TokenFactory.new()
	context.equal(fixture.relay.poll(0, tokens.next).code, R.Code.BACKPRESSURE, "next-round handshake request temporarily refused")
	context.equal(fixture.peer.network_status().state, "synchronizing", "pressure before running can retry")
	context.equal(tokens.calls, 1, "generate one unique next-round token")
	tokens.token.resize(0)
	context.equal(fixture.peer.drain_outbox().size(), 1, "release handshake reply capacity")
	var result: R.Result = fixture.relay.poll(0, tokens.next)
	context.equal(result.code, R.Code.OK, "cached owned token permits next round")
	context.equal(result.received, 1, "handshake reply accepted exactly once")
	context.equal(tokens.calls, 1, "handshake retry does not remint token")
	context.equal(fixture.peer.drain_outbox().size(), 1, "accepted retry publishes next-round request")
	F.new()._destroy(fixture)


func _invalid_tokens(context: RefCounted) -> void:
	for size: int in [-3, -2, -1, 0, 15, 17, 16777216]:
		var fixture: Dictionary = _build(context, false)
		_queue(context, fixture, 0)
		_queue(context, fixture, 1)
		var tokens: InvalidTokenFactory = InvalidTokenFactory.new(size)
		tokens.on_call = fixture.relay.detach if size in [-3, -2] else Callable()
		var expected: int = R.Code.WRONG_STATE if size in [-3, -2] else R.Code.INVALID_ARGUMENT
		var result: R.Result = fixture.relay.poll(20, tokens.next)
		context.equal(result.code, expected, "reject malformed token before peer pressure " + str(size))
		context.equal(result.received, 0, "invalid token never advances peer")
		context.equal(fixture.relay.get("_receive_token") == null, true, "invalid token never retained")
		context.equal(fixture.relay.poll(20).code, expected, "callback failure latched")
		if size in [-3, -2]:
			context.equal(fixture.relay.status().received_bytes, 0, "callback detach releases retained ingress")
			context.equal(fixture.client.get_signal_connection_list("game_data_binary_received").size(), 0, "callback detach releases SDK observer")
		F.new()._destroy(fixture)


class InvalidTokenFactory:
	extends RefCounted
	var size: int
	var on_call: Callable = Callable()

	func _init(value: int) -> void:
		size = value

	# Variant deliberately exercises malformed public callback returns.
	func next(_uuid: String) -> Variant:
		if on_call.is_valid():
			on_call.call()
		if size < 0 and size != -3:
			return "wrong-type"
		var token: PackedByteArray = PackedByteArray()
		token.resize(16 if size == -3 else size)
		return token
