extends Node2D

const Demo = preload("res://examples/integration/demo.gd")
const Game = preload("res://examples/integration/game.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const COLORS: Array[Color] = [Color.CORAL, Color.CORNFLOWER_BLUE]
const PULSE_TICKS: int = 18

var _demo: Demo = Demo.new()
var _code: int = Types.Code.OK
var _label: Label
var _last_effect: int = 0
var _pulses: Array[Vector2i] = []
var _replay_code: int = Types.Code.OK
var _controls: HBoxContainer
var _replay_button: Button
var _restart_button: Button


func _ready() -> void:
	_label = Label.new()
	_label.position = Vector2(24, 20)
	add_child(_label)
	_controls = HBoxContainer.new()
	_controls.name = "MatchControls"
	_controls.add_theme_constant_override("separation", 12)
	add_child(_controls)
	var names: PackedStringArray = PackedStringArray(["NoLag", "ShortLag", "LongLag", "Replay", "Restart"])
	var labels: PackedStringArray = PackedStringArray(["No delay (1)", "3-tick delay (2)", "12-tick delay (3)", "Watch replay (P)", "Restart (R)"])
	for index: int in range(names.size()):
		var button: Button = Button.new()
		button.name = names[index]
		button.text = labels[index]
		button.focus_mode = Control.FOCUS_NONE
		if index < 3:
			button.pressed.connect(_set_lag.bind([0, 3, 12][index]))
		elif index == 3:
			_replay_button = button
			button.pressed.connect(_toggle_replay)
		else:
			_restart_button = button
			button.pressed.connect(_restart)
		_controls.add_child(button)
	_code = _demo.start()
	_update_label()


func _exit_tree() -> void:
	_demo.stop_replay()
	if _demo.loop != null:
		_demo.loop.session.terminate()


func _physics_process(_delta: float) -> void:
	if _demo.replay_player != null:
		_replay_code = _demo.replay_tick()
		_update_label()
		return
	if _code not in [Types.Code.OK, Types.Code.PREDICTION_STALL, Types.Code.BUSY]:
		return
	var buttons: int = 0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		buttons |= Game.LEFT
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		buttons |= Game.RIGHT
	if Input.is_physical_key_pressed(KEY_SPACE):
		buttons |= Game.FIRE
	_code = _demo.tick(buttons)
	for id: int in _demo.effects.recent_ids:
		if id > _last_effect:
			_pulses.append(Vector2i(id, _demo.tick_count))
			_last_effect = id
	while not _pulses.is_empty() and _demo.tick_count - _pulses[0].y >= PULSE_TICKS:
		_pulses.pop_front()
	_update_label()


func _process(_delta: float) -> void:
	var viewport_size: Vector2 = get_viewport_rect().size
	var fit: float = minf(viewport_size.x / 760.0, viewport_size.y / maxf(560.0, _board_top() + 268.0))
	scale = Vector2(fit, fit)
	queue_redraw()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.alt_pressed or event.ctrl_pressed or event.meta_pressed or event.shift_pressed:
		return
	match event.keycode:
		KEY_1:
			_set_lag(0)
		KEY_2:
			_set_lag(3)
		KEY_3:
			_set_lag(12)
		KEY_P:
			_toggle_replay()
		KEY_R:
			_restart()
	_update_label()


func _set_lag(ticks: int) -> void:
	if _demo.replay_player == null:
		_demo.set_lag(ticks)
	_update_label()


func _toggle_replay() -> void:
	if _demo._mutation_code() == Types.Code.BUSY:
		return
	if _demo.replay_player != null:
		_demo.stop_replay()
		_replay_code = Types.Code.OK
	else:
		_replay_code = _demo.start_replay()
	_update_label()


func _restart() -> void:
	var code: int = _demo.reset()
	if code != Types.Code.OK:
		return
	_code = code
	_replay_code = Types.Code.OK
	_last_effect = 0
	_pulses.clear()
	_update_label()


func _update_label() -> void:
	var busy: bool = _demo._mutation_code() == Types.Code.BUSY
	_restart_button.disabled = busy
	_replay_button.disabled = busy
	_replay_button.text = "Back to match (P)" if _demo.replay_player != null else "Watch replay (P)"
	for index: int in range(3):
		var button: Button = _controls.get_child(index)
		button.disabled = busy or _demo.replay_player != null
	var status: Types.Status = _demo.loop.session.status()
	var state: String = "WAITING FOR INPUT" if _code == Types.Code.PREDICTION_STALL else "RUNNING"
	if _code != Types.Code.OK and _code != Types.Code.PREDICTION_STALL:
		state = "STOPPED: code %d, failure frame %d" % [_code, status.failure_frame]
	if _demo.replay_player == null and _replay_code != Types.Code.OK:
		state += " | REPLAY UNAVAILABLE: code %d" % _replay_code
	if _demo.replay_player != null:
		state = "REPLAY frame %d of %d" % [_demo.replay_player.current_frame(), _demo.replay_frames]
		if _replay_code == Types.Code.FRAME_EXHAUSTED:
			state = "REPLAY FINISHED, %d frames | P: back to the match" % _demo.replay_frames
		elif _replay_code != Types.Code.OK:
			state = "REPLAY STOPPED: code %d at frame %d" % [_replay_code, _demo.replay_player.failure_frame()]
	_label.text = (
		"Rollback-safe shots | %s\n" % state
		+ "A/D or arrows: move | Space: fire | P: watch replay | R: restart\n"
		+ "Remote delay: 1 = 0 ticks | 2 = 3 ticks | 3 = 12 ticks\n\n"
		+ "Frame %d | Confirmed %d | Delay %d | Queued %d\n" % [status.current_frame, status.confirmed_frame, _demo.lag_ticks, _demo.pending_input_count()]
		+ "Rollback loads %d | Stalled ticks %d | Confirmed effects %d\n\n" % [_demo.load_count(), _demo.stall_count, _demo.effects.total_count]
		+ "Hollow flashes: recent shots in corrected state; prediction can remove them.\n"
		+ "Filled pulses below: confirmed effects, played once after correction.\n"
		+ "Blue player is scripted. Delivery runs in this process."
	)
	_controls.position = Vector2(24, _label.position.y + _label.get_minimum_size().y + 8)


func _draw() -> void:
	if _demo.loop.driver == null:
		return
	var game: Game = _demo.shown_game()
	for player: int in range(2):
		var y: float = _board_top() + 28.0 + player * 140.0
		draw_rect(Rect2(24, y - 28, 712, 104), Color(0.08, 0.10, 0.15))
		var position: Vector2 = Vector2(120 + game.x[player] * 1.35, y)
		draw_circle(position, 13, COLORS[player])
		_text(Vector2(36, y + 6), "YOU" if player == 0 else "REMOTE", COLORS[player])
		for index: int in range(maxi(0, game.shot_total - Game.SHOT_SLOTS), game.shot_total):
			var id: int = game.shot_ids[index % Game.SHOT_SLOTS]
			if Game.shot_player(id) == player and game.frame - Game.shot_frame(id) <= 6:
				draw_arc(position, 25, 0, TAU, 32, COLORS[player], 3)
		for pulse: Vector2i in _pulses if _demo.replay_player == null else []:
			if Game.shot_player(pulse.x) == player:
				var age: float = float(_demo.tick_count - pulse.y) / PULSE_TICKS
				var tint: Color = COLORS[player]
				tint.a = 1.0 - age
				var pulse_position: Vector2 = Vector2(136 + (pulse.x % 36) * 16, y + 45)
				draw_circle(pulse_position, 8 + age * 6, tint)
				_text(pulse_position + Vector2(-7, 5), str(pulse.x), Color.WHITE)


func _text(position: Vector2, value: String, tint: Color) -> void:
	draw_string(ThemeDB.fallback_font, position, value, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, tint)


func _board_top() -> float:
	return _controls.position.y + _controls.get_minimum_size().y + 16.0
