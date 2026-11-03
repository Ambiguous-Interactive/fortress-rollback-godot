extends Node2D

const Demo = preload("res://examples/spectator/demo.gd")
const Game = preload("res://examples/integration/game.gd")
const Spectator = preload("res://addons/fortress_rollback/core/spectator_session.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const COLORS: Array[Color] = [Color.CORAL, Color.CORNFLOWER_BLUE]

const REPLAY_FILENAME: String = "fortress-spectator.frrp"
const REPLAY_WARNING_FRAMES: int = 600

var demo: Demo = Demo.new()
var _code: int = Types.Code.OK
var _replay_notice: String = ""
var _label: Label
var _follow_live_button: Button
var _pause_button: Button
var _step_button: Button
var _catchup_button: Button
var _policy_controls: HBoxContainer
var _host_controls: HBoxContainer
var _end_host_button: Button
var _lose_host_button: Button
var _restart_button: Button
var _save_replay_button: Button
var _host_delay_controls: HBoxContainer
var _pause_host_button: Button
var _step_host_button: Button
var _host_delay: OptionButton


func _ready() -> void:
	_label = Label.new()
	_label.position = Vector2(24, 20)
	_label.size.x = 712
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_label)
	_follow_live_button = Button.new()
	_follow_live_button.name = "FollowLive"
	_follow_live_button.text = "Follow live (F)"
	_follow_live_button.focus_mode = Control.FOCUS_NONE
	_follow_live_button.pressed.connect(_follow_live)
	add_child(_follow_live_button)
	_pause_button = Button.new()
	_pause_button.name = "PauseViewer"
	_pause_button.focus_mode = Control.FOCUS_NONE
	_pause_button.pressed.connect(_toggle_pause)
	add_child(_pause_button)
	_step_button = Button.new()
	_step_button.name = "StepViewer"
	_step_button.text = "Step viewer (N)"
	_step_button.focus_mode = Control.FOCUS_NONE
	_step_button.pressed.connect(_step_viewer)
	add_child(_step_button)
	_catchup_button = Button.new()
	_catchup_button.name = "CatchUpViewer"
	_catchup_button.text = "Catch up once (C)"
	_catchup_button.focus_mode = Control.FOCUS_NONE
	_catchup_button.pressed.connect(_catch_up_viewer)
	add_child(_catchup_button)
	_policy_controls = HBoxContainer.new()
	_policy_controls.name = "PlaybackPolicy"
	_policy_controls.add_theme_constant_override("separation", 12)
	add_child(_policy_controls)
	var names: PackedStringArray = PackedStringArray(["LessDelay", "MoreDelay", "SlowerCatchUp", "FasterCatchUp"])
	var labels: PackedStringArray = PackedStringArray(["Less delay ([)", "More delay (])", "Slower catch-up (,)", "Faster catch-up (.)"])
	for index: int in range(names.size()):
		var button: Button = Button.new()
		button.name = names[index]
		button.text = labels[index]
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(_adjust_policy.bind(index))
		_policy_controls.add_child(button)
	_host_controls = HBoxContainer.new()
	_host_controls.name = "HostControls"
	_host_controls.add_theme_constant_override("separation", 12)
	add_child(_host_controls)
	_end_host_button = Button.new()
	_end_host_button.name = "EndHost"
	_end_host_button.text = "End host (E)"
	_end_host_button.focus_mode = Control.FOCUS_NONE
	_end_host_button.pressed.connect(_finish_host)
	_host_controls.add_child(_end_host_button)
	_lose_host_button = Button.new()
	_lose_host_button.name = "LoseHostLink"
	_lose_host_button.text = "Lose host link (L)"
	_lose_host_button.focus_mode = Control.FOCUS_NONE
	_lose_host_button.pressed.connect(_lose_host_connection)
	_host_controls.add_child(_lose_host_button)
	_restart_button = Button.new()
	_restart_button.name = "RestartMatch"
	_restart_button.text = "Restart match (R)"
	_restart_button.focus_mode = Control.FOCUS_NONE
	_restart_button.pressed.connect(_restart)
	_host_controls.add_child(_restart_button)
	_save_replay_button = Button.new()
	_save_replay_button.name = "SaveViewedReplay"
	_save_replay_button.text = "Save viewed replay (V)"
	_save_replay_button.focus_mode = Control.FOCUS_NONE
	_save_replay_button.pressed.connect(_save_replay)
	_host_controls.add_child(_save_replay_button)
	_host_delay_controls = HBoxContainer.new()
	_host_delay_controls.name = "HostDelay"
	_host_delay_controls.add_theme_constant_override("separation", 12)
	add_child(_host_delay_controls)
	var delay_label: Label = Label.new()
	delay_label.text = "Host input delivery:"
	_host_delay_controls.add_child(delay_label)
	_host_delay = OptionButton.new()
	_host_delay.name = "Delay"
	_host_delay.focus_mode = Control.FOCUS_NONE
	for ticks: int in [0, 3, 12]:
		_host_delay.add_item("%d ticks" % ticks, ticks)
	_host_delay.item_selected.connect(_set_host_delay)
	_host_delay_controls.add_child(_host_delay)
	_pause_host_button = Button.new()
	_pause_host_button.name = "PauseHost"
	_pause_host_button.focus_mode = Control.FOCUS_NONE
	_pause_host_button.pressed.connect(_toggle_host_pause)
	_host_delay_controls.add_child(_pause_host_button)
	_step_host_button = Button.new()
	_step_host_button.name = "StepHost"
	_step_host_button.text = "Step host (T)"
	_step_host_button.focus_mode = Control.FOCUS_NONE
	_step_host_button.pressed.connect(_step_host)
	_host_delay_controls.add_child(_step_host_button)
	_code = demo.start()
	_update_label()


