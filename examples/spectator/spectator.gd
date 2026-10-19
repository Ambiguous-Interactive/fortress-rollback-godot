extends Node2D

const Demo = preload("res://examples/spectator/demo.gd")
const Game = preload("res://examples/integration/game.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const COLORS: Array[Color] = [Color.CORAL, Color.CORNFLOWER_BLUE]

var demo: Demo = Demo.new()
var _code: int = Types.Code.OK
var _label: Label


func _ready() -> void:
	_label = Label.new()
	_label.position = Vector2(24, 20)
	add_child(_label)
	_code = demo.start()
	_update_label()


func _physics_process(_delta: float) -> void:
	if _code not in [Types.Code.OK, Types.Code.PREDICTION_STALL]:
		return
	var buttons: int = 0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		buttons |= Game.LEFT
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		buttons |= Game.RIGHT
	if Input.is_physical_key_pressed(KEY_SPACE):
		buttons |= Game.FIRE
	_code = demo.tick(buttons)
	_update_label()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.keycode == KEY_P:
		demo.is_paused = not demo.is_paused
	elif event.keycode == KEY_N:
		demo.step_viewer()
	elif event.keycode == KEY_E:
		demo.finish_host()
	elif event.keycode == KEY_R:
		_code = demo.start()
	_update_label()


func _process(_delta: float) -> void:
	var size: Vector2 = get_viewport_rect().size
	var fit: float = minf(size.x / 760.0, size.y / 560.0)
	scale = Vector2(fit, fit)
	queue_redraw()


func _update_label() -> void:
	if demo.host == null or demo.viewer == null:
		_label.text = "Could not start: code %d" % _code
		return
	var state: String = "PAUSED" if demo.is_paused else "WATCHING"
	if demo.is_finishing:
		state = "DRAINING FINAL TAIL" if demo.is_host_finished else "CONFIRMING FINAL INPUTS"
	if demo.viewer.status().lifecycle == Types.Lifecycle.TERMINATED:
		state = "COMPLETE | R: start again" if demo.viewer_code == Types.Code.TERMINATED else "STOPPED: code %d | R: start again" % demo.viewer_code
	_label.text = (
		"Delayed spectator | %s\n" % state
		+ "A/D or arrows: move host | Space: fire\nP: pause viewer | N: step viewer | E: end host | R: restart\n"
		+ "Host frame %d | Confirmed %d | Viewer frame %d\n\n" % [demo.host.loop.game.frame, demo.host.loop.session.status().confirmed_frame, demo.game.frame]
		+ "Viewer holds 12 confirmed frames and catches up at most 4 per tick.\n"
		+ "A long pause can exceed retained history; the host keeps playing.\n"
		+ "Two local views. Live spectator networking is not connected."
	)


func _draw() -> void:
	if demo.game == null:
		return
	var games: Array[Game] = [demo.host.loop.game, demo.game]
	for panel: int in range(2):
		var top: float = 250.0 + panel * 150
		draw_rect(Rect2(24, top - 30, 712, 125), Color(0.08, 0.10, 0.15))
		draw_string(ThemeDB.fallback_font, Vector2(36, top), "HOST" if panel == 0 else "VIEWER", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)
		for player: int in range(2):
			var position: Vector2 = Vector2(120 + games[panel].x[player] * 1.35, top + 26 + player * 35)
			draw_circle(position, 11, COLORS[player])
			for index: int in range(maxi(0, games[panel].shot_total - Game.SHOT_SLOTS), games[panel].shot_total):
				var id: int = games[panel].shot_ids[index % Game.SHOT_SLOTS]
				if Game.shot_player(id) == player and games[panel].frame - Game.shot_frame(id) <= 6:
					draw_arc(position, 21, 0, TAU, 24, COLORS[player], 2)
