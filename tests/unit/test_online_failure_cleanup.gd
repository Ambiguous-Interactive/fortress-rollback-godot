extends RefCounted

# Value: protects=failed-room queue release; fails_when=SDK failure interrupts busy adapter detach; why_new=ordinary failure tests have no active transport callback
const Fixture = preload("res://tests/unit/test_online_example.gd")
const Lobby = preload("res://examples/online/lobby.gd")


class Client:
	extends Fixture.Client
	signal protocol_error(reason: String)
	var closes: int = 0
	var attempts: int = 0
	var incoming: PackedByteArray = PackedByteArray()
	var relay_ref: WeakRef
	var accepted_received: int = 0
	var fail_send: bool = true
	var fail_poll: bool = false
	var polls: int = 0
	func poll() -> void:
		polls += 1
		if fail_poll:
			protocol_error.emit("queued peer departure")
	func close(_code: int, _reason: String) -> Error:
		closes += 1
		return OK
	func send_game_data_binary(_bytes: PackedByteArray) -> Error:
		if not fail_send:
			return super.send_game_data_binary(_bytes)
		attempts += 1
		game_data_binary_received.emit(Fixture.V, 1, incoming)
		accepted_received = relay_ref.get_ref().status().received_packets
		protocol_error.emit("send failed")
		return ERR_INVALID_DATA


class BrowserMesh:
	extends Fixture.DirectFixture.FakeMesh
	func poll() -> void:
		pass


func cases() -> PackedStringArray:
	return PackedStringArray(["relay_send_failure", "sdk_failure_deadline"])


func _build(context: RefCounted) -> Dictionary:
	var lobby: Lobby = Lobby.new()
	var client: Client = Client.new()
	client.local = Fixture.U
	var mesh: BrowserMesh = BrowserMesh.new()
	var transport: Fixture.MeshFixture.Transport = Fixture.MeshFixture.Transport.new()
	transport.local = Fixture.U
	mesh.transport = transport
	var game: Fixture.Match = lobby.game_match
	context.equal(game.freeze(client, mesh, PackedStringArray([Fixture.V, Fixture.U]), PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8])), OK, "real frozen room")
	var plan: Fixture.MembershipFixture.Plan = Fixture.MembershipFixture.Plan.new()
	plan.data.peers = [{"player_id": Fixture.V, "initiate": true}]
	client.session_plan.emit(plan)
	var config: Fixture.RelayFixture.SDKConfig = Fixture.RelayFixture.SDKConfig.new()
	config.max_buffered_bytes = 4096
	config.max_outbound_frame_bytes = 4096
	var info: Fixture.RelayFixture.Info = Fixture.RelayFixture.Info.new()
	context.equal(game.start_transport(client, mesh, config, info, 0), OK, "real composed direct and relay adapters")
	lobby.client = client
	lobby.mesh = mesh
	lobby.state = "playing"
	lobby.has_readied = true
	client.protocol_error.connect(lobby._on_protocol_error)
	return {"lobby": lobby, "driver": game, "client": client, "mesh": mesh, "transport": transport, "config": config, "info": info}