func _exit_tree() -> void:
	if demo.viewer != null:
		demo.viewer.terminate()
	if demo.host != null:
		demo.host.loop.session.terminate()
		demo.host.stop_replay()


func _physics_process(_delta: float) -> void:
	if _code not in [Types.Code.OK, Types.Code.PREDICTION_STALL, Types.Code.BUSY]:
		return
	_code = demo.tick(_host_buttons())
	_update_label()


func _host_buttons() -> int:
	var buttons: int = 0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		buttons |= Game.LEFT
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		buttons |= Game.RIGHT
	if Input.is_physical_key_pressed(KEY_SPACE):
		buttons |= Game.FIRE
	return buttons


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.alt_pressed or event.ctrl_pressed or event.meta_pressed or event.shift_pressed:
		return
	var number_key: Key = event.physical_keycode if event.physical_keycode != KEY_NONE else event.keycode
	if number_key in [KEY_1, KEY_2, KEY_3]:
		_set_host_delay([KEY_1, KEY_2, KEY_3].find(number_key))
	elif event.keycode == KEY_H:
		_toggle_host_pause()
	elif event.keycode == KEY_T:
		_step_host()
	elif event.keycode == KEY_P:
		_toggle_pause()
	elif event.keycode == KEY_N:
		_step_viewer()
	elif event.keycode == KEY_C:
		_catch_up_viewer()
	elif event.keycode == KEY_F:
		_follow_live()
	elif event.keycode in [KEY_BRACKETLEFT, KEY_BRACKETRIGHT] and demo.viewer != null:
		_adjust_policy(0 if event.keycode == KEY_BRACKETLEFT else 1)
	elif event.keycode in [KEY_COMMA, KEY_PERIOD] and demo.viewer != null:
		_adjust_policy(2 if event.keycode == KEY_COMMA else 3)
	elif event.keycode == KEY_L:
		_lose_host_connection()
	elif event.keycode == KEY_E:
		_finish_host()
	elif event.keycode == KEY_V:
		_save_replay()
	elif event.keycode == KEY_R:
		_restart()
	_update_label()


func _finish_host() -> void:
	demo.finish_host()
	_update_label()


func _lose_host_connection() -> void:
	demo.lose_host_connection()
	_update_label()


func _restart() -> void:
	_code = demo.start()
	if _code == Types.Code.OK:
		_replay_notice = ""
	_update_label()


