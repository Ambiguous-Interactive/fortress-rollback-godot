extends RefCounted

# Value: protects=online service and finish controls preserve callback and expert ownership;
# fails_when=busy service changes clocks, transport or finish state; why_new=peer guards cannot undo outer match mutations; seam=none
const Fixture = preload("res://tests/unit/test_online_example.gd")
const Lobby = preload("res://examples/online/lobby.gd")
const LobbyFixture = preload("res://tests/unit/test_online_lifecycle.gd")
const Match = preload("res://examples/online/match.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


class ReentrantGame:
	extends Simulation
	var owner: WeakRef
	var boundary: int = -1
	var operation: String = ""
	var attempts: int = 0
	var observed: Dictionary = {}
	var fixture: Dictionary = {}

	func attempt(kind: int) -> void:
		if boundary != kind:
			return
		boundary = -1
		attempts += 1
		var target: Match = owner.get_ref()
		var before: Array = [target._last_now, target._tokens, target._held, target.stalls, target.replay_finishing, target.replay_capture_code]
		var result: int = -1
		match operation:
			"tick":
				target.tick(1000000000, Simulation.LEFT)
			"poll":
				result = int(target.poll_protocol_time(1000000000))
			"finish":
				result = target.finish_replay()
			"freeze":
				result = target.freeze(fixture.client, fixture.mesh, PackedStringArray([Fixture.U, Fixture.V]), PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8]))
			"start":
				result = target.start_transport(fixture.client, fixture.mesh, fixture.config, fixture.info, 1000000000)
			"delay":
				result = target.raise_input_delay()
			"suggestion":
				result = target.apply_suggested_delay()
		observed = {
			"before": before,
			"after": [target._last_now, target._tokens, target._held, target.stalls, target.replay_finishing, target.replay_capture_code],
			"failure": target.failure,
			"result": result,
		}

	func save_state(frame: int, writer: RefCounted) -> Driver.SaveResult:
		attempt(Types.Kind.SAVE)
		return super.save_state(frame, writer)

	func load_state(frame: int, reader: RefCounted) -> bool:
		attempt(Types.Kind.LOAD)
		return super.load_state(frame, reader)

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		attempt(Types.Kind.ADVANCE)
		return super.simulate_frame(frame, inputs)


class CancellationClient:
	extends Fixture.Client
	signal new_peer(peer_id: String, you_initiate: bool)
	signal player_reconnected(peer_id: String)


class SetupClient:
	extends CancellationClient
	var target_ref: WeakRef
	var boundary: String
	var cancel: bool
	var attempts: int = 0
	var required_calls: int = 1
	var observed_calls: int = 0
	var nested: int = -1

	func attempt(stage: String) -> void:
		if stage != boundary:
			return
		observed_calls += 1
		if observed_calls < required_calls:
			return
		attempts += 1
		boundary = ""
		var target: Match = target_ref.get_ref()
		if cancel:
			target.detach()
		else:
			nested = target.freeze(self, null, PackedStringArray(), PackedByteArray())

	func get_room_id() -> String:
		attempt("room")
		return Fixture.ROOM

	func get_player_id() -> String:
		attempt("player")
		return local


class SetupAdapter:
	extends Match.Adapter
	var target_ref: WeakRef
	var cancel: bool
	var armed: bool = false
	var nested: int = -1

	func status() -> Dictionary:
		if armed:
			armed = false
			var target: Match = target_ref.get_ref()
			if cancel:
				target.detach()
			else:
				nested = target.start_transport(null, null, null, null, 0)
		return super.status()


class SetupDirect:
	extends Match.Direct
	var callback: Callable
	var owned_before_callback: bool = false

	func configure(mesh: Object, membership: Membership, adapter: Adapter, peer: Peer, options: Options = null) -> int:
		var code: int = super.configure(mesh, membership, adapter, peer, options)
		if code == Code.OK and callback.is_valid():
			owned_before_callback = _mesh != null and _transport != null
			callback.call()
		return code


class SetupRelay:
	extends Match.Relay
	var callback: Callable
	var owned_before_callback: bool = false

	func configure(client: Object, sdk_config: Object, protocol_info: Object, membership: Membership, adapter: Adapter, peer: Peer, options: Options = null) -> int:
		var code: int = super.configure(client, sdk_config, protocol_info, membership, adapter, peer, options)
		if code == Code.OK and callback.is_valid():
			owned_before_callback = _client != null and client.game_data_binary_received.get_connections().size() == 1
			callback.call()
		return code


