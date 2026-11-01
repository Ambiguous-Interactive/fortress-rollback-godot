extends RefCounted

# Value: protects=diagnostic callbacks cannot replace or advance their owning viewer; fails_when=controls mutate playback during a callback;
# why_new=ordinary viewer controls and player reentry do not cross the composed ownership boundary; seam=none
const Scene = preload("res://examples/online/diagnostic.tscn")
const Fixture = preload("res://tests/unit/test_diagnostic_viewer.gd")
const Viewer = preload("res://examples/online/diagnostic_viewer.gd")
const Player = preload("res://addons/fortress_rollback/core/diagnostic_player.gd")
const Game = preload("res://examples/offline/simulation.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const SnapshotStatus = preload("res://addons/fortress_rollback/core/snapshot_status.gd")


class ReentrantGame:
	extends Game
	var owner_ref: WeakRef
	var callback_kind: int = -1
	var action: String = ""
	var attempted: bool = false
	var observations: Array[bool] = []
	var view: RefCounted
	var cancellation_codes: PackedInt32Array = PackedInt32Array()
	var callback_calls: PackedInt32Array = PackedInt32Array()
	var cancelled_view_expired: bool = false
	var scene_ref: WeakRef

	func _attempt(kind: int, active_view: RefCounted) -> void:
		if kind != callback_kind or attempted:
			return
		attempted = true
		view = active_view
		var target: RefCounted = owner_ref.get_ref()
		if action == "scene_exit":
			var player: RefCounted = target._player
			var scene: Node = scene_ref.get_ref()
			if not scene.is_inside_tree():
				scene._exit_tree()
			scene.free()
			observations.append(not target.open_bytes(Fixture.encoded(Fixture.capture())))
			target.restart()
			observations.append(target._player == player)
			return
		if action == "terminate":
			target.terminate()
			target.terminate()
			cancelled_view_expired = active_view.size().code == Types.Code.EXPIRED_VIEW if kind == Types.Kind.ADVANCE else active_view.status() == SnapshotStatus.Code.EXPIRED_VIEW
			cancellation_codes.append(target.step())
			cancellation_codes.append(target.configure(Fixture.capture(), self, SNAPSHOT_BYTES))
			return
		var before: Dictionary = target.status()
		var player: RefCounted = target._player
		var game: RefCounted = target.game
		var message: String = target.message
		match action:
			"restart":
				target.restart()
			"open", "invalid_open":
				observations.append(not target.open_bytes(Fixture.encoded(Fixture.capture()) if action == "open" else PackedByteArray()))
			"toggle":
				target.toggle_play()
			"step":
				target.step()
			"tick":
				target.tick()
		observations.append(target._player == player and target.game == game)
		observations.append(target.status() == before)
		observations.append(target.message == message)

	func load_state(frame_number: int, reader: RefCounted) -> bool:
		callback_calls.append(Types.Kind.LOAD)
		_attempt(Types.Kind.LOAD, reader)
		return true if action == "terminate" and attempted else super.load_state(frame_number, reader)

	func save_state(frame_number: int, writer: RefCounted) -> Driver.SaveResult:
		callback_calls.append(Types.Kind.SAVE)
		_attempt(Types.Kind.SAVE, writer)
		return Driver.SaveResult.new() if action == "terminate" and attempted else super.save_state(frame_number, writer)

	func simulate_frame(frame_number: int, inputs: Types.FrameInputs) -> bool:
		callback_calls.append(Types.Kind.ADVANCE)
		_attempt(Types.Kind.ADVANCE, inputs)
		return true if action == "terminate" and attempted else super.simulate_frame(frame_number, inputs)


func cases() -> PackedStringArray:
	return PackedStringArray(["viewer_callback_controls", "player_cancellation", "retired_playback", "scene_exit", "scene_exit_callbacks"])


func run_case(name: String, context: RefCounted) -> void:
	call("_" + name, context)
	context.finish()


func _viewer_callback_controls(context: RefCounted) -> void:
	var trace: Dictionary = Fixture.capture()
	for kind: int in [Types.Kind.LOAD, Types.Kind.SAVE, Types.Kind.ADVANCE]:
		for action: String in ["restart", "open", "invalid_open", "toggle", "step", "tick"]:
			var viewer: Viewer = Viewer.new()
			context.equal(viewer.open_bytes(Fixture.encoded(trace)), true, "healthy import before guarded control")
			var game: ReentrantGame = ReentrantGame.new()
			game.owner_ref = weakref(viewer)
			game.callback_kind = kind
			game.action = action
			viewer.game = game
			context.equal(viewer._player.configure(trace, game, Game.SNAPSHOT_BYTES), Types.Code.OK, "install observed matching game callbacks")
			viewer.toggle_play()
			viewer.tick()
			context.equal(game.attempted, true, "control executes inside the selected callback")
			for unchanged: bool in game.observations:
				context.equal(unchanged, true, "callback control preserves viewer ownership and state: " + action)
			context.equal(viewer.status().rows_consumed, 1, "outer service consumes exactly its original row")
			context.equal(viewer.status().code, Types.Code.OK, "nested control cannot publish BUSY as playback failure")
			context.equal(viewer.game == game, true, "outer service retains its executing game")
			context.bytes_equal(game.canonical_bytes(), trace.frames[1].state.hex_decode(), 3, "guarded service preserves canonical continuation")
			context.equal(viewer.is_playing, true, "guarded control cannot pause active playback")
			viewer.restart()
			context.equal(viewer.status().rows_consumed, 0, "idle restart remains available")
			context.equal(viewer.is_playing, false, "idle restart pauses the fresh lifetime")


# Value: protects=cancelled diagnostic work cannot apply later callbacks or retain active views;
# fails_when=termination only marks status after callback continuation; why_new=diagnostic player lacked cancellation; seam=none
func _player_cancellation(context: RefCounted) -> void:
	context.equal(Player.new().has_method("terminate"), true, "diagnostic owners can cancel playback")
	if not Player.new().has_method("terminate"):
		return
	for kind: int in [Types.Kind.LOAD, Types.Kind.SAVE, Types.Kind.ADVANCE]:
		var game: ReentrantGame = ReentrantGame.new()
		var player: Player = Player.new()
		game.owner_ref = weakref(player)
		game.callback_kind = kind
		game.action = "terminate"
		context.equal(player.configure(Fixture.capture(), game, Game.SNAPSHOT_BYTES), Types.Code.OK, "configure cancellable capture")
		context.equal(player.step(), Types.Code.TERMINATED, "callback cancellation stops the current row")
		context.equal(game.cancellation_codes, PackedInt32Array([Types.Code.BUSY, Types.Code.BUSY]), "cancellation retains callback guards")
		context.equal(game.cancelled_view_expired, true, "active view expires inside the cancelling callback")
		var calls: PackedInt32Array = PackedInt32Array([Types.Kind.LOAD])
		if kind != Types.Kind.LOAD:
			calls.append(Types.Kind.SAVE)
		if kind == Types.Kind.ADVANCE:
			calls.append(Types.Kind.ADVANCE)
		context.equal(game.callback_calls, calls, "cancellation prevents every later callback")
		context.equal(game.view.size().code if kind == Types.Kind.ADVANCE else game.view.status(),
			Types.Code.EXPIRED_VIEW if kind == Types.Kind.ADVANCE else SnapshotStatus.Code.EXPIRED_VIEW, "cancellation expires the active view immediately")
		context.equal(player.is_complete(), false, "cancelled work cannot claim completion")
		context.equal(player.report().advanced_frames, 0, "cancelled ADVANCE cannot publish completed work")
		context.equal(player.report().failure, {"frame": 2, "kind": "cancelled"}, "cancellation records its captured boundary")
		context.equal(player.step(), Types.Code.TERMINATED, "later service preserves cancellation")
		context.equal(player.configure(Fixture.capture(), Game.new(), Game.SNAPSHOT_BYTES), Types.Code.OK, "fresh explicit configuration releases cancellation")
		context.equal(player.step(), Types.Code.OK, "fresh lifetime runs normally")
		context.equal(player.report().failure, {}, "fresh lifetime clears prior failure")
	var empty: Player = Player.new()
	empty.terminate()
	context.equal(empty.step(), Types.Code.NOT_CONFIGURED, "unconfigured cancellation stays harmless")
	var damaged: Dictionary = Fixture.capture()
	damaged.frames[0].checksum = "00".repeat(16)
	var failed: Player = Player.new()
	context.equal(failed.configure(damaged, Game.new(), Game.SNAPSHOT_BYTES), Types.Code.OK, "configure comparison-failure control")
	context.equal(failed.step(), Types.Code.DESYNC, "control observes an actual checksum mismatch")
	var failure: Dictionary = failed.report()
	failed.terminate()
	context.equal(failed.step(), Types.Code.DESYNC, "later cancellation preserves original comparison error")
	context.equal(failed.report(), failure, "later cancellation preserves complete first-cause evidence")


# Value: protects=replacement retires the viewer-owned diagnostic player; fails_when=retained old handles continue game callbacks;
# why_new=ordinary restart tests inspect only the replacement; seam=none
func _retired_playback(context: RefCounted) -> void:
	for replacement: String in ["restart", "open", "invalid_open"]:
		var viewer: Viewer = Viewer.new()
		var bytes: PackedByteArray = Fixture.encoded(Fixture.capture())
		context.equal(viewer.open_bytes(bytes), true, "open original diagnostic lifetime")
		var old_player: Player = viewer._player
		var old_game: Game = viewer.game
		viewer.step()
		var before: PackedByteArray = old_game.canonical_bytes()
		if replacement == "restart":
			viewer.restart()
		else:
			context.equal(viewer.open_bytes(bytes if replacement == "open" else PackedByteArray()), replacement == "open", "replacement reports actual import outcome")
		context.equal(old_player.step(), Types.Code.OK if replacement == "invalid_open" else Types.Code.TERMINATED, "only successful replacement retires old callbacks")
		if replacement != "invalid_open":
			context.bytes_equal(old_game.canonical_bytes(), before, 3, "retained retired handle cannot advance its old game")
			viewer.step()
			context.equal(viewer.status().rows_consumed, 1, "fresh replacement remains independently playable")


# Value: protects=leaving diagnostic playback retires retained players; fails_when=old handles simulate after scene exit;
# why_new=retirement tests only replace or restart a viewer; seam=none
func _scene_exit(context: RefCounted) -> void:
	for mode: String in ["paused", "playing", "failed", "complete"]:
		var node: Node2D = Scene.instantiate()
		(Engine.get_main_loop() as SceneTree).root.add_child(node)
		if not node.is_inside_tree():
			node._ready()
		var trace: Dictionary = Fixture.capture()
		if mode == "failed":
			trace.frames[0].checksum = "00".repeat(16)
		context.equal(node.viewer.open_bytes(Fixture.encoded(trace)), true, "diagnostic exit fixture imports")
		var viewer: Viewer = node.viewer
		var player: Player = viewer._player
		var game: Game = viewer.game
		if mode == "playing":
			viewer.toggle_play()
		elif mode == "failed":
			viewer.step()
		elif mode == "complete":
			while viewer.can_step():
				viewer.step()
			context.equal(player.is_complete(), true, "diagnostic complete fixture reaches its ending")
		var before: Dictionary = viewer.status()
		var message: String = viewer.message
		var bytes: PackedByteArray = game.canonical_bytes()
		if not node.is_inside_tree():
			node._exit_tree()
		node.free()
		context.equal(
			viewer.message,
			message if mode == "failed" else "Playback stopped. Restart to inspect again.",
			"diagnostic exit names cancellation while retaining existing failure text"
		)
		context.equal(viewer.is_playing, false, "diagnostic scene exit stops cadence")
		context.equal(viewer.can_step(), false, "diagnostic scene exit stops controller playback")
		var code: int = player.step()
		context.equal(code, int(before.code) if mode == "failed" else Types.Code.TERMINATED, "diagnostic exit retires the owned player and preserves its first cause")
		viewer.tick()
		viewer.step()
		context.equal(viewer.status().rows_consumed, before.rows_consumed, "diagnostic exit preserves completed row count")
		context.bytes_equal(game.canonical_bytes(), bytes, game.frame, "retained diagnostic handles cannot change departed game")
		context.state(game.frame, bytes)


# Value: protects=diagnostic scene exit cancels executing game work and retains callback ownership;
# fails_when=the viewer restarts during teardown or accepts later callback results; why_new=idle exit has no active view; seam=none
func _scene_exit_callbacks(context: RefCounted) -> void:
	for kind: int in [Types.Kind.LOAD, Types.Kind.SAVE, Types.Kind.ADVANCE]:
		var node: Node2D = Scene.instantiate()
		(Engine.get_main_loop() as SceneTree).root.add_child(node)
		if not node.is_inside_tree():
			node._ready()
		var viewer: Viewer = node.viewer
		var trace: Dictionary = Fixture.capture()
		context.equal(viewer.open_bytes(Fixture.encoded(trace)), true, "diagnostic callback exit fixture imports")
		var game: ReentrantGame = ReentrantGame.new()
		game.owner_ref = weakref(viewer)
		game.scene_ref = weakref(node)
		game.callback_kind = kind
		game.action = "scene_exit"
		viewer.game = game
		var player: Player = viewer._player
		context.equal(player.configure(trace, game, Game.SNAPSHOT_BYTES), Types.Code.OK, "diagnostic callback exit game configures")
		viewer.toggle_play()
		viewer.tick()
		context.equal(game.attempted, true, "diagnostic teardown executes during selected callback")
		context.equal(is_instance_valid(node), false, "diagnostic callback frees actual scene")
		for unchanged: bool in game.observations:
			context.equal(unchanged, true, "diagnostic callback teardown preserves shared ownership")
		context.equal(viewer._player, player, "diagnostic callback cannot restart canceled player")
		context.equal(viewer.game, game, "diagnostic callback keeps its original game")
		context.equal(viewer.status().code, Types.Code.TERMINATED, "diagnostic outer service preserves cancellation")
		context.equal(viewer.status().rows_consumed, 0, "canceled diagnostic row is not completed")
		context.equal(viewer.is_playing, false, "diagnostic callback exit stops cadence")
		var calls: PackedInt32Array = game.callback_calls.duplicate()
		context.equal(player.step(), Types.Code.TERMINATED, "retained diagnostic player remains canceled")
		context.equal(game.callback_calls, calls, "diagnostic cancellation cannot invoke another callback")
		context.state(game.frame, game.canonical_bytes())