func _toggle_host_pause() -> void:
	demo.set_host_paused(not demo.is_host_paused)
	_update_label()


func _step_host() -> void:
	demo.step_host(_host_buttons())
	_update_label()


func _toggle_pause() -> void:
	demo.set_paused(not demo.is_paused)
	_update_label()


func _step_viewer() -> void:
	demo.step_viewer()
	_update_label()


func _catch_up_viewer() -> void:
	demo.catch_up_viewer()
	_update_label()


func _follow_live() -> void:
	demo.follow_live()
	_update_label()


func _save_replay() -> void:
	if not _can_export_replay():
		return
	_export_replay()
	_update_label()


func _can_export_replay() -> bool:
	if demo.viewer == null or demo._mutation_code() == Types.Code.BUSY:
		return false
	var recording: Types.RecordingStatus = demo.viewer.recording_status()
	if recording.capacity_frames == 0:
		return false
	if recording.finalized_frames > 0 or demo.viewer.status().lifecycle != Types.Lifecycle.TERMINATED:
		return true
	var retained: RefCounted = demo.driver.replay()
	return retained != null and not retained.checksum(0).is_empty()


func _adjust_policy(action: int) -> void:
	if demo.viewer == null:
		return
	var policy: PackedInt64Array = demo.viewer.playback_policy()
	var change: int = -1 if action in [0, 2] else 1
	if action < 2:
		demo.set_viewing_delay(policy[0] + change)
	else:
		demo.set_catchup_speed(policy[2] + change)
	_update_label()


func _set_host_delay(index: int) -> void:
	if _can_set_host_delay() and index >= 0 and index < _host_delay.item_count:
		demo.host.set_lag(_host_delay.get_item_id(index))
	_update_label()


func _can_set_host_delay() -> bool:
	return (
		demo.host != null
		and demo._mutation_code() != Types.Code.BUSY
		and not demo.is_finishing
		and not demo.is_host_finished
		and demo.host.loop.session.status().lifecycle != Types.Lifecycle.TERMINATED
	)


func _process(_delta: float) -> void:
	var size: Vector2 = get_viewport_rect().size
	var content_height: float = _board_top() + 150.0 + 125.0 + 24.0
	var fit: float = minf(size.x / 760.0, size.y / maxf(560.0, content_height))
	scale = Vector2(fit, fit)
	queue_redraw()


