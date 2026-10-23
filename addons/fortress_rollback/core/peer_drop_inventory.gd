class_name FortressPeerDropInventory
extends RefCounted

const VERSION: int = 1
const MAX_FRAME: int = 2147483647


static func capture(core: RefCounted, slots: PackedInt32Array) -> Dictionary:
	var receipts: Dictionary = {}
	for slot: int in slots:
		var retained: PackedInt64Array = core.retained_input_range(slot)
		receipts[slot] = Vector2i(-1, -1) if retained.is_empty() else Vector2i(retained[0], retained[1])
	return receipts


## Version, count, then ordered slot/i32-from/i32-through rows; -1 is an unavailable interval.
static func encode(receipts: Dictionary, slots: PackedInt32Array) -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray([VERSION, slots.size()])
	bytes.resize(2 + slots.size() * 9)
	for index: int in slots.size():
		var slot: int = slots[index]
		var retained: Vector2i = receipts[slot]
		var offset: int = 2 + index * 9
		bytes[offset] = slot
		bytes.encode_s32(offset + 1, retained.x)
		bytes.encode_s32(offset + 5, retained.y)
	return bytes


static func decode(bytes: PackedByteArray, slots: PackedInt32Array, capacity: int) -> Dictionary:
	if bytes.size() != 2 + slots.size() * 9 or bytes[0] != VERSION or bytes[1] != slots.size():
		return {}
	var receipts: Dictionary = {}
	for index: int in slots.size():
		var offset: int = 2 + index * 9
		if bytes[offset] != slots[index]:
			return {}
		var first: int = bytes.decode_s32(offset + 1)
		var through: int = bytes.decode_s32(offset + 5)
		if not (first == -1 and through == -1) and (first < 0 or through < first or through > MAX_FRAME or through - first > capacity):
			return {}
		receipts[slots[index]] = Vector2i(first, through)
	return receipts


static func highest(receipts: Dictionary) -> int:
	var frame: int = -1
	for slot: int in receipts:
		frame = maxi(frame, receipts[slot].y)
	return frame


static func covers(receipts: Dictionary, slots: PackedInt32Array, first: int, cut: int) -> bool:
	if first < 0 or cut < first or receipts.size() != slots.size():
		return false
	for slot: int in slots:
		if not receipts.has(slot):
			return false
		var retained: Vector2i = receipts[slot]
		if retained.x < 0 or retained.x > first or retained.y < cut:
			return false
	return true
