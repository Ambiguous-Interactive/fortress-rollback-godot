extends RefCounted

# Value: protects=offline inspection uses real rollback and shared ownership; fails_when=pause still advances or reset abandons active work;
# why_new=simulation-only checks cannot verify scene controls; seam=actual scene and driver
const Scene = preload("res://examples/offline/offline.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["inspection", "ownership"])


func run_case(name: String, context: RefCounted) -> void:
	var scene: Node = Scene.new()
	scene._ready()
	var controls: Node = scene.get_node_or_null("OfflineControls")
	context.equal(controls != null, true, "offline example exposes pointer inspection controls")
	if controls != null:
		call("_" + name, scene, context)
	scene._exit_tree()
	scene.free()
	context.finish()


func _key(scene: Node, key: Key) -> void:
	var event: InputEventKey = InputEventKey.new()
	event.pressed = true
	event.keycode = key
	scene._unhandled_key_input(event)


func _inspection(scene: Node, context: RefCounted) -> void:
	var pause: Button = scene.get_node("OfflineControls/Pause")
	var step: Button = scene.get_node("OfflineControls/Step")
	var restart: Button = scene.get_node("OfflineControls/Restart")
	context.equal(step.disabled, true, "continuous match cannot double-step")
	pause.pressed.emit()
	context.equal(scene._is_paused, true, "pointer pauses match")
	var before: PackedByteArray = scene._simulation.canonical_bytes()
	for tick: int in 10:
		scene._physics_process(0.0)
	context.bytes_equal(scene._simulation.canonical_bytes(), before, 0, "pause leaves full canonical state unchanged")
	var reference: Simulation = Simulation.new()
	var rows: Array[PackedByteArray] = [PackedByteArray([0]), PackedByteArray([0])]
	var statuses: PackedInt32Array = PackedInt32Array([Queue.Status.CONFIRMED, Queue.Status.CONFIRMED])
	for frame: int in 50:
		if frame % 2 == 0:
			step.pressed.emit()
		else:
			_key(scene, KEY_N)
		reference.simulate_frame(frame, Types.FrameInputs.new(rows, statuses))
		context.equal(scene._session.status().current_frame, frame + 1, "one explicit tick advances one frame through real sync-test")
		context.bytes_equal(scene._simulation.canonical_bytes(), reference.canonical_bytes(), frame + 1, "stepped rollback matches uninterrupted history")
		context.equal(scene._is_paused, true, "single-step stays paused")
	context.equal(scene._presentation.pulse_count, 6, "stepped presentation counts each corrected event once")
	var frame: int = scene._simulation.frame
	for modifier: String in ["ctrl_pressed", "alt_pressed", "meta_pressed", "shift_pressed", "echo"]:
		var event: InputEventKey = InputEventKey.new()
		event.keycode = KEY_N
		event.pressed = true
		event.set(modifier, true)
		scene._unhandled_key_input(event)
		context.equal(scene._simulation.frame, frame, "modified or repeated step cannot advance")
	_key(scene, KEY_P)
	context.equal(scene._is_paused, false, "keyboard resumes match")
	context.equal(step.disabled, true, "resume disables extra step")
	var old: RefCounted = scene._session
	restart.pressed.emit()
	context.equal(old.status().lifecycle, Types.Lifecycle.TERMINATED, "restart retires retained session")
	context.equal(scene._simulation.frame, 0, "pointer restart uses fresh simulation")
	context.equal(scene._presentation.pulse_count, 0, "restart clears cosmetic ledger")
	context.equal(scene._is_paused, false, "restart resumes continuous play")
	context.state(frame, reference.canonical_bytes())


func _reject(scene: Node, context: RefCounted) -> void:
	var paused: bool = scene._is_paused
	var session: RefCounted = scene._session
	var bytes: PackedByteArray = scene._simulation.canonical_bytes()
	scene._update_label()
	for action: String in ["Pause", "Step", "Restart"]:
		var button: Button = scene.get_node("OfflineControls/" + action)
		context.equal(button.disabled, true, "owned work disables " + action)
		button.pressed.emit()
		_key(scene, {"Pause": KEY_P, "Step": KEY_N, "Restart": KEY_R}[action])
		context.equal(scene._session == session, true, "owned work retains original session")
		context.equal(scene._is_paused, paused, "owned work retains pause policy")
		context.bytes_equal(scene._simulation.canonical_bytes(), bytes, session.status().current_frame, "owned controls preserve game state")


func _ownership(scene: Node, context: RefCounted) -> void:
	_key(scene, KEY_P)
	var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, 0, PackedByteArray([0])), Driver.LocalInput.new(1, 0, PackedByteArray([0]))]
	for sample: Driver.LocalInput in samples:
		context.equal(scene._session.submit_local_input(sample.player, sample.sample_frame, sample.bytes).code, Types.Code.OK, "expert stages local input")
	var opened: RefCounted = scene._session.begin_advance()
	context.equal(opened.code, Types.Code.READY, "expert holds real request batch")
	_reject(scene, context)
	scene._physics_process(0.0)
	context.equal(scene._label.text.contains("WAITING FOR ACTIVE WORK"), true, "paused ownership is visible")
	var request: RefCounted = opened.batch.next_request()
	var saved: Driver.SaveResult = scene._simulation.save_state(request.frame, request.writer)
	scene._session.complete_request(request.batch_id, request.request_id, saved.ok, saved.checksum)
	request = opened.batch.next_request()
	scene._session.complete_request(request.batch_id, request.request_id, scene._simulation.simulate_frame(request.frame, request.inputs))
	context.equal(opened.batch.next_request() == null, true, "expert releases original work")
	var scene_ref: WeakRef = weakref(scene)
	scene._driver.step_completed.connect(func(_code: int, _before: int, _after: int) -> void:
		_reject(scene_ref.get_ref(), context), CONNECT_ONE_SHOT)
	scene._step_match()
	context.equal(scene._simulation.frame, 2, "step retries after expert ownership releases")
	scene._session.terminate(Types.Code.CALLBACK_FAILED)
	scene._physics_process(0.0)
	context.equal(scene._label.text.contains("STOPPED"), true, "paused scene refreshes external termination")
	context.equal(scene.get_node("OfflineControls/Pause").disabled, true, "terminal pause disabled")
	context.equal(scene.get_node("OfflineControls/Step").disabled, true, "terminal step disabled")
	context.equal(scene.get_node("OfflineControls/Restart").disabled, false, "terminal reset remains available")
	_key(scene, KEY_R)
	context.equal(scene._simulation.frame, 0, "keyboard restart replaces stopped match")
