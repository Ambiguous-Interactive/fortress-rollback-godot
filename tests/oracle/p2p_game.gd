extends RefCounted

const Reference = preload("res://tests/oracle/reference_game.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
var game: RefCounted
var requests: Array[Dictionary] = []


func _init(players: int) -> void:
	game = Reference.new(players, 2)


func _record(kind: String, frame: int, inputs: Array[Dictionary]) -> void:
	requests.append({"kind": kind, "frame": frame, "inputs": inputs, "state_bytes": game.bytes().hex_encode(), "checksum": game.checksum()})


func save_state(frame: int, writer: RefCounted) -> Driver.SaveResult:
	var ok: bool = frame == game.frame and writer.write_bytes(game.bytes()) == 0
	_record("save", frame, [])
	return Driver.SaveResult.new(ok, game.checksum().hex_decode())


func load_state(frame: int, reader: RefCounted) -> bool:
	var restored: RefCounted = reader.read_bytes(game.bytes().size())
	if restored.code != 0 or not reader.is_complete() or not game.restore(restored.bytes).is_empty() or game.frame != frame:
		return false
	_record("load", frame, [])
	return true


func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
	if game.frame != frame or inputs == null:
		return false
	var size: Types.Result = inputs.size()
	if size.code != Types.Code.OK or size.value != game.accumulators.size():
		return false
	var traced: Array[Dictionary] = []
	for player: int in range(size.value):
		var input: Types.InputResult = inputs.read(player)
		if input.code != Types.Code.OK or input.status not in [Queue.Status.CONFIRMED, Queue.Status.PREDICTED] or input.bytes.size() != 4:
			return false
		var status: String = "confirmed" if input.status == Queue.Status.CONFIRMED else "predicted"
		traced.append({"player": player, "bytes": input.bytes.hex_encode(), "status": status})
	if not game.advance(traced).is_empty():
		return false
	_record("advance", frame, traced)
	return true
