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


class ObservedLobby:
	extends Lobby
	var resume: Dictionary = {}
	var label: String = ""

	func tick(now_us: int, buttons: int) -> void:
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
			resume = {"label": label, "host_before_us": clock_before, "host_after_us": now_us, "gap_us": now_us - clock_before,
				"protocol_before_us": protocol_before, "protocol_after_us": game_match.peer.network_status().last_now_us,
				"frame_before": before, "frame_after": game_match.peer.status().current_frame, "state": state, "message": message}


class ObservedGame:
	extends Simulation
	var saves: Dictionary = {}
	var restores: int = 0
	var is_corrupt: bool = false

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


func _ready() -> void:
	scene = Scene.instantiate()
	scene.controller = ObservedLobby.new()
	add_child(scene)
	JavaScriptBridge.eval("window.fortressOnlineReady = true")


func _process(_delta: float) -> void:
	# Commands cross the browser bridge as bounded JSON, never as executable snippets.
	var text: String = JavaScriptBridge.eval("JSON.stringify(window.fortressOnlineCommand || {})")
	if text.length() <= 4096:
		var value: Variant = JSON.parse_string(text)
		if value is Dictionary and int(value.get("id", 0)) > command_id:
			command_id = int(value.id)
			_command(value)
	var lobby: ObservedLobby = scene.controller as ObservedLobby
	if not lobby.has_readied and not lobby.game_match.game is ObservedGame:
		observed = ObservedGame.new()
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
		var receipt: int = core.received_frames()[slot]
		while inputs.size() <= mini(receipt, 255):
			var actual: Queue.Result = core._queues[slot].retained_confirmed_input(inputs.size())
			if actual.code != Queue.Code.OK:
				break
			inputs.append(actual.bytes[0])
		snapshots.merge(confirmed_snapshots(core, observed.saves), true)
	var result: Dictionary = {"state": lobby.state, "message": lobby.message, "room": lobby.room_code(), "slot": slot, "session_id": session_id,
		"uuid": lobby.game_match.membership.local_uuid() if lobby.has_readied else "",
		"room_id": lobby.client.call("get_room_id") if lobby.client != null else "",
		"direct_rejected": lobby.game_match.direct.status().rejected,
		"pending": lobby.game_match.fallback.status().pending_packets, "relay_pending": lobby.game_match.relay.status().pending_packets,
		"frame": current, "confirmed": confirmed, "failure": lobby.game_match.failure, "inputs": inputs, "snapshots": snapshots,
		"terminal_reason": lobby.game_match.peer.status().reason,
		"restores": observed.restores if observed != null else 0, "all_ready": lobby.all_ready,
		"ready_enabled": not scene.ready_button.disabled, "start_enabled": not scene.start_button.disabled, "command_id": command_id,
		"stale_callbacks": stale_callbacks, "resume": lobby.resume, "host_now_us": lobby._last_now, "epoch_us": lobby._epoch}
	JavaScriptBridge.eval("window.fortressOnline = " + JSON.stringify(result))


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
		"diagnostics":
			if not scene.diagnostics_button.disabled:
				scene.diagnostics_button.pressed.emit()
		"ready":
			if not scene.ready_button.disabled:
				scene.trace_checkbox.button_pressed = value.get("capture_trace", false) == true
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
	return {"state": lobby.state, "message": lobby.message, "all_ready": lobby.all_ready, "has_readied": lobby.has_readied,
		"session_id": lobby.game_match.membership.handshake_message().session_id.hex_encode(),
		"room_id": lobby.client.call("get_room_id"), "frame": lobby.game_match.peer.status().current_frame,
		"canonical": lobby.game_match.game.canonical_bytes().hex_encode(), "failure": lobby.game_match.failure,
		"info_id": str(lobby._info.get_instance_id()) if lobby._info != null else ""}
