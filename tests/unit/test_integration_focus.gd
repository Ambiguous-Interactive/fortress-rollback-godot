extends RefCounted

# Value: protects=focus loss freezes live delivery and effects; fails_when=background ticks consume input; why_new=manual pause misses application focus; seam=none
const Scene = preload("res://examples/integration/integration.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["live_focus_pause", "finishing_focus_pause", "completion_focus_pause", "replay_focus_pause", "replay_inspection"])


func run_case(name: String, context: RefCounted) -> void:
	var scene: Node2D = Scene.new()
	scene._ready()
	if name.begins_with("replay_"):
		_replay_inspection(scene, context, name == "replay_focus_pause")
		return
	scene._set_lag(12)
	for tick: int in 27:
		scene._physics_process(0.0)
	context.equal(scene._demo.pending_input_count() > 0, true, "focus loss crosses actual pending delivery")
	context.equal(scene._demo.effects.total_count > 0, true, "focus loss crosses already confirmed effects")
	if name == "finishing_focus_pause":
		scene._finish_match()
	if name == "completion_focus_pause":
		var scene_ref: WeakRef = weakref(scene)
		scene._demo.loop.driver.step_completed.connect(func(_code: int, _before: int, _after: int) -> void:
			scene_ref.get_ref().notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT), CONNECT_ONE_SHOT)
		var before: int = scene._demo.tick_count
		scene._physics_process(0.0)
		context.equal(scene._demo.tick_count, before + 1, "focus notification preserves accepted service")
	else:
		scene.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	var snapshot: Array = _snapshot(scene)
	context.equal(scene._is_paused, true, "application focus loss pauses the live match")
	for tick: int in 5:
		scene._physics_process(0.0)
	context.equal(_snapshot(scene), snapshot, "background ticks preserve canonical state, queues, samples and effects")
	context.equal(scene._label.text.contains("PAUSED"), true, "paused match explains explicit resume")
	context.equal(scene._pause_button.disabled, false, "focus-paused match offers pointer resume")
	context.equal(scene._pause_button.text, "Resume match (O)", "pointer action names explicit resume")
	context.equal(scene._step_button.disabled, false, "focus pause retains single-tick inspection")
	scene.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	scene._physics_process(0.0)
	context.equal(_snapshot(scene), snapshot, "focus return does not resume service")
	var key: InputEventKey = InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_O
	scene._unhandled_key_input(key)
	context.equal(scene._is_paused, false, "ordinary shortcut resumes focus-paused service")
	scene._physics_process(0.0)
	context.equal(scene._demo.tick_count, snapshot[0] + 1, "resume services exactly one delivery tick")
	context.equal(scene._is_finishing, name == "finishing_focus_pause", "focus pause preserves final-tail mode")
	context.state(scene._demo.loop.game.frame, scene._demo.loop.game.canonical_bytes())
	scene._exit_tree()
	scene.free()
	context.finish()


func _snapshot(scene: Node2D) -> Array:
	var pending: Array[PackedInt64Array] = []
	for row: RefCounted in scene._demo._pending:
		pending.append(PackedInt64Array([row.frame, row.due_tick, row.buttons]))
	return [scene._demo.tick_count, scene._demo.loop.game.canonical_bytes(), pending, scene._demo.effects.total_count,
		scene._demo.loop._sample_frame, scene._demo.loop._sample.duplicate(), scene._pulses.duplicate(), scene._last_effect]


# Value: protects=replay inspection and focus pause preserve exact viewed state; fails_when=background playback advances; why_new=live pause bypasses replay; seam=none
func _replay_inspection(scene: Node2D, context: RefCounted, focus_pause: bool) -> void:
	for tick: int in 40:
		scene._physics_process(0.0)
	scene._toggle_replay()
	context.equal(scene._demo.replay_player != null, true, "confirmed recording opens for inspection")
	for tick: int in 3:
		scene._physics_process(0.0)
	context.equal(scene._demo.replay_player.current_frame(), 3, "healthy replay automatically advances before pause")
	var live: Array = _snapshot(scene)
	if focus_pause:
		scene.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	else:
		scene._pause_button.pressed.emit()
	var frame: int = scene._demo.replay_player.current_frame()
	var state: PackedByteArray = scene._demo.replay_game.canonical_bytes()
	for tick: int in 5:
		scene._physics_process(0.0)
	context.bytes_equal(scene._demo.replay_game.canonical_bytes(), state, frame, "paused replay preserves exact viewed state")
	context.equal(scene._demo.replay_player.current_frame(), frame, "paused replay consumes no inputs")
	context.equal(scene._label.text.contains("REPLAY PAUSED"), true, "replay pause names its inspection mode")
	context.equal(scene._pause_button.text, "Resume replay (O)", "pause control offers explicit replay resume")
	context.equal(scene._pause_button.disabled or scene._step_button.disabled, false, "paused replay enables resume and single-frame controls")
	if focus_pause:
		scene.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
		scene._physics_process(0.0)
		context.bytes_equal(scene._demo.replay_game.canonical_bytes(), state, frame, "focus return requires explicit replay resume")
	var key: InputEventKey = InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_N
	scene._unhandled_key_input(key)
	context.equal(scene._demo.replay_player.current_frame(), frame + 1, "single-frame control consumes exactly one recorded input")
	scene._physics_process(0.0)
	context.equal(scene._demo.replay_player.current_frame(), frame + 1, "single frame leaves automatic playback paused")
	key.keycode = KEY_O
	scene._unhandled_key_input(key)
	scene._physics_process(0.0)
	context.equal(scene._demo.replay_player.current_frame(), frame + 2, "explicit resume continues playback")
	context.equal(_snapshot(scene), live, "replay controls preserve live state, delivery and effects")
	if not focus_pause:
		_replay_ownership(scene, context)
	context.state(scene._demo.replay_game.frame, scene._demo.replay_game.canonical_bytes())
	scene._toggle_replay()
	context.equal(scene._is_paused, focus_pause, "return to match preserves independent live pause")
	scene._exit_tree()
	scene.free()
	context.finish()