class SetupFallback:
	extends Match.Fallback
	var callback: Callable
	var owned_before_callback: bool = false

	func configure(direct: Direct, relay: Relay, membership: Membership, adapter: Adapter, peer: Peer, options: Options = null) -> int:
		var code: int = super.configure(direct, relay, membership, adapter, peer, options)
		if code == Code.OK and callback.is_valid():
			owned_before_callback = _direct != null and _relay != null
			callback.call()
		return code


class ReentrantCoordinator:
	extends Fixture.IdleCoordinator
	var actor: ReentrantGame

	func poll(now_us: int, factory: Callable = Callable()) -> Result:
		actor.attempt(Types.Kind.SAVE)
		return super.poll(now_us, factory)


class ReentrantClient:
	extends LobbyFixture.ClosingClient
	var lobby: WeakRef
	var operation: String
	var accepted: int = -1
	var armed: bool = true

	func poll() -> void:
		super.poll()
		if not armed:
			return
		armed = false
		var owner: Lobby = lobby.get_ref()
		match operation:
			"tick":
				owner.tick(1000000000, 0)
			"ready":
				accepted = owner.ready()
			"start":
				accepted = owner.start()
			"connect":
				accepted = owner.connect_room("ws://fixture", "player", "", 1000000000)


func cases() -> PackedStringArray:
	return PackedStringArray(["callback_controls", "notification_controls", "expert_controls", "service_controls", "lobby_controls", "setup_controls", "transport_setup_controls"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "transport_setup_controls":
		_transport_setup_controls(context)
		context.finish()
		return
	if name == "setup_controls":
		_setup_controls(context)
		context.finish()
		return
	if name == "lobby_controls":
		_lobby_controls(context)
		context.finish()
		return
	for operation: String in ["tick", "poll", "finish", "freeze", "start", "delay", "suggestion"]:
		var helper: RefCounted = Fixture.new()
		var fixtures: Array[Dictionary] = [helper._fixture(context, Fixture.U), helper._fixture(context, Fixture.V)]
		var target: Match = fixtures[0].driver
		var game: ReentrantGame = ReentrantGame.new()
		game.owner = weakref(target)
		game.fixture = {"client": fixtures[0].client, "mesh": fixtures[0].mesh, "config": fixtures[0].config, "info": fixtures[0].info}
		game.operation = operation
		target.game = game
		target.record_replay = true
		context.equal(target.peer._driver.configure(target.peer._core, game), Types.Code.OK, "callback game configures before play")
		var now: int = 0
		for turn: int in 20:
			for fixture: Dictionary in fixtures:
				fixture.driver.tick(now, Simulation.RIGHT)
			helper._deliver(fixtures)
			now += 16667
		context.equal(target.peer.network_status().state, "running", "real peers complete startup")
		context.equal(target.failure, "", "control match is healthy")
		if name == "callback_controls":
			game.boundary = Types.Kind.SAVE
			target.tick(now, Simulation.RIGHT)
		elif name == "service_controls":
			var coordinator: ReentrantCoordinator = ReentrantCoordinator.new()
			coordinator.actor = game
			target.fallback.detach()
			target.fallback = coordinator
			game.boundary = Types.Kind.SAVE
			target.tick(now, Simulation.RIGHT)
		elif name == "notification_controls":
			target.peer.step_completed.connect(
				func(_code: int, _before: int, _after: int) -> void:
					game.boundary = Types.Kind.SAVE
					game.attempt(Types.Kind.SAVE),
				CONNECT_ONE_SHOT
			)
			target.tick(now, Simulation.RIGHT)
		else:
			var core: RefCounted = target.peer._core
			var frame: int = core.status().current_frame
			context.equal(core.submit_local_input(target.local_slot, frame, PackedByteArray([Simulation.RIGHT])).code, Types.Code.OK, "expert stages a local sample")
			var opened: Types.Result = core.begin_advance()
			context.equal(opened.code, Types.Code.READY, "expert owns an active batch")
			var request: Types.Request = opened.batch.next_request()
			game.boundary = Types.Kind.SAVE
			game.attempt(Types.Kind.SAVE)
			context.equal(request.writer.status(), 0, "busy service preserves expert writer")
			core.terminate()
		context.equal(game.attempts, 1, "requested ownership boundary actually ran")
		context.equal(game.observed.get("after"), game.observed.get("before"), "busy " + operation + " preserves match state")
		context.equal(game.observed.get("failure"), "", "busy " + operation + " does not stop a healthy match")
		if operation in ["finish", "delay", "suggestion"]:
			context.equal(game.observed.get("result"), Types.Code.BUSY, "control explicitly refuses active game work")
		elif operation in ["freeze", "start"]:
			context.equal(game.observed.get("result"), ERR_BUSY, "setup refuses active game work before accessing SDK arguments")
		if name != "expert_controls":
			helper._deliver(fixtures)
			target.tick(now + 16667, Simulation.RIGHT)
			context.equal(target.failure, "", "ordinary service resumes at the actual clock")
		context.state(target.game.frame, target.game.canonical_bytes())
		for fixture: Dictionary in fixtures:
			fixture.driver.detach()
			fixture.mesh.free()
			fixture.client.free()
	context.finish()


func _lobby_controls(context: RefCounted) -> void:
	for operation: String in ["tick", "ready", "start", "connect"]:
		var lobby: Lobby = Lobby.new()
		var client: ReentrantClient = ReentrantClient.new()
		var mesh: LobbyFixture.ClosingMesh = LobbyFixture.ClosingMesh.new()
		client.lobby = weakref(lobby)
		client.operation = operation
		lobby.client = client
		lobby.mesh = mesh
		lobby.state = "lobby"
		lobby.tick(10, 0)
		context.equal(client.armed, false, "SDK poll exercises nested lobby control")
		context.equal(lobby._last_now, 10, "nested lobby work preserves accepted clock")
		context.equal(client.polls, 1, "SDK service does not recursively poll")
		context.equal(mesh.polls, 1, "mesh service runs once per accepted lobby tick")
		context.equal(lobby.state, "lobby", "busy room control preserves active room")
		context.equal(lobby.has_readied, false, "busy room control does not publish readiness")
		if operation != "tick":
			context.equal(client.accepted, ERR_BUSY, "SDK callback cannot start another room operation")
		lobby.tick(11, 0)
		context.equal(lobby._last_now, 11, "ordinary lobby service resumes at corrected time")
		context.equal(client.polls, 2, "later SDK service remains usable")
		client.free()
		mesh.free()


func _setup_controls(context: RefCounted) -> void:
	for stage: String in ["control", "room", "player", "adapter_room", "adapter_player"]:
		for cancel: bool in [false, true]:
			var target: Match = Match.new()
			var client: SetupClient = SetupClient.new()
			var mesh: Fixture.DirectFixture.FakeMesh = Fixture.DirectFixture.FakeMesh.new()
			client.local = Fixture.U
			client.target_ref = weakref(target)
			client.boundary = stage.trim_prefix("adapter_")
			client.required_calls = 2 if stage.begins_with("adapter_") else 1
			client.cancel = cancel
			var result: Error = target.freeze(client, mesh, PackedStringArray([Fixture.U, Fixture.V]), PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8]))
			if stage == "control":
				context.equal(result, OK, "ordinary initial setup remains supported")
			elif cancel:
				context.equal(result, ERR_UNAVAILABLE, "canceled SDK getter cannot revive setup: " + stage)
				if stage.begins_with("adapter_"):
					context.equal(target.peer._core != null, true, "adapter callback occurs after real peer configuration")
					_assert_detached(context, target, client, mesh, stage)
				else:
					context.equal(target.peer._core == null, true, "canceled getter cannot configure a new live session: " + stage)
					context.equal(target.local_slot, -1, "canceled getter cannot freeze player ownership: " + stage)
			else:
				context.equal(client.nested, ERR_BUSY, "nested freeze refuses SDK callback ownership: " + stage)
				context.equal(result, OK, "refused nested setup preserves the outer setup: " + stage)
			context.equal(target._is_busy(), false, "setup always releases operation ownership")
			target.detach()
			mesh.free()
			client.free()


