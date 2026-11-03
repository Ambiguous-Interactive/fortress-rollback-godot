extends SceneTree

# Value: protects=replay navigation, visible gameplay and online movement after GUI actions; fails_when=focus or control layout hides gameplay; seam=none.
const EffectsScene = preload("res://examples/integration/integration.gd")
const OfflineScene = preload("res://examples/offline/offline.tscn")
const PeerScene = preload("res://examples/peer/peer.tscn")
const InputNavigationFixture = preload("res://tests/unit/test_replay_input_navigation.gd")
const SpectatorScene = preload("res://examples/spectator/spectator.gd")
const CheckpointFixture = preload("res://tests/unit/test_replay_checkpoints.gd")
const ViewerTypes = preload("res://addons/fortress_rollback/core/session_types.gd")
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


func _key(code: Key, modified: bool = false, physical: Key = KEY_NONE) -> void:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code if physical == KEY_NONE else physical
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
	var frame_editor: LineEdit = scene._target.get_line_edit()
	frame_editor.text = "301"
	await _key(KEY_ENTER)
	_check(scene.viewer.is_seeking() and scene.viewer.current_frame() == 300, "actual Enter starts typed bounded navigation")
	_settle()
	_check(scene.viewer.current_frame() == 301 and not scene.viewer.is_playing, "actual Enter reaches exact frame paused")
	_check(root.gui_get_focus_owner() == null, "accepted typed navigation releases editable focus")
	await _key(KEY_N)
	_check(scene.viewer.current_frame() == 302, "playback shortcut works after submitting a frame")
	_check(scene.viewer._player.begin_advance().code == ViewerTypes.Code.READY, "manual request owns state before stale enabled submission")
	frame_editor.grab_focus()
	frame_editor.text = "10"
	await _key(KEY_ENTER)
	_check(scene.viewer.current_frame() == 302 and not scene.viewer.is_seeking(), "manual ownership refuses actual Enter without refresh")
	_check(root.gui_get_focus_owner() == frame_editor, "refused submission preserves editable focus")
	scene.viewer._player.terminate()
	scene.viewer.restart()
	scene._refresh()
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
	await _replay_layout()
	await _replay_wheel()
	await _submitted_restore_failure()
	await _submitted_current_failure()
	await _repeat_controls()
	await _player_change_controls()
	scene.queue_free()
	await process_frame
	await _online_controls()
	await _spectator_shortcuts()
	await _effects_controls()
	await _peer_controls()
	await _offline_controls()
	if checks == 255 and not failed:
		print("FORTRESS_REPLAY_NAVIGATION_OK 255")
		quit(0)
	else:
		print("FORTRESS_REPLAY_NAVIGATION_FAILED ", checks)
		quit(1)


func _replay_layout() -> void:
	for dimensions: Vector2i in [Vector2i(960, 540), Vector2i(640, 360), Vector2i(1280, 720)]:
		root.size = dimensions
		for playback_failed: bool in [false, true]:
			root.gui_release_focus()
			var recording: RefCounted = Fixture.recording(24)
			if playback_failed:
				recording._inputs[14] ^= 1
			_check(scene.viewer.open_bytes(recording.to_bytes()), "layout recording imports")
			if playback_failed:
				scene.viewer.seek(24)
				scene.viewer.tick()
			scene._refresh()
			await process_frame
			await process_frame
			_check(scene.viewer.has_failure() == playback_failed, "layout uses healthy playback and actual input-integrity failure")
			var controls: ScrollContainer = scene.get_node_or_null("ReplayControls")
			_check(controls != null, "replay actions have a bounded scrolling viewport")
			if controls == null:
				continue
			var bounds: Rect2 = controls.get_global_rect()
			_check(bounds.end.x <= dimensions.x and bounds.end.y + 100.0 < dimensions.y, "controls fit viewport and leave visible game space")
			var game_bounds: Rect2 = scene.get_global_transform() * scene._game_rect()
			_check(root.get_visible_rect().encloses(game_bounds) and game_bounds.position.y > bounds.end.y, "actual game draw geometry remains below controls inside viewport")
			controls.ensure_control_visible(scene._status)
			await process_frame
			_check(controls.scroll_vertical > 0, "real content scrolls to status and failure details")
			var status_bounds: Rect2 = scene._status.get_global_rect()
			_check(status_bounds.position.y >= bounds.position.y and status_bounds.end.y <= bounds.end.y, "status details fit vertically after scrolling")
			controls.scroll_horizontal = 10000
			_check(dimensions.x >= 700 or controls.scroll_horizontal > 0, "narrow viewport scrolls wide controls horizontally")
			controls.scroll_horizontal = 0
			scene._restart_button.grab_focus()
			await process_frame
			await process_frame
			_check(controls.follow_focus, "scroll viewport follows keyboard focus")
			_check(bounds.encloses(scene._restart_button.get_global_rect()), "keyboard focus reveals actual restart control")
			_check(root.gui_get_focus_owner() == scene._restart_button, "scrolling preserves the focused control")
			await _key(KEY_P)
			_check(scene.viewer.is_playing == (not playback_failed), "scrolled button focus preserves replay play routing and failure gates")
			await _key(KEY_P)
			_check(not scene.viewer.is_playing, "scrolled button focus preserves replay pause routing")
	root.size = Vector2i(960, 800)


