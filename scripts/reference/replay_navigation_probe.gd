extends SceneTree

# Value: protects=replay shortcut routing and online movement after GUI actions; fails_when=focus steals navigation or movement; seam=none.
const Scene = preload("res://examples/online/replay.tscn")
const Fixture = preload("res://tests/unit/test_replay_viewer.gd")
const OnlineScene = preload("res://examples/online/online.tscn")
const OnlineFixture = preload("res://tests/unit/test_online_example.gd")
const OnlineContext = preload("res://tests/runner/test_context.gd")


class ObservedLobby:
	extends OnlineFixture.Lobby
	var sampled: int = -1

	func tick(_now_us: int, buttons: int) -> void:
		sampled = buttons


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
	await _online_controls()
	if checks == 61 and not failed:
		print("FORTRESS_REPLAY_NAVIGATION_OK 61")
		quit(0)
	else:
		print("FORTRESS_REPLAY_NAVIGATION_FAILED ", checks)
		quit(1)


# Real GUI event dispatch needs a deferred live tree; initialization-only suites cannot focus controls.
func _online_controls() -> void:
	var helper: RefCounted = OnlineFixture.new()
	var context: RefCounted = OnlineContext.new(1701)
	var fixtures: Array[Dictionary] = [helper._fixture(context, OnlineFixture.U, null, true), helper._fixture(context, OnlineFixture.V, null, true)]
	for round_index: int in 100:
		for fixture: Dictionary in fixtures:
			fixture.driver.tick(round_index * 16667, 0)
		helper._deliver(fixtures)
	_check(context.failures.is_empty(), "online GUI fixture synchronizes actual recorded peers")
	var online: Node2D = OnlineScene.instantiate()
	root.add_child(online)
	online.set_physics_process(false)
	var lobby: ObservedLobby = ObservedLobby.new()
	lobby.game_match = fixtures[0].driver
	lobby.state = "playing"
	lobby.has_readied = true
	lobby.client = OnlineFixture.SceneClient.new()
	online.controller = lobby
	online._update_status()
	await process_frame
	await process_frame
	for button: Button in [online.raise_delay_button, online.apply_delay_button, online.diagnostics_button, online.replay_button]:
		var previous_delay: int = lobby.game_match.peer.input_delay(lobby.game_match.local_slot)
		if button == online.apply_delay_button:
			lobby.game_match.suggested_delay = previous_delay + 1
			lobby.game_match.suggested_frame = lobby.game_match.peer.status().current_frame
		online._update_status()
		_check(not button.disabled, "online gameplay action is enabled: " + button.text)
		await _click(button)
		_check(root.gui_get_focus_owner() == null, "online mouse action releases gameplay focus: " + button.text)
		if button in [online.raise_delay_button, online.apply_delay_button]:
			_check(lobby.game_match.peer.input_delay(lobby.game_match.local_slot) == previous_delay + 1, "mouse delay action takes effect")
		for index: int in 6:
			var event: InputEventKey = InputEventKey.new()
			event.keycode = KEY_UP
			event.physical_keycode = KEY_UP
			event.pressed = true
			Input.parse_input_event(event)
			await process_frame
			online._physics_process(0.0)
			_check(
				lobby.sampled == OnlineFixture.Simulation.UP and not root.gui_get_focus_owner() is LineEdit,
				"arrow movement survives active button click %s turn %d" % [button.text, index]
			)
			event.pressed = false
			Input.parse_input_event(event)
			await process_frame
	var previous_delay: int = lobby.game_match.peer.input_delay(lobby.game_match.local_slot)
	online.raise_delay_button.grab_focus()
	await _key(KEY_ENTER)
	_check(lobby.game_match.peer.input_delay(lobby.game_match.local_slot) == previous_delay + 1, "keyboard activation preserves delay button accessibility")
	_check(root.gui_get_focus_owner() == null, "keyboard activation releases gameplay focus")
	for code: Key in [KEY_EQUAL, KEY_R]:
		previous_delay = lobby.game_match.peer.input_delay(lobby.game_match.local_slot)
		lobby.game_match.suggested_delay = previous_delay + 1
		lobby.game_match.suggested_frame = lobby.game_match.peer.status().current_frame
		online._update_status()
		online.diagnostics_button.grab_focus()
		await _key(code)
		_check(lobby.game_match.peer.input_delay(lobby.game_match.local_slot) == previous_delay + 1, "focused button preserves delay shortcut")
		_check(root.gui_get_focus_owner() == null, "delay shortcut releases gameplay focus")
	var editor: LineEdit = LineEdit.new()
	online.add_child(editor)
	lobby.state = "offline"
	for method: String in ["_export_diagnostics", "_export_replay"]:
		editor.grab_focus()
		online.call(method)
		_check(root.gui_get_focus_owner() == editor, "offline export preserves unrelated text focus")
	lobby.state = "failed"
	var previous_message: String = lobby.message
	previous_delay = lobby.game_match.peer.input_delay(lobby.game_match.local_slot)
	online._raise_input_delay()
	online._apply_suggested_delay()
	_check(root.gui_get_focus_owner() == editor, "stale action preserves unrelated text focus")
	_check(lobby.game_match.peer.input_delay(lobby.game_match.local_slot) == previous_delay, "stale action preserves delay")
	_check(lobby.message == previous_message, "stale action preserves recovery message")
	var client: Node = lobby.client
	lobby.client = null
	client.free()
	online.free()
	for fixture: Dictionary in fixtures:
		fixture.driver.detach()
		fixture.mesh.free()
		fixture.client.free()


func _click(button: Button) -> void:
	var point: Vector2 = button.get_global_rect().get_center()
	for pressed: bool in [true, false]:
		var event: InputEventMouseButton = InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		Input.parse_input_event(event)
		await process_frame
