extends RefCounted

# Value: protects=online room identity, retained input and teardown; fails_when=room restarts alias or stalled input is resampled; seam=SDK public transport doubles
const Scene = preload("res://examples/online/online.tscn")
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
const Bridge = preload("res://scripts/reference/browser/online_bridge.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const U: String = MembershipFixture.U
const V: String = MembershipFixture.V
const ROOM: String = "10000000-0000-0000-0000-000000000001"


class SceneClient:
	extends Node
	func get_room_code() -> String:
		return "ROOM01"
	func get_players() -> Array:
		return []


class ObservedGame:
	extends Simulation
	var samples: Dictionary = {}
	func simulate_frame(input_frame: int, inputs: Types.FrameInputs) -> bool:
		if not super.simulate_frame(input_frame, inputs):
			return false
		samples[input_frame] = PackedInt32Array([inputs.read(0).bytes[0], inputs.read(1).bytes[0]])
		return true


class CallbackGame:
	extends Bridge.ObservedGame
	var core_ref: WeakRef
	var callback_visible: int = -1
	func save_state(saved_frame: int, writer: Bridge.Writer) -> Driver.SaveResult:
		var result: Driver.SaveResult = super.save_state(saved_frame, writer)
		callback_visible = Bridge.confirmed_snapshots(core_ref.get_ref(), saves).size()
		return result


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


class IdleCoordinator:
	extends Fallback
	var polls: int = 0
	func enqueue_batch(_packets: Array[Peer.Packet]) -> int:
		return Code.OK
	func poll(_now_us: int, _factory: Callable = Callable()) -> Result:
		polls += 1
		return Result.new(Code.OK)


class BusyCoordinator:
	extends Fallback
	var polls: int = 0
	func enqueue_batch(_packets: Array[Peer.Packet]) -> int:
		return Code.OK
	func poll(_now_us: int, _factory: Callable = Callable()) -> Result:
		polls += 1
		return Result.new(Code.OK)
	# A route with queued work never reports itself idle.
	func idle() -> bool:
		return false


class Client:
	extends MeshFixture.Client
	func get_room_id() -> String:
		return ROOM


func cases() -> PackedStringArray:
	return PackedStringArray(["identity", "optional_scene", "live_driver", "retained_batch", "idle_batch", "terminal_callbacks", "handshake_timeout",
		"observer_history", "viewer_lifetime", "scheduling_gaps", "delay_actions"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"delay_actions":
			_delay_actions(context)
		"viewer_lifetime":
			_viewer_lifetime(context)
		"observer_history":
			_observer_history(context)
		"identity":
			var identity: PackedByteArray = Match.session_identity(ROOM, PackedStringArray([U, V]))
			context.equal(identity.size(), 16, "domain separated application match identity")
			context.equal(identity, Match.session_identity(ROOM, PackedStringArray([V, U])), "roster order independent")
			context.equal(identity != Match.session_identity(V, PackedStringArray([U, V])), true, "new room has fresh identity")
			for roster: PackedStringArray in [PackedStringArray([U]), PackedStringArray([U, U]), PackedStringArray([U, "bad"])]:
				context.equal(Match.session_identity(ROOM, roster).is_empty(), true, "invalid room membership refused")
		"optional_scene":
			var node: Node = Scene.instantiate()
			node.call("_ready")
			var lobby: Lobby = node.get("controller")
			context.equal(lobby.ready(), ERR_UNAVAILABLE, "ready before joining is refused")
			context.equal(lobby.start(), ERR_UNAVAILABLE, "start before joining is refused")
			context.equal(lobby.connect_room("https://wrong", "Player", "", 0), ERR_INVALID_PARAMETER, "non websocket URL refused")
			if not ResourceLoader.exists(Lobby.SDK_PATH):
				context.equal(lobby.connect_room("ws://localhost:8080/ws", "Player", "", 0), ERR_UNAVAILABLE, "missing SDK is actionable without parse failure")
			lobby.disconnect_room()
			context.equal(lobby.state, "offline", "leave available after missing SDK")
			_recording_warning(context, node)
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
		"idle_batch":
			_idle_batch(context)
		"live_driver":
			_live_driver(context)
		"scheduling_gaps":
			_scheduling_gaps(context)
	context.finish()


func _fixture(context: RefCounted, uuid: String, configured_peer: Peer = null) -> Dictionary:
	var client: Client = Client.new()
	client.local = uuid
	var mesh: DirectFixture.FakeMesh = DirectFixture.FakeMesh.new()
	var transport: MeshFixture.Transport = MeshFixture.Transport.new()
	transport.local = uuid
	mesh.transport = transport
	var game_match: Match = Match.new()
	if configured_peer != null:
		game_match.peer = configured_peer
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
	var raised_at: int = fixtures[0].driver.peer.status().confirmed_frame
	context.equal(fixtures[0].driver.raise_input_delay(), Match.Types.Code.OK, "player raises input delay mid-match")
	for _round: int in 60:
		_deliver(fixtures)
		for fixture: Dictionary in fixtures:
			fixture.driver.tick(now, Simulation.LEFT)
			context.equal(fixture.driver.failure, "", "raised delay keeps both players running")
		now += 16667
	context.equal(fixtures[0].driver.peer.input_delay(fixtures[0].driver.local_slot), 3, "raised delay is in effect")
	context.equal(fixtures[1].driver.peer.status().confirmed_frame > raised_at + 30, true, "the other player confirms past the change")
	var suggested: Match = fixtures[0].driver
	context.equal(suggested.apply_suggested_delay(), Match.Types.Code.INVALID_CONFIGURATION, "nothing to apply without a suggestion")
	suggested.suggested_delay = 4
	suggested.suggested_frame = suggested.peer.status().current_frame
	context.equal(suggested.apply_suggested_delay(), Match.Types.Code.OK, "player applies a suggested delay")
	context.equal([suggested.peer.input_delay(suggested.local_slot), suggested.suggested_delay], [4, -1], "applied suggestion is in effect and cleared")
	suggested.suggested_delay = 3
	_deliver(fixtures)
	suggested.tick(now, Simulation.LEFT)
	context.equal(suggested.suggested_delay, -1, "a suggestion the current delay already covers is dropped")
	for age: int in [Match.SUGGESTION_FRAMES - 1, Match.SUGGESTION_FRAMES + 1]:
		suggested.suggested_delay = 5
		suggested.suggested_frame = suggested.peer.status().current_frame - age
		_deliver(fixtures)
		suggested.tick(now, Simulation.LEFT)
		context.equal(suggested.suggested_delay, 5 if age < Match.SUGGESTION_FRAMES else -1, "a suggestion expires after %d frames" % Match.SUGGESTION_FRAMES)
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


# Value: protects=published host scheduling gaps; fails_when=a stalled turn is invisible or an idle schedule reports one;
# why_new=#125 and #132 cannot separate a starved host from lost transport; seam=actual observer clock
func _scheduling_gaps(context: RefCounted) -> void:
	# A known schedule: ten service turns on an injected clock, one frame in flight.
	var steady: Bridge.Scheduling = Bridge.Scheduling.new()
	var now: int = 1000
	for turn: int in 10:
		steady.record_turn(now, now - 500, turn + 1, turn)
		now += 16667
	var summary: Dictionary = steady.summary()
	context.equal(summary["turns"], 10, "every service turn is counted")
	context.equal(summary["max_gap_us"], 16667, "the largest pause is the longest turn gap")
	context.equal(summary["max_gap_turns"], 1, "one nominal tick covers the pause")
	context.equal(summary["max_gap_transport_us"], 16667, "the pause covers the same transport time")
	context.equal(summary["confirmed_frames"], 10, "every confirmed frame is counted")
	context.equal(summary["confirmation_max_gap_us"], 16667, "a confirmed frame reports one turn of waiting")
	# The same schedule on a different injected clock reports a different summary.
	var slower: Bridge.Scheduling = Bridge.Scheduling.new()
	now = 1000
	for turn: int in 10:
		slower.record_turn(now, now - 500, turn + 1, turn)
		now += 33334
	context.equal(slower.summary()["max_gap_us"], 33334, "a slower clock reports a longer pause")
	context.equal(slower.summary()["max_gap_turns"], 2, "the slower pause covers two nominal ticks")
	context.equal(slower.summary()["confirmation_max_gap_us"], 33334, "the slower clock waits longer for confirmation")
	# A stalled turn is visible in the summary.
	var stalled: Bridge.Scheduling = Bridge.Scheduling.new()
	stalled.record_turn(0, 0, 1, 0)
	stalled.record_turn(500000, 500000, 1, 1)
	context.equal(stalled.summary()["max_gap_us"], 500000, "a stalled turn is visible")
	context.equal(stalled.summary()["max_gap_turns"], 30, "the stall covers thirty nominal ticks")
	context.equal(stalled.summary()["confirmation_max_gap_us"], 500000, "the stalled turn also delays confirmation")
	# A control that omits the stall reports no stall.
	var uninterrupted: Bridge.Scheduling = Bridge.Scheduling.new()
	uninterrupted.record_turn(0, 0, 1, 0)
	uninterrupted.record_turn(16667, 16667, 1, 1)
	context.equal(uninterrupted.summary()["max_gap_us"], 16667, "an uninterrupted schedule reports only its own pause")
	context.equal(uninterrupted.summary()["max_gap_turns"], 1, "an uninterrupted schedule claims no stall")
	# A backwards clock is the lobby's failure, not a gap.
	var backwards: Bridge.Scheduling = Bridge.Scheduling.new()
	backwards.record_turn(1000, 1000, 1, 0)
	backwards.record_turn(500, 500, 1, 0)
	context.equal(backwards.summary()["turns"], 1, "a backwards clock is ignored")
	# A turn before the match runs stamps no frame, so setup time is not a confirmation wait.
	var setup: Bridge.Scheduling = Bridge.Scheduling.new()
	setup.record_turn(0, 0, 1, 0, false)
	setup.record_turn(5000000, 5000000, 1, 0, false)
	setup.record_turn(5100000, 5100000, 1, 0, true)
	setup.record_turn(5200000, 5200000, 1, 1, true)
	context.equal(setup.summary()["confirmed_frames"], 2, "only running frames are counted")
	context.equal(setup.summary()["confirmation_max_gap_us"], 100000, "setup time is not a confirmation wait")
	# A running session starts with no confirmed frame: the frames it submits are stamped
	# anyway, so the first confirmation still reports the wait.
	var initial: Bridge.Scheduling = Bridge.Scheduling.new()
	initial.record_turn(0, 0, 1, -1, true)
	initial.record_turn(16667, 16667, 2, 0, true)
	context.equal(initial.summary()["confirmation_max_gap_us"], 16667, "the first confirmation reports its wait")
	context.equal(initial.summary()["confirmed_frames"], 1, "the first confirmation is counted")
	# A single turn has no gap, and the summary still names one nominal turn.
	var single: Bridge.Scheduling = Bridge.Scheduling.new()
	single.record_turn(1000, 1000, 1, 0)
	context.equal(single.summary()["turns"], 1, "a single turn is counted")
	context.equal(single.summary()["max_gap_us"], 0, "a single turn has no gap")
	context.equal(single.summary()["max_gap_turns"], 1, "a single turn names one nominal turn")
	context.equal(single.summary()["confirmation_max_gap_turns"], 1, "an unconfirmed frame names one nominal turn")
	# A new room restarts the transport clock, so the covered time never goes backwards.
	var restarted_clock: Bridge.Scheduling = Bridge.Scheduling.new()
	restarted_clock.record_turn(0, 500000, 1, 0)
	restarted_clock.record_turn(16667, -1, 1, 1)
	context.equal(restarted_clock.summary()["max_gap_transport_us"] >= 0, true, "a restarted transport clock never reports negative time")
	# A new room restarts the summary.
	var restarted: Bridge.Scheduling = Bridge.Scheduling.new()
	restarted.record_turn(0, 0, 1, 0)
	restarted.record_turn(16667, 16667, 1, 1)
	restarted.reset()
	context.equal(restarted.summary()["turns"], 0, "a new room restarts the turn count")
	context.equal(restarted.summary()["confirmed_frames"], 0, "a new room restarts the confirmed frames")
	restarted.record_turn(0, 0, 1, 0)
	context.equal(restarted.summary()["turns"], 1, "the restarted summary counts the new room")
# Value: protects=idle service batches; fails_when=an idle route repeats the whole bounded batch; why_new=the retained case only covers refusal; seam=actual example tick
func _idle_batch(context: RefCounted) -> void:
	var fixture: Dictionary = _fixture(context, U)
	var game_match: Match = fixture.driver
	var coordinator: IdleCoordinator = IdleCoordinator.new()
	game_match.fallback.detach()
	game_match.fallback = coordinator
	game_match.tick(0, Simulation.RIGHT)
	context.equal(coordinator.polls, 1, "an idle route stops the service batch after one poll")
	context.equal(game_match.failure, "", "an idle route does not terminate the match")
	game_match.tick(1, Simulation.LEFT)
	context.equal(coordinator.polls, 2, "every tick still services the transport once")
	var busy: BusyCoordinator = BusyCoordinator.new()
	game_match.fallback = busy
	game_match.tick(2, Simulation.RIGHT)
	context.equal(busy.polls, 8, "a route with queued work keeps the whole bounded batch")
	game_match.detach()
	fixture.mesh.free()
	fixture.client.free()


# Value: protects=confirmed callback history; fails_when=render gaps evict evidence; why_new=browser load depends on host cadence; seam=actual session/driver
func _observer_history(context: RefCounted) -> void:
	var rejected: Bridge.ObservedGame = Bridge.ObservedGame.new()
	var predicted_inputs: Types.FrameInputs = Types.FrameInputs.new([PackedByteArray([2]), PackedByteArray([0])],
		PackedInt32Array([Bridge.Queue.Status.CONFIRMED, Bridge.Queue.Status.PREDICTED]))
	context.equal(rejected.simulate_frame(2, predicted_inputs), false, "an invalid callback cannot prove prediction")
	context.equal(rejected.predicted_frame, -1, "failed simulation leaves the prediction barrier closed")
	var config: Config = Config.new()
	config.sync_test = false
	config.check_distance = 0
	config.max_snapshot_bytes = Simulation.SNAPSHOT_BYTES
	config.storage_budget_bytes = config.required_storage_bytes()
	var core: Session = Session.new()
	context.equal(core.configure(config), Types.Code.OK, "bounded production snapshot ring")
	var game: CallbackGame = CallbackGame.new()
	game.core_ref = weakref(core)
	var driver: Driver = Driver.new(core, game)
	# One render observation follows one hundred completed physical ticks.
	for frame: int in 100:
		var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, frame, PackedByteArray([2])), Driver.LocalInput.new(1, frame, PackedByteArray([4]))]
		context.equal(driver.step(frame, samples).code, Types.Code.OK, "real driver advances without rendering")
	context.equal(core.confirmed_checksums().size(), 8, "real core has evicted earlier corrected callback boundaries")
	context.equal(game.saves.size(), 100, "observer owns every real save callback")
	context.equal(game.callback_visible, 0, "active real callback hides owned history")
	context.equal(Bridge.confirmed_snapshots(core, game.saves).size(), 99, "render cadence cannot erase confirmed callback evidence")
	context.state(100, game.canonical_bytes())
	context.equal(game.predicted_frame, -1, "confirmed input callbacks never claim prediction")
	config.local_players = PackedInt32Array([0])
	core = Session.new()
	context.equal(core.configure(config), Types.Code.OK, "external inputs for actual pending correction")
	game = CallbackGame.new()
	game.core_ref = weakref(core)
	driver = Driver.new(core, game)
	for frame: int in 4:
		context.equal(driver.step(frame, [Driver.LocalInput.new(0, frame, PackedByteArray([2]))]).code, Types.Code.OK, "predict remote original input")
	context.equal(game.predicted_frame, 2, "actual successful frame-two prediction opens the witness barrier")
	var predicted: String = game.saves[3]
	for frame: int in 5:
		context.equal(core.receive_input(1, frame, PackedByteArray([4])).code, Types.Code.OK, "actual remote original causes earliest correction")
	context.equal(core.status().pending_rollback_frame, 0, "actual first predicted frame requires repair")
	context.equal(Bridge.confirmed_snapshots(core, game.saves).keys(), ["0"], "hide owned but uncorrected snapshots after receipt")
	context.equal(driver.step(5, [Driver.LocalInput.new(0, 4, PackedByteArray([2]))]).code, Types.Code.OK, "actual driver repairs predicted callbacks")
	context.equal(game.restores, 1, "actual rollback load executed")
	context.equal(game.saves[3] != predicted, true, "resimulation overwrites speculative snapshot bytes")
	context.equal(Bridge.confirmed_snapshots(core, game.saves)["3"], game.saves[3], "only repaired canonical prefix becomes visible")
	context.equal(core.submit_local_input(0, 5, PackedByteArray([2])).code, Types.Code.OK, "prepare active expert batch")
	context.equal(core.begin_advance().code, Types.Code.READY, "open ordered request batch")
	context.equal(Bridge.confirmed_snapshots(core, game.saves).is_empty(), true, "open batch hides callback-owned history")
	core.terminate()
	context.equal(Bridge.confirmed_snapshots(core, game.saves).is_empty(), true, "terminal core cannot publish fresh evidence")
	config.local_players = PackedInt32Array([0, 1])
	config.checksums_enabled = false
	core = Session.new()
	context.equal(core.configure(config), Types.Code.OK, "checksums-disabled configuration remains valid")
	game = CallbackGame.new()
	game.core_ref = weakref(core)
	driver = Driver.new(core, game)
	for frame: int in 4:
		var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, frame, PackedByteArray([2])), Driver.LocalInput.new(1, frame, PackedByteArray([4]))]
		context.equal(driver.step(frame, samples).code, Types.Code.OK, "actual callbacks without public checksum evidence")
	context.equal(game.saves.size(), 4, "actual callback bytes exist with checksums disabled")
	context.equal(Bridge.confirmed_snapshots(core, game.saves).is_empty(), true, "disabled checksum domain cannot publish evidence")


