extends RefCounted

const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
var frame: int = 0
var sums: PackedInt64Array = PackedInt64Array([0, 0])


func canonical_bytes() -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(24)
	bytes.encode_s64(0, frame)
	bytes.encode_s64(8, sums[0])
	bytes.encode_s64(16, sums[1])
	return bytes


func save_state(saved_frame: int, writer: RefCounted) -> Driver.SaveResult:
	var bytes: PackedByteArray = canonical_bytes()
	var hash: HashingContext = HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	return Driver.SaveResult.new(saved_frame == frame and writer.write_bytes(bytes) == 0, hash.finish().slice(0, 16))


func load_state(saved_frame: int, reader: RefCounted) -> bool:
	var result: RefCounted = reader.read_bytes(24)
	if result.code != 0 or result.bytes.decode_s64(0) != saved_frame:
		return false
	frame = saved_frame
	sums[0] = result.bytes.decode_s64(8)
	sums[1] = result.bytes.decode_s64(16)
	return true


func simulate_frame(current_frame: int, inputs: RefCounted) -> bool:
	if current_frame != frame:
		return false
	for player: int in 2:
		var sample: RefCounted = inputs.read(player)
		sums[player] += sample.bytes[0] * (frame + 1)
	frame += 1
	return true
