class_name FortressDiagnosticTraceReader
extends RefCounted

# gdlint: disable=max-returns


## Validates and copies a contiguous, restorable canonical window. Empty means invalid.
## Caller supplies the game's limits; declarations in a captured file cannot raise them.
static func decode(trace: Dictionary, players: int, width: int, snapshot_bytes: int) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	if players < 2 or players > 8 or width < 1 or width > 65536 or snapshot_bytes < 1 or snapshot_bytes > 16777216:
		return rows
	if trace.get("schema") != "fortress-canonical-trace-v1" or not trace.get("frames") is Array:
		return rows
	var source: Array = trace.frames
	if source.is_empty() or source.size() > 128:
		return rows
	var previous: int = -1
	var payload: int = 0
	for item: Variant in source:  # Captured JSON is untrusted until each field is checked.
		if not item is Dictionary or not integer(item.get("frame"), 0, 2147483647) or not item.get("state_available") is bool:
			return []
		var frame: int = int(item.frame)
		if previous >= 0 and frame != previous + 1:
			return []
		if not hex_bytes(item.get("state"), snapshot_bytes) or not hex_bytes(item.get("checksum"), 16):
			return []
		if item.checksum.length() not in [0, 32] or not item.get("inputs") is Array:
			return []
		if not item.state_available and (item.state != "" or item.checksum != ""):
			return []
		var inputs: Array = item.inputs
		payload += item.state.length() / 2 + item.checksum.length() / 2 + inputs.size() * width
		if payload > 67108864:
			return []
		if inputs.size() != players and not (inputs.is_empty() and item == source.back()):
			return []
		var decoded: Array[PackedByteArray] = []
		var statuses: PackedInt32Array = PackedInt32Array()
		for player: int in range(inputs.size()):
			var input: Variant = inputs[player]
			if not input is Dictionary or not integer(input.get("player"), player, player) or not integer(input.get("status"), 1, 2):
				return []
			if not hex_bytes(input.get("bytes"), width) or input.bytes.length() != width * 2:
				return []
			decoded.append(input.bytes.hex_decode())
			statuses.append(int(input.status))
		var state: PackedByteArray = item.state.hex_decode()
		var checksum: PackedByteArray = item.checksum.hex_decode()
		rows.append({"frame": frame, "state": state, "state_available": item.state_available, "checksum": checksum, "inputs": decoded, "statuses": statuses})
		previous = frame
	if not rows[0].state_available:
		return []
	# One restored boundary alone cannot establish a reproduced transition.
	if rows.size() < 2 or not rows.any(func(row: Dictionary) -> bool: return row.frame > rows[0].frame and row.state_available):
		return []
	return rows


static func integer(value: Variant, minimum: int, maximum: int) -> bool:
	# Godot's JSON parser returns floats, including integral frame numbers.
	return (value is int or value is float) and is_finite(float(value)) and value >= minimum and value <= maximum and value == int(value)


static func hex_bytes(value: Variant, max_bytes: int) -> bool:
	if not value is String or value.length() > max_bytes * 2 or value.length() % 2 != 0:
		return false
	for index: int in range(value.length()):
		if value.unicode_at(index) not in [48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 97, 98, 99, 100, 101, 102]:
			return false
	return true
