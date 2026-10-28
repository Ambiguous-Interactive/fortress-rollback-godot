extends SceneTree

# gdlint: disable=max-returns

const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const REVISION: String = "d124c89080004d96971a629bb0427056ee1805e3"
const PREFIX: String = "FORTRESS_QUEUE_RESULT "


func _initialize() -> void:
	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	if arguments.size() != 2 or arguments[0] != "--bundle":
		_fail("expected --bundle file")
		return
	var file: FileAccess = FileAccess.open(arguments[1], FileAccess.READ)
	if file == null or file.get_length() > 8000000:
		_fail("missing or oversized bundle")
		return
	var parser: JSON = JSON.new()
	if parser.parse(file.get_as_text()) != OK or not _valid_bundle(parser.data):
		_fail("invalid queue bundle")
		return
	var bundle: Dictionary = parser.data
	var cases: Array[Dictionary] = []
	for case: Dictionary in bundle["cases"]:
		cases.append(_execute(case))
	print(PREFIX + JSON.stringify({"format": 1, "upstream_revision": REVISION, "complete": true, "cases": cases}))
	quit(0)


func _execute(case: Dictionary) -> Dictionary:
	var queue: RefCounted = Queue.new()
	var neutral: PackedByteArray = PackedByteArray()
	neutral.resize(int(case["input_width"]))
	queue.configure(int(case["capacity"]), neutral)
	var records: Array[Dictionary] = []
	for index: int in range(case["operations"].size()):
		var operation: Dictionary = case["operations"][index]
		var kind: String = operation["kind"]
		var accepted: bool = true
		var frame: int = -1
		var bytes: String = ""
		var status: String = "none"
		var result: RefCounted
		match kind:
			"add", "add_reclaim":
				if kind == "add":
					result = queue.add_input(int(operation["frame"]), str(operation["bytes"]).hex_decode())
				else:
					result = queue.add_input_with_reclaim_floor(int(operation["frame"]), str(operation["bytes"]).hex_decode(), int(operation["floor"]))
				accepted = result.code == Queue.Code.OK
				frame = result.frame
			"read", "confirmed", "retained":
				var target: int = int(operation["frame"])
				if kind == "read":
					result = queue.input(target)
				elif kind == "confirmed":
					result = queue.confirmed_input(target)
				else:
					result = queue.retained_confirmed_input(target)
				accepted = result.code == Queue.Code.OK
				if accepted:
					frame = result.frame
					bytes = result.bytes.hex_encode()
					status = "confirmed" if result.status == Queue.Status.CONFIRMED else "predicted"
			"delay", "delay_reclaim":
				if kind == "delay":
					accepted = queue.set_frame_delay(int(operation["value"])) == Queue.Code.OK
				else:
					accepted = queue.set_frame_delay_with_reclaim_floor(int(operation["value"]), int(operation["floor"])) == Queue.Code.OK
			"discard":
				accepted = queue.discard_confirmed_frames(int(operation["frame"])) == Queue.Code.OK
			"reset":
				queue.reset_prediction()
		records.append(
			{
				"index": index,
				"kind": kind,
				"accepted": accepted,
				"frame": frame,
				"bytes": bytes,
				"status": status,
				"first_incorrect": queue.first_incorrect_frame(),
				"delay": queue.frame_delay()
			}
		)
	return {"name": case["name"], "records": records}


# Variant is required at the untrusted JSON boundary; validate before narrowing types.
func _valid_bundle(value: Variant) -> bool:
	if not _fields(value, ["format", "upstream_revision", "cases"]):
		return false
	if not _integer(value["format"], 1, 1) or value["upstream_revision"] != REVISION:
		return false
	if not value["cases"] is Array or value["cases"].is_empty() or value["cases"].size() > 1000:
		return false
	var names: Dictionary = {}
	for case: Variant in value["cases"]:
		if not _valid_case(case, names):
			return false
	return true


func _valid_case(value: Variant, names: Dictionary) -> bool:
	if not _fields(value, ["name", "capacity", "input_width", "player", "operations"]):
		return false
	if not value["name"] is String or value["name"].is_empty() or names.has(value["name"]):
		return false
	names[value["name"]] = true
	if not _integer(value["capacity"], 2, 128) or not _integer(value["input_width"], 1, 32) or not _integer(value["player"], 0, 7):
		return false
	if not value["operations"] is Array or value["operations"].is_empty() or value["operations"].size() > 10000:
		return false
	for operation: Variant in value["operations"]:
		if not _valid_operation(operation, int(value["input_width"])):
			return false
	return true


func _valid_operation(value: Variant, width: int) -> bool:
	if not value is Dictionary or not value.has("kind") or not value["kind"] is String:
		return false
	match value["kind"]:
		"read", "confirmed", "retained", "discard":
			return _fields(value, ["kind", "frame"]) and _integer(value["frame"], 0, 100000)
		"add":
			return _fields(value, ["kind", "frame", "bytes"]) and _integer(value["frame"], 0, 100000) and _hex(value["bytes"], width)
		"add_reclaim":
			return (
				_fields(value, ["kind", "frame", "bytes", "floor"]) and _integer(value["frame"], 0, 100000) and _integer(value["floor"], 0, 100000) and _hex(value["bytes"], width)
			)
		"delay_reclaim":
			return _fields(value, ["kind", "value", "floor"]) and _integer(value["value"], 0, 128) and _integer(value["floor"], 0, 100000)
		"delay":
			return _fields(value, ["kind", "value"]) and _integer(value["value"], 0, 128)
		"reset":
			return _fields(value, ["kind"])
	return false


func _fields(value: Variant, names: Array[String]) -> bool:
	return value is Dictionary and value.size() == names.size() and value.has_all(names)


func _integer(value: Variant, minimum: int, maximum: int) -> bool:
	if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
		return false
	return value >= minimum and value <= maximum and value == int(value)


func _hex(value: Variant, width: int) -> bool:
	if not value is String or value.length() != width * 2:
		return false
	for character: String in value:
		if character not in "0123456789abcdef":
			return false
	return true


func _fail(reason: String) -> void:
	printerr("queue oracle: " + reason)
	quit(2)