func _viewer_lifetime(context: RefCounted) -> void:
	var node: Node = Scene.instantiate()
	node.call("_ready")
	var inspector: Button
	for button: Node in node.find_children("*", "Button", true, false):
		if button is Button and button.text == "Inspect diagnostic file":
			inspector = button
	context.equal(inspector.disabled, false, "inspection available offline")
	var client: SceneClient = SceneClient.new()
	var lobby: Lobby = node.get("controller")
	lobby.client = client
	for state: String in ["lobby", "playing", "failed"]:
		lobby.state = state
		node.call("_update_status")
		context.equal(node.get("watch_button").disabled, true, "existing replay control preserves connected room")
		context.equal(inspector.disabled, true, "diagnostic control preserves connected room")
	lobby.client = null
	lobby.state = "offline"
	node.call("_update_status")
	context.equal(inspector.disabled, false, "inspection available after leaving")
	client.free()
	node.free()


# Value: protects=recording limits warn before final-state capture becomes unavailable;
# fails_when=only finalized rows trigger the warning or no advance warning exists; why_new=scene coverage checks omitted rows only; seam=none
func _recording_warning(context: RefCounted, node: Node) -> void:
	var near: String = "Replay limit in 300 simulated frames. Press Finish replay now to include the final state."
	var full: String = "Replay recording limit reached. Press Finish replay now to include the final state."
	var omitted: String = "Replay recording limit passed. Later gameplay and its final state are outside the recording."
	var rows: Array[Dictionary] = [
		{"capacity": 304, "frames": 3, "deliver": true, "warning": "", "label": "before warning threshold"},
		{"capacity": 304, "frames": 4, "deliver": true, "warning": near, "label": "five-second warning threshold"},
		{"capacity": 3, "frames": 3, "deliver": false, "warning": full, "label": "pending inputs fill the cap"},
		{"capacity": 3, "frames": 3, "deliver": true, "warning": full, "label": "finalized inputs fill the cap"},
		{"capacity": 3, "frames": 4, "deliver": true, "warning": omitted, "label": "gameplay exceeds the cap"},
		{"capacity": 0, "frames": 4, "deliver": true, "warning": "", "label": "recording disabled"},
		{"capacity": 3, "frames": 3, "deliver": true, "warning": "", "finishing": true, "label": "finishing already stops gameplay"},
		{"capacity": 3, "frames": 3, "deliver": false, "warning": "", "state": "offline", "label": "Leave suppresses unavailable finish action"},
		{"capacity": 3, "frames": 3, "deliver": true, "warning": "", "state": "failed", "label": "failure suppresses unavailable finish action"},
		{"capacity": 3, "frames": 4, "deliver": true, "warning": omitted, "state": "offline", "label": "Leave retains omitted disclosure"},
		{"capacity": 3, "frames": 4, "deliver": true, "warning": omitted, "state": "failed", "label": "failure retains omitted disclosure"},
		{"capacity": 3, "frames": 3, "deliver": true, "warning": "", "state": "playing", "label": "detached match rejects stale playing state"},
		{"capacity": 3, "frames": 3, "deliver": true, "warning": "", "failure": "Disconnected.", "label": "match failure rejects finish before lobby cleanup"},
	]
	for row: Dictionary in rows:
		var recorded: Dictionary = _fixture(context, U)
		var game_match: Match = recorded.driver
		game_match.record_replay = row.capacity > 0
		var config: Config = Config.new()
		config.sync_test = false
		config.check_distance = 0
		config.replay_max_frames = row.capacity
		config.local_players = PackedInt32Array([0])
		config.max_snapshot_bytes = Simulation.SNAPSHOT_BYTES
		config.storage_budget_bytes = config.required_storage_bytes()
		var core: Session = game_match.peer._core
		context.equal(core.configure(config), Types.Code.OK, "scene recording control configures")
		var driver: Driver = Driver.new(core, Simulation.new())
		node.controller.game_match = game_match
		node.controller.state = "playing"
		game_match.replay_finishing = row.get("finishing", false)
		for frame: int in row.frames:
			if row.deliver:
				context.equal(core.receive_input(1, frame, PackedByteArray([0])).code, Types.Code.OK, "receive scene recording input")
			context.equal(driver.step(frame, [Driver.LocalInput.new(0, frame, PackedByteArray([0]))]).code, Types.Code.OK, "scene gameplay reaches declared recording boundary")
		var detached: bool = row.has("state")
		if detached:
			game_match.detach()
			node.controller.state = row.state
		game_match.failure = row.get("failure", "")
		node.call("_update_status")
		var unavailable: bool = detached or row.capacity == 0 or row.get("finishing", false) or not game_match.failure.is_empty()
		context.equal(node.finish_replay_button.disabled, unavailable, "finish button agrees with actual match lifetime")
		if row.warning.is_empty():
			context.equal(node._status.text.contains("Replay limit in") or node._status.text.contains("Replay recording limit"), false, row.label)
		else:
			context.equal(node._status.text.contains(row.warning), true, row.label)
		if not row.deliver:
			context.equal(core.recording_status().pending_frames, 3, "pending-at-cap control uses actual unconfirmed gameplay")
		if row.capacity == 3 and row.frames == 4:
			context.equal(node._status.text.contains("Replay: 3/3 frames recorded | 0 pending | 1 later frames omitted"), true, "omitted count remains visible")
		var capture: int = Types.Code.UNSUPPORTED if row.capacity == 0 else Types.Code.OK
		if row.capacity > 0 and row.frames > row.capacity:
			capture = Types.Code.HISTORY_UNAVAILABLE
		elif not row.deliver:
			capture = Types.Code.PREDICTION_STALL
		if detached:
			capture = Types.Code.TERMINATED
		context.equal(driver.capture_replay_boundary().code, capture, "warning matches actual final-boundary capture availability")
		game_match.detach()
		recorded.mesh.free()
		recorded.client.free()


