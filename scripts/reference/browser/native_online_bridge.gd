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
const MAX_COMMAND_ID: int = 9_007_199_254_740_991
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
	var warmup_header: int
	var warmup_session: PackedByteArray
	var warmup_recipient: PackedByteArray
	var warmup_input_sender: String
	var warmup_ack_sender: String
	var last_native_acceptances: Dictionary = {}

	func observe_sdk(sender: String, encoding: int, bytes: PackedByteArray) -> void:
		if warmup_wire == null or encoding != 1:
			return
		var quality: bool = bytes.size() == RelayEnvelope.HEADER_BYTES + 46 and (bytes[RelayEnvelope.HEADER_BYTES + 30] & 3) == 0
		var watched_input: bool = sender == warmup_input_sender and bytes.size() > RelayEnvelope.HEADER_BYTES + 108
		var watched_ack: bool = sender == warmup_ack_sender and bytes.size() == RelayEnvelope.HEADER_BYTES + 32
		if not (watched_input or watched_ack or quality) or bytes.slice(37, 53) != warmup_recipient:
			return
		var envelope: RelayEnvelope.Decoded = RelayEnvelope.decode(bytes, NATIVE_PACKET_BYTES)
		if envelope.code == RelayEnvelope.R.Code.OK and envelope.sender == sender and envelope.session == warmup_session:
			_record("sdk", sender, envelope.payload, -1)

	func _receive_native(sender: String, bytes: PackedByteArray) -> int:
		var code: int = super._receive_native(sender, bytes)
		if code == Inputs.Code.OK:
			last_native_acceptances[sender] = {
				"accepted_us": Time.get_ticks_usec(),
				"kind": bytes.decode_u32(NATIVE_TAG_BYTES + 8) if bytes.size() >= NATIVE_TAG_BYTES + 12 else null,
				"bytes": bytes.size(),
			}
		_record("native", sender, bytes, code)
		return code

	func _record(stage: String, sender: String, bytes: PackedByteArray, code: int) -> void:
		if warmup_wire == null:
			return
		var quality: bool = bytes.size() == 46 and (bytes[30] & 3) == 0
		var watched_input: bool = sender == warmup_input_sender and bytes.size() > 108 and bytes.size() <= NATIVE_PACKET_BYTES
		var watched_ack: bool = sender == warmup_ack_sender and bytes.size() == 32
		if not (watched_input or watched_ack or quality) or bytes.decode_u32(16) != warmup_header or bytes.slice(0, 16) != warmup_session:
			return
		var kind: int = bytes.decode_u32(24)
		if (watched_input and kind == 2) or (watched_ack and kind == 3):
			warmup_wire.observeWarmupInput(stage, sender, bytes.hex_encode(), code)
		elif quality and kind == 4:
			warmup_wire.recordWarmup(stage, sender, bytes.hex_encode(), code)


