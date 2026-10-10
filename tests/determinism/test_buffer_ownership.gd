extends RefCounted

# Value: protects=owned input/snapshot bytes and expiring bounded views;
# fails_when=packed/objects are treated as values or stale ring slots load;
# why_new=engine boundaries and representation had no executable evidence; seam=research fixture
const Slots = preload("res://tests/determinism/ownership_slots.gd")


class State:
	extends RefCounted
	var value: int = 1


func cases() -> PackedStringArray:
	return PackedStringArray(["engine_boundaries", "owned_input", "snapshot_wraps", "snapshot_bounds"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"engine_boundaries":
			_engine_boundaries(context)
		"owned_input":
			_owned_input(context)
		"snapshot_wraps":
			_snapshot_wraps(context)
		"snapshot_bounds":
			_snapshot_bounds(context)
	context.finish()


func _mutate(bytes: PackedByteArray) -> void:
	bytes[0] = 9


func _engine_boundaries(context: RefCounted) -> void:
	var bytes: PackedByteArray = PackedByteArray([1, 2])
	var alias: PackedByteArray = bytes
	alias[0] = 3
	context.equal(bytes[0], 3, "packed assignment aliases")
	_mutate(bytes)
	context.equal(bytes[0], 9, "packed parameter aliases")
	var copy: PackedByteArray = bytes.duplicate()
	copy[0] = 4
	context.equal(bytes[0], 9, "packed duplicate owns")
	var typed: Array[int] = [1, 2]
	var typed_alias: Array[int] = typed
	typed_alias[0] = 8
	context.equal(typed[0], 8, "typed array aliases")
	var typed_copy: Array[int] = typed.duplicate()
	typed_copy[0] = 3
	context.equal(typed[0], 8, "typed duplicate owns primitive elements")
	var state: State = State.new()
	var nested: Array[State] = [state]
	var deep: Array[State] = nested.duplicate(true)
	deep[0].value = 7
	context.equal(state.value, 7, "deep duplicate retains RefCounted alias")
	var stream: StreamPeerBuffer = StreamPeerBuffer.new()
	stream.data_array = PackedByteArray([1, 2])
	var property: PackedByteArray = stream.data_array
	property[0] = 9
	context.bytes_equal(stream.data_array, PackedByteArray([1, 2]), 0, "property getter owns")
	var assigned: PackedByteArray = PackedByteArray([3, 4])
	stream.data_array = assigned
	assigned[0] = 9
	context.bytes_equal(stream.data_array, PackedByteArray([3, 4]), 0, "property setter owns")
	stream.seek(0)
	var result: Array = stream.get_data(2)
	context.equal(result[0], OK, "method read status")
	var read_bytes: PackedByteArray = result[1]
	read_bytes[0] = 8
	context.bytes_equal(stream.data_array, PackedByteArray([3, 4]), 0, "method result owns")
	stream.clear()
	stream.put_data(assigned)
	assigned[1] = 8
	context.bytes_equal(stream.data_array, PackedByteArray([9, 4]), 0, "method writes copy")
	context.state(0, stream.data_array)


func _owned_input(context: RefCounted) -> void:
	var caller: PackedByteArray = PackedByteArray([1, 0])
	var broken_history: PackedByteArray = caller
	var history: PackedByteArray = caller.duplicate()
	var input_ring: RefCounted = Slots.new(2, 2)
	var writer: RefCounted = input_ring.begin_save(0)
	context.equal(writer.write(caller), "OK", "fixed-width input into preallocated slot")
	context.equal(input_ring.commit(), "OK", "owned input published before submission returns")
	caller.fill(9)
	context.equal(broken_history == PackedByteArray([1, 0]), false, "negative control borrowed input corrupts")
	context.bytes_equal(history, PackedByteArray([1, 0]), 0, "copied submission survives caller mutation")
	var callback: PackedByteArray = history.duplicate()
	callback.fill(8)
	context.bytes_equal(history, PackedByteArray([1, 0]), 0, "callback copy cannot edit history")
	var reader: RefCounted = input_ring.begin_load(0, input_ring.generation_at(0))
	var stored: PackedByteArray = reader.read(2)
	context.bytes_equal(stored, PackedByteArray([1, 0]), 0, "preallocated input history owns bytes")
	context.equal(input_ring.finish_load(), "OK", "input exact-width read")
	stored.fill(8)
	reader = input_ring.begin_load(0, input_ring.generation_at(0))
	context.bytes_equal(reader.read(2), PackedByteArray([1, 0]), 0, "returned input cannot edit slot")
	context.equal(input_ring.finish_load(), "OK", "repeated input read")
	context.state(0, history)


func _snapshot_wraps(context: RefCounted) -> void:
	var ring: RefCounted = Slots.new(3, 8)
	var state: State = State.new()
	var scratch: PackedByteArray = PackedByteArray([state.value, 2, 3])
	var writer: RefCounted = ring.begin_save(0)
	context.equal(writer.write(scratch), "OK", "save A")
	context.equal(ring.begin_save(1), null, "save cannot overlap an active request")
	context.equal(ring.commit(), "OK", "publish A")
	var generation: int = ring.generation_at(0)
	context.equal(ring.protect(0, generation, true), true, "protect A")
	scratch.fill(9)
	state.value = 9
	for frame: int in range(1, 13):
		writer = ring.begin_save(frame)
		if frame % 3 == 0:
			context.equal(writer, null, "protected ring collision")
		else:
			context.equal(writer.write(PackedByteArray([frame])), "OK", "save B/reuse slot")
			context.equal(ring.commit(), "OK", "publish B/reuse slot")
	var reader: RefCounted = ring.begin_load(0, generation)
	var restored: PackedByteArray = reader.read(3)
	context.bytes_equal(restored, PackedByteArray([1, 2, 3]), 0, "reload A after four ring wraps")
	context.equal(ring.finish_load(), "OK", "consume exact length")
	var decoded_state: State = State.new()
	decoded_state.value = restored[0]
	context.equal(decoded_state.value, 1, "nested state restored from A after wraps")
	context.equal(state.value, 9, "original nested state remained mutated")
	restored.fill(7)
	context.equal(reader.status(), "EXPIRED_VIEW", "reader expires at acknowledgement")
	context.equal(reader.read(1).size(), 0, "expired reader cannot expose bytes")
	var checksum: PackedByteArray = ring.checksum_copy(0, generation)
	context.equal(checksum.size(), 16, "canonical checksum width")
	context.bytes_equal(checksum, "039058c6f2c0cb492c533b0a4d14ef77".hex_decode(), 0, "independent SHA256 prefix")
	var expected_checksum: PackedByteArray = checksum.duplicate()
	checksum.fill(0)
	context.bytes_equal(ring.checksum_copy(0, generation), expected_checksum, 0, "checksum copied")
	context.equal(ring.protect(0, generation, false), true, "release A")
	writer = ring.begin_save(15)
	context.equal(writer.write(PackedByteArray([5])), "OK", "reuse A slot")
	context.equal(ring.commit(), "OK", "replace A")
	context.equal(ring.begin_load(0, generation), null, "old frame rejected")
	context.equal(ring.begin_load(15, generation), null, "old generation rejected")
	context.state(0, expected_checksum)


func _snapshot_bounds(context: RefCounted) -> void:
	var ring: RefCounted = Slots.new(1, 4)
	var writer: RefCounted = ring.begin_save(0)
	context.equal(writer.write(PackedByteArray([1, 2, 3, 4])), "OK", "exact capacity")
	context.equal(ring.commit(), "OK", "publish full snapshot")
	var generation: int = ring.generation_at(0)
	context.equal(writer.write(PackedByteArray([9])), "EXPIRED_VIEW", "writer expires")
	writer = ring.begin_save(1)
	context.equal(writer.write(PackedByteArray([7, 8, 9])), "OK", "partial save before overflow")
	context.equal(writer.write(PackedByteArray([10, 11])), "OVERFLOW", "capacity plus one")
	context.equal(writer.write(PackedByteArray([7])), "OVERFLOW", "sticky writer failure")
	context.equal(ring.commit(), "INVALID_SAVE", "overflow cannot publish")
	var reader: RefCounted = ring.begin_load(0, generation)
	context.bytes_equal(reader.read(4), PackedByteArray([1, 2, 3, 4]), 0, "failed save preserves history")
	context.equal(ring.finish_load(), "OK", "old snapshot remains loadable")
	writer = ring.begin_save(1)
	context.equal(writer.write(PackedByteArray([7])), "OK", "variable length")
	context.equal(ring.commit(), "OK", "publish shorter snapshot")
	generation = ring.generation_at(1)
	reader = ring.begin_load(1, generation)
	context.equal(reader.read(2).size(), 0, "reader underflow rejected")
	context.equal(ring.finish_load(), "INVALID_LOAD", "sticky reader failure")
	reader = ring.begin_load(1, generation)
	context.equal(ring.finish_load(), "INVALID_LOAD", "trailing bytes rejected")
	reader = ring.begin_load(1, generation)
	var exact: PackedByteArray = reader.read(1)
	context.bytes_equal(exact, PackedByteArray([7]), 1, "unused tail is inaccessible")
	context.equal(ring.finish_load(), "OK", "short snapshot exact load")
	context.state(1, exact)