func run_case(name: String, context: RefCounted) -> void:
	if name == "sdk_failure_deadline":
		_clock_failure(context)
		context.finish()
		return
	var fixture: Dictionary = _build(context)
	var lobby: Lobby = fixture.lobby
	var client: Client = fixture.client
	var game: Fixture.Match = fixture.driver
	var transport: Fixture.MeshFixture.Transport = fixture.transport
	game.fallback.detach()
	# Configure the real coordinator before any work, with immediate relay fallback.
	var options: Fixture.Fallback.Options = Fixture.Fallback.Options.new()
	options.fallback_after_us = 0
	options.max_routes_per_poll = 1
	context.equal(game.fallback.configure(game.direct, game.relay, game.membership, game.adapter, game.peer, options), Fixture.Fallback.Code.OK, "real bounded fallback")
	transport.channel.buffered = 2000000
	var packets: Array[Fixture.Peer.Packet] = []
	for value: int in 2:
		packets.append(Fixture.Peer.Packet.new(game.membership.identity(Fixture.V), PackedByteArray([value + 1])))
	context.equal(game.fallback.enqueue_batch(packets), Fixture.Fallback.Code.OK, "own multiple packets across coordinator and relay")
	client.relay_ref = weakref(game.relay)
	client.incoming = Fixture.Match.Relay.Envelope.encode(game.membership.handshake_message().session_id, Fixture.V, Fixture.U, PackedByteArray([1]))
	lobby.tick(0, 0)
	context.equal(client.attempts, 1, "actual relay send enters synchronous SDK failure callback")
	context.equal(lobby.state, "failed", "callback terminates original lobby")
	context.equal(lobby.message, "SignalFish: send failed Leave, then create or join a fresh room.", "first SDK cause survives unwind")
	context.equal(game.fallback.status().pending_packets, 0, "coordinator releases packets after callback unwinds")
	context.equal(game.relay.status().pending_packets, 0, "relay releases refused send after callback unwinds")
	context.equal(client.accepted_received, 1, "actual addressed relay ingress accepted during send callback")
	context.equal(game.relay.status().received_packets, 0, "relay releases accepted ingress after callback unwinds")
	context.equal(client.is_connected("game_data_binary_received", game.relay._on_binary), false, "relay releases SDK callback after unwind")
	context.equal(game.has_started, false, "detached game remains stopped")
	var revision: int = game.adapter.status().lifetime_revision
	lobby.tick(1, 0)
	context.equal(client.attempts, 1, "terminal polling never retries gameplay")
	context.equal(game.adapter.status().lifetime_revision, revision, "completed cleanup does not repeatedly replace lifetime")
	lobby.disconnect_room()
	context.finish()


# Value: protects=elapsed liveness before SDK departures; fails_when=queued SDK failure skips overdue protocol polling; why_new=direct Match expiry has no SDK poll callback
func _clock_failure(context: RefCounted) -> void:
	var helper: RefCounted = Fixture.new()
	for offset: int in [0, 1]:
		var fixture: Dictionary = _build(context)
		var fixtures: Array[Dictionary] = [fixture, helper._fixture(context, Fixture.V)]
		var client: Client = fixture.client
		client.fail_send = false
		for round_index: int in 100:
			for item: Dictionary in fixtures:
				item.driver.tick(round_index * 16667, 0)
			helper._deliver(fixtures)
		var game: Fixture.Match = fixture.driver
		context.equal(game.peer.network_status().state, "running", "real peers synchronize before SDK departure deadline")
		var endpoint: Dictionary = game.peer.network_status().peers.values()[0]
		var resume: int = endpoint.last_recv_us + 2000000 + offset
		var frame: int = game.peer.status().current_frame
		var buffered: int = fixture.transport.incoming.size()
		context.equal(buffered > 0, true, "actual valid remote packets wait across suspended service")
		var lobby: Lobby = fixture.lobby
		lobby._epoch = 5000000
		lobby._last_now = lobby._epoch + game._last_now
		client.fail_poll = true
		lobby.tick(lobby._epoch + resume, 0)
		context.equal(lobby._last_now, lobby._epoch + resume, "host clock keeps full elapsed resume")
		context.equal(game.peer.network_status().last_now_us, resume, "protocol clock consumes exact full elapsed time before SDK callbacks")
		context.equal(client.polls, 1 if offset == 0 else 0, "only unexpired boundary services queued SDK departure")
		context.equal(game.peer.status().current_frame, frame, "deadline adjudication and SDK departure never advance gameplay")
		context.equal(fixture.transport.incoming.size(), buffered, "deadline preflight never consumes buffered gameplay")
		context.equal(lobby.state, "failed", "expiry or SDK departure preserves terminal room outcome")
		if offset == 0:
			context.equal(lobby.message, "SignalFish: queued peer departure Leave, then create or join a fresh room.", "exact boundary preserves SDK cause")
		else:
			context.equal(game.failure.is_empty(), false, "overdue expiry is resolved before queued departure")
		lobby.disconnect_room()
		fixtures[1].driver.detach()
		fixtures[1].client.free()
		fixtures[1].mesh.free()