class ObservedMultiplayer:
	extends "res://addons/fortress_rollback/transport/signalfish_webrtc_multiplayer_peer.gd"

	var _wire: JavaScriptObject
	var _remote_uuids: Dictionary
	var _target_peer: int = 0

	func _init(wire: JavaScriptObject, remote_uuids: Dictionary) -> void:
		_wire = wire
		_remote_uuids = remote_uuids

	@warning_ignore("native_method_override")
	func set_target_peer(peer_id: int) -> void:
		super.set_target_peer(peer_id)
		_target_peer = peer_id

	@warning_ignore("native_method_override")
	func put_packet(bytes: PackedByteArray) -> Error:
		var boundary: int = 0
		if _wire.meshSendTracing():
			var player: String = _remote_uuids.get(_target_peer, "")
			boundary = _wire.beginMeshSend(player, bytes.hex_encode())
		var code: Error = super.put_packet(bytes)
		if boundary > 0:
			_wire.endMeshSend(boundary, code)
		return code

	@warning_ignore("native_method_override")
	func remove_peer(peer_id: int) -> void:
		var player: String = _remote_uuids.get(peer_id, "")
		if not player.is_empty():
			_wire.recordMeshDeparture("mesh_remove_peer", player, has_peer(peer_id))
		super.remove_peer(peer_id)


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
	var relay_batch_peak: int = 0
	var relay_overflow: Dictionary = {}
	var warmup_wire: JavaScriptObject
	var relay_trace: JavaScriptObject
	var trace_expiry_clock: bool = false
	var close_wire: JavaScriptObject
	var _close_remote_uuids: Dictionary = {}
	var _engine_mesh_open: bool = false
	var leave_unacknowledged: Variant
	var _last_play_tick_us: int = -1
	var _play_tick_gap_us: int = -1
	var _next_warmup_tick_us: int = 0
	var _next_native_frontier_us: int = 0
	var _is_sampling_native_expiry: bool = false
	var _sdk_before_poll: int = -1
	var _sdk_poll_budget: int = -1

	func _connect_callbacks() -> void:
		if observe_recovery:
			client.connect("session_plan", _record_plan)
		if relay_trace != null:
			client.connect("player_left", _record_departure)
		if close_wire != null:
			client.connect("player_left", _record_mesh_departure)
			mesh.set("multiplayer_peer_factory", _observed_multiplayer)
		super._connect_callbacks()

	func disconnect_room() -> void:
		if state == "leaving":
			leave_unacknowledged = _leave_pending.duplicate()
		super.disconnect_room()

	func bind_close_roster(roster: PackedStringArray, owner: String) -> void:
		_close_remote_uuids.clear()
		if close_wire == null or roster.size() > 8 or not roster.has(owner):
			return
		for player: String in roster:
			if player == owner:
				continue
			var peer_id: int = Match.Membership.uuid_to_peer_id(player)
			if peer_id <= 0 or _close_remote_uuids.has(peer_id):
				_close_remote_uuids.clear()
				return
			_close_remote_uuids[peer_id] = player

	func _observed_multiplayer() -> WebRTCMultiplayerPeer:
		return ObservedMultiplayer.new(close_wire, _close_remote_uuids)

	func _record_mesh_departure(player: String) -> void:
		close_wire.recordMeshDeparture("sdk_player_left", player)

	func _record_departure(player: String) -> void:
		relay_trace.recordDeparture("sdk_departure", player)

	func _fail(reason: String) -> void:
		if state == "playing" and relay_trace != null and game_match.driver.native_terminal_detail() == "disconnected":
			var endpoint: int = game_match.driver.native_terminal_endpoint()
			var roster: PackedStringArray = game_match.membership.roster()
			if endpoint > 0 and endpoint <= roster.size():
				var queued: int = _sdk_packets()
				var observed_match: ObservedMatch = game_match
				var evidence: Dictionary = {
					"observed_us": Time.get_ticks_usec(),
					"sdk_queued": queued,
					"sdk_peak": maxi(sdk_receive_peak, queued),
					"sdk_before_poll": _sdk_before_poll,
					"service_started_us": _last_now,
					"service_gap_us": _play_tick_gap_us,
					"service_gap_peak_us": play_tick_gap_peak_us,
					"last_accepted": observed_match.last_native_acceptances.get(roster[endpoint - 1]),
				}
				relay_trace.recordDeparture("native_expiry", endpoint, JSON.stringify(evidence), _is_sampling_native_expiry)
		super._fail(reason)

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
		_sdk_before_poll = -1
		_sdk_poll_budget = -1
		_play_tick_gap_us = -1
		if state == "playing":
			_play_tick_gap_us = now_us - _last_play_tick_us if _last_play_tick_us >= 0 else -1
			play_tick_gap_peak_us = maxi(play_tick_gap_peak_us, _play_tick_gap_us)
			callbacks = [observations.saves, observations.restores, observations.advances]
			var frame: int = game_match.status().current_frame
			# Variations after the warmup force correction when delivery is held.
			if frame >= GATE_FRAME and frame % 2 == 0:
				buttons = 0
		_is_sampling_native_expiry = trace_expiry_clock and state == "playing"
		if _is_sampling_native_expiry:
			relay_trace.beginNativeService()
		super.tick(now_us, buttons)
		_is_sampling_native_expiry = false
		_last_play_tick_us = now_us if state == "playing" else -1
		if relay_trace != null and state == "playing":
			var status: Types.Status = game_match.status()
			relay_trace.observe(state, turns, status.current_frame, status.confirmed_frame, observations.restores, observations.history_limit)
		if state == "failed" and previous_state == "playing":
			failure_tick_callbacks = callbacks
		var sdk_backlog: bool = _sdk_before_poll >= 0 and _sdk_before_poll >= _sdk_poll_budget
		if warmup_wire != null and (sdk_backlog or now_us >= _next_warmup_tick_us or state == "failed"):
			var remaining: int = _sdk_packets() if state == "playing" else -1
			var status: Types.Status = game_match.status()
			var elapsed_us: int = Time.get_ticks_usec() - now_us
			var native_frontier: String = _sample_native_frontier(now_us, status)
			warmup_wire.recordWarmupTick(_sdk_before_poll, remaining, _sdk_poll_budget, elapsed_us,
				state, status.current_frame, status.confirmed_frame, native_frontier)
			_next_warmup_tick_us = now_us + 250000

	func _sample_native_frontier(now_us: int, status: Types.Status) -> String:
		if state != "playing" or status.current_frame - status.confirmed_frame < 2 or now_us < _next_native_frontier_us:
			return ""
		_next_native_frontier_us = now_us + 250000
		var backend: Driver.Native = game_match.driver._native_backend
		var native: RefCounted = backend._native if backend != null else null
		if native == null or not native.has_method(&"confirmation_diagnostics"):
			return ""
		var slots: Array = native.call(&"confirmation_diagnostics")
		return JSON.stringify(slots) if not slots.is_empty() else ""

	func _sdk_packets() -> int:
		# The pinned SDK transport owns the socket adapter and exposes no receive queue getter.
		var transport: RefCounted = client.get("transport")
		var socket: RefCounted = transport.get("_peer")
		return int(socket.call("get_available_packet_count")) if socket != null else -1

	func _poll_client() -> int:
		if state != "playing":
			return super._poll_client()
		_sdk_before_poll = _sdk_packets()
		sdk_receive_peak = maxi(sdk_receive_peak, _sdk_before_poll)
		var before: Dictionary = game_match.relay.status()
		relay_send_peak = maxi(relay_send_peak, before.pending_packets)
		var started_us: int = Time.get_ticks_usec()
		_sdk_poll_budget = super._poll_client()
		if state != "playing":
			return _sdk_poll_budget
		var status: Dictionary = game_match.relay.status()
		var admitted: int = status.received_packets - int(before.received_packets)
		relay_batch_peak = maxi(relay_batch_peak, admitted)
		relay_receive_peak = maxi(relay_receive_peak, status.received_packets)
		var overflow: Dictionary = status.receive_overflow
		if not overflow.is_empty() and relay_overflow.is_empty():
			overflow.merge({
				"sdk_before": _sdk_before_poll,
				"sdk_after": _sdk_packets(),
				"sdk_budget": _sdk_poll_budget,
				"batch_admitted": admitted,
				"service_started_us": _last_now,
				"poll_started_us": started_us,
				"poll_finished_us": Time.get_ticks_usec(),
			})
			relay_overflow = overflow
		return _sdk_poll_budget