func _replay_wheel() -> void:
	root.size = Vector2i(960, 540)
	for playback_failed: bool in [false, true]:
		var recording: RefCounted = Fixture.recording(24)
		if playback_failed:
			recording._inputs[14] ^= 1
		scene.viewer.open_bytes(recording.to_bytes())
		if playback_failed:
			scene.viewer.seek(24)
			scene.viewer.tick()
		else:
			scene.viewer.toggle_play()
		scene._refresh()
		await process_frame
		await process_frame
		var controls: ScrollContainer = scene._controls_view
		controls.scroll_vertical = 150
		await process_frame
		var before: Array = [scene.viewer.current_frame(), scene.viewer.is_playing, scene.viewer.has_failure(), scene.viewer.failure_report_bytes(), scene._timeline.value]
		for button: MouseButton in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var scroll_before: int = controls.scroll_vertical
			await _pointer(scene._timeline.get_global_rect().get_center(), true, button)
			_check(controls.scroll_vertical != scroll_before, "wheel over timeline scrolls parent controls")
			_check(
				before == [scene.viewer.current_frame(), scene.viewer.is_playing, scene.viewer.has_failure(), scene.viewer.failure_report_bytes(), scene._timeline.value],
				"wheel preserves playback and failure evidence"
			)
		if not playback_failed:
			await _pointer(scene._timeline.get_global_rect().get_center(), true)
			await _pointer(scene._timeline.get_global_rect().get_center(), false)
			_settle()
			_check(scene.viewer.current_frame() > 0 and not scene.viewer.is_playing, "timeline pointer selection still seeks and pauses")
			var frame_before: int = scene.viewer.current_frame()
			var timeline: Rect2 = scene._timeline.get_global_rect()
			await _pointer(timeline.position + timeline.size * Vector2(0.25, 0.5), true)
			var motion: InputEventMouseMotion = InputEventMouseMotion.new()
			motion.position = timeline.position + timeline.size * Vector2(0.75, 0.5)
			motion.global_position = motion.position
			motion.relative = Vector2(timeline.size.x * 0.5, 0)
			motion.button_mask = MOUSE_BUTTON_MASK_LEFT
			Input.parse_input_event(motion)
			await process_frame
			_check(scene._is_scrubbing and scene.viewer.current_frame() == frame_before, "timeline drag previews without advancing displayed game")
			await _pointer(motion.position, false)
			_settle()
			_check(scene.viewer.current_frame() > frame_before and not scene.viewer.is_playing, "timeline drag release still seeks and pauses")
	root.size = Vector2i(960, 800)


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
		await _pointer(point, pressed)


