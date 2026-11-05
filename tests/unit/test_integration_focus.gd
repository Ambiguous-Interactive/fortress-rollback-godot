extends RefCounted

# Value: protects=focus loss freezes live delivery and effects; fails_when=background ticks consume input; why_new=manual pause misses application focus; seam=none
const Scene = preload("res://examples/integration/integration.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["live_focus_pause", "finishing_focus_pause", "completion_focus_pause"])


func run_case(name: String, context: RefCounted) -> void:
	var scene: Node2D = Scene.new()
	scene._ready()
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
