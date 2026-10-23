extends RefCounted
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
var frame: int = 0
var values: PackedInt64Array = PackedInt64Array()
var history: Dictionary = {}
var loads: int = 0
var corrupt_restore: bool = false
var corrupt_continuation: bool = false
func _init(count: int, corrupt: bool = false) -> void:
	values.resize(count)
	corrupt_restore = corrupt
func bytes() -> PackedByteArray:
	var result: PackedByteArray = PackedByteArray()
	result.resize(4 + 4 * values.size())
	result.encode_u32(0, frame)
	for slot: int in values.size():
		result.encode_u32(4 + slot * 4, values[slot])
	return result
func save_state(_frame: int, writer: RefCounted) -> Driver.SaveResult:
	var state: PackedByteArray = bytes()
	var hash: HashingContext = HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(state)
	return Driver.SaveResult.new(writer.write_bytes(state) == 0, hash.finish().slice(0, 16))
func load_state(_frame: int, reader: RefCounted) -> bool:
	var result: RefCounted = reader.read_bytes(bytes().size())
	if result.code != 0 or not reader.is_complete():
		return false
	loads += 1
	frame = result.bytes.decode_u32(0)
	for slot: int in values.size():
		values[slot] = result.bytes.decode_u32(4 + slot * 4)
	if corrupt_restore: values[0] ^= 1
	return true
func simulate_frame(_frame: int, inputs: RefCounted) -> bool:
	for slot: int in values.size():
		var input: RefCounted = inputs.read(slot)
		if input.bytes.size() != 1:
			return false
		values[slot] = (values[slot] * 33 + input.bytes[0]) & 0xffffffff
	if corrupt_continuation: values[0] ^= 1
	frame += 1
	history[frame] = bytes()
	return true