func _pointer(point: Vector2, pressed: bool, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = button
	event.pressed = pressed
	Input.parse_input_event(event)
	await process_frame


func _submitted_restore_failure() -> void:
	for damaged: bool in [false, true]:
		scene.viewer.open_bytes(Fixture.recording(400).to_bytes())
		var game: RefCounted = CheckpointFixture.FaultGame.new()
		scene.viewer._player.terminate()
		scene.viewer.game = game.game
		_check(
			scene.viewer._player.configure(scene.viewer._recording, game, Fixture.Simulation.SNAPSHOT_BYTES, 300, 121) == ViewerTypes.Code.OK,
			"configure recorded cache restoration control"
		)
		for frame: int in range(302):
			scene.viewer.step()
		_check(scene.viewer.current_frame() == 302 and scene.viewer._player.checkpoint_frames().has(0), "original playback retains earlier checkpoint")
		scene._refresh()
		await process_frame
		await process_frame
		var editor: LineEdit = scene._target.get_line_edit()
		editor.grab_focus()
		await process_frame
		editor.text = "10"
		game.fault = "wrong state" if damaged else "none"
		await _key(KEY_ENTER)
		_check(scene.viewer.is_seeking() != damaged and scene.viewer.has_failure() == damaged, "Enter preserves accepted seek or exact restore failure")
		_check(root.gui_get_focus_owner() == editor if damaged else root.gui_get_focus_owner() == null, "only accepted restoration releases editable focus")
		if damaged:
			_check(scene.viewer._player.failure_comparison() == "checkpoint_checksum", "rejected Enter retains checkpoint mismatch evidence")
		else:
			_settle()
			_check(scene.viewer.current_frame() == 10, "accepted cache restore reaches typed destination")


func _submitted_current_failure() -> void:
	for damaged: bool in [false, true]:
		scene.queue_free()
		await process_frame
		scene = Scene.instantiate()
		root.add_child(scene)
		scene.set_physics_process(false)
		var recording: RefCounted = Fixture.recording(24)
		if damaged:
			recording._checksums[0] ^= 1
		_check(scene.viewer.open_bytes(recording.to_bytes()), "open same-boundary Enter control")
		scene._refresh()
		await process_frame
		await process_frame
		var editor: LineEdit = scene._target.get_line_edit()
		editor.grab_focus()
		await process_frame
		editor.text = "0"
		await _key(KEY_ENTER)
		_check(scene.viewer.current_frame() == 0 and not scene.viewer.is_seeking(), "same-boundary Enter never consumes input")
		_check(scene.viewer.has_failure() == damaged, "same-boundary Enter validates actual current state")
		_check(root.gui_get_focus_owner() == editor if damaged else root.gui_get_focus_owner() == null, "failed current-state validation retains editable focus")
		_check(scene.viewer._player.failure_comparison() == ("state_checksum" if damaged else ""), "current-state Enter preserves exact validation evidence")


func _spectator_shortcuts() -> void:
	root.size = Vector2i(760, 560)
	var local: Node2D = SpectatorScene.new()
	root.add_child(local)
	local.set_physics_process(false)
	await process_frame
	await process_frame
	await _key(KEY_3)
	_check(local.demo.host.lag_ticks == 12, "ordinary US number row selects host delivery")
	for index: int in range(3):
		await _key(KEY_AMPERSAND, false, [KEY_1, KEY_2, KEY_3][index])
		_check(local.demo.host.lag_ticks == [0, 3, 12][index], "routed number key selects host delivery")
		_check(local.demo.host.loop.game.frame == 0 and local.demo.game.frame == 0, "routed host policy never samples either game")
		_check(root.gui_get_focus_owner() == null, "host policy shortcut preserves movement focus")
	await _key(KEY_1, true)
	_check(local.demo.host.lag_ticks == 12, "modified host delivery shortcut is refused")
	await _key(KEY_H)
	_check(local.demo.is_host_paused, "H pauses live host independently")
	for tick: int in 5:
		local._physics_process(0.0)
	_check(local.demo.host.loop.game.frame == 0, "paused host samples no new live input")
	await _click(local._pause_host_button)
	_check(not local.demo.is_host_paused, "pointer resumes host independently")
	await process_frame
	await process_frame
	var host_frame: int = local.demo.host.loop.game.frame
	await _click(local._step_host_button)
	_check(local.demo.is_host_paused and local.demo.host.loop.game.frame == host_frame + 1, "real pointer steps paused host once")
	local._physics_process(0.0)
	_check(local.demo.host.loop.game.frame == host_frame + 1, "ordinary physics preserves stepped host pause")
	await _key(KEY_T)
	_check(local.demo.is_host_paused and local.demo.host.loop.game.frame == host_frame + 2, "T steps host independently of viewer")
	await _key(KEY_H)
	await _key(KEY_H, true)
	_check(not local.demo.is_host_paused, "modified H preserves host pause state")
	local.demo.set_paused(true)
	for tick: int in range(40):
		local.demo.tick(0)
	local.demo.set_viewing_delay(0)
	_check(local.demo.viewer.begin_advance().code == ViewerTypes.Code.READY, "actual viewer request owns host policy composition")
	await _key(KEY_1)
	_check(local.demo.host.lag_ticks == 12, "routed host shortcut preserves viewer ownership")
	local.demo.viewer.terminate()
	local.demo.finish_host()
	await _key(KEY_1)
	_check(local.demo.host.lag_ticks == 12, "routed host shortcut preserves final-tail schedule")
	await _key(KEY_R)
	_check(local.demo.host.lag_ticks == 3, "routed restart restores host delivery default")
	await _key(KEY_1)
	_check(local.demo.host.lag_ticks == 0, "host delivery shortcut resumes after restart")
	local.queue_free()
	await process_frame


func _repeat_controls() -> void:
	_check(scene.viewer.open_bytes(Fixture.recording(3).to_bytes()), "open live repeat fixture")
	scene._refresh()
	await process_frame
	await process_frame
	scene._controls_view.ensure_control_visible(scene._repeat)
	scene._repeat.grab_focus()
	await _key(KEY_SPACE)
	_check(scene.viewer.repeat_playback() and scene._repeat.button_pressed, "focused Repeat has real keyboard activation")
	scene.viewer.set_playback_speed(16)
	scene.viewer.toggle_play()
	scene._physics_process(0.0)
	_check(scene.viewer.current_frame() == 3 and scene.viewer.is_playing, "repeat leaves completed state visible for one tick")
	var retired: RefCounted = scene.viewer._player
	scene._physics_process(0.0)
	_check(scene.viewer.current_frame() == 3 and scene.viewer._player != retired, "repeat creates another validated playback lifetime")
	_check(retired.step() == ViewerTypes.Code.TERMINATED and retired.failure_code() == ViewerTypes.Code.TERMINATED, "repeated playback retires original player")
	await _key(KEY_P)
	_check(not scene.viewer.is_playing, "focused repeat control preserves pause shortcut at ending")
	scene.viewer.set_repeat_playback(false)
	scene.viewer.set_playback_speed(4)


func _effects_controls() -> void:
	root.size = Vector2i(760, 560)
	var local: Node2D = EffectsScene.new()
	root.add_child(local)
	local.set_physics_process(false)
	await process_frame
	await process_frame
	_check(local._demo.tick_count == 0 and not local._is_paused, "live effects fixture starts without sampled input")
	await _click(local._pause_button)
	_check(local._is_paused, "pointer pauses live effects match")
	local._physics_process(0.0)
	_check(local._demo.tick_count == 0, "paused physics preserves service clock")
	await _key(KEY_N)
	_check(local._is_paused and local._demo.tick_count == 1, "N services exactly one paused tick")
	await _click(local._step_button)
	_check(local._is_paused and local._demo.tick_count == 2, "pointer services exactly one paused tick")
	await _key(KEY_O)
	_check(not local._is_paused, "O resumes match after pointer inspection")
	_check(local._board_top() * local.scale.y < root.size.y - 200.0 * local.scale.y, "inspection controls preserve visible effects board")
	local.queue_free()
	await process_frame


func _player_change_controls() -> void:
	_check(scene.viewer.open_bytes(InputNavigationFixture.new()._recording().to_bytes()), "player-filter recording opens")
	scene._refresh()
	await process_frame
	scene._controls_view.ensure_control_visible(scene._change_player)
	scene._change_player.grab_focus()
	await _key(KEY_SPACE)
	await _key(KEY_DOWN)
	await _key(KEY_ENTER)
	_check(scene.viewer.change_player() == 0, "real selector chooses first recorded player")
	await _click(scene._next_input_change)
	_settle()
	_check(scene.viewer.current_frame() == 450, "pointer reaches first player's control change")
	scene._refresh()
	scene._change_player.grab_focus()
	await _key(KEY_SPACE)
	await _key(KEY_DOWN)
	await _key(KEY_ENTER)
	_check(scene.viewer.change_player() == 1, "real selector chooses second recorded player")
	await _click(scene._next_input_change)
	_settle()
	_check(scene.viewer.current_frame() == 700, "player filter skips other player's status change")
	scene._refresh()
	await _click(scene._status_changes_only)
	_check(scene._next_input_change.disabled, "status-only and player filters intersect")
	await _click(scene._previous_input_change)
	_settle()
	_check(scene.viewer.current_frame() == 0, "player with no status transition returns to initial statuses")
	scene._refresh()
	_check(scene.viewer._player.begin_advance().code == ViewerTypes.Code.READY, "expert request owns selected replay")
	scene._refresh()
	_check(scene._change_player.disabled, "live selector disables during expert ownership")
	scene.viewer._player.terminate()


func _peer_controls() -> void:
	root.size = Vector2i(1040, 720)
	var local: Node2D = PeerScene.instantiate()
	root.add_child(local)
	local.set_physics_process(false)
	for tick: int in 60:
		local._physics_process(0.0)
	await process_frame
	await process_frame
	_check(not local._actions.delay_first.disabled, "peer pointer delay waits for both live peers")
	for action: String in ["loss", "latency", "reorder", "block"]:
		var before: Array = [local._match.drop_every, local._match.latency_ticks, local._match.reorder, local._match.is_partitioned]
		await _click(local._actions[action])
		var after: Array = [local._match.drop_every, local._match.latency_ticks, local._match.reorder, local._match.is_partitioned]
		_check(before != after, "real peer fault click changes " + action)
		_check(root.gui_get_focus_owner() == null, "peer pointer preserves movement focus")
	await _click(local._actions.pause)
	_check(local._is_paused, "real pointer pauses peer packet service")
	var now: int = local._match.now_us
	local._physics_process(0.0)
	_check(local._match.now_us == now, "paused peer GUI preserves packet clock")
	await _key(KEY_N)
	_check(local._match.now_us == now + local.Match.TICK_US, "routed N services one peer tick")
	await _click(local._actions.step)
	_check(local._match.now_us == now + 2 * local.Match.TICK_US, "real pointer services one peer tick")
	_check(root.gui_get_focus_owner() == null, "inspection click preserves movement focus")
	await _key(KEY_P)
	_check(not local._is_paused and local._actions.step.disabled, "routed P resumes continuous peer service")
	var before_delay: int = local._match.sessions[0].input_delay(0)
	await _click(local._actions.delay_first)
	_check(local._match.sessions[0].input_delay(0) == before_delay + 1, "real pointer raises peer input delay")
	for dimensions: Vector2i in [Vector2i(1040, 720), Vector2i(640, 360)]:
		root.size = dimensions
		await process_frame
		await process_frame
		_check(root.get_visible_rect().encloses(local._controls.get_global_rect()), "peer controls fit resized viewport")
		var arena: Rect2 = local.get_global_transform() * Rect2(Vector2(24, local._board_top()), Vector2(992, 300))
		_check(root.get_visible_rect().encloses(arena), "both peer arenas remain visible below controls")
	await _click(local._actions.reset)
	_check(
		local._match.games[0].frame == 0 and local._match.latency_ticks == 12 and not local._match.is_partitioned,
		"pointer reset starts a fresh peer match preserving fault policy"
	)
	local.queue_free()
	await process_frame


func _offline_controls() -> void:
	root.size = Vector2i(760, 560)
	var local: Node2D = OfflineScene.instantiate()
	root.add_child(local)
	local.set_physics_process(false)
	await process_frame
	await process_frame
	await _click(local._pause_button)
	_check(local._is_paused, "real pointer pauses offline driver")
	local._physics_process(0.0)
	_check(local._simulation.frame == 0, "paused offline GUI samples no input")
	await _key(KEY_N)
	_check(local._simulation.frame == 1 and local._is_paused, "routed N advances one offline frame")
	await _click(local._step_button)
	_check(local._simulation.frame == 2 and local._is_paused, "real pointer advances one offline frame")
	_check(root.gui_get_focus_owner() == null, "offline inspection preserves movement focus")
	for dimensions: Vector2i in [Vector2i(760, 560), Vector2i(640, 360)]:
		root.size = dimensions
		await process_frame
		await process_frame
		_check(root.get_visible_rect().encloses(local._controls.get_global_rect()), "offline controls fit resized viewport")
		var arena: Rect2 = local.get_global_transform() * Rect2(Vector2(24, local._board_top()), Vector2(480, 300))
		_check(root.get_visible_rect().encloses(arena), "offline arena remains visible below controls")
	await _key(KEY_P)
	_check(not local._is_paused and local._step_button.disabled, "routed P resumes offline driver")
	await _click(local._restart_button)
	_check(local._simulation.frame == 0, "real pointer restarts offline game")
	_check(root.get_visible_rect().encloses(local._label.get_global_rect()), "wrapped offline instructions fit actual viewport")
	local.queue_free()
	await process_frame
