extends Node2D

const Viewer = preload("res://examples/online/replay_viewer.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const COLORS: Array[Color] = [Color.CORAL, Color.CORNFLOWER_BLUE, Color.GOLD, Color.MEDIUM_SEA_GREEN]
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
      if (file.size > 1048576) { this.dispose(); callback('', 'Replay exceeds the 1 MiB limit.'); return; }
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

var viewer: Viewer = Viewer.new()
var _status: Label
var _play: Button
var _step_button: Button
var _restart_button: Button
var _dialog: FileDialog
var _web_import: JavaScriptObject
var _web_callback: JavaScriptObject


func _ready() -> void:
	var panel: VBoxContainer = VBoxContainer.new()
	panel.position = Vector2(24, 16)
	panel.custom_minimum_size = Vector2(680, 0)
	add_child(panel)
	var title: Label = Label.new()
	title.text = "Watch an online recording | no server required"
	panel.add_child(title)
	var buttons: HBoxContainer = HBoxContainer.new()
	panel.add_child(buttons)
	_button(buttons, "Open replay", _open)
	_play = _button(buttons, "Play", _toggle)
	_step_button = _button(buttons, "Step", _step)
	_restart_button = _button(buttons, "Restart", _restart)
	_button(buttons, "Back to online", _back)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(_status)
	if OS.has_feature("web"):
		JavaScriptBridge.eval(WEB_IMPORT, true)
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


func _native_file(path: String) -> void:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		viewer.message = "Could not open the replay file."
	elif file.get_length() > Viewer.MAX_BYTES:
		viewer.message = "Replay exceeds the 1 MiB limit."
	else:
		viewer.open_bytes(file.get_buffer(file.get_length()))
	_refresh()


func _web_file(arguments: Array) -> void:
	if not str(arguments[1]).is_empty():
		viewer.message = str(arguments[1])
	else:
		viewer.open_bytes(Marshalls.base64_to_raw(str(arguments[0])))
	_refresh()


func _toggle() -> void:
	viewer.toggle_play()
	_refresh()


func _step() -> void:
	viewer.is_playing = false
	viewer.step()
	_refresh()


func _restart() -> void:
	viewer.restart()
	_refresh()


func _back() -> void:
	get_tree().change_scene_to_file("res://examples/online/online.tscn")


func _exit_tree() -> void:
	if _web_import != null:
		_web_import.dispose()


func _physics_process(_delta: float) -> void:
	viewer.tick()
	_refresh()


func _refresh() -> void:
	_status.text = "%s\nFrame %d / %d" % [viewer.message, viewer.current_frame(), viewer.frame_count()]
	_play.text = "Pause" if viewer.is_playing else "Play"
	_play.disabled = viewer.frame_count() == 0 or viewer.current_frame() >= viewer.frame_count()
	_step_button.disabled = _play.disabled
	_restart_button.disabled = viewer.frame_count() == 0
	queue_redraw()


func _draw() -> void:
	var origin: Vector2 = Vector2(24, 150)
	var available: Vector2 = get_viewport_rect().size - origin - Vector2(16, 16)
	var fit: float = clampf(minf(available.x / 480.0, available.y / 300.0), 0.1, 1.0)
	draw_set_transform(origin, 0.0, Vector2.ONE * fit)
	draw_rect(Rect2(Vector2.ZERO, Vector2(480, 300)), Color(0.08, 0.10, 0.15))
	for slot: int in 2:
		var position: Vector2 = Vector2(viewer.game.x[slot], viewer.game.y[slot])
		var tint: Color = COLORS[viewer.game.color[slot]]
		draw_circle(position, 12, tint)
		draw_string(ThemeDB.fallback_font, position + Vector2(-4, 5), str(slot + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.BLACK)
