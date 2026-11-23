extends Node

# Value: protects=callback correction and departure; fails_when=rows diverge or simulation continues after leave; why_new=legacy uses a different protocol; seam=browser sends
const Scene = preload("res://examples/online/online.tscn")
const Lobby = preload("res://examples/online/lobby.gd")
const Match = preload("res://examples/online/match.gd")
const RelayEnvelope = preload("res://addons/fortress_rollback/transport/signalfish_relay_envelope.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Reader = preload("res://addons/fortress_rollback/core/snapshot_reader.gd")
const Writer = preload("res://addons/fortress_rollback/core/snapshot_writer.gd")
const GATE_FRAME: int = 12
const HISTORY_LIMIT: int = 128
const RECOVERY_HISTORY_LIMIT: int = 512


class ObservedGame:
	extends Simulation

	var rows: Dictionary = {}
	var snapshots: Dictionary = {}
	var saves: int = 0
	var restores: int = 0
	var advances: int = 0
	var first_prediction: int = -1
	var movement_errors: int = 0
	var history_limit: int

	func _init(players: int, limit: int) -> void:
		super(players, Driver.Native.INPUT_BYTES)
		history_limit = limit

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
		if input_frame < history_limit:
			rows[str(input_frame)] = row
			snapshots[str(frame)] = canonical_bytes().hex_encode()
		return true


class ObservedMatch:
	extends Match

	var warmup_wire: JavaScriptObject
	var warmup_session: PackedByteArray
	var warmup_recipient: PackedByteArray

	func observe_sdk(sender: String, encoding: int, bytes: PackedByteArray) -> void:
		if warmup_wire == null or encoding != 1 or bytes.size() != RelayEnvelope.HEADER_BYTES + 46:
			return
		if (bytes[RelayEnvelope.HEADER_BYTES + 30] & 3) != 0 or bytes.slice(37, 53) != warmup_recipient:
			return
		var envelope: RelayEnvelope.Decoded = RelayEnvelope.decode(bytes, 46)
		if envelope.code == RelayEnvelope.R.Code.OK and envelope.sender == sender and envelope.session == warmup_session:
			_record("sdk", sender, envelope.payload, -1)

	func _receive_native(sender: String, bytes: PackedByteArray) -> int:
		var code: int = super._receive_native(sender, bytes)
		_record("native", sender, bytes, code)
		return code

	func _record(stage: String, sender: String, bytes: PackedByteArray, code: int) -> void:
		if warmup_wire == null or bytes.size() != 46 or (bytes[30] & 3) != 0:
			return
		# Match the pinned native quality report and retain its exact tagged bytes.
		if bytes.decode_u32(16) == 0x000252f5 and bytes.decode_u32(24) == 4 and bytes.slice(0, 16) == warmup_session:
			warmup_wire.recordWarmup(stage, sender, bytes.hex_encode(), code)


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
	var observe_recovery: bool = false
	var plan: Dictionary = {}
	var plan_events: int = 0
	var started_on_full_mesh: bool = false
	var play_tick_gap_peak_us: int = 0
	var sdk_receive_peak: int = 0
	var relay_receive_peak: int = 0
	var relay_send_peak: int = 0
	var warmup_wire: JavaScriptObject
	var _engine_mesh_open: bool = false
	var _last_play_tick_us: int = -1
	var _next_warmup_tick_us: int = 0

	func _connect_callbacks() -> void:
		if observe_recovery:
			client.connect("session_plan", _record_plan)
		super._connect_callbacks()

	func _record_plan(value: RefCounted) -> void:
		plan = value.call("to_dict")
		plan_events += 1

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
		var available: int = -1
		var budget: int = -1
		if state == "playing":
			if _last_play_tick_us >= 0:
				play_tick_gap_peak_us = maxi(play_tick_gap_peak_us, now_us - _last_play_tick_us)
			_last_play_tick_us = now_us
			available = _sdk_packets()
			sdk_receive_peak = maxi(sdk_receive_peak, available)
			if warmup_wire != null:
				budget = int(client.get("transport").get("max_packets_per_poll"))
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
		if warmup_wire != null and available >= 0 and (available >= budget or now_us >= _next_warmup_tick_us or state == "failed"):
			var remaining: int = _sdk_packets() if state == "playing" else -1
			warmup_wire.recordWarmupTick(available, remaining, budget, Time.get_ticks_usec() - now_us, state == "failed")
			_next_warmup_tick_us = now_us + 250000

	func _sdk_packets() -> int:
		# The pinned SDK transport owns the socket adapter and exposes no receive queue getter.
		var transport: RefCounted = client.get("transport")
		var socket: RefCounted = transport.get("_peer")
		return int(socket.call("get_available_packet_count")) if socket != null else -1


var scene: Node2D
var lobby: ObservedLobby
var command_id: int = 0
var command_code: Error = OK
var session_id: String = ""
var uuid: String = ""
var room_id: String = ""
var warmup_match: ObservedMatch
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
	if warmup_match != null and (lobby.state == "failed" or match_status.confirmed_frame >= GATE_FRAME):
		lobby.warmup_wire.finishWarmup("failed" if lobby.state == "failed" else "gate")
		if is_instance_valid(lobby.client):
			lobby.client.disconnect("game_data_binary_received", warmup_match.observe_sdk)
		warmup_match.warmup_wire = null
		lobby.warmup_wire = null
		warmup_match = null
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
		"history_limit": game.history_limit if game != null else HISTORY_LIMIT,
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
		"plan": lobby.plan,
		"plan_events": lobby.plan_events,
		"sdk_room_id": lobby.client.call("get_room_id") if lobby.client != null else "",
		"sdk_epochs": _sdk_epochs(),
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
	if frames < 1 or frames > game.history_limit:
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
			lobby.observe_recovery = bool(value.get("observe_recovery", false))
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
			if bool(value.get("trace_warmup", false)):
				if lobby.state != "connecting":
					command_code = ERR_UNAVAILABLE
					return
				warmup_match = ObservedMatch.new()
				lobby.warmup_wire = JavaScriptBridge.get_interface("fortressNativeWire")
				warmup_match.warmup_wire = lobby.warmup_wire
				lobby.game_match = warmup_match
				lobby.client.connect("game_data_binary_received", warmup_match.observe_sdk)
			var history_limit: int = RECOVERY_HISTORY_LIMIT if lobby.observe_recovery else HISTORY_LIMIT
			lobby.observations = ObservedGame.new(int(value.players), history_limit)
			lobby.game_match.game = lobby.observations
		"ready":
			scene.ready_button.pressed.emit()
			if not lobby.has_readied:
				command_code = ERR_UNAVAILABLE
				return
			uuid = lobby.game_match.membership.local_uuid()
			session_id = lobby.game_match.membership.handshake_message().session_id.hex_encode()
			room_id = lobby.client.call("get_room_id")
			var roster: PackedStringArray = []
			if warmup_match != null:
				roster = lobby.game_match.membership.roster()
				warmup_match.warmup_session = session_id.hex_decode()
				warmup_match.warmup_recipient = uuid.replace("-", "").hex_decode()
			JavaScriptBridge.eval("window.fortressNativeWire.bind(...%s)" % JSON.stringify([session_id, uuid, roster]))
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


func _sdk_epochs() -> Dictionary:
	var epochs: Dictionary = {}
	if lobby.observe_recovery:
		for player: String in _sdk_roster():
			epochs[player] = lobby.client.call("_get_player_epoch", player)
	return epochs


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
