extends SceneTree

# Value: protects=GUI routes replay shortcuts after focus changes; fails_when=buttons consume action keys or text shortcuts navigate; seam=none.
const Scene = preload("res://examples/online/replay.tscn")
const Fixture = preload("res://tests/unit/test_replay_viewer.gd")


class KeyObserver:
	extends Node
	var received: Array[int] = []

	func _unhandled_key_input(event: InputEvent) -> void:
		if event is InputEventKey and event.pressed:
			received.append(event.keycode)


var scene: Node2D
var failed: bool = false
var checks: int = 0


func _initialize() -> void:
	_run.call_deferred()


func _check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failed = true
		print("FAILED: ", label)


func _key(code: Key, modified: bool = false) -> void:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = code
	event.unicode = code + 32 if code in [KEY_J, KEY_L] else 0
	event.pressed = true
	event.ctrl_pressed = modified
	Input.parse_input_event(event)
	await process_frame
	event.pressed = false
	Input.parse_input_event(event)
	await process_frame


func _settle() -> void:
	while scene.viewer.is_seeking():
		scene._physics_process(0.0)


func _run() -> void:
	root.size = Vector2i(960, 800)
	scene = Scene.instantiate()
	root.add_child(scene)
	scene.set_physics_process(false)
	_check(scene.viewer.open_bytes(Fixture.recording(650).to_bytes()), "open recording")
	scene._refresh()
	var observer: KeyObserver = KeyObserver.new()
	scene.add_child(observer)
	for index: int in 3:
		await process_frame
	scene._time_buttons[2].grab_focus()
	await _key(KEY_L, true)
	_check(scene.viewer.current_frame() == 0 and not scene.viewer.is_seeking(), "modified shortcut preserves frame")
	observer.received.clear()
	await _key(KEY_L)
	_check(scene.viewer.is_seeking() and scene.viewer.current_frame() == 0, "button-focused L starts bounded seek")
	_check(observer.received.has(KEY_L), "button-focused L reaches unhandled routing")
	_settle()
	_check(scene.viewer.current_frame() == 300, "L reaches five seconds")
	var line: LineEdit = LineEdit.new()
	scene.add_child(line)
	var text: TextEdit = TextEdit.new()
	scene.add_child(text)
	line.text = "entry"
	line.caret_column = 5
	text.text = "entry"
	text.set_caret_column(5)
	for editor: Control in [line, text]:
		editor.grab_focus()
		await _key(KEY_L)
		var edited_text: String = line.text if editor == line else text.text
		_check(scene.viewer.current_frame() == 300 and not scene.viewer.is_seeking() and edited_text == "entryl", "editable control receives text without navigation")
	scene._target.get_line_edit().grab_focus()
	await _key(KEY_L)
	_check(scene.viewer.current_frame() == 300 and not scene.viewer.is_seeking(), "SpinBox text focus preserves playback")
	scene._time_buttons[0].grab_focus()
	await _key(KEY_HOME)
	_settle()
	_check(scene.viewer.current_frame() == 0, "button-focused Home reaches start")
	await _key(KEY_END)
	_settle()
	_check(scene.viewer.current_frame() == 650, "button-focused End reaches ending")
	await _key(KEY_J)
	_settle()
	_check(scene.viewer.current_frame() == 350, "button-focused J navigates backward")
	scene._timeline.grab_focus()
	observer.received.clear()
	await _key(KEY_HOME)
	_settle()
	_check(scene.viewer.current_frame() == 0 and not observer.received.has(KEY_HOME), "timeline owns Home through GUI handling")
	await _key(KEY_END)
	_settle()
	_check(scene.viewer.current_frame() == 650 and not observer.received.has(KEY_END), "timeline owns End through GUI handling")
	scene._time_buttons[1].grab_focus()
	await _key(KEY_RIGHT)
	_check(scene.viewer.current_frame() == 650 and not scene.viewer.is_seeking(), "arrow focus navigation does not jump playback")
	scene._timeline_drag_started()
	await _key(KEY_J)
	_check(scene.viewer.current_frame() == 650 and not scene.viewer.is_seeking(), "timeline hold refuses routed jump")
	scene._timeline_drag_ended(false)
	scene.queue_free()
	await process_frame
	if checks == 15 and not failed:
		print("FORTRESS_REPLAY_NAVIGATION_OK 15")
		quit(0)
	else:
		print("FORTRESS_REPLAY_NAVIGATION_FAILED ", checks)
		quit(1)
