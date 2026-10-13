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


func _ready() -> void:
	scene = Scene.instantiate()
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
	var lobby: Lobby = scene.controller
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
		"frame": current, "confirmed": confirmed, "failure": lobby.game_match.failure, "inputs": inputs, "snapshots": snapshots,
		"restores": observed.restores if observed != null else 0, "all_ready": lobby.all_ready,
		"ready_enabled": not scene.ready_button.disabled, "start_enabled": not scene.start_button.disabled, "command_id": command_id}
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
		"ready":
			if not scene.ready_button.disabled:
				scene.ready_button.pressed.emit()
		"start":
			if not scene.start_button.disabled:
				scene.start_button.pressed.emit()
		"leave":
			if not scene.leave_button.disabled:
				scene.leave_button.pressed.emit()
