extends RefCounted

# Value: protects=callback cancellation ends online service without freeing emitting nodes or advancing canceled work;
# fails_when=Leave frees a live SDK owner or a detached match runs another frame; why_new=ordinary cleanup runs between ticks; seam=none
const Fixture = preload("res://tests/unit/test_online_example.gd")
const Lobby = preload("res://examples/online/lobby.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


class CancelClient:
	extends Node
	signal left
	var armed: bool = false
	var polls: int = 0
	var closes: int = 0
	var leave_stage: String = ""

	func poll() -> void:
		polls += 1
		if armed:
			armed = false
			left.emit()

	func close(_code: int, _reason: String) -> Error:
		closes += 1
		left.emit()
		return OK

	func get_players() -> Array[RefCounted]:
		return [RoomPlayer.new(Fixture.U), RoomPlayer.new(Fixture.V)]

	func set_ready() -> Error:
		if leave_stage == "ready":
			left.emit()
		return OK

	func start_game() -> Error:
		left.emit()
		return OK


class RoomPlayer:
	extends RefCounted
	var id: String

	func _init(uuid: String) -> void:
		id = uuid


class RoomMatch:
	extends Fixture.Match
	var owner: WeakRef
	var leave_on_freeze: bool = false
	var leave_on_start: bool = false
	var starts: int = 0

	func freeze(_client: Object, _mesh: Object, _roster: PackedStringArray, _incarnation: PackedByteArray) -> Error:
		if leave_on_freeze:
			owner.get_ref().disconnect_room()
		return OK

	func start_transport(_client: Object, _mesh: Object, _config: Object, _info: Object, _now_us: int) -> Error:
		starts += 1
		if leave_on_start:
			owner.get_ref().disconnect_room()
		return OK


class StartupAdapter:
	extends Fixture.Match.Adapter
	var owner: WeakRef
	var armed: bool = false

	func status() -> Dictionary:
		if armed:
			armed = false
			owner.get_ref().disconnect_room()
		return {"route": "mesh"}


class StartupTransport:
	extends RefCounted
	var owner: WeakRef
	var phase: String

	func poll() -> void:
		if phase == "poll":
			owner.get_ref().disconnect_room()

	func get_peers() -> Dictionary:
		if phase == "peers":
			owner.get_ref().disconnect_room()
		return {2: {"connected": true}}


class StartupMesh:
	extends CancelMesh
	var controller: WeakRef
	var phase: String
	var transport: StartupTransport = StartupTransport.new()

	func get_multiplayer_peer() -> Object:
		if phase == "getter":
			controller.get_ref().disconnect_room()
		return transport


class CancelCoordinator:
	extends Fixture.IdleCoordinator
	var owner: WeakRef
	var boundary: String

	func enqueue_batch(_packets: Array[Fixture.Peer.Packet]) -> int:
		if boundary == "enqueue":
			owner.get_ref().detach()
		return Code.OK

	func poll(_now_us: int, _factory: Callable = Callable()) -> Result:
		owner.get_ref().detach()
		return Result.new(Code.BACKPRESSURE)


class CancelMesh:
	extends Node
	signal left
	var armed: bool = false
	var polls: int = 0

	func poll() -> void:
		polls += 1
		if armed:
			armed = false
			left.emit()


class CancelGame:
	extends Simulation
	var owner: WeakRef
	var boundary: int = -1
	var canceled_frame: int = -1
	var calls_after_cancel: int = 0

	func cancel(kind: int) -> bool:
		if canceled_frame >= 0:
			calls_after_cancel += 1
		if boundary != kind:
			return false
		boundary = -1
		canceled_frame = frame
		owner.get_ref().detach()
		return true

	func save_state(saved_frame: int, writer: RefCounted) -> Driver.SaveResult:
		var saved: Driver.SaveResult = super.save_state(saved_frame, writer)
		cancel(Types.Kind.SAVE)
		return saved

	func simulate_frame(input_frame: int, inputs: Types.FrameInputs) -> bool:
		var advanced: bool = super.simulate_frame(input_frame, inputs)
		cancel(Types.Kind.ADVANCE)
		return advanced


func cases() -> PackedStringArray:
	return PackedStringArray(["sdk_leave", "game_leave", "notification_leave", "idle_leave", "room_leave", "transport_leave", "startup_leave", "manual_leave"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "sdk_leave":
		_sdk_leave(context)
	elif name == "idle_leave":
		_idle_leave(context)
	elif name == "room_leave":
		_room_leave(context)
	elif name == "startup_leave":
		_startup_leave(context)
	elif name == "manual_leave":
		_manual_leave(context)
	elif name == "transport_leave":
		_transport_leave(context)
	else:
		_match_leave(context, name == "notification_leave")
	context.finish()


func _sdk_leave(context: RefCounted) -> void:
	for source: String in ["control", "client", "mesh"]:
		var lobby: Lobby = Lobby.new()
		var client: CancelClient = CancelClient.new()
		var mesh: CancelMesh = CancelMesh.new()
		Engine.get_main_loop().root.add_child(client)
		Engine.get_main_loop().root.add_child(mesh)
		client.armed = source == "client"
		mesh.armed = source == "mesh"
		client.left.connect(lobby.disconnect_room)
		mesh.left.connect(lobby.disconnect_room)
		lobby.client = client
		lobby.mesh = mesh
		lobby.state = "lobby"
		lobby.tick(10, 0)
		if source == "control":
			context.equal(lobby.state, "lobby", "ordinary SDK poll preserves room")
			context.equal(mesh.polls, 1, "ordinary service polls mesh")
			lobby.disconnect_room()
		else:
			context.equal(lobby.state, "offline", "callback Leave completes logical cleanup")
			context.equal(lobby.client, null, "callback Leave clears client ownership")
			context.equal(lobby.mesh, null, "callback Leave clears mesh ownership")
			context.equal(lobby._is_busy(), false, "callback Leave releases service guard after unwind")
			context.equal(is_instance_valid(client), true, "emitting SDK owner survives until callback returns")
			context.equal(is_instance_valid(mesh), true, "mesh release waits for active service")
			if is_instance_valid(client):
				context.equal(client.closes, 1, "callback closes signaling once")
				context.equal(client.is_queued_for_deletion(), true, "client physical release is scheduled")
			if is_instance_valid(mesh):
				context.equal(mesh.polls, int(source == "mesh"), "Leave fences later SDK work")
				context.equal(mesh.is_queued_for_deletion(), true, "mesh physical release is scheduled")
			lobby.tick(11, 0)
			context.equal(lobby._last_now, 10, "retired room stops accepting service time")


func _match_leave(context: RefCounted, notification: bool) -> void:
	for kind: int in [Types.Kind.SAVE] if notification else [Types.Kind.SAVE, Types.Kind.ADVANCE]:
		var helper: RefCounted = Fixture.new()
		var fixtures: Array[Dictionary] = [helper._fixture(context, Fixture.U), helper._fixture(context, Fixture.V)]
		var target: Fixture.Match = fixtures[0].driver
		var game: CancelGame = CancelGame.new()
		game.owner = weakref(target)
		target.game = game
		context.equal(target.peer._driver.configure(target.peer._core, game), Types.Code.OK, "cancel callback configures")
		var now: int = 0
		for turn: int in 20:
			for fixture: Dictionary in fixtures:
				fixture.driver.tick(now, Simulation.RIGHT)
			helper._deliver(fixtures)
			now += 16667
		context.equal(target.failure, "", "cancel control has healthy gameplay")
		if notification:
			target.peer.step_completed.connect(
				func(_code: int, _before: int, _after: int) -> void:
					game.canceled_frame = game.frame
					target.detach(),
				CONNECT_ONE_SHOT
			)
		else:
			game.boundary = kind
		target.tick(now, Simulation.RIGHT)
		context.equal(game.canceled_frame >= 0, true, "cancellation boundary actually ran")
		context.equal(target.has_started, false, "callback detaches match")
		context.equal(target.failure, "", "intentional detach does not report transport failure")
		context.equal(target.peer.status().lifecycle, Types.Lifecycle.TERMINATED, "detach retires the shared session")
		context.equal(game.frame, game.canceled_frame, "no game state advances after cancellation")
		context.equal(game.calls_after_cancel, 0, "no later callback runs after cancellation")
		var bytes: PackedByteArray = game.canonical_bytes()
		target.tick(now + 1, Simulation.LEFT)
		context.bytes_equal(game.canonical_bytes(), bytes, game.frame, "retained canceled match cannot advance")
		for fixture: Dictionary in fixtures:
			fixture.driver.detach()
			fixture.mesh.free()
			fixture.client.free()


func _idle_leave(context: RefCounted) -> void:
	var lobby: Lobby = Lobby.new()
	var client: CancelClient = CancelClient.new()
	var mesh: CancelMesh = CancelMesh.new()
	lobby.client = client
	lobby.mesh = mesh
	lobby.state = "lobby"
	lobby.disconnect_room()
	context.equal(lobby.state, "offline", "ordinary Leave completes immediately")
	context.equal(is_instance_valid(client), false, "idle client releases synchronously")
	context.equal(is_instance_valid(mesh), false, "idle mesh releases synchronously")


func _room_leave(context: RefCounted) -> void:
	for stage: String in ["freeze", "ready", "start"]:
		var lobby: Lobby = Lobby.new()
		var client: CancelClient = CancelClient.new()
		var mesh: CancelMesh = CancelMesh.new()
		var game: RoomMatch = RoomMatch.new()
		Engine.get_main_loop().root.add_child(client)
		Engine.get_main_loop().root.add_child(mesh)
		game.owner = weakref(lobby)
		game.leave_on_freeze = stage == "freeze"
		client.leave_stage = stage
		client.left.connect(lobby.disconnect_room)
		lobby.client = client
		lobby.mesh = mesh
		lobby.game_match = game
		lobby.state = "lobby"
		var code: Error
		if stage == "start":
			lobby.is_creator = true
			lobby.has_readied = true
			lobby.all_ready = true
			code = lobby.start()
		else:
			code = lobby.ready()
		context.equal(code, ERR_UNAVAILABLE, "Leave overrides successful SDK setup return")
		context.equal(lobby.state, "offline", "room operation cannot revive a canceled room")
		context.equal(lobby.has_readied, false, "canceled setup does not publish readiness")
		context.equal(lobby._is_busy(), false, "canceled setup releases controller ownership")
		context.equal(client.closes, 1, "reentrant close cannot repeat logical Leave")
		context.equal(client.is_queued_for_deletion(), true, "room callback owner releases after unwind")


func _transport_leave(context: RefCounted) -> void:
	for phase: String in ["enqueue", "poll"]:
		var fixture: Dictionary = Fixture.new()._fixture(context, Fixture.U)
		var target: Fixture.Match = fixture.driver
		var coordinator: CancelCoordinator = CancelCoordinator.new()
		coordinator.owner = weakref(target)
		coordinator.boundary = phase
		target.fallback.detach()
		target.fallback = coordinator
		target.tick(0, Simulation.RIGHT)
		context.equal(target.has_started, false, "transport callback retires match")
		context.equal(target.failure, "", "transport cancellation is not an unexpected send failure")
		context.equal(target.peer.status().lifecycle, Types.Lifecycle.TERMINATED, "transport cancellation retires driver")
		context.equal(target.game.frame, 0, "canceled transport service cannot start gameplay")
		target.detach()
		fixture.mesh.free()
		fixture.client.free()


func _startup_leave(context: RefCounted) -> void:
	for phase: String in ["control", "route", "getter", "poll", "peers", "start"]:
		var lobby: Lobby = Lobby.new()
		var client: CancelClient = CancelClient.new()
		var mesh: StartupMesh = StartupMesh.new()
		var game: RoomMatch = RoomMatch.new()
		var adapter: StartupAdapter = StartupAdapter.new()
		Engine.get_main_loop().root.add_child(client)
		Engine.get_main_loop().root.add_child(mesh)
		game.owner = weakref(lobby)
		game.leave_on_start = phase == "start"
		adapter.owner = weakref(lobby)
		adapter.armed = phase == "route"
		game.adapter = adapter
		mesh.controller = weakref(lobby)
		mesh.phase = phase
		mesh.transport.owner = weakref(lobby)
		mesh.transport.phase = phase
		lobby.client = client
		lobby.mesh = mesh
		lobby.game_match = game
		lobby.has_readied = true
		lobby.state = "starting"
		lobby._deadline = 100
		lobby.tick(10, 0)
		if phase == "control":
			context.equal(lobby.state, "playing", "uncanceled transport setup publishes playback")
			context.equal(game.starts, 1, "ordinary setup starts transport once")
			lobby.disconnect_room()
		else:
			context.equal(lobby.state, "offline", "startup Leave preserves intentional room exit: " + phase)
			context.equal(lobby.message.begins_with("Left the room."), true, "startup cancellation does not become failure: " + phase)
			context.equal(game.starts, int(phase == "start"), "no setup continues after its owner leaves: " + phase)
			context.equal(lobby._is_busy(), false, "startup cancellation releases controller guard")


func _manual_leave(context: RefCounted) -> void:
	for operation: String in ["leave", "failure"]:
		var helper: RefCounted = Fixture.new()
		var fixtures: Array[Dictionary] = [helper._fixture(context, Fixture.U), helper._fixture(context, Fixture.V)]
		var target: Fixture.Match = fixtures[0].driver
		for turn: int in 20:
			for fixture: Dictionary in fixtures:
				fixture.driver.tick(turn * 16667, Simulation.RIGHT)
			helper._deliver(fixtures)
		var core: RefCounted = target.peer._core
		var frame: int = core.status().current_frame
		context.equal(core.submit_local_input(target.local_slot, frame, PackedByteArray([Simulation.RIGHT])).code, Types.Code.OK, "manual cancellation stages input")
		var batch: Types.Result = core.begin_advance()
		context.equal(batch.code, Types.Code.READY, "manual cancellation retains an open batch")
		var request: Types.Request = batch.batch.next_request()
		var lobby: Lobby = Lobby.new()
		var client: CancelClient = CancelClient.new()
		var mesh: CancelMesh = CancelMesh.new()
		Engine.get_main_loop().root.add_child(client)
		Engine.get_main_loop().root.add_child(mesh)
		lobby.client = client
		lobby.mesh = mesh
		lobby.game_match = target
		lobby.state = "playing"
		if operation == "leave":
			lobby.disconnect_room()
			context.equal(lobby.connect_room("invalid", "player", "", 0), ERR_INVALID_PARAMETER, "retired manual batch does not block fresh-room validation")
		else:
			lobby._fail("original failure")
			lobby.tick(1, 0)
			context.equal(client.polls, 1, "failed-state service completes SDK close despite old manual work")
			context.equal(lobby.message.begins_with("original failure"), true, "manual cancellation preserves failure cause")
			lobby.disconnect_room()
		context.equal(lobby._is_busy(), false, "retired manual owner does not keep lobby busy")
		context.equal(request.writer.status() != 0, true, "Leave expires retained manual writer")
		for fixture: Dictionary in fixtures:
			fixture.driver.detach()
			fixture.mesh.free()
			fixture.client.free()
