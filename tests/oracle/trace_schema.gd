extends RefCounted

# gdlint: disable=max-returns
# Variant is intentional at each untrusted JSON boundary. Godot 4.3 has no
# typed dictionaries and parses JSON integers as floating-point values.
const Game = preload("res://tests/oracle/reference_game.gd")
const REVISION: String = "f13cd5c0f2815926785a395947e18da0dbea0dd8"
const FRAME_MAX: int = 2147483647


static func validate(trace: Dictionary) -> String:
	if not _fields(trace, "format upstream_revision scenario operations final_state"):
		return "trace: unknown or missing fields"
	if not integer(trace["format"], 1, 1) or trace["upstream_revision"] != REVISION:
		return "trace: unsupported format or revision"
	var error: String = _scenario(trace["scenario"])
	if not error.is_empty():
		return error
	var scenario: Dictionary = trace["scenario"]
	var sources: Array = scenario["operations"]
	if not trace["operations"] is Array or trace["operations"].size() != sources.size():
		return "trace: operation count differs from scenario"
	var frame: int = 0
	for index: int in range(sources.size()):
		var operation: Variant = trace["operations"][index]
		error = _operation(operation, sources[index], index, frame, int(scenario["players"]))
		if not error.is_empty():
			return "operation %d: %s" % [index, error]
		frame = int(operation["frame_after"])
	if not _fields(trace["final_state"], "frame bytes checksum"):
		return "final state: unknown or missing fields"
	return _state(trace["final_state"], int(scenario["players"]), "bytes")


static func _scenario(value: Variant) -> String:
	if not _fields(value, "format upstream_revision players input_width check_distance input_delay operations"):
		return "scenario: unknown or missing fields"
	if not integer(value["format"], 1, 1) or value["upstream_revision"] != REVISION:
		return "scenario: unsupported format or revision"
	if not integer(value["players"], 2, 8) or not integer(value["input_width"], 4, 4):
		return "scenario: invalid players or input width"
	if not integer(value["check_distance"], 0, 7) or not integer(value["input_delay"], 0, 7):
		return "scenario: invalid check distance or input delay"
	if not value["operations"] is Array or value["operations"].size() < 1 or value["operations"].size() > 10000:
		return "scenario: empty or oversized operations"
	for operation: Variant in value["operations"]:
		if not operation is Dictionary:
			return "scenario: operation is not an object"
		match operation.get("kind"):
			"input":
				if not _fields(operation, "kind player bytes"):
					return "scenario input: unknown or missing fields"
				if not integer(operation["player"], 0, 255) or not Game.valid_hex(operation["bytes"], 8):
					return "scenario input: invalid handle or bytes"
			"advance", "events":
				if not _fields(operation, "kind"):
					return "scenario operation: unknown or missing fields"
			_:
				return "scenario: unknown operation kind"
	return ""


static func _operation(value: Variant, source: Dictionary, index: int, frame: int, players: int) -> String:
	if not _fields(value, "index kind result error frame_before frame_after confirmed_frame requests events"):
		return "unknown or missing operation fields"
	if not integer(value["index"], index, index) or value["kind"] != source["kind"]:
		return "invalid operation index or kind"
	if not integer(value["frame_before"], frame, frame) or not integer(value["frame_after"], 0, FRAME_MAX):
		return "invalid operation frame chain"
	if value["confirmed_frame"] != null:
		return "confirmation unavailable in sync-test API"
	if value["result"] not in ["ok", "error"]:
		return "invalid operation result"
	if value["result"] == "ok" and value["error"] != null:
		return "successful operation carries an error"
	if value["result"] == "error" and (not value["error"] is String or value["error"].is_empty()):
		return "failed operation lacks a nonempty error"
	if not value["requests"] is Array or not value["events"] is Array or not value["events"].is_empty():
		return "invalid requests or nonempty sync-test events"
	var is_advance: bool = source["kind"] == "advance" and value["result"] == "ok"
	if not is_advance and not value["requests"].is_empty():
		return "requests outside a successful advance"
	if is_advance and value["requests"].is_empty():
		return "successful advance missing requests"
	if value["frame_after"] != frame + (1 if is_advance else 0):
		return "impossible exposed frame transition"
	for request: Variant in value["requests"]:
		var error: String = _request(request, players)
		if not error.is_empty():
			return error
	return ""


static func _request(value: Variant, players: int) -> String:
	if not _fields(value, "kind frame state_bytes checksum inputs"):
		return "request: unknown or missing fields"
	if value["kind"] not in ["save", "load", "advance"] or not integer(value["frame"], 0, FRAME_MAX - 1):
		return "request: invalid kind or frame"
	if not value["inputs"] is Array:
		return "request: inputs is not an array"
	var error: String = _state(value, players, "state_bytes")
	if not error.is_empty():
		return error
	if value["kind"] != "advance":
		return "snapshot request has inputs" if not value["inputs"].is_empty() else ""
	if value["inputs"].size() != players:
		return "request: input count differs from players"
	for player: int in range(players):
		var input: Variant = value["inputs"][player]
		if not _fields(input, "player bytes status"):
			return "request input: unknown or missing fields"
		if not integer(input["player"], player, player) or not Game.valid_hex(input["bytes"], 8):
			return "request input: invalid player slot or bytes"
		if input["status"] not in ["confirmed", "predicted", "disconnected"]:
			return "request input: invalid status"
	return ""


static func _state(value: Dictionary, players: int, bytes_key: String) -> String:
	if not integer(value["frame"], 0, FRAME_MAX):
		return "state: invalid frame"
	if not Game.valid_hex(value[bytes_key], 8 * (players + 1)) or not Game.valid_hex(value["checksum"], 32):
		return "state: invalid canonical bytes or checksum"
	return ""


static func _fields(value: Variant, names: String) -> bool:
	if not value is Dictionary:
		return false
	var expected: PackedStringArray = names.split(" ")
	return value.size() == expected.size() and value.has_all(expected)


static func integer(value: Variant, minimum: int, maximum: int) -> bool:
	return (value is int or value is float) and value >= minimum and value <= maximum and value == int(value)
