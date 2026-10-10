extends RefCounted

# Research primitives, not a released addon API. Dictionary results hold typed
# scalar/packed values because Godot 4.3 has no typed Dictionary syntax.
const I64_MAX: int = 9223372036854775807
const I64_MIN: int = -9223372036854775807 - 1
const U32_MAX: int = 4294967295
const FRAME_MAX: int = 2147483647


static func encode_unsigned(limbs: PackedInt64Array, width: int) -> Dictionary:
	if width not in [2, 4, 8, 16] or limbs.size() != maxi(1, width / 4):
		return {"ok": false, "error": "WIDTH"}
	for limb: int in limbs:
		if limb < 0 or limb > (65535 if width == 2 else U32_MAX):
			return {"ok": false, "error": "RANGE"}
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(width)
	for index: int in range(width):
		bytes[index] = (limbs[index / 4] >> ((index % 4) * 8)) & 255
	return {"ok": true, "bytes": bytes}


static func decode_unsigned(bytes: PackedByteArray, offset: int, width: int) -> Dictionary:
	if width not in [2, 4, 8, 16]:
		return {"ok": false, "error": "WIDTH"}
	# Subtract after offset validation; offset + width could itself overflow.
	if offset < 0 or offset > bytes.size() or width > bytes.size() - offset:
		return {"ok": false, "error": "SHORT_BUFFER"}
	var limbs: PackedInt64Array = PackedInt64Array()
	limbs.resize(maxi(1, width / 4))
	for index: int in range(width):
		limbs[index / 4] |= int(bytes[offset + index]) << ((index % 4) * 8)
	return {"ok": true, "limbs": limbs, "next_offset": offset + width}


static func encode_i32(value: int) -> Dictionary:
	if value < -2147483648 or value > FRAME_MAX:
		return {"ok": false, "error": "RANGE"}
	return encode_unsigned(PackedInt64Array([value & U32_MAX]), 4)


static func decode_i32(bytes: PackedByteArray, offset: int) -> Dictionary:
	var result: Dictionary = decode_unsigned(bytes, offset, 4)
	if not result["ok"]:
		return result
	var value: int = result["limbs"][0]
	result["value"] = value - 4294967296 if value > FRAME_MAX else value
	return result


static func checked_add(a: int, b: int) -> Dictionary:
	if (b > 0 and a > I64_MAX - b) or (b < 0 and a < I64_MIN - b):
		return {"ok": false, "error": "OVERFLOW"}
	return {"ok": true, "value": a + b}


static func checked_divrem(a: int, b: int) -> Dictionary:
	if b == 0:
		return {"ok": false, "error": "ZERO_DIVISOR"}
	if a == I64_MIN and b == -1:
		return {"ok": false, "error": "OVERFLOW"}
	return {"ok": true, "quotient": a / b, "remainder": a % b}


static func checked_shift(value: int, count: int, right: bool) -> Dictionary:
	if count < 0 or count > 63:
		return {"ok": false, "error": "SHIFT_RANGE"}
	return {"ok": true, "value": (value >> count) if right else (value << count)}


static func advance_frame(frame: int) -> Dictionary:
	if frame < 0 or frame >= FRAME_MAX:
		return {"ok": false, "error": "FRAME_RANGE"}
	return {"ok": true, "value": frame + 1}


static func increment_sequence16(sequence: int) -> Dictionary:
	if sequence < 0 or sequence > 65535:
		return {"ok": false, "error": "SEQUENCE_RANGE"}
	return {"ok": true, "value": (sequence + 1) & 65535}


static func increment_sequence32(sequence: int) -> Dictionary:
	# The audited u32 round_seq is monotonic; unlike a u16 status epoch it
	# must exhaust explicitly rather than accepting a wrapped stale reply.
	if sequence < 0 or sequence >= U32_MAX:
		return {"ok": false, "error": "SEQUENCE_RANGE"}
	return {"ok": true, "value": sequence + 1}
