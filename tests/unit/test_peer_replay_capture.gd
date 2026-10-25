extends RefCounted

# Value: protects=peer final-state capture through encoded sessions; fails_when=the peer polls or bypasses callback guards;
# why_new=driver capture does not own endpoint state; seam=none
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Fixture = preload("res://tests/unit/test_peer_session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const L = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")
const Game = preload("res://tests/oracle/p2p_game.gd")
const SnapshotStatus = preload("res://addons/fortress_rollback/core/snapshot_status.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")


class CaptureGame:
	extends Game
	var peer_ref: WeakRef
	var action: String = "guard"
	var observations: PackedInt32Array = PackedInt32Array()
	var writer_view: RefCounted

	func save_state(frame: int, writer: RefCounted) -> Driver.SaveResult:
		writer_view = writer
		var saved: Driver.SaveResult = super.save_state(frame, writer)
		var peer: Peer = peer_ref.get_ref()
		if action == "guard":
			observations.append(peer.capture_replay_boundary().code)
			observations.append(peer.recover(1).code)
			observations.append(peer.poll(1))
			observations.append(peer.close(1))
			observations.append(peer._core.begin_capture_replay_boundary().code)
		elif action == "fail":
			saved.ok = false
		elif action == "cancel":
			peer._driver.terminate()
		return saved


class LastInputDiverges:
	extends Game

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		var ok: bool = super.simulate_frame(frame, inputs)
		if frame == 2:
			game.accumulators[0] += 1
		return ok


func cases() -> PackedStringArray:
	return PackedStringArray(["capture_final", "capture_guards", "capture_callbacks", "capture_cap"])


func run_case(name: String, context: RefCounted) -> void:
	context.equal(Peer.new().has_method("capture_replay_boundary"), true, "public peer capture exists")
	if Peer.new().has_method("capture_replay_boundary"):
		call("_" + name, context)
	context.finish()


# Value: protects=peer final SAVE preserves wire state and reports callback failure; fails_when=wrapper polls or publishes during capture;
# why_new=driver terminal cases do not exercise encoded peer ownership; seam=none
func _capture_final(context: RefCounted) -> void:
	var fixture: RefCounted = Fixture.new()
	var mesh: Dictionary = fixture._build(context, 2, 0, false, 128, true, false, 8, null, 60, 0, null, 128, 4)
	for frame: int in range(3):
		mesh.now += 1000
		fixture._tick(context, mesh)
	fixture._deliver(context, mesh, fixture._drain(mesh))
	fixture._deliver(context, mesh, fixture._drain(mesh))
	for _iteration: int in 4:
		for peer: Peer in mesh.peers:
			context.equal(peer.recover(mesh.now + 1).code, Types.Code.OK, "recover finalized prefix")
		fixture._deliver(context, mesh, fixture._drain(mesh))
	for index: int in 2:
		var peer: Peer = mesh.peers[index]
		var before: Dictionary = peer.network_status()
		mesh.games[index].requests.clear()
		var notices: Array[int] = []
		peer.step_completed.connect(func(code: int, _before: int, _after: int) -> void: notices.append(code))
		var captured: Driver.StepResult = peer.call("capture_replay_boundary")
		context.equal(captured.code, Types.Code.OK, "capture encoded peer's finalized boundary")
		context.equal(captured.frame_before, 3, "capture begins at final frame")
		context.equal(captured.frame_after, 3, "capture adds no frame")
		context.equal(peer.network_status(), before, "capture neither polls clocks nor publishes controls")
		context.equal(peer.drain_outbox().is_empty(), true, "capture produces no packets")
		context.equal(mesh.games[index].requests.size(), 1, "capture invokes one bounded SAVE")
		context.equal(mesh.games[index].requests[0].kind, "save", "capture invokes no simulation")
		context.equal(notices, [Types.Code.OK], "capture reports completion once")
		context.equal(peer.replay().checksum(3), mesh.games[index].game.checksum().hex_decode(), "terminal evidence binds original state")
		context.equal(peer.replay().to_bytes().decode_u16(4), 6, "explicit peer capture produces version six")
		for diverges: bool in [false, true]:
			var player: Player = Player.new()
			var playback: Game = LastInputDiverges.new(2) if diverges else Game.new(2)
			context.equal(player.configure(peer.replay(), playback, 20), Types.Code.OK, "configure peer recording playback")
			for frame: int in 3:
				context.equal(player.step(), Types.Code.OK, "play original encoded-peer input")
			context.equal(player.step(), Types.Code.DESYNC if diverges else Types.Code.OK, "only terminal SAVE distinguishes last-input divergence")
			if diverges:
				context.equal(player.failure_frame(), 3, "last-input divergence fails at boundary N")
				context.equal(player.failure_expected_checksum(), peer.replay().checksum(3), "terminal failure retains recorded evidence")
				context.equal(player.failure_actual_checksum(), playback.game.checksum().hex_decode(), "terminal failure retains actual game evidence")


