extends SceneTree

# gdlint: disable=max-returns

const ReferenceGame = preload("res://tests/oracle/reference_game.gd")
const TraceSchema = preload("res://tests/oracle/trace_schema.gd")
const PREFIX: String = "FORTRESS_ORACLE_GAME_RESULT "

var _snapshots: Dictionary = {}
var _records: Array[Dictionary] = []
var _requests: int = 0
var _counts: Dictionary = {"save": 0, "load": 0, "advance": 0}


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() != 2 or args[0] != "--trace":
		_finish("expected --trace PATH")
		return
	var file: FileAccess = FileAccess.open(args[1], FileAccess.READ)
	if file == null:
		_finish("cannot read trace")
		return
	var parser: JSON = JSON.new()
	if parser.parse(file.get_as_text()) != OK or not parser.data is Dictionary:
		_finish("trace is not a JSON object")
		return
	var trace: Dictionary = parser.data
	var schema_error: String = TraceSchema.validate(trace)
	if not schema_error.is_empty():
		_finish(schema_error)
		return
	var scenario: Dictionary = trace["scenario"]
	var operations: Array = trace["operations"]
	var game: RefCounted = ReferenceGame.new(int(scenario["players"]))
	for index: int in range(operations.size()):
		var error: String = _operation(game, operations[index], index)
		if not error.is_empty():
			_finish("operation %d: %s" % [index, error])
			return
	var error: String = _compare(game, trace["final_state"], "bytes")
	_finish("final state: " + error if not error.is_empty() else "")


func _operation(game: RefCounted, operation: Dictionary, index: int) -> String:
	if operation["frame_before"] != game.frame:
		return "frame_before mismatch"
	for request: Dictionary in operation["requests"]:
		var error: String = _request(game, request)
		if not error.is_empty():
			return "request %d: %s" % [_requests, error]
		_requests += 1
	if operation.get("frame_after") != game.frame:
		return "frame_after mismatch"
	_records.append({"index": index, "kind": operation["kind"], "passed": true, "frame": game.frame})
	return ""


func _request(game: RefCounted, request: Dictionary) -> String:
	var kind: String = request["kind"]
	var error: String = ""
	match kind:
		"save":
			if request["frame"] != game.frame or not request["inputs"].is_empty():
				return "save frame mismatch or nonempty inputs"
			_snapshots[int(request["frame"])] = game.bytes().duplicate()
		"load":
			if not _snapshots.has(int(request["frame"])) or not request["inputs"].is_empty():
				return "load has no saved snapshot or has inputs"
			# Never inject the oracle's claimed bytes into the independent game.
			error = game.restore(_snapshots[int(request["frame"])].duplicate())
		"advance":
			if request["frame"] != game.frame:
				return "advance input frame mismatch"
			error = game.advance(request["inputs"])
	if not error.is_empty():
		return error
	error = _compare(game, request, "state_bytes", 1 if kind == "advance" else 0)
	if error.is_empty():
		_counts[kind] += 1
	return error


func _compare(game: RefCounted, expected: Dictionary, bytes_key: String, frame_offset: int = 0) -> String:
	if expected.get("frame") != game.frame - frame_offset:
		return "frame mismatch: expected %s, actual %d" % [str(expected.get("frame")), game.frame - frame_offset]
	var state: String = game.bytes().hex_encode()
	if not ReferenceGame.valid_hex(expected.get(bytes_key), state.length()) or expected[bytes_key] != state:
		return "state mismatch at frame %d: expected %s, actual %s" % [game.frame, str(expected.get(bytes_key)), state]
	var checksum: String = game.checksum()
	if not ReferenceGame.valid_hex(expected.get("checksum"), 32) or expected["checksum"] != checksum:
		return "checksum mismatch at frame %d: expected %s, actual %s" % [game.frame, str(expected.get("checksum")), checksum]
	return ""


func _finish(error: String) -> void:
	var errors: Array[String] = []
	if not error.is_empty():
		errors.append(error)
	var result: Dictionary = {
		"format": 1,
		"complete": true,
		"passed": errors.is_empty(),
		"count": _records.size(),
		"request_count": _requests,
		"request_counts": _counts,
		"records": _records,
		"engine_version": Engine.get_version_info()["string"],
		"errors": errors,
	}
	print(PREFIX + JSON.stringify(result))
	quit(0 if errors.is_empty() else 1)