var scene: Node2D
var lobby: ObservedLobby
var command_id: int = 0
var command_code: Error = OK
var departure_id: int = 0
var departure_code: Error = OK
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
	JavaScriptBridge.eval("window.fortressNativeProfile = %s; window.fortressNativeReady = true" % JSON.stringify(Driver.Native.installed_profile()))


func _process(_delta: float) -> void:
	if departure_id == 0:
		_read_browser_command()
	var match_status: Types.Status = lobby.game_match.status()
	var warmup_ready: bool = lobby.state == "playing" and match_status.confirmed_frame >= GATE_FRAME
	if warmup_match != null and (lobby.state == "failed" or warmup_ready):
		lobby.warmup_wire.finishWarmup(lobby.state, match_status.current_frame, match_status.confirmed_frame, lobby.game_match.driver.native_terminal_endpoint())
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
		"relay_batch_peak": lobby.relay_batch_peak,
		"relay_overflow": lobby.relay_overflow,
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
		"terminal_endpoint": lobby.game_match.driver.native_terminal_endpoint(),
		"interrupted": lobby.game_match.driver.native_interrupted_endpoints(),
		"sdk_roster": _sdk_roster(),
		"sdk_mesh_peers": lobby.mesh.call("get_peer_ids") if lobby.state == "failed" and is_instance_valid(lobby.mesh) else [],
		"mesh_quiesced_for": lobby._quiesced_for,
		"leave_unacknowledged": lobby.leave_unacknowledged,
		"frozen_roster": lobby.game_match.membership.roster(),
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
	JavaScriptBridge.eval("window.fortressNative = " + JSON.stringify(result))
	if departure_id != 0 and (lobby.state == "offline" or departure_code != OK):
		JavaScriptBridge.eval(
			(
				"const { state, leave_unacknowledged: unacknowledged } = window.fortressNative; "
				+ "console.debug('fortress native departure ' + JSON.stringify({id: %d, stage: 'published', code: %d, state, unacknowledged, page_ms: performance.now()}))"
			) % [departure_id, departure_code],
			false
		)
		departure_id = 0
	if game != null:
		_capture_history(game)