func _replay_ownership(scene: Node2D, context: RefCounted) -> void:
	scene._toggle_pause()
	var player: RefCounted = scene._demo.replay_player
	var frame: int = player.current_frame()
	var opened: Types.Result = player.begin_advance()
	context.equal(opened.code, Types.Code.READY, "expert owns paused replay work")
	scene._physics_process(0.0)
	context.equal(scene._pause_button.disabled and scene._step_button.disabled, true, "expert work disables replay controls")
	scene._pause_button.pressed.emit()
	scene._step_button.pressed.emit()
	context.equal(player.current_frame(), frame, "stale controls preserve expert replay work")
	context.equal(scene._is_replay_paused, true, "stale resume cannot clear paused replay mode")
	while true:
		var request: Types.Request = opened.batch.next_request()
		if request == null:
			break
		var ok: bool = false
		var checksum: PackedByteArray = PackedByteArray()
		if request.kind == Types.Kind.SAVE:
			var saved: RefCounted = scene._demo.replay_game.save_state(request.frame, request.writer)
			ok = saved.ok
			checksum = saved.checksum
		elif request.kind == Types.Kind.ADVANCE:
			ok = scene._demo.replay_game.simulate_frame(request.frame, request.inputs)
		context.equal(player.complete_request(request.batch_id, request.request_id, ok, checksum).code, Types.Code.OK, "expert completes accepted replay work")
	var state: PackedByteArray = scene._demo.replay_game.canonical_bytes()
	scene._physics_process(0.0)
	context.bytes_equal(scene._demo.replay_game.canonical_bytes(), state, frame + 1, "expert release never resumes paused playback")
	context.equal(scene._pause_button.disabled or scene._step_button.disabled, false, "expert release refreshes paused replay controls")
	player.terminate()
	scene._physics_process(0.0)
	context.equal(scene._replay_code, Types.Code.TERMINATED, "paused replay observes externally retired player")
	context.equal(scene._pause_button.disabled and scene._step_button.disabled, true, "retired paused replay cannot resume or step")
	context.equal(scene._label.text.contains("REPLAY STOPPED"), true, "retired replay reports terminal status rather than pause")

	scene._toggle_replay()
	scene._toggle_replay()
	scene._toggle_pause()
	player = scene._demo.replay_player
	scene._demo.replay_game.x[0] += 1
	scene._step_button.pressed.emit()
	context.equal(scene._replay_code, Types.Code.DESYNC, "paused frame step still checks original recorded checksum")
	var stopped: PackedByteArray = scene._demo.replay_game.canonical_bytes()
	scene._pause_button.pressed.emit()
	scene._step_button.pressed.emit()
	scene._physics_process(0.0)
	context.equal(scene._replay_code, Types.Code.DESYNC, "replay inspection controls preserve first checksum failure")
	context.bytes_equal(scene._demo.replay_game.canonical_bytes(), stopped, 0, "failed inspection never consumes recorded input")
	context.equal(scene._pause_button.disabled and scene._step_button.disabled, true, "checksum failure disables replay inspection")

	_finished_replay_ownership(context)


# Value: protects=finished replay survives unrelated live ownership; fails_when=BUSY clears EOF; why_new=ownership tests hold healthy playback; seam=none
func _finished_replay_ownership(context: RefCounted) -> void:
	var scene: Node2D = Scene.new()
	scene._ready()
	scene._set_lag(0)
	for tick: int in 6:
		scene._physics_process(0.0)
	scene._toggle_replay()
	for tick: int in 8:
		scene._physics_process(0.0)
	context.equal(scene._replay_code, Types.Code.FRAME_EXHAUSTED, "healthy replay reaches its clean ending")
	scene.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	var player: RefCounted = scene._demo.replay_player
	var state: PackedByteArray = scene._demo.replay_game.canonical_bytes()
	var session: RefCounted = scene._demo.loop.session
	var opened: Types.Result = session.begin_capture_replay_boundary()
	context.equal(opened.code, Types.Code.READY, "live boundary capture temporarily owns completed replay's match")
	scene._physics_process(0.0)
	context.equal(scene._replay_code, Types.Code.FRAME_EXHAUSTED, "unrelated live ownership preserves completed replay status")
	var request: Types.Request = opened.batch.next_request()
	var saved: RefCounted = scene._demo.loop.game.save_state(request.frame, request.writer)
	context.equal(session.complete_request(request.batch_id, request.request_id, saved.ok, saved.checksum).code, Types.Code.OK,
		"live expert completes boundary capture without replay mutation")
	context.equal(opened.batch.next_request() == null, true, "live capture releases its temporary ownership")
	scene._physics_process(0.0)
	context.equal(scene._replay_code, Types.Code.FRAME_EXHAUSTED, "released ownership preserves completed replay status")
	context.equal(scene._pause_button.disabled and scene._step_button.disabled, true, "completed replay remains unavailable for resume or stepping")
	context.equal(scene._label.text.contains("REPLAY FINISHED"), true, "released ownership keeps completed replay visible")
	scene._pause_button.pressed.emit()
	scene._step_button.pressed.emit()
	scene._physics_process(0.0)
	context.equal(scene._replay_code, Types.Code.FRAME_EXHAUSTED, "stale replay controls do not revive completed playback")
	context.bytes_equal(scene._demo.replay_game.canonical_bytes(), state, player.current_frame(), "completed playback holds exact canonical ending")
	scene._exit_tree()
	scene.free()
