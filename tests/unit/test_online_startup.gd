extends RefCounted

# Value: protects=independent online handshake completion; fails_when=valid unordered early gameplay kills a synchronizing peer; seam=actual Match callers and SDK transport doubles
const Example = preload("res://tests/unit/test_online_example.gd")
const Match = preload("res://examples/online/match.gd")
const Lobby = preload("res://examples/online/lobby.gd")
const RelayFixture = preload("res://tests/unit/test_signalfish_relay.gd")
const MembershipFixture = preload("res://tests/unit/test_signalfish_membership.gd")
const Protocol = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")


func cases() -> PackedStringArray:
	return PackedStringArray([
		"asymmetric_direct", "asymmetric_relay", "early_validation", "native_relay_plan", "native_ingress_pressure", "native_terminal_endpoint"
	])


func run_case(name: String, context: RefCounted) -> void:
	if name == "early_validation":
		_early_validation(context)
		context.finish()
		return
	if name == "native_relay_plan":
		_native_relay_plan(context)
		context.finish()
		return
	if name == "native_ingress_pressure":
		_native_ingress_pressure(context)
		context.finish()
		return
	if name == "native_terminal_endpoint":
		_native_terminal_endpoint(context)
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


# Value: protects=native relay startup on accepted SDK fallback; fails_when=either startup gate requires a literal relay plan; seam=production lobby, match and adapters
func _native_relay_plan(context: RefCounted) -> void:
	var rows: Array[Array] = [
		["native", "relay", "relay", "relay", "", "relay", "playing"],
		["native", "relay", "host", "direct", "relay", "relay_required", "playing"],
		["native", "relay", "host", "direct", "direct", "blocked", "failed"],
		["native", "mesh", "host", "direct", "relay", "relay_required", "failed"],
		["legacy", "mesh", "host", "direct", "relay", "relay_required", "failed"],
	]
	for row: Array in rows:
		var client: LobbyClient = LobbyClient.new()
		var mesh: LobbyMesh = LobbyMesh.new()
		var lobby: Lobby = Lobby.new()
		lobby.client = client
		lobby.mesh = mesh
		lobby.game_match = StartupMatch.new()
		lobby.backend = row[0]
		lobby._requested_route = row[1]
		lobby._config = RelayFixture.SDKConfig.new()
		lobby._config.max_buffered_bytes = 4096
		lobby._config.max_outbound_frame_bytes = 4096
		lobby._info = RelayFixture.Info.new()
		lobby.state = "lobby"
		lobby.has_readied = true
		var incarnation: PackedByteArray = PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8])
		var label: String = "/".join(PackedStringArray(row.slice(0, 6)))
		var game: Match = lobby.game_match
		context.equal(game.freeze(client, mesh, PackedStringArray([Example.U, Example.V]), incarnation), OK, "freeze room " + label)
		if lobby.backend == "native":
			game.driver._native_backend = Match.Driver.Native.new()
		var plan: MembershipFixture.Plan = MembershipFixture.Plan.new()
		plan.data.topology = row[2]
		plan.data.transport = row[3]
		plan.data.fallback = row[4]
		plan.data.peers.clear()
		client.session_plan.emit(plan)
		context.equal(game.adapter.status().route, row[5], "plan attribution " + label)
		context.equal(mesh.attached, false, "non-mesh plan detaches the mesh " + label)
		lobby.tick(0, 0)
		context.equal(lobby.state, row[6], "lobby route selection " + label + " " + lobby.message)
		var started: bool = row[6] == "playing"
		context.equal(game.has_started, started, "match startup " + label)
		context.equal(game.relay.status().code, Match.Relay.Code.OK if started else Match.Relay.Code.WRONG_STATE, "relay setup " + label)
		context.equal(game.direct.status().code, Match.Direct.Code.WRONG_STATE, "no direct transport " + label)
		lobby.disconnect_room()


class LobbyClient:
	extends RelayFixture.Client
	var incoming: Array[PackedByteArray] = []

	func get_room_id() -> String:
		return Example.ROOM

	func poll() -> void:
		for _index: int in mini(transport.max_packets_per_poll, incoming.size()):
			if transport.can_receive_packet.is_valid() and not transport.can_receive_packet.call():
				break
			game_data_binary_received.emit(Example.V, 1, incoming.pop_front())

	func close(_code: int, _reason: String) -> void:
		pass