func _read_browser_command() -> void:
	var text: String = JavaScriptBridge.eval("JSON.stringify(window.fortressNativeCommand || {})")
	if text.length() > 1024:
		return
	var value: Variant = JSON.parse_string(text)
	if not value is Dictionary:
		return
	var raw_id: Variant = value.get("id")
	if not (raw_id is int or raw_id is float) or not is_finite(float(raw_id)) or raw_id != floorf(float(raw_id)) \
		or raw_id <= command_id or raw_id > MAX_COMMAND_ID:
		return
	command_id = int(raw_id)
	if value.get("kind") == "leave":
		departure_id = command_id
		lobby.leave_unacknowledged = null
		JavaScriptBridge.eval("console.debug('fortress native departure ' + JSON.stringify({id: %d, stage: 'entered', page_ms: performance.now()}))" % departure_id)
	_command(value)
	if departure_id != 0:
		departure_code = command_code


func _capture_history(game: ObservedGame) -> void:
	var frames: int = JavaScriptBridge.eval("window.fortressNativeCapture?.frames || 0")
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
	JavaScriptBridge.eval(
		(
			"const {id} = window.fortressNativeCapture; window.fortressNativeCapture = null; const history = "
			+ JSON.stringify(receipt)
			+ "; window.fortressNativePostRelease?.mark('history_published', history.frames); "
			+ "console.debug('fortress native history ' + JSON.stringify({id, ...history}))"
		),
		false
	)


func _command(value: Dictionary) -> void:
	command_code = OK
	match value.get("kind", ""):
		"connect":
			if lobby.client != null:
				command_code = ERR_UNAVAILABLE
				return
			lobby.wait_for_full_mesh = bool(value.get("wait_for_full_mesh", false))
			lobby.observe_recovery = bool(value.get("observe_recovery", false))
			lobby.close_wire = JavaScriptBridge.get_interface("fortressNativeWire") if bool(value.get("trace_close", false)) else null
			lobby.relay_trace = JavaScriptBridge.get_interface("fortressNativePostRelease") if value.route == "relay" else null
			lobby.trace_expiry_clock = lobby.relay_trace != null and bool(value.get("trace_expiry_clock", false))
			scene.endpoint.text = str(value.endpoint)
			scene.player_name.text = str(value.name)
			scene.room_code.text = str(value.room)
			scene.backend_choice.select(2 if value.route == "relay" else 1)
			scene.room_size.value = int(value.players)
			var button: Button = scene.create_button if scene.room_code.text.is_empty() else scene.join_button
			button.pressed.emit()
			if lobby.client == null or lobby.backend != "native" or lobby.state != "connecting":
				command_code = ERR_UNAVAILABLE
				return
			if lobby.relay_trace != null:
				lobby.game_match = ObservedMatch.new()
				if bool(value.get("trace_warmup", false)):
					warmup_match = lobby.game_match
					lobby.warmup_wire = JavaScriptBridge.get_interface("fortressNativeWire")
					warmup_match.warmup_wire = lobby.warmup_wire
					var wire_version: int = Driver.Native.WIRE_PROFILES.get(Driver.Native.installed_profile(), 0)
					warmup_match.warmup_header = 0x52f5 | (wire_version << 16)
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
			var roster: PackedStringArray = lobby.game_match.membership.roster()
			if warmup_match != null:
				warmup_match.warmup_session = session_id.hex_decode()
				warmup_match.warmup_recipient = uuid.replace("-", "").hex_decode()
				if roster.size() == 8 and uuid == roster[1]:
					warmup_match.warmup_input_sender = roster[0]
				elif roster.size() == 8 and uuid == roster[0]:
					warmup_match.warmup_ack_sender = roster[1]
			JavaScriptBridge.eval("window.fortressNativeWire.bind(...%s)" % JSON.stringify([session_id, uuid, roster]))
			lobby.bind_close_roster(roster, uuid)
			if lobby.relay_trace != null:
				JavaScriptBridge.eval("window.fortressNativePostRelease.bindDeparture(...%s)" % JSON.stringify([uuid, roster]))
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
