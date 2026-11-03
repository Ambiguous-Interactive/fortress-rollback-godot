extends Node2D

const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Match = preload("res://examples/peer/match.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const COLORS: Array[Color] = [Color.CORAL, Color.CORNFLOWER_BLUE, Color.GOLD, Color.MEDIUM_SEA_GREEN]
var _match: Match = Match.new()
var _label: Label
var _delay_result: String = ""
var _controls: VBoxContainer
var _actions: Dictionary = {}


func _ready() -> void:
	_label = Label.new()
	_label.position = Vector2(24, 16)
	_label.add_theme_font_size_override("font_size", 14)
	add_child(_label)
	_controls = VBoxContainer.new()
	_controls.name = "PeerControls"
	_controls.add_theme_constant_override("separation", 8)
	add_child(_controls)
	for row: PackedStringArray in [
		PackedStringArray(["loss", "latency", "reorder", "block", "desync"]),
		PackedStringArray(["delay_first", "delay_second", "reset"])
	]:
		var container: HBoxContainer = HBoxContainer.new()
		container.add_theme_constant_override("separation", 8)
		_controls.add_child(container)
		for action: String in row:
			var button: Button = Button.new()
			button.name = action
			button.focus_mode = Control.FOCUS_NONE
			button.pressed.connect(_apply_action.bind(action))
			container.add_child(button)
			_actions[action] = button
	_match.reset()
	_update_label()


func _exit_tree() -> void:
	for session: Peer in _match.sessions:
		if session._core != null:
			session._core.terminate()


func _physics_process(_delta: float) -> void:
	_match.tick(PackedInt32Array([_buttons(KEY_A, KEY_D, KEY_W, KEY_S), _buttons(KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN)]))
	_update_label()


func _process(_delta: float) -> void:
	var size: Vector2 = get_viewport_rect().size
	var fit: float = minf(size.x / 1040.0, size.y / maxf(520.0, _board_top() + 320.0))
	scale = Vector2(fit, fit)
	queue_redraw()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.alt_pressed or event.ctrl_pressed or event.meta_pressed or event.shift_pressed:
		return
	var number_key: Key = event.physical_keycode if event.physical_keycode != KEY_NONE else event.keycode
	if number_key in [KEY_1, KEY_2]:
		_apply_action("delay_first" if number_key == KEY_1 else "delay_second")
	else:
		var actions: Dictionary = {KEY_R: "reset", KEY_L: "loss", KEY_T: "latency", KEY_O: "reorder", KEY_SPACE: "block", KEY_X: "desync"}
		if actions.has(event.keycode):
			_apply_action(actions[event.keycode])


func _apply_action(action: String) -> void:
	if _match._has_operation_guard():
		return
	if action == "reset":
		if _match.reset() == Match.I.Code.OK:
			_delay_result = ""
	elif action in ["delay_first", "delay_second"]:
		if not _can_change_delay():
			return
		var player: int = 0 if action == "delay_first" else 1
		var code: int = _match.raise_input_delay(player)
		_delay_result = "" if code == Peer.Types.Code.OK else " | peer %d delay unchanged (code %d)" % [player + 1, code]
	elif action == "desync":
		if _can_change_delay():
			_match.inject_desync()
	elif _can_configure_faults():
		match action:
			"loss":
				_match.drop_every = 0 if _match.drop_every > 0 else 7
			"latency":
				_match.latency_ticks = 12 if _match.latency_ticks == 3 else 3
			"reorder":
				_match.reorder = not _match.reorder
			"block":
				_match.is_partitioned = not _match.is_partitioned
	_update_label()


func _can_configure_faults() -> bool:
	if _match._has_operation_guard() or _match.failure != Match.I.Code.OK or _match.sessions.size() != 2:
		return false
	for session: Peer in _match.sessions:
		if session.status().lifecycle != Peer.Types.Lifecycle.RUNNING:
			return false
	return true


func _can_change_delay() -> bool:
	if not _can_configure_faults():
		return false
	for session: Peer in _match.sessions:
		if session.network_status().state != "running" or session.status().lifecycle != Peer.Types.Lifecycle.RUNNING:
			return false
	return true


func _buttons(left: Key, right: Key, up: Key, down: Key) -> int:
	return (int(Input.is_physical_key_pressed(left)) * Simulation.LEFT + int(Input.is_physical_key_pressed(right)) * Simulation.RIGHT
		+ int(Input.is_physical_key_pressed(up)) * Simulation.UP + int(Input.is_physical_key_pressed(down)) * Simulation.DOWN)


func _update_label() -> void:
	_actions.loss.text = "Loss: %s (L)" % ("on" if _match.drop_every > 0 else "off")
	_actions.latency.text = "Latency: %d ticks (T)" % _match.latency_ticks
	_actions.reorder.text = "Reorder: %s (O)" % ("on" if _match.reorder else "off")
	_actions.block.text = "Unblock packets (Space)" if _match.is_partitioned else "Block packets (Space)"
	_actions.desync.text = "Wrong game rules (X)"
	_actions.delay_first.text = "Peer 1 delay +1 (1)"
	_actions.delay_second.text = "Peer 2 delay +1 (2)"
	_actions.reset.text = "Reset match (R)"
	for action: String in _actions:
		var button: Button = _actions[action]
		if action == "reset":
			button.disabled = _match._has_operation_guard()
		elif action in ["delay_first", "delay_second", "desync"]:
			button.disabled = not _can_change_delay()
		else:
			button.disabled = not _can_configure_faults()
	_label.text = ("Two peer sessions | actual encoded bytes in this process | failure: %d\n"
		+ "WASD: player 1 | Arrows: player 2 | R: reset | Space: block packets | X: wrong game rules\n"
		+ "L: loss (%s) | T: latency (%d ticks) | O: reorder (%s) | blocked: %s%s%s\n"
		+ "Sent %d | Dropped %d | Delivered %d | Queued %d / 256") % [
		_match.failure, str(_match.drop_every > 0), _match.latency_ticks, str(_match.reorder), str(_match.is_partitioned),
		" | 1/2: raise peer input delay" if _can_change_delay() else "", _delay_result,
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

	_controls.position = Vector2(24, _label.position.y + _label.get_minimum_size().y + 8)


func _board_top() -> float:
	return _controls.position.y + _controls.get_minimum_size().y + 16.0


func _draw() -> void:
	for peer: int in range(_match.games.size()):
		var origin: Vector2 = Vector2(24 + peer * 512, _board_top())
		draw_rect(Rect2(origin, Vector2(480, 300)), Color(0.08, 0.10, 0.15))
		var game: Match.Game = _match.games[peer]
		for player: int in range(2):
			var position: Vector2 = origin + Vector2(game.x[player], game.y[player])
			var tint: Color = COLORS[game.color[player]]
			draw_circle(position, 12, tint)
			draw_string(ThemeDB.fallback_font, position + Vector2(-4, 5), str(player + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.BLACK)
			if game.event_frame[player] >= 0 and game.frame - game.event_frame[player] <= 8:
				draw_arc(position, 20, 0, TAU, 32, tint, 3)