class LobbyMesh:
	extends MembershipFixture.FakeMesh

	func poll() -> void:
		pass


class StartupMatch:
	extends Match

	# The fixture exercises transport startup without executing native gameplay.
	func tick(_now_us: int, _buttons: int) -> void:
		pass


# Value: protects=native receive retry ownership; fails_when=a full native queue drops a valid datagram; seam=online match and binary relay receiver
func _native_ingress_pressure(context: RefCounted) -> void:
	var client: LobbyClient = LobbyClient.new()
	var mesh: LobbyMesh = LobbyMesh.new()
	var game: Match = Match.new()
	var incarnation: PackedByteArray = PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8])
	context.equal(game.freeze(client, mesh, PackedStringArray([Example.U, Example.V]), incarnation), OK, "freeze room")
	var backend: Match.Driver.Native = Match.Driver.Native.new()
	var ingress: NativeIngress = NativeIngress.new()
	backend._native = ingress
	game.driver._native_backend = backend
	game._native_identity = game.membership.handshake_message().session_id
	var plan: MembershipFixture.Plan = MembershipFixture.Plan.new()
	plan.data.topology = "relay"
	plan.data.transport = "relay"
	plan.data.peers.clear()
	client.session_plan.emit(plan)
	var config: RelayFixture.SDKConfig = RelayFixture.SDKConfig.new()
	config.max_buffered_bytes = 4096
	config.max_outbound_frame_bytes = 4096
	context.equal(game.start_transport(client, mesh, config, RelayFixture.Info.new(), 0), OK, "native relay ready")

	var payload: PackedByteArray = PackedByteArray([91, 72])
	var invalid: PackedByteArray = _native_envelope(game, PackedByteArray([0]))
	var valid: PackedByteArray = _native_envelope(game, payload)
	client.game_data_binary_received.emit(Example.V, 1, invalid)
	client.game_data_binary_received.emit(Example.V, 1, valid)
	var pressure: Match.Relay.Result = game.relay.poll(0)
	context.equal(pressure.code, Match.Relay.Code.BACKPRESSURE, "valid datagram surfaces recoverable pressure")
	context.equal(pressure.peer_code, Match.Inputs.Code.BACKPRESSURE, "match forwards native pressure")
	context.equal(pressure.received, 0, "neither malformed nor refused datagram counted as accepted")
	context.equal(game.relay.status().received_packets, 1, "malformed datagram dropped and exact valid datagram retained")
	context.equal(game.relay.status().received_bytes, valid.size(), "retained bytes accounted for")
	context.equal(ingress.accepted.size(), 0, "full native queue does not accept")
	context.equal(game.driver.receive_native(2, payload), false, "boolean receive API still refuses capacity")

	ingress.full = false
	var retry: Match.Relay.Result = game.relay.poll(1)
	context.equal(retry.code, Match.Relay.Code.OK, "pressure clears on retry")
	context.equal(retry.received, 1, "exact retained datagram accepted once")
	context.equal(ingress.accepted, [payload], "native ingress receives original bytes after capacity frees")
	context.equal(game.relay.status().received_bytes, 0, "retry releases retained bytes")
	context.equal(game.relay.poll(2).received, 0, "no duplicate retry after acceptance")

	var lobby: Lobby = Lobby.new()
	lobby.client = client
	lobby.game_match = game
	lobby.backend = "native"
	lobby.state = "playing"
	lobby._config = config
	config.max_inbound_packets_per_poll = 256
	var burst: Array[PackedByteArray] = []
	for index: int in 256:
		var sample: PackedByteArray = PackedByteArray([index, 72])
		burst.append(sample)
		client.incoming.append(_native_envelope(game, sample))

	lobby._poll_client()
	context.equal(game.relay.status().code, Match.Relay.Code.OK, "a fully addressed SDK burst is paced before overflow")
	context.equal(client.incoming.size(), 128, "the excess burst stays in SDK FIFO order")
	ingress.full = true
	context.equal(game.relay.poll(3).code, Match.Relay.Code.BACKPRESSURE, "full native inbox retains the burst head")
	lobby._poll_client()
	context.equal(client.incoming.size(), 128, "a full relay FIFO leaves the SDK queue untouched")
	ingress.full = false
	context.equal(game.relay.poll(4).received, 64, "native service drains one bounded receive batch")
	lobby._poll_client()
	context.equal(client.incoming.size(), 64, "next SDK drain respects the partially occupied FIFO")
	context.equal(game.relay.poll(5).received, 64, "the next bounded batch makes progress")
	lobby._poll_client()
	context.equal(client.incoming.size(), 0, "every SDK packet eventually leaves the backlog")
	context.equal(game.relay.poll(6).received + game.relay.poll(7).received, 128, "two native service turns consume the remaining burst")
	context.equal(ingress.accepted.slice(1), burst, "all SDK bytes reach native once in arrival order")

	var identity: PackedByteArray = game.membership.handshake_message().session_id
	var other_recipient: PackedByteArray = Match.Relay.Envelope.encode(identity, Example.V, Example.V, identity + payload)
	for _index: int in 128:
		client.incoming.append(other_recipient)
	for index: int in 128:
		client.incoming.append(_native_envelope(game, burst[index]))
	lobby._poll_client()
	context.equal(client.incoming.size(), 0, "unrelated broadcasts do not halve the SDK poll budget")
	context.equal(game.relay.status().received_packets, 128, "all addressed frames fit after the unrelated broadcasts")
	context.equal(client.transport.can_receive_packet.is_null(), true, "the guard ends with the playing SDK poll")
	lobby.client = null
	game.detach()
	mesh.free()
	client.free()