# Value: protects=delay prompts and keys share live readiness; fails_when=retained observations enable stale actions;
# why_new=live_driver checks match operations without scene feedback; seam=actual scene handlers and packet fixtures
func _delay_actions(context: RefCounted) -> void:
	for phase: String in ["live", "leave", "transport_failure", "match_failure", "finishing", "fresh_room", "stale_suggestion"]:
		var fixtures: Array[Dictionary] = [_fixture(context, U), _fixture(context, V)]
		for round_index: int in 100:
			for fixture: Dictionary in fixtures:
				fixture.driver.tick(round_index * 16667, 0)
			_deliver(fixtures)
		var node: Node = Scene.instantiate()
		node.call("_ready")
		var lobby: Lobby = node.controller
		var game_match: Match = fixtures[0].driver
		lobby.game_match = game_match
		lobby.state = "playing"
		lobby.message = "Keep the connection message."
		game_match.suggested_delay = 4
		game_match.suggested_frame = game_match.peer.status().current_frame
		context.equal(game_match.peer.network_status().state, "running", "delay control has actual synchronized peers")
		match phase:
			"leave":
				node.call("_leave")
			"transport_failure":
				lobby._on_protocol_error("connection lost")
			"match_failure":
				game_match.failure = "Transport stopped. Leave and create a new room."
				lobby.message = game_match.failure
			"finishing":
				game_match.record_replay = true
				context.equal(game_match.finish_replay(), Types.Code.OK, "actual finish stops new gameplay")
			"fresh_room":
				node.call("_leave")
				_fresh_room(context, node, game_match)
			"stale_suggestion":
				game_match.suggested_delay = 2
				game_match.tick(100 * 16667, 0)
		var actionable: bool = phase in ["live", "stale_suggestion"]
		node.call("_update_status")
		context.equal(node._status.text.contains("= raises"), actionable, phase + " manual prompt readiness")
		context.equal(node._status.text.contains("R applies"), phase == "live", phase + " suggestion prompt readiness")
		if phase != "fresh_room":
			context.equal(node._status.text.contains("You: player"), true, phase + " retained observations remain visible")
		var old_message: String = lobby.message
		var old_delay: int = game_match.peer.input_delay(game_match.local_slot)
		for key: Key in [KEY_R, KEY_EQUAL, KEY_KP_ADD]:
			var event: InputEventKey = InputEventKey.new()
			event.keycode = key
			event.pressed = true
			node.call("_unhandled_key_input", event)
			if not actionable:
				context.equal(lobby.message, old_message, phase + " rejected key preserves recovery message")
		if phase == "live":
			context.equal(game_match.peer.input_delay(game_match.local_slot), 6, "live suggestion and both raise keys work")
		elif phase == "stale_suggestion":
			context.equal(game_match.peer.input_delay(game_match.local_slot), old_delay + 2, "stale suggestion does not block manual raise")
		else:
			context.equal(game_match.peer.input_delay(game_match.local_slot), old_delay, phase + " stale keys preserve delay")
		node.free()
		lobby.disconnect_room()
		for fixture: Dictionary in fixtures:
			fixture.driver.detach()
			fixture.mesh.free()
			fixture.client.free()


