extends Node2D

const Viewer = preload("res://examples/online/replay_viewer.gd")
const IntegrationGame = preload("res://examples/integration/game.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const COLORS: Array[Color] = [Color.CORAL, Color.CORNFLOWER_BLUE, Color.GOLD, Color.MEDIUM_SEA_GREEN]
const FAILURE_FILENAME: String = "fortress-replay-failure.json"
const WEB_IMPORT: String = """
window.fortressReplayImport = {
  input: null, reader: null,
  choose: function(callback) {
    this.dispose();
    const input = document.createElement('input');
    input.type = 'file'; input.accept = '.frrp';
    this.input = input;
    input.onchange = () => {
      const file = input.files[0];
      if (!file) { this.dispose(); return; }
      if (file.size > %d) { this.dispose(); callback('', %s); return; }
      const reader = new FileReader(); this.reader = reader;
      reader.onerror = () => { this.dispose(); callback('', 'Could not read the replay file.'); };
      reader.onload = () => {
        const encoded = String(reader.result).split(',')[1];
        this.dispose(); callback(encoded, '');
      };
      reader.readAsDataURL(file);
    };
    input.oncancel = () => this.dispose();
    input.style.display = 'none'; document.body.appendChild(input); input.click();
  },
  dispose: function() {
    if (this.reader) { this.reader.onload = null; this.reader.onerror = null; this.reader.abort(); this.reader = null; }
    if (this.input) { this.input.onchange = null; this.input.oncancel = null; this.input.remove(); this.input = null; }
  }
};
"""


class MetadataLabel:
	extends Label

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_PASS

	func _make_custom_tooltip(text: String) -> Object:
		var tooltip: Label = Label.new()
		tooltip.text = text
		tooltip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		tooltip.custom_minimum_size.x = 560.0
		if is_inside_tree():
			tooltip.custom_minimum_size.x = minf(560.0, maxf(1.0, get_viewport_rect().size.x - 32.0))
		return tooltip


var viewer: Viewer = Viewer.new()
var _panel: VBoxContainer
var _status: Label
var _recording_metadata: Label
var _play: Button
var _step_button: Button
var _validate_button: Button
var _back_button: Button
var _previous_checkpoint: Button
var _next_checkpoint: Button
var _previous_input_change: Button
var _next_input_change: Button
var _previous_recorded_checksum: Button
var _next_recorded_checksum: Button
var _failure_download: Button
var _failure_notice: String = ""
var _prefix_download: Button
var _prefix_notice: String = ""
var _prefix_frame: int = -1
var _prefix_game: RefCounted
var _restart_button: Button
var _speed: OptionButton
var _target: SpinBox
var _seek_button: Button
var _cancel_button: Button
var _timeline: HSlider
var _timeline_label: Label
var _is_scrubbing: bool = false
var _dialog: FileDialog
var _web_import: JavaScriptObject
var _web_callback: JavaScriptObject
var _drop_window: Window


func _enter_tree() -> void:
	if not OS.has_feature("web"):
		_drop_window = get_window()
		_drop_window.files_dropped.connect(_files_dropped)


func _ready() -> void:
	var panel: VBoxContainer = VBoxContainer.new()
	_panel = panel
	panel.position = Vector2(24, 16)
	panel.custom_minimum_size = Vector2(680, 0)
	add_child(panel)
	var title: Label = Label.new()
	title.text = "Watch an online or spectator recording | no server required"
	panel.add_child(title)
	_recording_metadata = MetadataLabel.new()
	_recording_metadata.name = "RecordingMetadata"
	_recording_metadata.clip_text = true
	_recording_metadata.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	panel.add_child(_recording_metadata)
	var shortcuts: Label = Label.new()
	shortcuts.text = "P play/pause | N next frame | B back one frame | R restart | Esc cancel seek"
	panel.add_child(shortcuts)
	var buttons: HBoxContainer = HBoxContainer.new()
	panel.add_child(buttons)
	_button(buttons, "Open replay", _open)
	_play = _button(buttons, "Play", _toggle)
	_step_button = _button(buttons, "Step", _step)
	_restart_button = _button(buttons, "Restart", _restart)
	_button(buttons, "Back to online", _back)
	var speed_caption: Label = Label.new()
	speed_caption.text = "Speed:"
	buttons.add_child(speed_caption)
	_speed = OptionButton.new()
	_speed.name = "PlaybackSpeed"
	for caption: String in ["¼×", "½×", "1×", "2×", "4×"]:
		_speed.add_item(caption)
	_speed.select(2)
	_speed.item_selected.connect(_speed_selected)
	buttons.add_child(_speed)
	var navigation: HBoxContainer = HBoxContainer.new()
	panel.add_child(navigation)
	_back_button = _button(navigation, "Back one frame", _back_one_frame)
	var caption: Label = Label.new()
	caption.text = "Go to frame:"
	navigation.add_child(caption)
	_target = SpinBox.new()
	_target.step = 1
	_target.custom_minimum_size.x = 130
	navigation.add_child(_target)
	_seek_button = _button(navigation, "Go", _seek)
	_cancel_button = _button(navigation, "Cancel seek", _cancel_seek)
	var checkpoints: HBoxContainer = HBoxContainer.new()
	panel.add_child(checkpoints)
	_previous_checkpoint = _button(checkpoints, "Previous checkpoint", _jump_checkpoint.bind(false))
	_next_checkpoint = _button(checkpoints, "Next checkpoint", _jump_checkpoint.bind(true))
	var exports: HBoxContainer = HBoxContainer.new()
	panel.add_child(exports)
	_failure_download = _button(exports, "Download failure", _download_failure)
	_prefix_download = _button(exports, "Download prefix", _download_prefix)
	_validate_button = _button(exports, "Validate state", _validate_state)
	_validate_button.tooltip_text = "Check available recorded evidence at this paused frame without consuming input. Missing checksums remain unverified."
	_prefix_download.tooltip_text = "Save original inputs before the displayed frame, preserving recorded checksum evidence."
	var changes: HBoxContainer = HBoxContainer.new()
	panel.add_child(changes)
	_previous_input_change = _button(changes, "Previous input change", _jump_input_change.bind(false))
	_next_input_change = _button(changes, "Next input change", _jump_input_change.bind(true))
	var checksums: HBoxContainer = HBoxContainer.new()
	panel.add_child(checksums)
	_previous_recorded_checksum = _button(checksums, "Previous recorded checksum", _jump_recorded_checksum.bind(false))
	_next_recorded_checksum = _button(checksums, "Next recorded checksum", _jump_recorded_checksum.bind(true))
	var timeline_row: HBoxContainer = HBoxContainer.new()
	panel.add_child(timeline_row)
	_timeline = HSlider.new()
	_timeline.name = "ReplayTimeline"
	_timeline.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_timeline.tooltip_text = "Drag to choose a recorded moment; release to navigate and pause."
	_timeline.step = 1
	_timeline.value_changed.connect(_timeline_changed)
	_timeline.drag_started.connect(_timeline_drag_started)
	_timeline.drag_ended.connect(_timeline_drag_ended)
	timeline_row.add_child(_timeline)
	_timeline_label = Label.new()
	timeline_row.add_child(_timeline_label)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(_status)
	if OS.has_feature("web"):
		JavaScriptBridge.eval(WEB_IMPORT % [Viewer.MAX_BYTES, JSON.stringify(Viewer.FILE_SIZE_MESSAGE)], true)
		_web_import = JavaScriptBridge.get_interface("fortressReplayImport")
		_web_callback = JavaScriptBridge.create_callback(_web_file)
	else:
		_dialog = FileDialog.new()
		_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_dialog.filters = PackedStringArray(["*.frrp ; Fortress replay"])
		_dialog.file_selected.connect(_native_file)
		add_child(_dialog)
	_refresh()


func _button(parent: Node, caption: String, callback: Callable) -> Button:
	var button: Button = Button.new()
	button.text = caption
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


func _open() -> void:
	if OS.has_feature("web"):
		_web_import.choose(_web_callback)
	else:
		_dialog.popup_centered_ratio(0.8)


## Native file drops share the chooser's bounded decoder and preserve active game work.
func _files_dropped(paths: PackedStringArray) -> void:
	if _is_scrubbing or viewer._is_busy():
		return
	if paths.size() != 1:
		viewer.message = "Drop one replay file at a time."
		_refresh()
		return
	_native_file(paths[0])


func _native_file(path: String) -> void:
	if _is_scrubbing or viewer._is_busy():
		return
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	var length: int = file.get_length() if file != null else 0
	if file == null:
		viewer.message = "Could not open the replay file."
	elif length > Viewer.MAX_BYTES:
		viewer.message = Viewer.FILE_SIZE_MESSAGE
	else:
		viewer.open_bytes(file.get_buffer(length))
	_refresh()


func _web_file(arguments: Array) -> void:
	if _is_scrubbing or viewer._is_busy():
		return
	if not str(arguments[1]).is_empty():
		viewer.message = str(arguments[1])
	else:
		viewer.open_bytes(Marshalls.base64_to_raw(str(arguments[0])))
	_refresh()


func _toggle() -> void:
	if _is_scrubbing:
		return
	viewer.toggle_play()
	_refresh()


func _step() -> void:
	if _is_scrubbing:
		return
	if viewer.is_playing:
		viewer.toggle_play()
	viewer.step()
	_refresh()


func _validate_state() -> void:
	if _is_scrubbing:
		return
	viewer.validate_state()
	_refresh()


func _speed_selected(index: int) -> void:
	if _is_scrubbing:
		return
	viewer.set_playback_speed([1, 2, 4, 8, 16][index])
	_refresh()


func _back_one_frame() -> void:
	if _is_scrubbing:
		return
	viewer.step_back()
	_refresh()


func _seek() -> void:
	if _is_scrubbing:
		return
	_target.apply()
	viewer.seek(int(_target.value))
	_refresh()


func _timeline_drag_started() -> void:
	if viewer._is_busy() or viewer.frame_count() == 0:
		return
	_is_scrubbing = true
	if viewer.is_seeking():
		viewer.cancel_seek()
	if viewer.is_playing:
		viewer.toggle_play()
	_refresh()


func _timeline_drag_ended(changed: bool) -> void:
	if not _is_scrubbing:
		return
	_is_scrubbing = false
	if viewer._is_busy():
		return
	if viewer.is_playing:
		viewer.toggle_play()
	if changed:
		viewer.seek(int(_timeline.value))
	_refresh()


func _timeline_changed(value: float) -> void:
	if not _is_scrubbing:
		viewer.seek(int(value))
		_refresh()


func _time_label(frame: int) -> String:
	@warning_ignore("integer_division")
	var seconds: int = frame / 60
	@warning_ignore("integer_division")
	return "%d:%02d" % [seconds / 60, seconds % 60]


func _cancel_seek() -> void:
	if _is_scrubbing:
		return
	viewer.cancel_seek()
	_refresh()


func _jump_checkpoint(forward: bool) -> void:
	if _is_scrubbing:
		return
	viewer.seek_checkpoint(forward)
	_refresh()


func _jump_input_change(forward: bool) -> void:
	if _is_scrubbing:
		return
	viewer.seek_input_change(forward)
	_refresh()


func _jump_recorded_checksum(forward: bool) -> void:
	if _is_scrubbing:
		return
	viewer.seek_recorded_checksum(forward)
	_refresh()


func _restart() -> void:
	if _is_scrubbing:
		return
	viewer.restart()
	_refresh()


func _back() -> void:
	get_tree().change_scene_to_file("res://examples/online/online.tscn")


func _exit_tree() -> void:
	viewer.terminate()
	if is_instance_valid(_drop_window):
		_drop_window.files_dropped.disconnect(_files_dropped)
		_drop_window = null
	if _web_import != null:
		_web_import.dispose()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo or event.alt_pressed or event.ctrl_pressed or event.meta_pressed or event.shift_pressed:
		return
	if _dialog != null and _dialog.visible:
		return
	if is_inside_tree():
		var focused: Control = get_viewport().gui_get_focus_owner()
		if focused is LineEdit or focused is TextEdit:
			return
	var action: Button
	match event.keycode:
		KEY_P:
			action = _play
		KEY_N:
			action = _step_button
		KEY_B:
			action = _back_button
		KEY_R:
			action = _restart_button
		KEY_ESCAPE:
			action = _cancel_button
	if action != null and not action.disabled:
		action.pressed.emit()
		if is_inside_tree():
			get_viewport().set_input_as_handled()


func _physics_process(_delta: float) -> void:
	if not _is_scrubbing:
		viewer.tick()
	_refresh()


func _refresh() -> void:
	_recording_metadata.text = viewer.recording_summary()
	_recording_metadata.tooltip_text = viewer.recording_details()
	if viewer.current_frame() != _prefix_frame or viewer.game != _prefix_game:
		_prefix_notice = ""
		_prefix_game = null
	if not viewer.has_failure():
		_failure_notice = ""
	_status.text = (
		"%s\nFrame %d / %d | Checksums checked: %d / %d recorded"
		% [viewer.message, viewer.current_frame(), viewer.frame_count(), viewer.checked_checksum_count(), viewer.recorded_checksum_count()]
	)
	_status.text += "\n" + viewer.current_state_coverage_message()
	_status.text += "\n" + viewer.input_summary()
	if not _failure_notice.is_empty():
		_status.text += "\n" + _failure_notice
	if not _prefix_notice.is_empty():
		_status.text += "\n" + _prefix_notice
	_failure_download.disabled = not viewer.has_failure()
	_prefix_download.disabled = _is_scrubbing or not viewer.can_export_prefix()
	_play.text = "Pause" if viewer.is_playing else "Play"
	_play.disabled = _is_scrubbing or viewer.is_seeking() or not viewer.can_step()
	_step_button.disabled = _play.disabled
	_validate_button.disabled = _is_scrubbing or not viewer.can_validate_state()
	_back_button.disabled = _is_scrubbing or viewer.is_seeking() or viewer.current_frame() == 0
	_restart_button.disabled = _is_scrubbing or (viewer.frame_count() == 0 and viewer.recorded_checksum_count() == 0)
	_speed.disabled = _is_scrubbing
	_timeline.set_block_signals(true)
	_timeline.max_value = viewer.frame_count()
	if not _is_scrubbing:
		_timeline.value = viewer.current_frame()
	_timeline.set_block_signals(false)
	_timeline.editable = _is_scrubbing or (viewer.frame_count() > 0 and not viewer._is_busy())
	_timeline_label.text = "%s / %s" % [_time_label(viewer.current_frame()), _time_label(viewer.frame_count())]
	_target.max_value = viewer.frame_count()
	_target.editable = not _is_scrubbing and viewer.frame_count() > 0
	_seek_button.disabled = _is_scrubbing or viewer.frame_count() == 0
	_cancel_button.disabled = _is_scrubbing or not viewer.is_seeking()
	_previous_checkpoint.disabled = _is_scrubbing or viewer.checkpoint_target(false) < 0
	_next_checkpoint.disabled = _is_scrubbing or viewer.checkpoint_target(true) < 0
	_previous_input_change.disabled = _is_scrubbing or viewer.input_change_target(false) < 0
	_next_input_change.disabled = _is_scrubbing or viewer.input_change_target(true) < 0
	_previous_recorded_checksum.disabled = _is_scrubbing or viewer.recorded_checksum_target(false) < 0
	_next_recorded_checksum.disabled = _is_scrubbing or viewer.recorded_checksum_target(true) < 0
	queue_redraw()


func _draw() -> void:
	var origin: Vector2 = Vector2(24, maxf(225.0, _panel.position.y + _panel.size.y + 16.0))
	var available: Vector2 = get_viewport_rect().size - origin - Vector2(16, 16)
	var fit: float = clampf(minf(available.x / 480.0, available.y / 300.0), 0.1, 1.0)
	draw_set_transform(origin, 0.0, Vector2.ONE * fit)
	draw_rect(Rect2(Vector2.ZERO, Vector2(480, 300)), Color(0.08, 0.10, 0.15))
	if viewer.is_integration_game():
		_draw_integration_game(viewer.game)
	else:
		var game: Simulation = viewer.game
		for slot: int in 2:
			var position: Vector2 = Vector2(game.x[slot], game.y[slot])
			var tint: Color = COLORS[game.color[slot]]
			draw_circle(position, 12, tint)
			draw_string(ThemeDB.fallback_font, position + Vector2(-4, 5), str(slot + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.BLACK)


func _draw_integration_game(game: IntegrationGame) -> void:
	for slot: int in 2:
		var position: Vector2 = Vector2(40 + game.x[slot], 100 + slot * 70)
		draw_circle(position, 12, COLORS[slot])
		draw_string(ThemeDB.fallback_font, position + Vector2(-4, 5), str(slot + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.BLACK)
		for index: int in range(maxi(0, game.shot_total - IntegrationGame.SHOT_SLOTS), game.shot_total):
			var id: int = game.shot_ids[index % IntegrationGame.SHOT_SLOTS]
			if IntegrationGame.shot_player(id) == slot and game.frame - IntegrationGame.shot_frame(id) <= 6:
				draw_arc(position, 21, 0, TAU, 24, COLORS[slot], 2)


func _download_failure() -> void:
	var bytes: PackedByteArray = viewer.failure_report_bytes()
	if bytes.is_empty():
		return
	if OS.has_feature("web"):
		JavaScriptBridge.download_buffer(bytes, FAILURE_FILENAME, "application/json")
		_failure_notice = "Failure report download requested. Keep the original replay file with it."
	else:
		var path: String = "user://" + FAILURE_FILENAME
		var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			_failure_notice = "Could not save the failure report."
		else:
			file.store_buffer(bytes)
			var saved: bool = file.get_error() == OK
			file.close()
			_failure_notice = "Failure report saved: " + ProjectSettings.globalize_path(path) if saved else "Could not save the failure report."
	_refresh()


func _download_prefix() -> void:
	if _is_scrubbing:
		return
	var bytes: PackedByteArray = viewer.prefix_bytes()
	if bytes.is_empty():
		return
	var frame: int = viewer.current_frame()
	var filename: String = viewer.prefix_filename()
	_prefix_frame = frame
	_prefix_game = viewer.game
	if OS.has_feature("web"):
		JavaScriptBridge.download_buffer(bytes, filename, "application/octet-stream")
		_prefix_notice = "Prefix download requested: original inputs before frame %d." % frame
	else:
		var path: String = "user://" + filename
		var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			_prefix_notice = "Could not save the replay prefix."
		else:
			file.store_buffer(bytes)
			var saved: bool = file.get_error() == OK
			file.close()
			_prefix_notice = "Prefix saved: " + ProjectSettings.globalize_path(path) if saved else "Could not save the replay prefix."
	_refresh()
