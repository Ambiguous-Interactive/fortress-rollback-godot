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
const HISTORY_FRAMES: int = 40


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
		var result: Driver.SaveResult = super.save_state(saved_frame, writer)
		if result.ok:
			saves += 1
		return result

	func load_state(saved_frame: int, reader: Reader) -> bool:
		var accepted: bool = super.load_state(saved_frame, reader)
		if accepted:
			restores += 1
		return accepted

	func simulate_frame(input_frame: int, inputs: Types.FrameInputs) -> bool:
		var positions_x: PackedInt32Array = x.duplicate()
		var positions_y: PackedInt32Array = y.duplicate()
		var accepted: bool = super.simulate_frame(input_frame, inputs)
		if not accepted:
			return false
		advances += 1
		var row: Array[int] = []
		for player: int in inputs.player_count():
			var sample: Types.InputResult = inputs.read(player)
			var buttons: int = sample.bytes[0]
			row.append(buttons)
			if first_prediction == -1 and input_frame >= GATE_FRAME and sample.status == Queue.Status.PREDICTED:
				first_prediction = input_frame
			var dx: int = int(bool(buttons & RIGHT)) - int(bool(buttons & LEFT))
			var dy: int = int(bool(buttons & DOWN)) - int(bool(buttons & UP))
			if x[player] != clampi(positions_x[player] + 2 * dx, 20, 460) or y[player] != clampi(positions_y[player] + 2 * dy, 20, 280):
				movement_errors += 1
		if input_frame < HISTORY_FRAMES:
			rows[str(input_frame)] = row
			snapshots[str(frame)] = canonical_bytes().hex_encode()
		return true


class ObservedLobby:
	extends Lobby

	var observations: ObservedGame
	var turns: int = 0

	func tick(now_us: int, buttons: int) -> void:
		turns += 1
		if state == "playing":
			var frame: int = game_match.status().current_frame
			if frame == GATE_FRAME:
				JavaScriptBridge.eval("window.fortressNativeWire.arm()")
			# Alternate the actual canvas input after the gate starts. A peer
			# predicting the last delivered row must then correct its game state.
			if frame >= GATE_FRAME and frame % 2 == 0:
				buttons = 0
		super.tick(now_us, buttons)


var scene: Node2D
var lobby: ObservedLobby
var command_id: int = 0
var command_code: Error = OK
var session_id: String = ""
var uuid: String = ""
var room_id: String = ""


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
		"reason": match_status.reason,
		"terminated": match_status.lifecycle == Types.Lifecycle.TERMINATED,
		"turns": lobby.turns,
		"stalls": lobby.game_match.stalls,
		"failure": lobby.game_match.failure,
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
		# Keep full callback history out of the per-render status payload.
		if JavaScriptBridge.eval("window.fortressNativeCapture === true"):
			result["rows"] = game.rows
			result["snapshots"] = game.snapshots
	JavaScriptBridge.eval("window.fortressNative = " + JSON.stringify(result))


func _command(value: Dictionary) -> void:
	command_code = OK
	match value.get("kind", ""):
		"connect":
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
			JavaScriptBridge.eval("window.fortressNativeWire.bind(" + JSON.stringify(session_id) + ")")
		"start":
			scene.start_button.pressed.emit()
		"leave":
			scene.leave_button.pressed.emit()
