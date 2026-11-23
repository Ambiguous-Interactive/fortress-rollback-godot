extends Node

# Value: protects=callback correction and departure; fails_when=rows diverge or simulation continues after leave; why_new=legacy uses a different protocol; seam=browser sends
const Scene = preload("res://examples/online/online.tscn")
const Lobby = preload("res://examples/online/lobby.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Reader = preload("res://addons/fortress_rollback/core/snapshot_reader.gd")
const Writer = preload("res://addons/fortress_rollback/core/snapshot_writer.gd")
const GATE_FRAME: int = 12
const HISTORY_LIMIT: int = 128


class ObservedGame:
	extends Simulation

	var rows: Dictionary = {}
	var snapshots: Dictionary = {}
	var saves: int = 0
	var restores: int = 0
	var advances: int = 0
	var first_prediction: int = -1
	var movement_errors: int = 0

	func _init(players: int) -> void:
		super(players, Driver.Native.INPUT_BYTES)

	func save_state(saved_frame: int, writer: Writer) -> Driver.SaveResult:
		saves += 1
		return super.save_state(saved_frame, writer)

	func load_state(saved_frame: int, reader: Reader) -> bool:
		restores += 1
		return super.load_state(saved_frame, reader)

	func simulate_frame(input_frame: int, inputs: Types.FrameInputs) -> bool:
		var positions_x: PackedInt32Array = x.duplicate()
		var positions_y: PackedInt32Array = y.duplicate()
		advances += 1
		var accepted: bool = super.simulate_frame(input_frame, inputs)
		if not accepted:
			return false
		var row: Array[int] = []
		for player: int in inputs.player_count():
			var sample: Types.InputResult = inputs.read(player)
			var buttons: int = sample.bytes.decode_u32(0) if sample.bytes.size() == Driver.Native.INPUT_BYTES else -1
			row.append(buttons)
			if first_prediction == -1 and input_frame >= GATE_FRAME and sample.status == Queue.Status.PREDICTED:
				first_prediction = input_frame
			var dx: int = int(bool(buttons & RIGHT)) - int(bool(buttons & LEFT))
			var dy: int = int(bool(buttons & DOWN)) - int(bool(buttons & UP))
			if x[player] != clampi(positions_x[player] + 2 * dx, 20, 460) or y[player] != clampi(positions_y[player] + 2 * dy, 20, 280):
				movement_errors += 1
		if input_frame < HISTORY_LIMIT:
			rows[str(input_frame)] = row
			snapshots[str(frame)] = canonical_bytes().hex_encode()
		return true


class ObservedLobby:
	extends Lobby

	var observations: ObservedGame
	var turns: int = 0
	var transport_wait_started: int = -1
	var transport_start_delay: int = -1
	var previous_transport_delay: int = -1
	var browser_open_wait_ticks: int = 0
	var open_mesh_wait_ticks: int = 0
	var failure_tick_callbacks: PackedInt32Array = []
	var wait_for_full_mesh: bool = false
	var started_on_full_mesh: bool = false
	var _engine_mesh_open: bool = false
	var _last_play_tick_us: int = -1
	var play_tick_gap_peak_us: int = 0
	var sdk_receive_peak: int = 0
	var relay_receive_peak: int = 0
	var relay_send_peak: int = 0

	func _maybe_start_transport(route: String, now_us: int, revision: int) -> void:
		if transport_wait_started < 0:
			transport_wait_started = now_us
		var elapsed: int = now_us - transport_wait_started
		var mesh_open: bool = route == "mesh" and JavaScriptBridge.eval("window.fortressNativeWire.meshOpen(%d)" % (player_count - 1))
		# The direct-only witness starts after every real channel connects.
		if wait_for_full_mesh and route == "mesh" and not mesh_open:
			return
		_engine_mesh_open = false
		super._maybe_start_transport(route, now_us, revision)
		if transport_start_delay < 0:
			if state == "playing":
				transport_start_delay = elapsed
				started_on_full_mesh = mesh_open and _engine_mesh_open
			else:
				previous_transport_delay = elapsed
				if mesh_open:
					browser_open_wait_ticks += 1
				if mesh_open and _engine_mesh_open:
					open_mesh_wait_ticks += 1

	func _mesh_can_start(revision: int, allow_missing_links: bool) -> bool:
		var ready: bool = super._mesh_can_start(revision, allow_missing_links)
		_engine_mesh_open = _engine_sees_full_mesh()
		return ready

	func _engine_sees_full_mesh() -> bool:
		if not is_instance_valid(mesh):
			return false
		var transport: Object = mesh.call("get_multiplayer_peer")
		if transport == null:
			return false
		var peers: Dictionary = transport.call("get_peers")
		if peers.size() != player_count - 1:
			return false
		var owner: String = game_match.membership.local_uuid()
		for peer_id: int in peers:
			var peer_uuid: String = game_match.membership.uuid_for_peer_id(peer_id)
			if peer_uuid.is_empty() or peer_uuid == owner or not peers[peer_id].get("connected", false):
				return false
		return true

	func tick(now_us: int, buttons: int) -> void:
		turns += 1
		var previous_state: String = state
		var callbacks: PackedInt32Array = []
		if state == "playing":
			if _last_play_tick_us >= 0:
				play_tick_gap_peak_us = maxi(play_tick_gap_peak_us, now_us - _last_play_tick_us)
			_last_play_tick_us = now_us
			# The pinned SDK transport owns the socket adapter and exposes no receive queue getter.
			var transport: RefCounted = client.get("transport")
			var socket: RefCounted = transport.get("_peer")
			if socket != null:
				sdk_receive_peak = maxi(sdk_receive_peak, socket.call("get_available_packet_count"))
			var relay_status: Dictionary = game_match.relay.status()
			relay_receive_peak = maxi(relay_receive_peak, relay_status.received_packets)
			relay_send_peak = maxi(relay_send_peak, relay_status.pending_packets)
			callbacks = [observations.saves, observations.restores, observations.advances]
			var frame: int = game_match.status().current_frame
			# Variations after the warmup force correction when delivery is held.
			if frame >= GATE_FRAME and frame % 2 == 0:
				buttons = 0
		super.tick(now_us, buttons)
		if state == "failed" and previous_state == "playing":
			failure_tick_callbacks = callbacks


var scene: Node2D
var lobby: ObservedLobby
var command_id: int = 0
var command_code: Error = OK
var session_id: String = ""
var uuid: String = ""
var room_id: String = ""
var blocked_uuid: String = ""
var closed_channel_state: int = -1
var closed_channel_frame: int = -1


func _ready() -> void:
	scene = Scene.instantiate()
	lobby = ObservedLobby.new()
	scene.controller = lobby
	add_child(scene)
	JavaScriptBridge.eval("window.fortressNativeReady = true")


func _process(_delta: float) -> void:
	var text: String = JavaScriptBridge.eval("JSON.stringify(window.fortressNativeCommand || {})")
	if text.length() <= 1024:
		var value: Variant = JSON.parse_string(text)
		if value is Dictionary and int(value.get("id", 0)) > command_id:
			command_id = int(value.id)
			_command(value)
	var match_status: Types.Status = lobby.game_match.status()
	var game: ObservedGame = lobby.observations
	var result: Dictionary = {
		"state": lobby.state,
		"message": lobby.message,
		"room": lobby.room_code(),
		"uuid": uuid,
		"room_id": room_id,
		"slot": lobby.game_match.local_slot,
		"session_id": session_id,
		"ready_enabled": not scene.ready_button.disabled,
		"start_enabled": not scene.start_button.disabled,
		"command_id": command_id,
		"command_code": command_code,
		"frame": match_status.current_frame,
		"confirmed": match_status.confirmed_frame,
		"history_limit": HISTORY_LIMIT,
		"reason": match_status.reason,
		"terminated": match_status.lifecycle == Types.Lifecycle.TERMINATED,
		"turns": lobby.turns,
		"play_tick_gap_peak_us": lobby.play_tick_gap_peak_us,
		"sdk_receive_peak": lobby.sdk_receive_peak,
		"relay_receive_peak": lobby.relay_receive_peak,
		"relay_send_peak": lobby.relay_send_peak,
		"transport_start_delay": lobby.transport_start_delay,
		"previous_transport_delay": lobby.previous_transport_delay,
		"browser_open_wait_ticks": lobby.browser_open_wait_ticks,
		"open_mesh_wait_ticks": lobby.open_mesh_wait_ticks,
		"started_on_full_mesh": lobby.started_on_full_mesh,
		"failure_tick_callbacks": lobby.failure_tick_callbacks,
		"stalls": lobby.game_match.stalls,
		"failure": lobby.game_match.failure,
		"closed_channel_state": closed_channel_state,
		"closed_channel_frame": closed_channel_frame,
		"terminal_detail": lobby.game_match.driver.native_terminal_detail(),
		"interrupted": lobby.game_match.driver.native_interrupted_endpoints(),
		"sdk_roster": _sdk_roster(),
		"relay_peers": lobby.game_match.fallback.status().relay_peers,
	}
	if game != null:
		(
			result
			. merge(
				{
					"game_frame": game.frame,
					"saves": game.saves,
					"restores": game.restores,
					"advances": game.advances,
					"prediction": game.first_prediction,
					"movement_errors": game.movement_errors,
				}
			)
		)
		_capture_history(game)
	JavaScriptBridge.eval("window.fortressNative = " + JSON.stringify(result))


func _capture_history(game: ObservedGame) -> void:
	var frames: int = JavaScriptBridge.eval("window.fortressNativeCapture || 0")
	if frames < 1 or frames > HISTORY_LIMIT:
		return
	var rows: Dictionary = {}
	var snapshots: Dictionary = {}
	for input_frame: int in frames:
		var row_key: String = str(input_frame)
		var snapshot_key: String = str(input_frame + 1)
		rows[row_key] = game.rows.get(row_key)
		snapshots[snapshot_key] = game.snapshots.get(snapshot_key)
	var receipt: Dictionary = {"frames": frames, "rows": rows, "snapshots": snapshots}
	JavaScriptBridge.eval("window.fortressNativeCapture = 0; window.fortressNativeHistory = " + JSON.stringify(receipt))


func _command(value: Dictionary) -> void:
	command_code = OK
	match value.get("kind", ""):
		"connect":
			lobby.wait_for_full_mesh = bool(value.get("wait_for_full_mesh", false))
			scene.endpoint.text = str(value.endpoint)
			scene.player_name.text = str(value.name)
			scene.room_code.text = str(value.room)
			scene.backend_choice.select(2 if value.route == "relay" else 1)
			scene.room_size.value = int(value.players)
			var button: Button = scene.create_button if scene.room_code.text.is_empty() else scene.join_button
			button.pressed.emit()
			if lobby.client == null or lobby.backend != "native":
				command_code = ERR_UNAVAILABLE
				return
			lobby.observations = ObservedGame.new(int(value.players))
			lobby.game_match.game = lobby.observations
		"ready":
			scene.ready_button.pressed.emit()
			if not lobby.has_readied:
				command_code = ERR_UNAVAILABLE
				return
			uuid = lobby.game_match.membership.local_uuid()
			session_id = lobby.game_match.membership.handshake_message().session_id.hex_encode()
			room_id = lobby.client.call("get_room_id")
			JavaScriptBridge.eval("window.fortressNativeWire.bind(...%s)" % JSON.stringify([session_id, uuid]))
		"block_startup":
			blocked_uuid = str(value.uuid)
			lobby.client.connect("session_plan", _close_link, CONNECT_ONE_SHOT)
		"close_link":
			blocked_uuid = str(value.uuid)
			_close_link()
		"start":
			scene.start_button.pressed.emit()
		"leave":
			scene.leave_button.pressed.emit()


func _sdk_roster() -> PackedStringArray:
	var roster: PackedStringArray = []
	if lobby.client != null:
		var players: Array = lobby.client.call("get_players")
		for player: RefCounted in players:
			roster.append(player.get("id"))
	return roster


func _close_link(_plan: RefCounted = null) -> void:
	var transport: Object = lobby.mesh.call("get_multiplayer_peer")
	if transport == null:
		return
	var peer_id: int = Lobby.Match.Membership.uuid_to_peer_id(blocked_uuid)
	if not transport.call("has_peer", peer_id):
		return
	var entry: Dictionary = transport.call("get_peer", peer_id)
	var channel: WebRTCDataChannel = entry.channels[2]
	closed_channel_state = channel.get_ready_state()
	closed_channel_frame = lobby.game_match.status().current_frame
	channel.close()
