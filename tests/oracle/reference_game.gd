extends RefCounted

# Independent request-boundary game, never a rollback/session implementation.
const U32_MASK: int = 4294967295
const FRAME_MAX: int = 2147483647
const FNV_OFFSET: int = -3750763034362895579
const FNV_PRIME: int = 1099511628211

var version: int = 1
var rng: int = 8173
var pending: int = 0
var frame: int = 0
var accumulators: PackedInt64Array = PackedInt64Array()


func _init(players: int, format_version: int = 1) -> void:
	version = format_version
	accumulators.resize(players)
	accumulators.fill(0)


func advance(inputs: Array) -> String:
	if frame >= FRAME_MAX:
		return "frame exhausted"
	if inputs.size() != accumulators.size():
		return "input slot count differs from player count"
	var decoded: PackedInt64Array = PackedInt64Array()
	for player: int in range(inputs.size()):
		if not inputs[player] is Dictionary:
			return "input slot is not an object"
		var slot: Dictionary = inputs[player]
		if slot.get("player") != player or slot.get("status") not in ["confirmed", "predicted", "disconnected"]:
			return "invalid player slot or input status"
		if not valid_hex(slot.get("bytes"), 8):
			return "invalid input bytes"
		var bytes: PackedByteArray = String(slot["bytes"]).hex_decode()
		decoded.append(bytes.decode_u32(0))
	var next_pending: int = 0
	if version == 2:
		rng = (rng * 1664525 + 1013904223) & U32_MASK
	for player: int in range(decoded.size()):
		var event: int = pending + (rng & 255) * (player + 1) if version == 2 else 0
		accumulators[player] = (accumulators[player] + decoded[player] + event) & U32_MASK
		next_pending = (next_pending + (player + 1) * decoded[player]) & U32_MASK
	pending = next_pending
	frame += 1
	return ""


func bytes() -> PackedByteArray:
	var output: PackedByteArray = PackedByteArray()
	output.resize(4 + 4 * accumulators.size() + (8 if version == 2 else 0))
	output.encode_s32(0, frame)
	for player: int in range(accumulators.size()):
		output.encode_u32(4 + 4 * player, accumulators[player])
	if version == 2:
		output.encode_u32(output.size() - 8, rng)
		output.encode_u32(output.size() - 4, pending)
	return output


func restore(snapshot: PackedByteArray) -> String:
	if snapshot.size() != bytes().size():
		return "snapshot width differs from game state width"
	var restored_frame: int = snapshot.decode_s32(0)
	if restored_frame < 0:
		return "negative snapshot frame"
	frame = restored_frame
	for player: int in range(accumulators.size()):
		accumulators[player] = snapshot.decode_u32(4 + 4 * player)
	if version == 2:
		rng = snapshot.decode_u32(snapshot.size() - 8)
		pending = snapshot.decode_u32(snapshot.size() - 4)
	return ""


func checksum() -> String:
	# Signed overflow preserves the low 64 bits; format each byte explicitly.
	var low: int = FNV_OFFSET
	for byte: int in bytes():
		low = (low ^ byte) * FNV_PRIME
	return _hex64(~low) + _hex64(low)


static func valid_hex(value: Variant, width: int) -> bool:
	# Variant is required at the untrusted JSON boundary.
	if not value is String or value.length() != width:
		return false
	for character: String in value:
		if character not in "0123456789abcdef":
			return false
	return true


static func _hex64(value: int) -> String:
	var result: String = ""
	for byte: int in range(7, -1, -1):
		result += "%02x" % ((value >> (8 * byte)) & 255)
	return result
