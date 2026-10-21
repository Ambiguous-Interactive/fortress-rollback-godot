extends SceneTree

# Value: protects=raw callback statuses and error evidence; fails_when=invalid views silently become predicted;
# why_new=oracle game is independent of the production queue; seam=none
const Game = preload("res://tests/oracle/p2p_game.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
var failures: PackedStringArray = PackedStringArray()
var checks: int = 0


func _initialize() -> void:
	for status: int in [Queue.Status.NONE, -1, 4, 2147483647]:
		for slot: int in range(2):
			var statuses: PackedInt32Array = PackedInt32Array([Queue.Status.CONFIRMED, Queue.Status.PREDICTED])
			statuses[slot] = status
			_rejected(Types.FrameInputs.new(_bytes(), statuses), "invalid status " + str(status) + " slot " + str(slot))
	_rejected(BrokenRead.new(_bytes(), PackedInt32Array([1, 2])), "failed input read")
	_rejected(BrokenSize.new(_bytes(), PackedInt32Array([1, 2])), "failed view size")
	var expired: Types.FrameInputs = Types.FrameInputs.new(_bytes(), PackedInt32Array([1, 2]))
	expired._expire()
	_rejected(expired, "expired view")
	_rejected(Types.FrameInputs.new([], PackedInt32Array()), "missing roster")
	var valid: RefCounted = Game.new(2)
	checks += 1
	if not valid.simulate_frame(0, Types.FrameInputs.new(_bytes(), PackedInt32Array([1, 2]))):
		failures.append("valid mixed confirmed/predicted rejected")
	checks += 1
	if valid.game.frame != 1 or valid.requests.size() != 1 or valid.requests[0].inputs[1].status != "predicted":
		failures.append("valid callback evidence missing")
	# A dropped slot reports its own status, which the game keeps as evidence.
	var dropped: RefCounted = Game.new(2)
	checks += 1
	if not dropped.simulate_frame(0, Types.FrameInputs.new(_bytes(), PackedInt32Array([1, Queue.Status.DISCONNECTED]))):
		failures.append("valid disconnected status rejected")
	checks += 1
	if dropped.game.frame != 1 or dropped.requests.size() != 1 or dropped.requests[0].inputs[1].status != "disconnected":
		failures.append("disconnected callback evidence missing")
	print("FORTRESS_P2P_GAME_CONTROL " + JSON.stringify({"complete": true, "passed": failures.is_empty(), "checks": checks, "failures": failures}))
	quit(0 if failures.is_empty() else 1)


func _bytes() -> Array[PackedByteArray]:
	return [PackedByteArray([17, 0, 0, 0]), PackedByteArray([34, 0, 0, 0])]


func _rejected(inputs: Types.FrameInputs, label: String) -> void:
	var game: RefCounted = Game.new(2)
	var before: PackedByteArray = game.game.bytes()
	checks += 1
	if game.simulate_frame(0, inputs):
		failures.append(label + " accepted")
	checks += 1
	if game.game.bytes() != before or not game.requests.is_empty():
		failures.append(label + " mutated canonical state or callback inventory")


class BrokenRead:
	extends Types.FrameInputs

	func read(player: int) -> Types.InputResult:
		var result: Types.InputResult = super.read(player)
		result.code = Types.Code.EXPIRED_VIEW
		return result


class BrokenSize:
	extends Types.FrameInputs

	func size() -> Types.Result:
		var result: Types.Result = super.size()
		result.code = Types.Code.EXPIRED_VIEW
		return result
