extends Node2D

const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Match = preload("res://examples/peer/match.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const COLORS: Array[Color] = [Color.CORAL, Color.CORNFLOWER_BLUE, Color.GOLD, Color.MEDIUM_SEA_GREEN]
var _match: Match = Match.new()
var _label: Label
var _delay_result: String = ""


func _ready() -> void:
	_label = Label.new()
	_label.position = Vector2(24, 16)
	_label.add_theme_font_size_override("font_size", 14)
	add_child(_label)
	_match.reset()
	_update_label()


func _physics_process(_delta: float) -> void:
	_match.tick(PackedInt32Array([_buttons(KEY_A, KEY_D, KEY_W, KEY_S), _buttons(KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN)]))
	_update_label()


func _process(_delta: float) -> void:
	var size: Vector2 = get_viewport_rect().size
	var fit: float = minf(size.x / 1040.0, size.y / 520.0)
	scale = Vector2(fit, fit)
	queue_redraw()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_R:
			_match.reset()
			_delay_result = ""
		KEY_L:
			_match.drop_every = 0 if _match.drop_every > 0 else 7
		KEY_T:
			_match.latency_ticks = 12 if _match.latency_ticks == 3 else 3
		KEY_O:
			_match.reorder = not _match.reorder
		KEY_SPACE:
			_match.is_partitioned = not _match.is_partitioned
		KEY_X:
			_match.inject_desync()
		KEY_1, KEY_2:
			var player: int = 0 if event.keycode == KEY_1 else 1
			var code: int = _match.raise_input_delay(player)
			_delay_result = "" if code == Peer.Types.Code.OK else " | peer %d delay unchanged (code %d)" % [player + 1, code]
	_update_label()


func _buttons(left: Key, right: Key, up: Key, down: Key) -> int:
	return (int(Input.is_physical_key_pressed(left)) * Simulation.LEFT + int(Input.is_physical_key_pressed(right)) * Simulation.RIGHT
		+ int(Input.is_physical_key_pressed(up)) * Simulation.UP + int(Input.is_physical_key_pressed(down)) * Simulation.DOWN)


func _update_label() -> void:
	_label.text = ("Two peer sessions | actual encoded bytes in this process | failure: %d\n"
		+ "WASD: player 1 | Arrows: player 2 | R: reset | Space: block packets | X: wrong game rules\n"
		+ "L: loss (%s) | T: latency (%d ticks) | O: reorder (%s) | blocked: %s | 1/2: raise peer input delay%s\n"
		+ "Sent %d | Dropped %d | Delivered %d | Queued %d / 256") % [
		_match.failure, str(_match.drop_every > 0), _match.latency_ticks, str(_match.reorder), str(_match.is_partitioned), _delay_result,
		_match.sent, _match.dropped, _match.delivered, _match.queued_packets()]
	for player: int in range(_match.sessions.size()):
		var session: Peer = _match.sessions[player]
		var network: Dictionary = session.network_status()
		var peer: Dictionary = network.peers.values()[0]
		_label.text += "\nPeer %d: %s | frame %d | confirmed %d | delay %d | ACK %d | pending %d | restores %d | stalls %d" % [
			player + 1, network.state, session.status().current_frame, session.status().confirmed_frame, session.input_delay(player),
			peer.last_acked_frame, peer.pending_frames, _match.games[player].restores, _match.stalls[player]]
		_label.text += "\n  RTT %d ms | ahead %d | interrupted %s | event %s | terminal reason %d" % [
			peer.get("round_trip_time_ms", 0), network.get("frames_ahead", 0), str(peer.get("interrupted", false)),
			_match.latest_events[player].get("kind", "none"), session.status().reason]
		var event: Dictionary = _match.latest_events[player]
		if event.get("kind", "") == "desync_detected":
			_label.text += " | mismatch frame %d" % event.frame


func _draw() -> void:
	for peer: int in range(_match.games.size()):
		var origin: Vector2 = Vector2(24 + peer * 512, 200)
		draw_rect(Rect2(origin, Vector2(480, 300)), Color(0.08, 0.10, 0.15))
		var game: Match.Game = _match.games[peer]
		for player: int in range(2):
			var position: Vector2 = origin + Vector2(game.x[player], game.y[player])
			var tint: Color = COLORS[game.color[player]]
			draw_circle(position, 12, tint)
			draw_string(ThemeDB.fallback_font, position + Vector2(-4, 5), str(player + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.BLACK)
			if game.event_frame[player] >= 0 and game.frame - game.event_frame[player] <= 8:
				draw_arc(position, 20, 0, TAU, 32, tint, 3)
