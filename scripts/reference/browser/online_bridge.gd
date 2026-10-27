extends Node

# Development observer: actual scene/UI and actual driver remain the execution path.
const Scene = preload("res://examples/online/online.tscn")
const Simulation = preload("res://examples/offline/simulation.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Writer = preload("res://addons/fortress_rollback/core/snapshot_writer.gd")
const Reader = preload("res://addons/fortress_rollback/core/snapshot_reader.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const Lobby = preload("res://examples/online/lobby.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const ReplayPlayer = preload("res://addons/fortress_rollback/core/replay_player.gd")
# A 16 KiB replay becomes 32 KiB of hex; reserve bounded JSON field overhead.
const MAX_COMMAND_CHARS: int = 2 * 16384 + 1024


## Bounded summary of the host's service cadence and of its confirmation waits.
## The clock is injected: the exported page passes the real host clock, native suites pass their own.
## The summary never enters the canonical game state, the retained diagnostics or a recording.
class Scheduling:
	var turns: int = 0
	var max_gap_us: int = 0
	var max_gap_turns: int = 1
	var max_gap_transport_us: int = 0
	var confirmation_max_gap_us: int = 0
	var confirmation_max_gap_turns: int = 1
	var confirmed_frames: int = 0

	var _last_turn_us: int = -1
	var _last_transport_us: int = 0
	var _last_current: int = -1
	var _last_confirmed: int = -1
	var _submitted: Dictionary = {}

	## A new room starts a new summary: the counters describe one room, not the page.
	func reset() -> void:
		turns = 0
		max_gap_us = 0
		max_gap_turns = 1
		max_gap_transport_us = 0
		confirmation_max_gap_us = 0
		confirmation_max_gap_turns = 1
		confirmed_frames = 0
		_last_turn_us = -1
		_last_transport_us = 0
		_last_current = -1
		_last_confirmed = -1
		_submitted.clear()

	## One service turn: the host clock, the elapsed transport clock and the local/confirmed frames.
	## A turn outside a running match stamps no frame, so room setup is not a confirmation wait.
	func record_turn(now_us: int, transport_us: int, current: int, confirmed: int, running: bool = true) -> void:
		if now_us < _last_turn_us:
			return
		if _last_turn_us >= 0:
			var gap: int = now_us - _last_turn_us
			if gap > max_gap_us:
				max_gap_us = gap
				max_gap_turns = _nominal_turns(gap)
				# A new room restarts the transport clock, so the covered time never goes backwards.
				max_gap_transport_us = maxi(0, transport_us - _last_transport_us)
		turns += 1
		_last_turn_us = now_us
		_last_transport_us = transport_us
		if not running:
			return
		# A running session starts with no confirmed frame: the frames it submits are
		# stamped anyway, so the first confirmation still reports its wait.
		if current > _last_current:
			for frame: int in range(_last_current + 1, current + 1):
				_submitted[frame] = now_us
		_last_current = maxi(_last_current, current)
		if confirmed > _last_confirmed:
			for frame: int in range(_last_confirmed + 1, confirmed + 1):
				var gap: int = now_us - int(_submitted.get(frame, now_us))
				if gap > confirmation_max_gap_us:
					confirmation_max_gap_us = gap
					confirmation_max_gap_turns = _nominal_turns(gap)
				_submitted.erase(frame)
			confirmed_frames += confirmed - _last_confirmed
			_last_confirmed = confirmed
		# Only the frames between the confirmed frontier and the current frame stay retained.
		for frame: Variant in _submitted.keys():
			if int(frame) <= confirmed:
				_submitted.erase(frame)

	## The nominal fixed-tick turns a pause covered.
	func _nominal_turns(gap_us: int) -> int:
		return maxi(1, gap_us * maxi(1, Engine.physics_ticks_per_second) / 1000000)

	func summary() -> Dictionary:
		return {
			"turns": turns,
			"ticks_per_second": maxi(1, Engine.physics_ticks_per_second),
			"max_gap_us": max_gap_us,
			"max_gap_turns": max_gap_turns,
			"max_gap_transport_us": max_gap_transport_us,
			"confirmation_max_gap_us": confirmation_max_gap_us,
			"confirmation_max_gap_turns": confirmation_max_gap_turns,
			"confirmed_frames": confirmed_frames
		}


class ObservedLobby:
	extends Lobby
	var resume: Dictionary = {}
	var label: String = ""
	var scheduling: Scheduling = Scheduling.new()

	var _observed_match: Variant = null

	## A new room starts a new summary, so the counters describe one room.
	func connect_room(endpoint: String, player_name: String, room: String, now_us: int) -> Error:
		var previous: Variant = game_match
		var code: Error = super.connect_room(endpoint, player_name, room, now_us)
		if game_match != previous:
			_observed_match = game_match
			scheduling.reset()
		return code

	func tick(now_us: int, buttons: int) -> void:
		# A new room starts a new summary, so the counters describe one room.
		if game_match != _observed_match:
			_observed_match = game_match
			scheduling.reset()
		var armed: String = str(JavaScriptBridge.eval("window.fortressOnlineResumeLabel || ''"))
		if armed != label:
			label = armed
			resume.clear()
		var before: int = game_match.peer.status().current_frame
		var clock_before: int = _last_now
		var protocol_before: int = game_match.peer.network_status().last_now_us
		var was_playing: bool = state == "playing"
		super.tick(now_us, buttons)
		if was_playing and not label.is_empty() and now_us - clock_before > int(resume.get("gap_us", 0)):
			resume = {
				"label": label,
				"host_before_us": clock_before,
				"host_after_us": now_us,
				"gap_us": now_us - clock_before,
				"protocol_before_us": protocol_before,
				"protocol_after_us": game_match.peer.network_status().last_now_us,
				"frame_before": before,
				"frame_after": game_match.peer.status().current_frame,
				"state": state,
				"message": message
			}
		var playing: bool = state == "playing"
		var status: Variant = game_match.peer.status()
		scheduling.record_turn(now_us, game_match.peer.network_status().last_now_us, status.current_frame, status.confirmed_frame, playing)


class ObservedGame:
	extends Simulation
	var saves: Dictionary = {}
	var restores: int = 0
	var is_corrupt: bool = false
	var predicted_frame: int = -1
	var lifetime: int = 0

	func simulate_frame(input_frame: int, frame_inputs: Types.FrameInputs) -> bool:
		var predicted: bool = false
		if input_frame >= 2:
			for player: int in frame_inputs.player_count():
				var sample: Types.InputResult = frame_inputs.read(player)
				predicted = predicted or (sample.code == Types.Code.OK and sample.status == Queue.Status.PREDICTED)
		var accepted: bool = super.simulate_frame(input_frame, frame_inputs)
		if accepted and predicted and predicted_frame < 0:
			predicted_frame = input_frame
		return accepted

	func save_state(saved_frame: int, writer: Writer) -> Driver.SaveResult:
		var result: Driver.SaveResult = super.save_state(saved_frame, writer)
		if result.ok and saved_frame < 256:
			saves[saved_frame] = canonical_bytes().hex_encode()
		return result

	func load_state(saved_frame: int, reader: Reader) -> bool:
		var accepted: bool = super.load_state(saved_frame, reader)
		if accepted:
			restores += 1
			if is_corrupt:
				x[0] = 20 + (x[0] - 20 + 1) % 441
		return accepted


var scene: Node2D
var observed: ObservedGame
var inputs: Array[int] = []
var snapshots: Dictionary = {}
var command_id: int = 0
var old_callbacks: Array[Dictionary] = []
var stale_callbacks: Dictionary = {}
var replay_playback: Dictionary = {}
var diagnostic_scene: Node2D
var viewer_scene: Node2D
var game_lifetime: int = 0


func _ready() -> void:
	scene = Scene.instantiate()
	scene.controller = ObservedLobby.new()
	add_child(scene)
	JavaScriptBridge.eval("window.fortressOnlineReady = true")


func _process(_delta: float) -> void:
	# Commands cross the browser bridge as bounded JSON, never as executable snippets.
	var text: String = JavaScriptBridge.eval("JSON.stringify(window.fortressOnlineCommand || {})")
	if text.length() <= MAX_COMMAND_CHARS:
		var value: Variant = JSON.parse_string(text)
		if value is Dictionary and int(value.get("id", 0)) > command_id:
			command_id = int(value.id)
			_command(value)
	var lobby: ObservedLobby = scene.controller as ObservedLobby
	if not lobby.has_readied and not lobby.game_match.game is ObservedGame:
		observed = ObservedGame.new()
		game_lifetime += 1
		observed.lifetime = game_lifetime
		observed.is_corrupt = JavaScriptBridge.eval("window.fortressOnlineCorrupt || false")
		lobby.game_match.game = observed
		inputs.clear()
		snapshots.clear()
	var current: int = lobby.game_match.peer.status().current_frame
	var confirmed: int = lobby.game_match.peer.status().confirmed_frame
	var slot: int = lobby.game_match.local_slot
	var session_id: String = ""
	if lobby.has_readied:
		session_id = lobby.game_match.membership.handshake_message().session_id.hex_encode()
	if lobby.game_match.has_started and observed != null:
		current = lobby.game_match.peer.status().current_frame
		confirmed = lobby.game_match.peer.status().confirmed_frame
		var core: RefCounted = lobby.game_match.peer._core
		snapshots.merge(confirmed_snapshots(core, observed.saves), true)
	_capture_inputs(lobby)
	var result: Dictionary = {
		"state": lobby.state,
		"message": lobby.message,
		"room": lobby.room_code(),
		"slot": slot,
		"session_id": session_id,
		"uuid": lobby.game_match.membership.local_uuid() if lobby.has_readied else "",
		"room_id": lobby.client.call("get_room_id") if lobby.client != null else "",
		"direct_rejected": lobby.game_match.direct.status().rejected,
		"pending": lobby.game_match.fallback.status().pending_packets,
		"relay_pending": lobby.game_match.relay.status().pending_packets,
		"frame": current,
		"confirmed": confirmed,
		"failure": lobby.game_match.failure,
		"inputs": inputs,
		"snapshots": snapshots,
		"terminal_reason": lobby.game_match.peer.status().reason,
		"failure_diagnostic": lobby.game_match.peer.diagnostics() if lobby.state == "failed" else {},
		"failure_clocks": failure_clocks(lobby) if lobby.state == "failed" else [],
		"restores": observed.restores if observed != null else 0,
		"predicted_frame": observed.predicted_frame if observed != null else -1,
		"game_lifetime": observed.lifetime if observed != null else 0,
		"predicted_lifetime": observed.lifetime if observed != null and observed.predicted_frame >= 2 else 0,
		"corrupt": observed.is_corrupt if observed != null else false,
		"all_ready": lobby.all_ready,
		"ready_enabled": not scene.ready_button.disabled,
		"start_enabled": not scene.start_button.disabled,
		"command_id": command_id,
		"replay_enabled": not scene.replay_button.disabled,
		"replay_captured": lobby.game_match.replay_captured,
		"replay_capture_code": lobby.game_match.replay_capture_code,
		"replay_playback": replay_playback,
		"viewer": viewer_report(),
		"diagnostic_viewer": diagnostic_viewer_report(),
		"stale_callbacks": stale_callbacks,
		"resume": lobby.resume,
		"scheduling": lobby.scheduling.summary(),
		"host_now_us": lobby._last_now,
		"epoch_us": lobby._epoch
	}
	JavaScriptBridge.eval("window.fortressOnline = " + JSON.stringify(result))


func _capture_inputs(lobby: ObservedLobby) -> void:
	var slot: int = lobby.game_match.local_slot
	var core: Session = lobby.game_match.peer._core
	if observed == null or core == null or slot < 0:
		return
	var receipt: int = core.received_frames()[slot]
	while inputs.size() <= mini(receipt, 255):
		var actual: Queue.Result = core._queues[slot].retained_confirmed_input(inputs.size())
		if actual.code != Queue.Code.OK:
			break
		inputs.append(actual.bytes[0])


static func confirmed_snapshots(core: Session, saves: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	if core._mutation_code() != Session.Code.OK or not core._config.checksums_enabled:
		return result
	var status: Session.Types.Status = core.status()
	var ceiling: int = mini(status.current_frame, status.confirmed_frame - 1)
	if status.pending_rollback_frame != -1:
		ceiling = mini(ceiling, status.pending_rollback_frame)
	# Callback bytes outlive the nine-slot game ring; receipt alone never proves repair.
	for frame: int in saves:
		if frame >= 0 and frame < 256 and frame <= ceiling:
			result[str(frame)] = saves[frame]
	return result


func _command(value: Dictionary) -> void:
	match value.get("kind", ""):
		"create", "join":
			scene.endpoint.text = str(value.get("endpoint", ""))
			scene.player_name.text = str(value.get("name", "Player"))
			scene.room_code.text = str(value.get("room", ""))
			var button: Button = scene.create_button if value.kind == "create" else scene.join_button
			if not button.disabled:
				button.pressed.emit()
		"replay":
			if not scene.replay_button.disabled:
				scene.replay_button.pressed.emit()
		"finish_replay":
			if not scene.finish_replay_button.disabled:
				scene.finish_replay_button.pressed.emit()
		"watch_replay":
			viewer_scene = load("res://examples/online/replay.tscn").instantiate()
			scene.hide()
			scene.set_physics_process(false)
			add_child(viewer_scene)
		"inspect_diagnostic":
			diagnostic_scene = load("res://examples/online/diagnostic.tscn").instantiate()
			scene.hide()
			scene.set_physics_process(false)
			add_child(diagnostic_scene)
		"diagnostic_control":
			for button: Node in diagnostic_scene.find_children("*", "Button", true, false):
				if button is Button and button.text == value.get("button", "") and not button.disabled:
					button.pressed.emit()
		"viewer_target":
			for field: Node in viewer_scene.find_children("*", "SpinBox", true, false):
				if field is SpinBox:
					field.value = int(value.get("frame", 0))
		"viewer_control":
			for button: Node in viewer_scene.find_children("*", "Button", true, false):
				if button is Button and button.text == value.get("button", "") and not button.disabled:
					button.pressed.emit()
		"validate_replay":
			replay_playback = _play_replay(str(value.get("hex", "")))
		"diagnostics":
			if not scene.diagnostics_button.disabled:
				scene.diagnostics_button.pressed.emit()
		"ready":
			if not scene.ready_button.disabled:
				scene.trace_checkbox.button_pressed = value.get("capture_trace", false) == true
				scene.replay_checkbox.button_pressed = value.get("record_replay", false) == true
				scene.ready_button.pressed.emit()
		"start":
			if not scene.start_button.disabled:
				scene.start_button.pressed.emit()
		"capture_callbacks":
			var lobby: Lobby = scene.controller as Lobby
			old_callbacks.clear()
			for signal_name: String in ["protocol_info", "room_joined", "lobby_state_changed", "protocol_error"]:
				for connection: Dictionary in lobby.client.get_signal_connection_list(signal_name):
					if connection.callable.get_object() != lobby._callbacks:
						continue
					old_callbacks.append({"kind": signal_name, "callable": connection.callable, "receiver": connection.callable.get_object(), "info": lobby._info})
		"old_callbacks":
			var lobby: Lobby = scene.controller as Lobby
			var before: Dictionary = callback_boundary(lobby)
			var calls: int = 0
			var kinds: PackedStringArray = PackedStringArray()
			for callback: Dictionary in old_callbacks:
				if callback.callable.is_valid():
					match callback.kind:
						"protocol_info":
							callback.callable.call(callback.info)
						"room_joined":
							callback.callable.call(null)
						"lobby_state_changed":
							callback.callable.call(0, PackedStringArray(), false)
						"protocol_error":
							callback.callable.call("delayed old-room error")
					calls += 1
					kinds.append(callback.kind)
			stale_callbacks = {"calls": calls, "kinds": kinds, "before": before, "after": callback_boundary(lobby)}
		"leave":
			if not scene.leave_button.disabled:
				scene.leave_button.pressed.emit()


func callback_boundary(lobby: Lobby) -> Dictionary:
	return {
		"state": lobby.state,
		"message": lobby.message,
		"all_ready": lobby.all_ready,
		"has_readied": lobby.has_readied,
		"session_id": lobby.game_match.membership.handshake_message().session_id.hex_encode(),
		"room_id": lobby.client.call("get_room_id"),
		"frame": lobby.game_match.peer.status().current_frame,
		"canonical": lobby.game_match.game.canonical_bytes().hex_encode(),
		"failure": lobby.game_match.failure,
		"info_id": str(lobby._info.get_instance_id()) if lobby._info != null else ""
	}


func _play_replay(hex: String) -> Dictionary:
	var recording: Replay = Replay.new()
	var decoded: int = recording.decode(hex.hex_decode(), 16384)
	if decoded != Replay.DecodeCode.OK or recording.frame_count() > 256:
		return {"decode_code": decoded}
	var game: Simulation = Simulation.new()
	var player: ReplayPlayer = ReplayPlayer.new()
	var code: int = player.configure(recording, game, Simulation.SNAPSHOT_BYTES)
	while code == Session.Code.OK:
		code = player.step()
	return {"decode_code": decoded, "code": code, "frames": player.current_frame(), "failure_frame": player.failure_frame(), "canonical": game.canonical_bytes().hex_encode()}


func viewer_report() -> Dictionary:
	if viewer_scene == null:
		return {}
	var viewer: RefCounted = viewer_scene.viewer
	return {
		"frame": viewer.current_frame(),
		"frames": viewer.frame_count(),
		"playing": viewer.is_playing,
		"message": viewer.message,
		"state": viewer.game.canonical_bytes().hex_encode()
	}


func failure_clocks(lobby: Lobby) -> Array[Dictionary]:
	var clocks: Array[Dictionary] = []
	for endpoint: Dictionary in lobby.game_match.peer.network_status().peers.values():
		clocks.append({"now_us": endpoint.get("now_us", -1), "last_recv_us": endpoint.get("last_recv_us", -1), "last_send_us": endpoint.get("last_send_us", -1)})
	return clocks


func diagnostic_viewer_report() -> Dictionary:
	if diagnostic_scene == null:
		return {}
	return {"status": diagnostic_scene.viewer.status(), "state": diagnostic_scene.viewer.game.canonical_bytes().hex_encode(), "message": diagnostic_scene.viewer.message}
