extends SceneTree

const Spectator = preload("res://addons/fortress_rollback/core/spectator_session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
class Game:
	extends RefCounted
	var transcript: Array[Array] = []

	func save_state(_frame: int, _writer: RefCounted) -> Driver.SaveResult:
		return Driver.SaveResult.new(false)

	func load_state(_frame: int, _reader: RefCounted) -> bool:
		return false

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		var row: Array[int] = [frame]
		if inputs.size().value != 2:
			return false
		for player: int in range(2):
			var input: Types.InputResult = inputs.read(player)
			if input.code != Types.Code.OK or input.bytes.size() != 1 or input.status != Spectator.Queue.Status.CONFIRMED:
				return false
			row.append(input.bytes[0])
		transcript.append(row)
		return true


func _initialize() -> void:
	var traces: Array[Dictionary] = []
	for case_id: int in range(4):
		var capacity: int = 2 + case_id % 2
		var preplay: bool = case_id < 2
		var speed: int = 2 if preplay else 1
		var config: Config = Config.new()
		config.spectator = true
		config.local_players = PackedInt32Array()
		config.sync_test = false
		config.check_distance = 0
		config.max_prediction_frames = 0
		config.queue_capacity = capacity
		config.history_slots = 1
		config.max_snapshot_bytes = 8
		config.storage_budget_bytes = config.required_storage_bytes()
		var viewer: Spectator = Spectator.new()
		if viewer.configure(config) != Types.Code.OK or viewer.set_playback(0, 1, speed) != Types.Code.OK:
			quit(2)
			return
		var game: Game = Game.new()
		var driver: Driver = Driver.new(viewer, game)
		var observations: Array[Dictionary] = [_observe(viewer)]
		var empty: Array[Driver.LocalInput] = []
		for frame: int in range(12):
			var row: Array[PackedByteArray] = [PackedByteArray([frame % 2]), PackedByteArray([0])]
			if viewer.receive_host_frame(frame, row).code != Types.Code.OK:
				quit(2)
				return
			observations.append(_observe(viewer))
			# Preserve preplay backlog; the second case starts before filling a complete ring.
			if (preplay and frame % capacity == capacity - 1) or (not preplay and frame % capacity == 0) or frame == 11:
				var pending: int = viewer.host_frontier() - viewer.status().current_frame + 1
				for _step: int in range(pending):
					if driver.step(frame, empty).code != Types.Code.OK:
						quit(2)
						return
					observations.append(_observe(viewer))
				if driver.step(frame, empty).code != Types.Code.PREDICTION_STALL:
					quit(2)
					return
				observations.append(_observe(viewer))
		traces.append({"capacity": capacity, "preplay": preplay, "speed": speed, "observations": observations, "transcript": game.transcript})
	print("FORTRESS_SPECTATOR_TRACE " + JSON.stringify(traces))
	quit(0)


func _observe(viewer: Spectator) -> Dictionary:
	var buffer: Array[Array] = []
	for index: int in range(viewer._host_tags.size()):
		var row: Array[int] = [0, 0]
		if viewer._host_tags[index] >= 0:
			row = [viewer._host_rows[index][0], viewer._host_rows[index][1]]
		buffer.append(row)
	var backlog: int = viewer.host_frontier() - viewer.status().current_frame + 1
	return {
		"current": viewer.status().current_frame - 1, "received": viewer.host_frontier(), "tags": Array(viewer._host_tags), "inputs": buffer,
		"backlog": backlog, "advice": viewer.recommended_steps(), "catchup": backlog > viewer.playback_policy()[1]
	}