func _update_label() -> void:
	_host_delay.disabled = not _can_set_host_delay()
	_pause_host_button.disabled = _host_delay.disabled
	_step_host_button.disabled = _host_delay.disabled or (demo.host != null and demo.host.replay_player != null)
	_pause_host_button.text = "Resume host (H)" if demo.is_host_paused else "Pause host (H)"
	if demo.host != null:
		_host_delay.select(_host_delay.get_item_index(demo.host.lag_ticks))
	_restart_button.disabled = demo._mutation_code() == Types.Code.BUSY
	_save_replay_button.disabled = not _can_export_replay()
	_end_host_button.disabled = (_restart_button.disabled or demo.host == null or demo.is_finishing or demo.host.loop.session.status().lifecycle == Types.Lifecycle.TERMINATED)
	_lose_host_button.disabled = demo.viewer == null or demo.viewer.status().lifecycle == Types.Lifecycle.TERMINATED
	_follow_live_button.disabled = demo.viewer == null or demo._mutation_code() == Types.Code.BUSY or demo.viewer._mutation_code() != Types.Code.OK
	_pause_button.disabled = _follow_live_button.disabled
	_step_button.disabled = _follow_live_button.disabled
	_catchup_button.disabled = _follow_live_button.disabled
	_pause_button.text = "Resume viewer (P)" if demo.is_paused else "Pause viewer (P)"
	for button: Button in _policy_controls.get_children():
		button.disabled = _follow_live_button.disabled
	if demo.host == null or demo.viewer == null:
		_label.text = "Could not start: code %d" % _code
		return
	var state: String = "PAUSED" if demo.is_paused else "WATCHING"
	var policy: PackedInt64Array = demo.viewer.playback_policy()
	var playback: Dictionary = demo.viewer.playback_status()
	var limits: PackedInt64Array = PackedInt64Array([0, playback.capacity_frames - 1, 1, playback.capacity_frames])
	for index: int in range(4):
		var button: Button = _policy_controls.get_child(index)
		button.disabled = button.disabled or policy[0 if index < 2 else 2] == limits[index]
	if not demo.is_paused:
		if playback.state == Spectator.PlaybackState.WAITING_FOR_INPUT:
			state = "BUFFERING | waiting for confirmed input"
		elif playback.state == Spectator.PlaybackState.DELAYED:
			state = ("BUFFERING" if demo.game.frame == 0 else "WATCHING") + " | viewing delay (%d confirmed frames buffered)" % playback.buffered_frames
		if playback.missing_frame >= 0 and playback.playable_frames == 0:
			var later: int = playback.pending_frames - playback.buffered_frames
			state = "BUFFERING | waiting for confirmed frame %d (%d later frame%s received)" % [playback.missing_frame, later, "" if later == 1 else "s"]
	if demo.is_finishing:
		state = "CONFIRMING FINAL INPUTS"
		if demo.is_host_finished:
			state = "FINAL TAIL PAUSED | P: resume or N: step" if demo.is_paused else "DRAINING FINAL TAIL"
	var status: Types.Status = demo.viewer.status()
	if status.lifecycle == Types.Lifecycle.TERMINATED:
		state = "COMPLETE | R: start again" if demo.viewer.is_complete() else "STOPPED: %s | R: start again" % _stop_reason(status)
		if status.reason == Types.Code.HISTORY_UNAVAILABLE:
			state = "HISTORY UNAVAILABLE | R: start again"
	if demo.is_host_connection_lost:
		state = "HOST CONNECTION LOST | R: start again"
	var buffer_notice: String = ""
	if demo.is_paused and status.lifecycle != Types.Lifecycle.TERMINATED and not playback.input_closed and playback.available_frames == 0:
		buffer_notice = "Input buffer full. P: resume or C: catch up to receive more.\n"
	_label.text = (
		"Delayed spectator | %s\n" % state
		+ "A/D or arrows: move host | Space: fire\nP: pause viewer | N: step viewer | C: catch up once\nF: follow live\n"
		+ "1/2/3: host delivery 0/3/12 ticks | H: pause/resume host | T: step host\n"
		+ "E: end host\n[: less delay | ]: more delay\nComma: slower catch-up | Period: faster catch-up\n"
		+ "L: lose host link | V: save viewed replay | R: restart\n"
		+ (
			"Host frame %d | Confirmed %d | Viewer frame %d | Host delivery %d ticks\n\n"
			% [demo.host.loop.game.frame, demo.host.loop.session.status().confirmed_frame, demo.game.frame, demo.host.lag_ticks]
		)
		+ ("Host paused. Outstanding inputs still confirm; viewer can catch up.\n" if demo.is_host_paused and not demo.is_finishing else "")
		+ "Viewer holds %d confirmed frames and catches up at most %d per tick.\n" % [policy[0], policy[2]]
		+ "Buffered %d confirmed frames | Later rows %d\n" % [playback.buffered_frames, playback.pending_frames - playback.buffered_frames]
		+ buffer_notice
		+ _recording_feedback()
		+ "A long viewer pause can exceed retained history while the host runs.\n"
		+ "Two local views. Live spectator networking is not connected."
		+ ("\n" + _replay_notice if not _replay_notice.is_empty() else "")
	)

	_follow_live_button.position = Vector2(24, _label.position.y + _label.get_minimum_size().y + 8)
	_pause_button.position = _follow_live_button.position + Vector2(_follow_live_button.get_minimum_size().x + 12, 0)
	_step_button.position = _pause_button.position + Vector2(_pause_button.get_minimum_size().x + 12, 0)
	_catchup_button.position = _step_button.position + Vector2(_step_button.get_minimum_size().x + 12, 0)
	_policy_controls.position = _follow_live_button.position + Vector2(0, _follow_live_button.get_minimum_size().y + 8)
	_host_controls.position = _policy_controls.position + Vector2(0, _policy_controls.get_minimum_size().y + 8)
	_host_delay_controls.position = _host_controls.position + Vector2(0, _host_controls.get_minimum_size().y + 8)


