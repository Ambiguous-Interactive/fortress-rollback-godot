extends Node2D

const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Presentation = preload("res://examples/offline/presentation.gd")
const COLORS: Array[Color] = [Color.CORAL, Color.CORNFLOWER_BLUE, Color.GOLD, Color.MEDIUM_SEA_GREEN]

var _session: Session = Session.new()
var _simulation: Simulation = Simulation.new()
var _presentation: Presentation = Presentation.new()
var _driver: Driver
var _label: Label
var _code: int = Types.Code.OK
var _is_paused: bool = false
var _controls: HBoxContainer
var _pause_button: Button
var _step_button: Button
var _restart_button: Button
var _previous_positions: Array[Vector2] = [Vector2(120, 160), Vector2(360, 160)]
var _current_positions: Array[Vector2] = [Vector2(120, 160), Vector2(360, 160)]


func _ready() -> void:
	_label = Label.new()
	_label.position = Vector2(24, 24)
	_label.size.x = 504
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_label)
	_controls = HBoxContainer.new()
	_controls.name = "OfflineControls"
	_controls.add_theme_constant_override("separation", 12)
	add_child(_controls)
	for action: String in ["Pause", "Step", "Restart"]:
		var button: Button = Button.new()
		button.name = action
		button.focus_mode = Control.FOCUS_NONE
		_controls.add_child(button)
	_pause_button = _controls.get_node("Pause")
	_pause_button.pressed.connect(_toggle_pause)
	_step_button = _controls.get_node("Step")
	_step_button.text = "Step frame (N)"
	_step_button.pressed.connect(_step_match)
	_restart_button = _controls.get_node("Restart")
	_restart_button.text = "Restart (R)"
	_restart_button.pressed.connect(_restart)
	_restart()


func _restart() -> void:
	if _session._mutation_code() == Types.Code.BUSY:
		return
	var config: Config = Config.new()
	config.check_distance = 8
	config.max_prediction_frames = 8
	config.history_slots = 9
	config.max_snapshot_bytes = Simulation.SNAPSHOT_BYTES
	config.storage_budget_bytes = config.required_storage_bytes()
	var candidate: Session = Session.new()
	var code: int = candidate.configure(config)
	if code != Types.Code.OK:
		return
	_session.terminate()
	_session = candidate
	_simulation = Simulation.new()
	_presentation = Presentation.new()
	_driver = Driver.new(_session, _simulation)
	_code = code
	_is_paused = false
	_current_positions = [Vector2(_simulation.x[0], _simulation.y[0]), Vector2(_simulation.x[1], _simulation.y[1])]
	_previous_positions = _current_positions.duplicate()
	_update_label()


func _exit_tree() -> void:
	_session.terminate()


func _physics_process(_delta: float) -> void:
	if _session._mutation_code() == Types.Code.BUSY:
		_code = Types.Code.BUSY
	elif not _is_paused and _can_service():
		_advance_match()
	_update_label()


func _can_service() -> bool:
	return (_session._mutation_code() == Types.Code.OK
		and _code in [Types.Code.OK, Types.Code.BUSY])


func _toggle_pause() -> void:
	if _can_service():
		_is_paused = not _is_paused
	_update_label()


func _step_match() -> void:
	if _is_paused and _can_service():
		_advance_match()
	_update_label()


func _advance_match() -> void:
	_previous_positions = _current_positions.duplicate()
	var frame: int = _session.status().current_frame
	var samples: Array[Driver.LocalInput] = [
		Driver.LocalInput.new(0, frame, PackedByteArray([_buttons(KEY_A, KEY_D, KEY_W, KEY_S)])),
		Driver.LocalInput.new(1, frame, PackedByteArray([_buttons(KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN)])),
	]
	# Time is only the driver's monotonic poll input; simulation never reads it.
	_code = _driver.step(Time.get_ticks_usec(), samples).code
	if _code == Types.Code.OK:
		_presentation.reconcile(_simulation)
		for player: int in range(2):
			_current_positions[player] = Vector2(_simulation.x[player], _simulation.y[player])


func _process(_delta: float) -> void:
	var viewport_size: Vector2 = get_viewport_rect().size
	var fit: float = minf(viewport_size.x / 552.0, viewport_size.y / maxf(456.0, _board_top() + 324.0))
	scale = Vector2(fit, fit)
	queue_redraw()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.alt_pressed or event.ctrl_pressed or event.meta_pressed or event.shift_pressed:
		return
	match event.keycode:
		KEY_R:
			_restart()
		KEY_P:
			_toggle_pause()
		KEY_N:
			_step_match()


func _buttons(left: Key, right: Key, up: Key, down: Key) -> int:
	return (
		int(Input.is_physical_key_pressed(left)) * Simulation.LEFT
		+ int(Input.is_physical_key_pressed(right)) * Simulation.RIGHT
		+ int(Input.is_physical_key_pressed(up)) * Simulation.UP
		+ int(Input.is_physical_key_pressed(down)) * Simulation.DOWN
	)


func _update_label() -> void:
	var status: String = "PAUSED" if _is_paused else "running"
	if _session._mutation_code() == Types.Code.BUSY:
		status = "WAITING FOR ACTIVE WORK"
	elif _session.status().lifecycle == Types.Lifecycle.TERMINATED:
		_code = _session.status().reason
		status = "STOPPED (code %d, failure frame %d)" % [_code, _session.status().failure_frame]
	elif _code not in [Types.Code.OK, Types.Code.BUSY]:
		status = "STOPPED (code %d)" % _code
	_pause_button.disabled = not _can_service()
	_pause_button.text = "Resume (P)" if _is_paused else "Pause (P)"
	_step_button.disabled = _pause_button.disabled or not _is_paused
	_restart_button.disabled = _session._mutation_code() == Types.Code.BUSY
	_label.text = (
		(
			"Offline rollback sync-test: %s\nFrame: %d | Rewind distance: 8 | Unique pulses: %d\n"
			+ "Player 1: WASD | Player 2: arrow keys\nR: restart | P: pause | N: step frame\nPulses use snapshotted randomness and delayed events."
		)
		% [status, _session.status().current_frame, _presentation.pulse_count]
	)

	_controls.position = Vector2(24, _label.position.y + _label.get_minimum_size().y + 8)


func _board_top() -> float:
	return _controls.position.y + _controls.get_minimum_size().y + 16.0


func _draw() -> void:
	draw_rect(Rect2(24, _board_top(), 480, 300), Color(0.08, 0.10, 0.15))
	for player: int in range(2):
		var interpolated: Vector2 = _current_positions[player] if _is_paused else _previous_positions[player].lerp(
			_current_positions[player], Engine.get_physics_interpolation_fraction())
		var position: Vector2 = Vector2(24, _board_top()) + interpolated
		var tint: Color = COLORS[_simulation.color[player]]
		draw_circle(position, 12, tint)
		draw_string(ThemeDB.fallback_font, position + Vector2(-4, 5), str(player + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.BLACK)
		# Rebuild this reversible visual from corrected state instead of spawning in callbacks.
		if _simulation.event_frame[player] >= 0 and _simulation.frame - _simulation.event_frame[player] <= 8:
			draw_arc(position, 20, 0, TAU, 32, tint, 3)
