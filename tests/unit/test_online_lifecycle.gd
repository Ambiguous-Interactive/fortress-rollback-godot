extends RefCounted

# Value: protects=expiry before retained transport retry; fails_when=pressure freezes clocks or stale traffic revives expiry; why_new=ordinary timeout has no retained batch
const Fixture = preload("res://tests/unit/test_online_example.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Lobby = preload("res://examples/online/lobby.gd")


class ClosingClient:
	extends Node
	signal protocol_error(reason: String)
	signal disconnected(code: int, reason: String)
	var failure_stage: String = ""
	var closes: int = 0
	var polls: int = 0
	var ready_calls: int = 0
	var is_closed: bool = false
	func close(_code: int, _reason: String) -> Error:
		closes += 1
		protocol_error.emit("reentrant close")
		return OK
	func poll() -> void:
		polls += 1
		if closes > 0:
			is_closed = true
			disconnected.emit(1000, "closed")
		elif failure_stage == "client_poll":
			protocol_error.emit("original failure")
	func get_players() -> Array[RefCounted]:
		return [Player.new(), Player.new()]
	func set_ready() -> Error:
		ready_calls += 1
		if failure_stage == "ready":
			protocol_error.emit("original failure")
		return OK
	func start_game() -> Error:
		protocol_error.emit("original failure")
		return OK


class Player:
	extends RefCounted
	var id: String = "player"


class ClosingMesh:
	extends Node
	var callback: Callable
	var polls: int = 0
	var transport: ClosingTransport = ClosingTransport.new()
	func poll() -> void:
		polls += 1
		if callback.is_valid():
			callback.call("original failure")
	func get_multiplayer_peer() -> Object:
		return transport


class ClosingTransport:
	extends RefCounted
	var callback: Callable
	func poll() -> void:
		if callback.is_valid():
			callback.call("original failure")
	func get_peers() -> Dictionary:
		return {2: {"connected": true}}


class ClosingAdapter:
	extends Fixture.Match.Adapter
	var checks: int = 0
	func status() -> Dictionary:
		checks += 1
		return {"route": "mesh"}


class ClosingMatch:
	extends Fixture.Match
	var callback: Callable
	var freezes: int = 0
	func freeze(_client: Object, _mesh: Object, _roster: PackedStringArray, _incarnation: PackedByteArray) -> Error:
		freezes += 1
		if callback.is_valid():
			callback.call("original failure")
		return OK
	func start_transport(_client: Object, _mesh: Object, _config: Object, _info: Object, _now_us: int) -> Error:
		callback.call("original failure")
		return OK


class PressuredTransport:
	extends Fixture.RefusedCoordinator
	var delegate: Fixture.Fallback
	func poll(now_us: int, factory: Callable = Callable()) -> Result:
		return delegate.poll(now_us, factory)
	func detach() -> void:
		delegate.detach()


class BoundedPeer:
	extends Fixture.Peer
	# Variant parameters preserve the production peer's validated configuration boundary.
	func configure(config: Variant, local: Variant, game: Variant, handshake: Variant, inputs: Variant, lifecycle: Variant = null) -> int:
		handshake.max_transitions = 2
		handshake.roundtrips = 1
		return super.configure(config, local, game, handshake, inputs, lifecycle)


func cases() -> PackedStringArray:
	return PackedStringArray(["pressured_handshake_expiry", "saturated_handshake_expiry", "pressured_running_expiry", "short_suspend", "diagnostic_pressure",
		"failure_close", "ready_failure", "startup_failure"])


func run_case(name: String, context: RefCounted) -> void:
	if name in ["failure_close", "ready_failure", "startup_failure"]:
		_lobby_failure(context, name)
		context.finish()
		return
	var helper: RefCounted = Fixture.new()
	if name == "diagnostic_pressure":
		_diagnostic_pressure(context, helper)
		context.finish()
		return
	var fixtures: Array[Dictionary] = [helper._fixture(context, Fixture.U), helper._fixture(context, Fixture.V)]
	if name not in ["pressured_handshake_expiry", "saturated_handshake_expiry"]:
		for round_index: int in 100:
			for fixture: Dictionary in fixtures:
				fixture.driver.tick(round_index * 16667, Simulation.RIGHT)
			helper._deliver(fixtures)
		for fixture: Dictionary in fixtures:
			context.equal(fixture.driver.peer.network_status().state, "running", "actual peers synchronize before suspension")
	if name == "short_suspend":
		var frames: PackedInt32Array = PackedInt32Array()
		for fixture: Dictionary in fixtures:
			frames.append(fixture.driver.peer.status().current_frame)
		for index: int in 2:
			var fixture: Dictionary = fixtures[index]
			fixture.driver.tick(2400000, Simulation.LEFT)
			context.equal(fixture.driver.failure, "", "sub-timeout elapsed suspension preserves session")
			context.equal(fixture.driver.peer.status().current_frame <= frames[index] + 1, true, "elapsed time does not create catch-up simulation")
			context.equal(fixture.driver.peer.network_status().last_now_us, 2400000, "protocol uses full elapsed host time")
		for round_index: int in 60:
			helper._deliver(fixtures)
			for fixture: Dictionary in fixtures:
				fixture.driver.tick(2400000 + round_index * 16667, Simulation.LEFT)
				context.equal(fixture.driver.failure, "", "actual original-input recovery after short suspension")
		for index: int in 2:
			context.equal(fixtures[index].driver.peer.status().confirmed_frame > frames[index] + 30, true, "confirmation progresses after resume")
	else:
		var fixture: Dictionary = fixtures[0]
		var coordinator: Fixture.RefusedCoordinator = Fixture.RefusedCoordinator.new()
		var buffered: Array[Dictionary] = []
		if name == "pressured_running_expiry":
			buffered.assign(fixture.transport.incoming.duplicate(true))
			context.equal(buffered.is_empty(), false, "retain actual valid remote packets for overdue resume")
			var transport: PressuredTransport = PressuredTransport.new()
			transport.delegate = fixture.driver.fallback
			coordinator = transport
		else:
			fixture.driver.fallback.detach()
		fixture.driver.fallback = coordinator
		var is_handshake: bool = name in ["pressured_handshake_expiry", "saturated_handshake_expiry"]
		var start: int = 0 if is_handshake else 1666700
		fixture.driver.tick(start, Simulation.RIGHT)
		if name == "saturated_handshake_expiry":
			for round_index: int in range(1, 150):
				fixture.driver.tick(round_index * 200001, Simulation.RIGHT)
			context.equal(fixture.driver.failure, "", "bounded token pressure remains recoverable before expiry")
		context.equal(fixture.driver._pending.is_empty(), false, "actual drained batch remains caller-owned under pressure")
		var deadline: int = 30000000
		if name == "pressured_running_expiry":
			var endpoints: Dictionary = fixture.driver.peer.network_status().peers
			deadline = endpoints.values()[0].last_recv_us + 2000000
		fixture.driver.tick(deadline, Simulation.LEFT)
		context.equal(fixture.driver.failure, "", "exact expiry boundary remains eligible")
		var attempts: int = coordinator.attempts
		var frame: int = fixture.driver.peer.status().current_frame
		fixture.transport.incoming.append_array(buffered)
		fixture.driver.tick(deadline + 1, Simulation.LEFT)
		context.equal(fixture.driver.failure.is_empty(), false, "retained output cannot suppress expiry on resume")
		context.equal(coordinator.attempts, attempts, "expiry is adjudicated before retrying retained transport")
		if name == "pressured_running_expiry":
			context.equal(fixture.transport.incoming.size(), buffered.size(), "expired resume never consumes valid buffered gameplay")
		context.equal(fixture.driver.peer.status().current_frame, frame, "expired session never advances")
		fixture.driver.tick(deadline + 1000000, Simulation.RIGHT)
		context.equal(fixture.driver.peer.status().current_frame, frame, "late service cannot resurrect expired game")
	for fixture: Dictionary in fixtures:
		fixture.driver.detach()
		fixture.mesh.free()
		fixture.client.free()
	context.finish()


# Value: protects=terminal room release; fails_when=local failure leaves a socket alive or callback success revives readiness; why_new=existing cases cover only rollback expiry
func _lobby_failure(context: RefCounted, name: String) -> void:
	var stages: Array[String] = ["local", "client_poll", "mesh_poll"]
	if name == "ready_failure":
		stages = ["freeze", "ready"]
	elif name == "startup_failure":
		stages = ["start", "transport_poll", "transport_setup"]
	for stage: String in stages:
		var lobby: Lobby = Lobby.new()
		var client: ClosingClient = ClosingClient.new()
		var mesh: ClosingMesh = ClosingMesh.new()
		var game: ClosingMatch = ClosingMatch.new()
		lobby.client = client
		lobby.mesh = mesh
		lobby.game_match = game
		lobby.state = "lobby"
		client.protocol_error.connect(lobby._on_protocol_error)
		client.disconnected.connect(lobby._on_failure)
		client.failure_stage = stage
		if name == "ready_failure":
			if stage == "freeze":
				game.callback = lobby._on_protocol_error
			context.equal(lobby.ready(), ERR_UNAVAILABLE, "synchronous failure overrides successful ready return: " + stage)
			context.equal(client.ready_calls, 0 if stage == "freeze" else 1, "failure prevents later SDK room work: " + stage)
			context.equal(lobby.has_readied, false, "failed callback cannot publish readiness: " + stage)
		elif name == "startup_failure":
			lobby.has_readied = true
			lobby.all_ready = true
			lobby.is_creator = true
			game.adapter = ClosingAdapter.new()
			if stage == "start":
				context.equal(lobby.start(), ERR_UNAVAILABLE, "synchronous start failure overrides SDK success")
			else:
				lobby.state = "starting"
				if stage == "transport_poll":
					mesh.transport.callback = lobby._on_protocol_error
				else:
					game.callback = lobby._on_protocol_error
				lobby.tick(0, 0)
			context.equal(game.game.frame, 0, "startup failure never advances game: " + stage)
		else:
			if stage == "local":
				lobby._on_protocol_error("original failure")
			else:
				if stage == "mesh_poll":
					mesh.callback = lobby._on_protocol_error
					lobby.has_readied = true
					game.adapter = ClosingAdapter.new()
				lobby.tick(0, 0)
			context.equal(mesh.polls, 1 if stage == "mesh_poll" else 0, "failed room stops mesh service: " + stage)
			if stage == "mesh_poll":
				context.equal(game.adapter.checks, 0, "mesh callback failure prevents later transport service")
		context.equal(lobby.state, "failed", "failure remains terminal: " + stage)
		context.equal(lobby.message, "SignalFish: original failure Leave, then create or join a fresh room.", "close callbacks preserve original recovery reason")
		context.equal(client.closes, 1, "terminal failure closes signaling once: " + stage)
		lobby.tick(1, 0)
		context.equal(client.is_closed, true, "failed tick services physical close completion: " + stage)
		context.equal(client.closes, 1, "close completion does not re-close: " + stage)
		game.callback = Callable()
		mesh.callback = Callable()
		mesh.transport.callback = Callable()
		lobby.disconnect_room()


func _diagnostic_pressure(context: RefCounted, helper: RefCounted) -> void:
	var fixtures: Array[Dictionary] = [helper._fixture(context, Fixture.U, BoundedPeer.new()), helper._fixture(context, Fixture.V)]
	var fixture: Dictionary = fixtures[0]
	var coordinator: PressuredTransport = PressuredTransport.new()
	coordinator.delegate = fixture.driver.fallback
	fixture.driver.fallback = coordinator
	fixture.driver.tick(0, 0)
	var original: PackedByteArray = coordinator.observed[0].duplicate()
	var remote: Fixture.Peer = fixtures[1].driver.peer
	var source: PackedByteArray = remote.peer_ids()[0]
	context.equal(remote.receive(original, source, 0, fixtures[1].driver.next_token()), Fixture.Match.Inputs.Code.OK, "remote answers original retained request")
	var packets: Array[Fixture.Peer.Packet] = remote.drain_outbox()
	var request: PackedByteArray = packets[0].bytes
	for _copy: int in 2:
		context.equal(fixture.driver.peer.receive(request, fixture.driver.peer.peer_ids()[0], 30000000), Fixture.Match.Inputs.Code.OK,
			"actual duplicate requests fill accepted diagnostic bank before expiry")
	for packet: Fixture.Peer.Packet in packets:
		if Fixture.Match.Protocol.Kind.SYNC_REPLY == int(packet.bytes[6]):
			fixture.transport.incoming.append({"source": Fixture.Match.Membership.uuid_to_peer_id(Fixture.V), "channel": 0, "mode": 0, "bytes": packet.bytes})
	context.equal(fixture.transport.incoming.is_empty(), false, "actual completion reply waits in transport")
	fixture.driver.tick(30000001, 0)
	context.equal(fixture.driver.failure.is_empty(), false, "draining deadline pressure must precede buffered completion")
	context.equal(fixture.driver.peer.status().current_frame, 0, "diagnostic pressure cannot revive expired handshake")
	context.equal(fixture.transport.incoming.is_empty(), false, "expired completion reply remains unconsumed")
	for item: Dictionary in fixtures:
		item.driver.detach()
		item.mesh.free()
		item.client.free()