func _native_envelope(game: Match, payload: PackedByteArray) -> PackedByteArray:
	var identity: PackedByteArray = game.membership.handshake_message().session_id
	return Match.Relay.Envelope.encode(identity, Example.V, Example.U, identity + payload)


class NativeIngress:
	extends RefCounted

	var full: bool = true
	var accepted: Array[PackedByteArray] = []

	func receive_from_result(endpoint: int, bytes: PackedByteArray) -> int:
		if endpoint != 2 or bytes.size() != 2:
			return Match.Driver.Native.ReceiveCode.REJECTED
		if full:
			return Match.Driver.Native.ReceiveCode.FULL
		accepted.append(bytes)
		return Match.Driver.Native.ReceiveCode.ACCEPTED



class LegacyTerminal:
	extends RefCounted

	var detail: String = "disconnected"

	func step_roster(_sample: PackedByteArray, _callbacks: RefCounted) -> int:
		return -1

	func terminal_reason() -> String:
		return detail


class TerminalWithEndpoint:
	extends LegacyTerminal

	func terminal_endpoint() -> int:
		return 2


# Value: protects=first native expiry diagnostic across teardown and older extension builds;
# fails_when=cleanup drops the endpoint or calls an absent method; seam=public driver lifecycle with both extension method sets
func _native_terminal_endpoint(context: RefCounted) -> void:
	var samples: Array[PackedByteArray] = [PackedByteArray([1, 0, 0, 0])]
	for detail: String in ["disconnected", "legacy", "desync", "room_departure"]:
		var driver: Match.Driver = Match.Driver.new()
		context.equal(driver.native_terminal_endpoint(), 0, "no native session")
		var backend: Match.Driver.Native = Match.Driver.Native.new()
		var binding: LegacyTerminal = LegacyTerminal.new() if detail == "legacy" else TerminalWithEndpoint.new()
		if detail == "desync":
			binding.detail = detail
		backend._native = binding
		backend._local_players = PackedInt32Array([0])
		driver._native_backend = backend
		context.equal(driver.native_terminal_endpoint(), 0, "before terminal step " + detail)
		if detail == "room_departure":
			driver.terminate()
		else:
			driver.step_local(0, samples)
		context.equal(driver.status().lifecycle, Match.Types.Lifecycle.TERMINATED, "terminal status " + detail)
		context.equal(backend._native, null, "native owner dropped " + detail)
		driver.terminate()
		driver.step_local(1, samples)
		context.equal(driver.native_terminal_endpoint(), 2 if detail == "disconnected" else 0, "latched diagnostic " + detail)