func _transport_setup_controls(context: RefCounted) -> void:
	_transport_configure_controls(context)
	for cancel: bool in [false, true]:
		var target: Match = Match.new()
		var client: CancellationClient = CancellationClient.new()
		var mesh: Fixture.DirectFixture.FakeMesh = Fixture.DirectFixture.FakeMesh.new()
		var transport: Fixture.MeshFixture.Transport = Fixture.MeshFixture.Transport.new()
		var adapter: SetupAdapter = SetupAdapter.new()
		client.local = Fixture.U
		transport.local = Fixture.U
		mesh.transport = transport
		adapter.target_ref = weakref(target)
		adapter.cancel = cancel
		target.adapter = adapter
		context.equal(
			target.freeze(client, mesh, PackedStringArray([Fixture.U, Fixture.V]), PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8])), OK, "transport test freezes ordinary setup"
		)
		var plan: Fixture.MembershipFixture.Plan = Fixture.MembershipFixture.Plan.new()
		plan.data.peers = [{"player_id": Fixture.V, "initiate": true}]
		client.session_plan.emit(plan)
		var config: Fixture.RelayFixture.SDKConfig = Fixture.RelayFixture.SDKConfig.new()
		config.max_buffered_bytes = 4096
		config.max_outbound_frame_bytes = 4096
		var info: Fixture.RelayFixture.Info = Fixture.RelayFixture.Info.new()
		adapter.armed = true
		var result: Error = target.start_transport(client, mesh, config, info, 0)
		context.equal(adapter.armed, false, "transport setup crosses actual adapter status callback")
		if cancel:
			context.equal(result, ERR_UNAVAILABLE, "canceled transport setup refuses completion")
			_assert_detached(context, target, client, mesh, "adapter_status")
		else:
			context.equal(result, OK, "refused nested transport setup preserves ordinary startup")
			context.equal(adapter.nested, ERR_BUSY, "transport setup owns callbacks until completion")
			context.equal(target.has_started, true, "ordinary startup still publishes started match")
		context.equal(target._is_busy(), false, "transport setup releases operation ownership")
		target.detach()
		mesh.free()
		client.free()