# SDK resource doubles exercise the real Create/Join boundary without installing the optional SDK.
func _fresh_room(context: RefCounted, node: Node, previous: Match) -> void:
	var client: String = "extends Node\n"
	for signal_name: String in ["protocol_info", "room_joined", "lobby_state_changed", "protocol_error", "connection_failed", "authentication_error",
		"room_join_failed", "server_error", "reconnection_failed", "disconnected", "going_away", "room_left", "reconnected"]:
		client += "signal " + signal_name + "\n"
	client += "func set_auto_reconnect(_enabled: bool) -> void: pass\nfunc configure(_config: Object) -> Error: return OK\n"
	client += "func connect_to_server() -> Error: return OK\nfunc close(_code: int, _reason: String) -> Error: return OK\n"
	client += "func get_room_code() -> String: return \"\"\nfunc get_players() -> Array: return []\n"
	var config: String = "extends RefCounted\n"
	for property: String in ["app_id", "endpoint_url", "protocol_version", "supported_transports", "supported_topologies", "game_data_format",
		"decode_msgpack_payloads", "auto_poll"]:
		config += "var " + property + "\n"
	var sources: Array[String] = [client, config, "extends Node\nvar multiplayer_peer_factory: Callable\nvar peer_connection_factory: Callable\n"]
	var paths: Array[String] = [Lobby.SDK_PATH, Lobby.CONFIG_PATH, Lobby.MESH_PATH]
	var originals: Array[Resource] = []
	var doubles: Array[GDScript] = []
	for index: int in paths.size():
		originals.append(load(paths[index]) if ResourceLoader.exists(paths[index]) else null)
		var script: GDScript = GDScript.new()
		script.source_code = sources[index]
		context.equal(script.reload(), OK, "SDK resource double compiles")
		script.take_over_path(paths[index])
		doubles.append(script)
	for join_room: bool in [false, true]:
		node.endpoint.text = "ws://fixture"
		node.player_name.text = "Player"
		node.room_code.text = "ROOM01" if join_room else ""
		var old_match: Match = node.controller.game_match
		old_match.suggested_delay = 5
		var button: Button = node.join_button if join_room else node.create_button
		button.pressed.emit()
		var replacement: Match = node.controller.game_match
		context.equal(node.controller.state, "connecting", "production room connection starts")
		context.equal(replacement != old_match and replacement != previous, true, "production room connection replaces the match")
		context.equal(replacement.suggested_delay, -1, "production replacement discards stale recommendation")
		context.equal(replacement.local_slot, -1, "new room has no seated player before startup")
		context.equal(node._status.text.contains("= raises") or node._status.text.contains("R applies"), false, "fresh room has no delay actions")
		if not join_room:
			node.call("_leave")
	for index: int in paths.size():
		doubles[index].take_over_path("")
		if originals[index] != null:
			originals[index].take_over_path(paths[index])
