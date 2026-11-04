extends RefCounted

# Value: protects=ending a playable match confirms its exact tail; fails_when=finish samples another frame or omits late effects; why_new=existing scene runs forever; seam=none
const Scene = preload("res://examples/integration/integration.gd")
const Demo = preload("res://examples/integration/demo.gd")
const Game = preload("res://examples/integration/game.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


class CaptureGame:
	extends Demo.DemoGame
	var on_save: Callable
	var fail_save: bool = false

	func save_state(frame: int, writer: Game.Writer) -> Game.Driver.SaveResult:
		if on_save.is_valid():
			on_save.call()
		return Game.Driver.SaveResult.new(false) if fail_save else super.save_state(frame, writer)


func cases() -> PackedStringArray:
	return PackedStringArray(["confirmed_ending", "finish_ownership", "empty_and_capped"])


func run_case(name: String, context: RefCounted) -> void:
	var scene: Node2D = Scene.new()
	scene._ready()
	context.equal(scene.has_method("_finish_match"), true, "finish action exists")
	if scene.has_method("_finish_match"):
		call("_" + name, context, scene)
	scene._exit_tree()
	scene.free()
	context.finish()


func _confirmed_ending(context: RefCounted, scene: Node2D) -> void:
	for lag: int in [0, 3, 12]:
		scene._restart()
		scene._set_lag(lag)
		var reference: Game = Game.new()
		for tick: int in range(27):
			var frame: int = scene._demo.loop.game.frame
			var buttons: int = Game.FIRE | (Game.LEFT if tick % 3 == 0 else Game.RIGHT)
			var held: int = scene._demo.loop._sample[0] if scene._demo.loop._sample_frame == frame else buttons
			var code: int = scene._demo.tick(buttons)
			if code == Types.Code.OK:
				var remote: int = (Game.FIRE if frame % 8 < 4 else 0) | (Game.LEFT if frame % 7 < 3 else Game.RIGHT)
				var rows: Array[PackedByteArray] = [PackedByteArray([held]), PackedByteArray([remote])]
				context.equal(reference.simulate_frame(frame, Types.FrameInputs.new(rows, PackedInt32Array([0, 0]))), true, "original actual history advances")
		var final_frame: int = scene._demo.loop.game.frame
		var finish: Button = scene.get_node_or_null("InspectionControls/Finish")
		context.equal(finish != null, true, "pointer finish control exists")
		if finish == null:
			return
		scene._toggle_pause()
		finish.pressed.emit()
		context.equal(scene._is_finishing, true, "pointer starts finishing")
		context.equal(scene._is_paused, true, "finish preserves paused inspection")
		var clock: int = scene._demo.tick_count
		scene._physics_process(0.0)
		context.equal(scene._demo.tick_count, clock, "paused finish does not advance delivery")
		for attempt: int in range(20):
			if scene._is_finished:
				break
			scene._step_match()
			context.equal(scene._demo.loop.game.frame, final_frame, "finishing never samples a new frame")
		context.equal(scene._is_finished, true, "bounded delayed tail finishes")
		context.equal(scene._demo.loop.session.status().confirmed_frame, final_frame - 1, "every original frame confirms")
		context.bytes_equal(scene._demo.loop.game.canonical_bytes(), reference.canonical_bytes(), final_frame, "final canonical state matches original inputs")
		context.equal(scene._demo.effects.total_count, reference.shot_total, "each actual shot effect plays once")
		var ending: PackedByteArray = scene._demo.loop.game.canonical_bytes()
		var effects: int = scene._demo.effects.total_count
		clock = scene._demo.tick_count
		for attempt: int in range(3):
			scene._finish_match()
			scene._step_match()
			scene._physics_process(0.0)
		context.equal(scene._demo.tick_count, clock, "completed finish stays idle")
		context.equal(scene._demo.effects.total_count, effects, "completed finish never repeats effects")
		var replay: RefCounted = scene._demo.loop.driver.replay()
		context.equal(replay.frame_count(), final_frame, "replay retains every original frame")
		context.equal(replay.checksum(final_frame).size(), 16, "replay captures final canonical boundary")
		scene._toggle_replay()
		for frame: int in range(final_frame + 2):
			scene._physics_process(0.0)
		context.equal(scene._replay_code, Types.Code.FRAME_EXHAUSTED, "complete replay validates its ending")
		context.bytes_equal(scene._demo.replay_game.canonical_bytes(), ending, final_frame, "replay ends on original corrected state")
		context.equal(scene._demo.tick_count, clock, "replay preserves completed match clock")
		context.state(final_frame, ending)


func _finish_ownership(context: RefCounted, scene: Node2D) -> void:
	var key: InputEventKey = InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_E
	var completed: Callable = func(_code: int, _before: int, _after: int) -> void:
		scene._unhandled_key_input(key)
		context.equal(scene._is_finishing, false, "completion cannot start finishing")
	scene._demo.loop.driver.step_completed.connect(completed)
	scene._physics_process(0.0)
	scene._demo.loop.driver.step_completed.disconnect(completed)
	var session: RefCounted = scene._demo.loop.session
	var opened: Types.Result = session.begin_capture_replay_boundary()
	# Initial speculative history may refuse capture, so retain an ordinary expert advance instead.
	if opened.code != Types.Code.READY:
		var frame: int = session.status().current_frame
		context.equal(session.submit_local_input(0, frame, PackedByteArray([0])).code, Types.Code.OK, "expert stages sample")
		opened = session.begin_advance()
	context.equal(opened.code, Types.Code.READY, "expert owns match")
	scene._unhandled_key_input(key)
	context.equal(scene._is_finishing, false, "expert ownership refuses finish")
	scene._demo.loop.session.terminate()
	scene._restart()
	key.shift_pressed = true
	scene._unhandled_key_input(key)
	context.equal(scene._is_finishing, false, "modified shortcut is ignored")
	key.shift_pressed = false
	scene._unhandled_key_input(key)
	context.equal(scene._is_finishing, true, "unmodified shortcut starts finishing")
	scene._restart()
	context.equal(scene._is_finishing or scene._is_finished, false, "restart clears ending state")
	var game: CaptureGame = CaptureGame.new()
	context.equal(scene._demo.loop.start(game), Types.Code.OK, "callback-owned match starts")
	var calls: Array[int] = [0]
	game.on_save = func() -> void:
		calls[0] += 1
		scene._finish_match()
		context.equal(scene._is_finishing, false, "game callback cannot start finishing")
	scene._physics_process(0.0)
	context.equal(scene._demo.loop.game.frame, 1, "restarted match resumes actual simulation")
	context.equal(calls[0], 1, "callback rejection was exercised")
	game.on_save = Callable()


func _empty_and_capped(context: RefCounted, scene: Node2D) -> void:
	for cap: int in [0, 2]:
		scene._restart()
		scene._set_lag(0)
		if cap > 0:
			var config: RefCounted = scene._demo.loop.session._config.owned_copy()
			config.replay_max_frames = cap
			config.storage_budget_bytes = config.required_storage_bytes()
			context.equal(scene._demo.loop.session.configure(config), Types.Code.OK, "small replay cap configures")
			for frame: int in range(4):
				context.equal(scene._demo.tick(Game.FIRE), Types.Code.OK, "game advances beyond recording cap")
		scene._finish_match()
		scene._physics_process(0.0)
		context.equal(scene._is_finished, true, "empty or capped match still completes")
		context.equal(scene._code, Types.Code.OK, "recording cap is not a match failure")
		var frame: int = scene._demo.loop.game.frame
		var replay: RefCounted = scene._demo.loop.driver.replay()
		context.equal(replay.frame_count(), cap, "ending never pads the recording")
		context.equal(replay.checksum(frame).is_empty(), cap > 0, "only retained complete ending gets final checksum")

		scene._update_label()
		if cap > 0:
			context.equal(scene._label.text.contains("Replay holds the first 2 frames"), true, "capped replay ending is visible")
	scene._restart()
	var game: CaptureGame = CaptureGame.new()
	game.fail_save = true
	context.equal(scene._demo.loop.start(game), Types.Code.OK, "final-save failure match starts")
	scene._finish_match()
	scene._physics_process(0.0)
	context.equal(scene._code, Types.Code.CALLBACK_FAILED, "final capture failure stays explicit")
	context.equal(scene._is_finished, false, "failed final save never claims completion")
	context.equal(scene._demo.loop.driver.replay().checksum(0).is_empty(), true, "failed save publishes no terminal checksum")