func _assert_detached(context: RefCounted, target: Match, client: Object, mesh: Object, stage: String) -> void:
	context.equal(target.has_started, false, "canceled setup cannot publish started state: " + stage)
	context.equal(target.peer.status().lifecycle, Types.Lifecycle.TERMINATED, "canceled setup retires configured peer: " + stage)
	context.equal(mesh.attached, false, "canceled setup releases mesh: " + stage)
	for signal_name: String in ["new_peer", "player_reconnected"]:
		context.equal(client.has_signal(signal_name), true, "cancellation fixture exposes optional listener: " + signal_name)
	for signal_name: String in Match.Adapter.LIFETIME_SIGNALS + ["session_plan", "game_data_binary_received", "new_peer", "player_reconnected"]:
		if client.has_signal(signal_name):
			context.equal(client.get_signal_connection_list(signal_name).size(), 0, "canceled setup releases listener: " + stage + "/" + signal_name)
	context.equal(target.direct._mesh == null, true, "canceled setup releases direct ownership: " + stage)
	context.equal(target.relay._client == null, true, "canceled setup releases relay ownership: " + stage)
	context.equal(target.fallback._relay == null, true, "canceled setup releases fallback ownership: " + stage)


func _transport_configure_controls(context: RefCounted) -> void:
	for stage: String in ["control", "direct", "relay", "fallback"]:
		var target: Match = Match.new()
		var client: CancellationClient = CancellationClient.new()
		var mesh: Fixture.DirectFixture.FakeMesh = Fixture.DirectFixture.FakeMesh.new()
		var transport: Fixture.MeshFixture.Transport = Fixture.MeshFixture.Transport.new()
		var direct: SetupDirect = SetupDirect.new()
		var relay: SetupRelay = SetupRelay.new()
		var fallback: SetupFallback = SetupFallback.new()
		target.direct = direct
		target.relay = relay
		target.fallback = fallback
		client.local = Fixture.U
		transport.local = Fixture.U
		mesh.transport = transport
		context.equal(target.freeze(client, mesh, PackedStringArray([Fixture.U, Fixture.V]), PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8])), OK, "configure callback fixture freezes")
		var plan: Fixture.MembershipFixture.Plan = Fixture.MembershipFixture.Plan.new()
		plan.data.peers = [{"player_id": Fixture.V, "initiate": true}]
		client.session_plan.emit(plan)
		var config: Fixture.RelayFixture.SDKConfig = Fixture.RelayFixture.SDKConfig.new()
		config.max_buffered_bytes = 4096
		config.max_outbound_frame_bytes = 4096
		var info: Fixture.RelayFixture.Info = Fixture.RelayFixture.Info.new()
		if stage != "control":
			target.get(stage).callback = target.detach
		var result: Error = target.start_transport(client, mesh, config, info, 0)
		if stage == "control":
			context.equal(result, OK, "ordinary composed transport setup succeeds")
			context.equal(target.has_started, true, "ordinary composed setup publishes running state")
		else:
			context.equal(target.get(stage).owned_before_callback, true, "callback occurs after actual transport ownership: " + stage)
			context.equal(result, ERR_UNAVAILABLE, "configure callback cancels composed startup: " + stage)
			_assert_detached(context, target, client, mesh, stage)
		context.equal(target._is_busy(), false, "composed transport callback releases match guard")
		direct.callback = Callable()
		relay.callback = Callable()
		fallback.callback = Callable()
		target.detach()
		mesh.free()
		client.free()
