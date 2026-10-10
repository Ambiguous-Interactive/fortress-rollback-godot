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
var _previous_positions: Array[Vector2] = [Vector2(120, 160), Vector2(360, 160)]
var _current_positions: Array[Vector2] = [Vector2(120, 160), Vector2(360, 160)]


func _ready() -> void:
	_label = Label.new()
	_label.position = Vector2(24, 24)
	add_child(_label)
	var config: Config = Config.new()
	config.check_distance = 8
	config.max_prediction_frames = 8
	config.history_slots = 9
	config.max_snapshot_bytes = Simulation.SNAPSHOT_BYTES
	config.storage_budget_bytes = config.required_storage_bytes()
	_code = _session.configure(config)
	_driver = Driver.new(_session, _simulation)
	_update_label()


func _physics_process(_delta: float) -> void:
	if _code != Types.Code.OK:
		return
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
	_update_label()


func _process(_delta: float) -> void:
	var viewport_size: Vector2 = get_viewport_rect().size
	var fit: float = minf(viewport_size.x / 552.0, viewport_size.y / 456.0)
	scale = Vector2(fit, fit)
	queue_redraw()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_R:
		get_tree().reload_current_scene()


func _buttons(left: Key, right: Key, up: Key, down: Key) -> int:
	return (
		int(Input.is_physical_key_pressed(left)) * Simulation.LEFT
		+ int(Input.is_physical_key_pressed(right)) * Simulation.RIGHT
		+ int(Input.is_physical_key_pressed(up)) * Simulation.UP
		+ int(Input.is_physical_key_pressed(down)) * Simulation.DOWN
	)


func _update_label() -> void:
	var status: String = "running" if _code == Types.Code.OK else "STOPPED (code %d, failure frame %d)" % [_code, _session.status().failure_frame]
	_label.text = (
		(
			"Offline rollback sync-test: %s\nFrame: %d | Rewind distance: 8 | Unique pulses: %d\n"
			+ "Player 1: WASD | Player 2: arrow keys | R: restart\nPulses use snapshotted randomness and delayed events."
		)
		% [status, _session.status().current_frame, _presentation.pulse_count]
	)


func _draw() -> void:
	draw_rect(Rect2(24, 132, 480, 300), Color(0.08, 0.10, 0.15))
	for player: int in range(2):
		var interpolated: Vector2 = _previous_positions[player].lerp(_current_positions[player], Engine.get_physics_interpolation_fraction())
		var position: Vector2 = Vector2(24, 132) + interpolated
		var tint: Color = COLORS[_simulation.color[player]]
		draw_circle(position, 12, tint)
		draw_string(ThemeDB.fallback_font, position + Vector2(-4, 5), str(player + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.BLACK)
		# Rebuild this reversible visual from corrected state instead of spawning in callbacks.
		if _simulation.event_frame[player] >= 0 and _simulation.frame - _simulation.event_frame[player] <= 8:
			draw_arc(position, 20, 0, TAU, 32, tint, 3)