func _stop_reason(status: Types.Status) -> String:
	if status.reason in [Types.Code.CALLBACK_FAILED, Types.Code.SNAPSHOT_FAILED]:
		var operations: Dictionary = {Types.Kind.SAVE: "saving state", Types.Kind.LOAD: "loading state", Types.Kind.ADVANCE: "simulating input"}
		var text: String = "failed while " + operations.get(status.failure_kind, "processing game state")
		if status.failure_frame >= 0:
			text += " at frame %d" % status.failure_frame
		return text
	var reasons: Dictionary = {
		Types.Code.PROTOCOL_FAILED: "host stream failed",
		Types.Code.TERMINATED: "viewing canceled",
		Types.Code.FRAME_EXHAUSTED: "frame limit reached",
		Types.Code.DESYNC: "state checksum mismatch",
		Types.Code.INPUT_FAILED: "confirmed input failed",
		Types.Code.STALE_REQUEST: "playback request expired",
		Types.Code.EXPIRED_VIEW: "playback request expired",
	}
	return reasons.get(status.reason, "code %d" % status.reason)


func _recording_feedback() -> String:
	var recording: Types.RecordingStatus = demo.viewer.recording_status()
	if recording.capacity_frames == 0:
		return "Viewed replay recording is disabled.\n"
	var text: String = "Viewed replay: %d/%d frames recorded" % [recording.finalized_frames, recording.capacity_frames]
	if recording.omitted_frames > 0:
		return text + " | %d later viewed frames omitted.\nSaved replay ends before the displayed state.\n" % recording.omitted_frames
	text += "\n"
	if demo.viewer.status().lifecycle != Types.Lifecycle.TERMINATED:
		var remaining: int = recording.capacity_frames - recording.finalized_frames - recording.pending_frames
		if remaining == 0:
			text += "Replay limit reached. Save now to include the displayed state.\n"
		elif remaining <= REPLAY_WARNING_FRAMES:
			text += "Replay limit in %d viewed frames.\n" % remaining
	return text


func _export_replay() -> void:
	var bytes: PackedByteArray = demo.replay_bytes()
	if bytes.is_empty():
		_replay_notice = "No viewed replay is available, or playback is busy."
		return
	if OS.has_feature("web"):
		JavaScriptBridge.download_buffer(bytes, REPLAY_FILENAME, "application/octet-stream")
		_replay_notice = "Replay download requested: " + REPLAY_FILENAME
	else:
		var path: String = "user://" + REPLAY_FILENAME
		var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			_replay_notice = "Could not save replay (%d)." % FileAccess.get_open_error()
			return
		file.store_buffer(bytes)
		file.flush()
		_replay_notice = "Replay saved: " + ProjectSettings.globalize_path(path) if file.get_error() == OK else "Could not write replay."


func _board_top() -> float:
	return _host_delay_controls.position.y + _host_delay_controls.get_minimum_size().y + 16.0


func _draw() -> void:
	if demo.game == null:
		return
	var games: Array[Game] = [demo.host.loop.game, demo.game]
	for panel: int in range(2):
		var top: float = _board_top() + 30.0 + panel * 150
		draw_rect(Rect2(24, top - 30, 712, 125), Color(0.08, 0.10, 0.15))
		draw_string(ThemeDB.fallback_font, Vector2(36, top), "HOST" if panel == 0 else "VIEWER", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)
		for player: int in range(2):
			var position: Vector2 = Vector2(120 + games[panel].x[player] * 1.35, top + 26 + player * 35)
			draw_circle(position, 11, COLORS[player])
			for index: int in range(maxi(0, games[panel].shot_total - Game.SHOT_SLOTS), games[panel].shot_total):
				var id: int = games[panel].shot_ids[index % Game.SHOT_SLOTS]
				if Game.shot_player(id) == player and games[panel].frame - Game.shot_frame(id) <= 6:
					draw_arc(position, 21, 0, TAU, 24, COLORS[player], 2)
