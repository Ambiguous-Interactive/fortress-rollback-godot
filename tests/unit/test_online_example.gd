extends RefCounted

# Value: protects=online room identity, retained input and teardown; fails_when=room restarts alias or stalled input is resampled; seam=SDK public transport doubles
const Match = preload("res://examples/online/match.gd")
const Fallback = preload("res://addons/fortress_rollback/transport/signalfish_fallback.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Lobby = preload("res://examples/online/lobby.gd")
const MeshFixture = preload("res://tests/unit/test_signalfish_fallback_mesh.gd")
const DirectFixture = preload("res://tests/unit/test_signalfish_webrtc.gd")
const RelayFixture = preload("res://tests/unit/test_signalfish_relay.gd")
const MembershipFixture = preload("res://tests/unit/test_signalfish_membership.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const U: String = MembershipFixture.U
const V: String = MembershipFixture.V
const ROOM: String = "10000000-0000-0000-0000-000000000001"


class ObservedGame:
	extends Simulation
	var samples: Dictionary = {}
	func simulate_frame(input_frame: int, inputs: Types.FrameInputs) -> bool:
		if not super.simulate_frame(input_frame, inputs):
			return false
		samples[input_frame] = PackedInt32Array([inputs.read(0).bytes[0], inputs.read(1).bytes[0]])
		return true


class RefusedCoordinator:
	extends Fallback
	var is_blocked: bool = true
	var observed: Array[PackedByteArray] = []
	var attempts: int = 0
	func enqueue_batch(packets: Array[Peer.Packet]) -> int:
		attempts += 1
		for packet: Peer.Packet in packets:
			observed.append(packet.bytes.duplicate())
		return Code.BACKPRESSURE if is_blocked else Code.OK
	func poll(_now_us: int, _factory: Callable = Callable()) -> Result:
		return Result.new(Code.OK)


class Client:
	extends MeshFixture.Client
	func get_room_id() -> String:
		return ROOM


func cases() -> PackedStringArray:
	return PackedStringArray(["identity", "optional_scene", "live_driver", "retained_batch", "terminal_callbacks", "handshake_timeout"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"identity":
			var identity: PackedByteArray = Match.session_identity(ROOM, PackedStringArray([U, V]))
			context.equal(identity.size(), 16, "domain separated application match identity")
			context.equal(identity, Match.session_identity(ROOM, PackedStringArray([V, U])), "roster order independent")
			context.equal(identity != Match.session_identity(V, PackedStringArray([U, V])), true, "new room has fresh identity")
			for roster: PackedStringArray in [PackedStringArray([U]), PackedStringArray([U, U]), PackedStringArray([U, "bad"])]:
				context.equal(Match.session_identity(ROOM, roster).is_empty(), true, "invalid room membership refused")
		"optional_scene":
			var scene: PackedScene = load("res://examples/online/online.tscn")
			var node: Node = scene.instantiate()
			node.call("_ready")
			var lobby: Lobby = node.get("controller")
			context.equal(lobby.ready(), ERR_UNAVAILABLE, "ready before joining is refused")
			context.equal(lobby.start(), ERR_UNAVAILABLE, "start before joining is refused")
			context.equal(lobby.connect_room("https://wrong", "Player", "", 0), ERR_INVALID_PARAMETER, "non websocket URL refused")
			if not ResourceLoader.exists(Lobby.SDK_PATH):
				context.equal(lobby.connect_room("ws://localhost:8080/ws", "Player", "", 0), ERR_UNAVAILABLE, "missing SDK is actionable without parse failure")
			lobby.disconnect_room()
			context.equal(lobby.state, "offline", "leave available after missing SDK")
			node.free()
		"handshake_timeout":
			var fixture: Dictionary = _fixture(context, U)
			fixture.driver.tick(30000000, 0)
			context.equal(fixture.driver.failure, "", "handshake remains eligible at exact configured timeout")
			fixture.driver.tick(30000001, 0)
			context.equal(fixture.driver.failure.is_empty(), false, "missing rollback handshake times out after connected mesh")
			fixture.driver.detach()
			fixture.mesh.free()
			fixture.client.free()
		"terminal_callbacks":
			for failure_first: bool in [true, false]:
				var lobby: Lobby = Lobby.new()
				if failure_first:
					lobby._on_failure("failure")
					lobby._on_room(null)
				else:
					lobby._on_room(null)
					lobby._on_failure("failure")
				lobby._on_lobby(0, PackedStringArray(), true)
				context.equal(lobby.state, "failed", "failure remains terminal regardless of queued room callback order")
				context.equal(lobby.all_ready, false, "late ready callback cannot reopen failed lobby")
				context.equal(lobby.ready(), ERR_UNAVAILABLE, "terminal room cannot ready old lifetime")
			var duplicate: Lobby = Lobby.new()
			duplicate._on_room(null)
			duplicate._on_room(null)
			context.equal(duplicate.state, "failed", "duplicate room baseline refuses old lifetime")
		"retained_batch":
			_retained_batch(context)
		"live_driver":
			_live_driver(context)
	context.finish()


func _fixture(context: RefCounted, uuid: String) -> Dictionary:
	var client: Client = Client.new()
	client.local = uuid
	var mesh: DirectFixture.FakeMesh = DirectFixture.FakeMesh.new()
	var transport: MeshFixture.Transport = MeshFixture.Transport.new()
	transport.local = uuid
	mesh.transport = transport
	var game_match: Match = Match.new()
	game_match.game = ObservedGame.new()
	context.equal(game_match.freeze(client, mesh, PackedStringArray([V, U]), PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8])), OK, "freeze real game membership")
	var plan: MembershipFixture.Plan = MembershipFixture.Plan.new()
	plan.data.peers = [{"player_id": V if uuid == U else U, "initiate": uuid == U}]
	client.session_plan.emit(plan)
	var config: RelayFixture.SDKConfig = RelayFixture.SDKConfig.new()
	config.max_buffered_bytes = 4096
	config.max_outbound_frame_bytes = 4096
	var info: RelayFixture.Info = RelayFixture.Info.new()
	context.equal(game_match.start_transport(client, mesh, config, info, 0), OK, "start real peer + composed transport")
	return {"driver": game_match, "client": client, "mesh": mesh, "transport": transport, "config": config, "info": info}


func _deliver(fixtures: Array[Dictionary]) -> void:
	for source: int in 2:
		var receiver: Dictionary = fixtures[1 - source]
		var sender: Dictionary = fixtures[source]
		for packet: Dictionary in sender.transport.routed:
			receiver.transport.incoming.append({"source": Match.Membership.uuid_to_peer_id(sender.client.local), "channel": 0, "mode": 0, "bytes": packet.bytes})
		sender.transport.routed.clear()
		for bytes: PackedByteArray in sender.client.sent:
			receiver.client.game_data_binary_received.emit(sender.client.local, 1, bytes)
		sender.client.sent.clear()


func _live_driver(context: RefCounted) -> void:
	var fixtures: Array[Dictionary] = [_fixture(context, U), _fixture(context, V)]
	var now: int = 0
	for _round: int in 100:
		for fixture: Dictionary in fixtures:
			fixture.driver.tick(now, 0)
			context.equal(fixture.driver.failure, "", "real handshake callback token accepts remote UUID")
		_deliver(fixtures)
		now += 16667
	for fixture: Dictionary in fixtures:
		context.equal(fixture.driver.peer.network_status().state, "running", "both actual peers synchronize")
	# Withhold all delivery until both exhaust prediction, then change held keyboard state.
	for _round: int in 30:
		for fixture: Dictionary in fixtures:
			fixture.driver.tick(now, Simulation.RIGHT)
		now += 16667
	var held_frames: PackedInt32Array = PackedInt32Array()
	for fixture: Dictionary in fixtures:
		held_frames.append(fixture.driver.peer.status().current_frame)
		context.equal(fixture.driver.stalls > 0, true, "partition exhausts prediction")
		fixture.driver.tick(now, Simulation.LEFT)
	for _round: int in 90:
		_deliver(fixtures)
		for fixture: Dictionary in fixtures:
			fixture.driver.tick(now, Simulation.LEFT)
			context.equal(fixture.driver.failure, "", "partition recovery retains protocol and input ownership")
		now += 16667
	for index: int in 2:
		var fixture: Dictionary = fixtures[index]
		context.equal(fixture.driver.peer.status().confirmed_frame > held_frames[index], true, "confirmed gameplay recovers beyond stalled input")
		var observed: ObservedGame = fixture.driver.game
		context.equal(observed.samples[held_frames[index] + 2][index], Simulation.RIGHT, "first stalled sample survives changed keys until actual acceptance")
		context.equal(fixture.driver.game.frame > held_frames[index] + 30, true, "game resumes beyond prediction bound")
		fixture.driver.tick(now - 16668, 0)
		context.equal(fixture.driver.failure.is_empty(), false, "backward protocol clock fails closed")
		fixture.driver.detach()
		context.equal(fixture.driver.has_started, false, "terminal detach stops game advancement")
		fixture.mesh.free()
		fixture.client.free()


func _retained_batch(context: RefCounted) -> void:
	var fixture: Dictionary = _fixture(context, U)
	var game_match: Match = fixture.driver
	var coordinator: RefusedCoordinator = RefusedCoordinator.new()
	game_match.fallback.detach()
	game_match.fallback = coordinator
	game_match.tick(0, Simulation.RIGHT)
	context.equal(coordinator.attempts, 8, "bounded service retries refused caller-owned batch")
	context.equal(coordinator.observed.size(), 8, "refusal retains one original handshake packet")
	var original: PackedByteArray = coordinator.observed[0].duplicate()
	for observed: PackedByteArray in coordinator.observed:
		context.equal(observed, original, "every retry preserves exact encoded bytes")
	coordinator.is_blocked = false
	game_match.tick(1, Simulation.LEFT)
	context.equal(coordinator.attempts, 9, "acceptance transfers original batch once")
	context.equal(coordinator.observed.back(), original, "accepted bytes equal refused original")
	context.equal(game_match.failure, "", "recoverable ownership pressure does not terminate")
	game_match.detach()
	fixture.mesh.free()
	fixture.client.free()
