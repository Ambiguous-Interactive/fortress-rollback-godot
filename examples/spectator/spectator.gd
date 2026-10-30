extends Node2D

const Demo = preload("res://examples/spectator/demo.gd")
const Game = preload("res://examples/integration/game.gd")
const Spectator = preload("res://addons/fortress_rollback/core/spectator_session.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const COLORS: Array[Color] = [Color.CORAL, Color.CORNFLOWER_BLUE]

const REPLAY_FILENAME: String = "fortress-spectator.frrp"

var demo: Demo = Demo.new()
var _code: int = Types.Code.OK
var _replay_notice: String = ""
var _label: Label


func _ready() -> void:
	_label = Label.new()
	_label.position = Vector2(24, 20)
	_label.size.x = 712
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
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
	elif event.keycode in [KEY_BRACKETLEFT, KEY_BRACKETRIGHT] and demo.viewer != null:
		var delay: int = demo.viewer.playback_policy()[0]
		demo.set_viewing_delay(maxi(0, delay + (-1 if event.keycode == KEY_BRACKETLEFT else 1)))
	elif event.keycode in [KEY_COMMA, KEY_PERIOD] and demo.viewer != null:
		var speed: int = demo.viewer.playback_policy()[2]
		demo.set_catchup_speed(maxi(1, speed + (-1 if event.keycode == KEY_COMMA else 1)))
	elif event.keycode == KEY_L:
		demo.lose_host_connection()
	elif event.keycode == KEY_E:
		demo.finish_host()
	elif event.keycode == KEY_V:
		_export_replay()
	elif event.keycode == KEY_R:
		_code = demo.start()
		_replay_notice = ""
	_update_label()


func _process(_delta: float) -> void:
	var size: Vector2 = get_viewport_rect().size
	var content_height: float = _board_top() + 150.0 + 125.0 + 24.0
	var fit: float = minf(size.x / 760.0, size.y / maxf(560.0, content_height))
	scale = Vector2(fit, fit)
	queue_redraw()


func _update_label() -> void:
	if demo.host == null or demo.viewer == null:
		_label.text = "Could not start: code %d" % _code
		return
	var state: String = "PAUSED" if demo.is_paused else "WATCHING"
	var policy: PackedInt64Array = demo.viewer.playback_policy()
	var playback: Dictionary = demo.viewer.playback_status()
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
		state = "COMPLETE | R: start again" if demo.viewer.is_complete() else "STOPPED: code %d | R: start again" % status.reason
		if status.reason == Types.Code.HISTORY_UNAVAILABLE:
			state = "HISTORY UNAVAILABLE | R: start again"
	if demo.is_host_connection_lost:
		state = "HOST CONNECTION LOST | R: start again"
	_label.text = (
		"Delayed spectator | %s\n" % state
		+ "A/D or arrows: move host | Space: fire\nP: pause viewer | N: step viewer | E: end host\n[: less delay | ]: more delay\n,: slower catch-up | .: faster catch-up\n"
		+ "L: lose host link | V: save viewed replay | R: restart\n"
		+ "Host frame %d | Confirmed %d | Viewer frame %d\n\n" % [demo.host.loop.game.frame, demo.host.loop.session.status().confirmed_frame, demo.game.frame]
		+ "Viewer holds %d confirmed frames and catches up at most %d per tick.\n" % [policy[0], policy[2]]
		+ "Buffered %d confirmed frames | Later rows %d\n" % [playback.buffered_frames, playback.pending_frames - playback.buffered_frames]
		+ "A long pause can exceed retained history; the host keeps playing.\n"
		+ "Two local views. Live spectator networking is not connected."
		+ ("\n" + _replay_notice if not _replay_notice.is_empty() else "")
	)


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
	return _label.position.y + _label.get_minimum_size().y + 16.0


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
