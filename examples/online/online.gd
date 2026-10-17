extends Node2D

const Lobby = preload("res://examples/online/lobby.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const COLORS: Array[Color] = [Color.CORAL, Color.CORNFLOWER_BLUE, Color.GOLD, Color.MEDIUM_SEA_GREEN]
var controller: Lobby = Lobby.new()
var endpoint: LineEdit
var player_name: LineEdit
var room_code: LineEdit
var create_button: Button
var join_button: Button
var ready_button: Button
var start_button: Button
var leave_button: Button
var diagnostics_button: Button
var trace_checkbox: CheckBox
var _status: Label


func _ready() -> void:
	var panel: VBoxContainer = VBoxContainer.new()
	panel.position = Vector2(24, 16)
	panel.custom_minimum_size = Vector2(680, 0)
	add_child(panel)
	var title: Label = Label.new()
	title.text = "Online rollback | two players in separate browsers"
	panel.add_child(title)
	endpoint = _field(panel, "SignalFish endpoint", "ws://127.0.0.1:8080/v3/ws")
	player_name = _field(panel, "Player name", "Player")
	room_code = _field(panel, "Room code (blank to create)", "")
	var buttons: HBoxContainer = HBoxContainer.new()
	panel.add_child(buttons)
	create_button = _button(buttons, "Create room", _create)
	join_button = _button(buttons, "Join room", _join)
	ready_button = _button(buttons, "Ready", _ready_player)
	start_button = _button(buttons, "Start", _start_game)
	leave_button = _button(buttons, "Leave / new room", _leave)
	diagnostics_button = _button(buttons, "Diagnostics", _export_diagnostics)
	trace_checkbox = CheckBox.new()
	trace_checkbox.text = "Include game state and inputs in diagnostics (choose before Ready)"
	panel.add_child(trace_checkbox)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(_status)
	_update_status()


func _physics_process(_delta: float) -> void:
	var focused: Control = get_viewport().gui_get_focus_owner()
	var buttons: int = 0
	if not focused is LineEdit:
		buttons = (
			_pressed(KEY_A, KEY_LEFT) * Simulation.LEFT
			+ _pressed(KEY_D, KEY_RIGHT) * Simulation.RIGHT
			+ _pressed(KEY_W, KEY_UP) * Simulation.UP
			+ _pressed(KEY_S, KEY_DOWN) * Simulation.DOWN
		)
	controller.tick(Time.get_ticks_usec(), buttons)
	_update_status()
	queue_redraw()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode in [KEY_EQUAL, KEY_KP_ADD]:
		var code: int = controller.game_match.raise_input_delay()
		controller.message = "Input delay raised." if code == Lobby.Match.Types.Code.OK else "Input delay unchanged (code %d)." % code


func _exit_tree() -> void:
	controller.disconnect_room()


func _pressed(first: Key, second: Key) -> int:
	return int(Input.is_physical_key_pressed(first) or Input.is_physical_key_pressed(second))


func _field(parent: Node, caption: String, value: String) -> LineEdit:
	var row: HBoxContainer = HBoxContainer.new()
	parent.add_child(row)
	var label: Label = Label.new()
	label.text = caption
	label.custom_minimum_size.x = 220
	row.add_child(label)
	var field: LineEdit = LineEdit.new()
	field.text = value
	field.custom_minimum_size.x = 440
	row.add_child(field)
	return field


func _button(parent: Node, caption: String, callback: Callable) -> Button:
	var button: Button = Button.new()
	button.text = caption
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


func _create() -> void:
	controller.connect_room(endpoint.text.strip_edges(), player_name.text, "", Time.get_ticks_usec())
	_update_status()


func _join() -> void:
	if room_code.text.strip_edges().is_empty():
		controller.message = "Enter the room code shared by the creator."
	else:
		controller.connect_room(endpoint.text.strip_edges(), player_name.text, room_code.text, Time.get_ticks_usec())
	_update_status()


func _ready_player() -> void:
	if not controller.has_readied:
		controller.game_match.capture_trace = trace_checkbox.button_pressed
	if controller.ready() == OK:
		get_viewport().gui_release_focus()
	_update_status()


func _start_game() -> void:
	controller.start()
	get_viewport().gui_release_focus()
	_update_status()


func _leave() -> void:
	controller.disconnect_room()
	room_code.text = ""
	_update_status()


func _update_status() -> void:
	var connected: bool = controller.client != null
	create_button.disabled = connected
	join_button.disabled = connected
	leave_button.disabled = not connected
	diagnostics_button.disabled = controller.game_match.local_slot < 0
	trace_checkbox.disabled = controller.has_readied
	endpoint.editable = not connected
	player_name.editable = not connected
	room_code.editable = not connected
	if connected and not controller.room_code().is_empty():
		room_code.text = controller.room_code()
	var players: int = controller.client.call("get_players").size() if connected else 0
	ready_button.disabled = controller.state != "lobby" or controller.has_readied or players != 2
	start_button.disabled = controller.state != "lobby" or not controller.is_creator or not controller.has_readied or not controller.all_ready
	_status.text = "%s\n%s\nRoom: %s | players: %d / 2" % [controller.state.capitalize(), controller.message, controller.room_code(), players]
	var game: Lobby.Match = controller.game_match
	if game.local_slot >= 0:
		var state: Lobby.Match.Types.Status = game.peer.status()
		_status.text += (
			"\nYou: player %d | frame %d | confirmed %d | delay %d (= raises) | stalls %d | event %s"
			% [game.local_slot + 1, state.current_frame, state.confirmed_frame, game.peer.input_delay(game.local_slot), game.stalls, game.latest_event]
		)
		var counts: Lobby.Match.Types.Statistics = game.peer.statistics()
		_status.text += (
			"\nRollbacks: %d | max depth: %d | replayed frames: %d | relay links: %d"
			% [counts.rollback_count, counts.max_rollback_depth, counts.resimulated_frames, game.fallback.status().relay_peers.size()]
		)


## Export selected observations and explicitly enabled game evidence; no SDK config or room/player identities.
func diagnostic_report() -> Dictionary:
	var game: Lobby.Match = controller.game_match
	var report: Dictionary = game.peer.diagnostics()
	report["engine"] = Engine.get_version_info().string
	var transport: Dictionary = game.fallback.status()
	report["transport"] = {"relay_links": transport.relay_peers.size(), "pending_packets": transport.pending_packets, "pending_bytes": transport.pending_bytes}
	return report


func _export_diagnostics() -> void:
	var text: String = JSON.stringify(diagnostic_report(), "\t")
	if OS.has_feature("web"):
		JavaScriptBridge.download_buffer(text.to_utf8_buffer(), "fortress-diagnostics.json", "application/json")
	else:
		DisplayServer.clipboard_set(text)


func _draw() -> void:
	var origin: Vector2 = Vector2(24, maxf(310, to_local(_status.get_global_rect().end).y + 16))
	draw_rect(Rect2(origin, Vector2(480, 300)), Color(0.08, 0.10, 0.15))
	var game: Simulation = controller.game_match.game
	for player: int in 2:
		var position: Vector2 = origin + Vector2(game.x[player], game.y[player])
		var tint: Color = COLORS[game.color[player]]
		draw_circle(position, 12, tint)
		draw_string(ThemeDB.fallback_font, position + Vector2(-4, 5), str(player + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.BLACK)