func _capture_guards(context: RefCounted) -> void:
	context.equal(Peer.new().call("capture_replay_boundary").code, Types.Code.NOT_CONFIGURED, "unconfigured capture")
	var fixture: RefCounted = Fixture.new()
	var mesh: Dictionary = fixture._build(context, 2, 0, false, 128, false)
	context.equal(mesh.peers[0].call("capture_replay_boundary").code, Types.Code.NOT_SYNCHRONIZED, "capture cannot bypass startup")
	mesh = fixture._build(context, 2, 0, false, 128, true, false, 8, L.Options.new(), 60, 0, null, 128, 4)
	var peer: Peer = mesh.peers[0]
	peer._busy = true
	context.equal(peer.call("capture_replay_boundary").code, Types.Code.BUSY, "capture respects peer owner")
	peer._busy = false
	var other: Driver = Driver.new(peer._core, mesh.games[0])
	var peer_ref: WeakRef = weakref(peer)
	var guarded: PackedInt32Array = PackedInt32Array()
	other.step_completed.connect(
		func(_code: int, _before: int, _after: int) -> void:
			guarded.append(peer_ref.get_ref().capture_replay_boundary().code)
			guarded.append(peer_ref.get_ref()._core.begin_capture_replay_boundary().code)
	)
	context.equal(other.capture_replay_boundary().code, Types.Code.OK, "separate driver owns its completion notification")
	context.equal(guarded, PackedInt32Array([Types.Code.BUSY, Types.Code.BUSY]), "peer capture cannot clear another facade's notification guard")
	var staged: Array[Driver.LocalInput] = fixture._inputs(mesh, 0)
	context.equal(peer._core.submit_local_input(0, 0, staged[0].bytes).code, Types.Code.OK, "stage a same-frame sample before capture")
	context.equal(peer.capture_replay_boundary().code, Types.Code.OK, "capture does not consume a staged future input")
	context.equal(peer.scheduled_local_input(0).bytes, staged[0].bytes, "capture retains exact retry bytes")
	context.equal(peer.step(1, fixture._inputs(mesh, 0)).code, Types.Code.OK, "simulate predicted local frame")
	var before: Dictionary = peer.network_status()
	context.equal(peer.call("capture_replay_boundary").code, Types.Code.PREDICTION_STALL, "capture refuses predicted history")
	context.equal(peer.network_status(), before, "refused capture preserves endpoints and clock")
	peer.drain_outbox()
	context.equal(peer.close(2), I.Code.OK, "close before further capture")
	context.equal(peer.call("capture_replay_boundary").code, Types.Code.TERMINATED, "terminal capture stays refused")


func _capture_callbacks(context: RefCounted) -> void:
	for action: String in ["guard", "fail", "cancel"]:
		var fixture: RefCounted = Fixture.new()
		var game: CaptureGame = CaptureGame.new(2)
		var mesh: Dictionary = fixture._build(context, 2, 0, false, 128, true, false, 8, L.Options.new(), 60, 0, game, 128, 4)
		var peer: Peer = mesh.peers[0]
		game.peer_ref = weakref(peer)
		game.action = action
		var notices: Array[int] = []
		var peer_ref: WeakRef = weakref(peer)
		peer.step_completed.connect(
			func(_code: int, _before: int, _after: int) -> void:
				notices.append(peer_ref.get_ref().capture_replay_boundary().code)
				notices.append(peer_ref.get_ref()._core.begin_capture_replay_boundary().code)
		)
		var captured: Driver.StepResult = peer.capture_replay_boundary()
		context.equal(game.writer_view.status(), SnapshotStatus.Code.EXPIRED_VIEW, "capture writer expires after every callback outcome")
		context.equal(notices, [Types.Code.BUSY, Types.Code.BUSY], "completion guard fences peer and shared engine")
		if action == "guard":
			context.equal(captured.code, Types.Code.OK, "empty finalized prefix can capture")
			context.equal(
				game.observations, PackedInt32Array([Types.Code.BUSY, Types.Code.BUSY, I.Code.BUSY, I.Code.BUSY, Types.Code.BUSY]), "callbacks cannot mutate capture owner"
			)
			context.equal(peer.replay().checksum(0), game.game.checksum().hex_decode(), "empty capture binds initial state")
			context.equal(peer.close(1), I.Code.OK, "close works after capture guards release")
		else:
			context.equal(captured.code, Types.Code.CALLBACK_FAILED if action == "fail" else Types.Code.TERMINATED, "capture reports first callback outcome")
			context.equal(captured.reason, Types.Code.CALLBACK_FAILED if action == "fail" else Types.Code.TERMINATED, "capture retains terminal reason")
			context.equal(peer.replay().checksum(0).is_empty(), true, "failed or cancelled capture publishes no new evidence")
			if action == "fail":
				context.equal(captured.failure_frame, 0, "failed capture identifies exact SAVE boundary")
				context.equal(captured.failure_kind, Types.Kind.SAVE, "failed capture identifies SAVE")


func _capture_cap(context: RefCounted) -> void:
	for capture_at_cap: bool in [false, true]:
		var fixture: RefCounted = Fixture.new()
		var mesh: Dictionary = fixture._build(context, 2, 0, false, 128, true, false, 8, null, 60, 0, null, 128, 3)
		for frame: int in 3:
			mesh.now += 1000
			fixture._tick(context, mesh)
			fixture._deliver(context, mesh, fixture._drain(mesh))
		for _round: int in 4:
			for peer: Peer in mesh.peers:
				context.equal(peer.recover(mesh.now).code, Types.Code.OK, "finalize boundary at recording cap")
			fixture._deliver(context, mesh, fixture._drain(mesh))
		var peer: Peer = mesh.peers[0]
		if capture_at_cap:
			context.equal(peer.capture_replay_boundary().code, Types.Code.OK, "capture authentic capped endpoint")
		var endpoint: PackedByteArray = peer.replay().checksum(3)
		mesh.now += 1000
		fixture._tick(context, mesh)
		context.equal(peer.status().current_frame, 4, "game continues beyond capped recording")
		context.equal(peer.capture_replay_boundary().code, Types.Code.HISTORY_UNAVAILABLE, "newer live state cannot certify older prefix")
		context.equal(peer.replay().checksum(3), endpoint, "cap retains only authentic previously captured evidence")
		context.equal(endpoint.size(), 16 if capture_at_cap else 0, "uncaptured cap never gains terminal evidence")
