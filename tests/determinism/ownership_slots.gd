extends RefCounted


# Research representation, not the session API: fixed storage, checked views,
# atomic publication and protected history. No raw backing bytes escape.
class Slot:
	extends RefCounted
	var bytes: PackedByteArray
	var staging: PackedByteArray
	var frame: int = -1
	var generation: int = 0
	var length: int = 0
	var checksum: PackedByteArray
	var is_protected: bool = false

	func _init(capacity: int) -> void:
		bytes.resize(capacity)
		staging.resize(capacity)


class View:
	extends RefCounted
	var slot: Slot
	var generation: int
	var frame: int
	var cursor: int = 0
	var is_live: bool = true
	var has_error: bool = false
	var is_writer: bool
	var scratch: PackedByteArray

	func _init(target: Slot, requested_frame: int, writing: bool) -> void:
		slot = target
		generation = slot.generation
		frame = requested_frame
		is_writer = writing
		if writing:
			scratch = slot.staging

	func is_valid() -> bool:
		return is_live and generation == slot.generation and (is_writer or frame == slot.frame)

	func write(data: PackedByteArray) -> String:
		if not is_valid():
			return "EXPIRED_VIEW"
		if not is_writer or has_error or data.size() > scratch.size() - cursor:
			has_error = true
			return "OVERFLOW"
		for index: int in range(data.size()):
			scratch[cursor + index] = data[index]
		cursor += data.size()
		return "OK"

	func read(count: int) -> PackedByteArray:
		if not is_valid():
			return PackedByteArray()
		if is_writer or count < 0 or count > slot.length - cursor:
			has_error = true
			return PackedByteArray()
		var result: PackedByteArray = slot.bytes.slice(cursor, cursor + count)
		cursor += count
		return result

	func status() -> String:
		return "OK" if is_valid() else "EXPIRED_VIEW"


var slots: Array[Slot] = []
var active: View


func _init(slot_count: int, capacity: int) -> void:
	for index: int in range(slot_count):
		slots.append(Slot.new(capacity))


func begin_save(frame: int) -> View:
	if active != null or frame < 0:
		return null
	var slot: Slot = slots[frame % slots.size()]
	if slot.is_protected:
		return null
	active = View.new(slot, frame, true)
	return active


func commit() -> String:
	if active == null:
		return "NO_OPERATION"
	var view: View = active
	active = null
	view.is_live = false
	if view.has_error or not view.is_writer:
		return "INVALID_SAVE"
	var slot: Slot = view.slot
	for index: int in range(view.cursor):
		slot.bytes[index] = view.scratch[index]
	slot.length = view.cursor
	slot.frame = view.frame
	slot.generation += 1
	var hash_context: HashingContext = HashingContext.new()
	hash_context.start(HashingContext.HASH_SHA256)
	hash_context.update(slot.bytes.slice(0, slot.length))
	slot.checksum = hash_context.finish().slice(0, 16)
	return "OK"


func begin_load(frame: int, generation: int) -> View:
	if active != null or frame < 0:
		return null
	var slot: Slot = slots[frame % slots.size()]
	if slot.frame != frame or slot.generation != generation:
		return null
	active = View.new(slot, frame, false)
	return active


func finish_load() -> String:
	if active == null:
		return "NO_OPERATION"
	var view: View = active
	active = null
	view.is_live = false
	return "OK" if not view.has_error and view.cursor == view.slot.length else "INVALID_LOAD"


func protect(frame: int, generation: int, enabled: bool) -> bool:
	var slot: Slot = slots[frame % slots.size()]
	if slot.frame != frame or slot.generation != generation:
		return false
	slot.is_protected = enabled
	return true


func checksum_copy(frame: int, generation: int) -> PackedByteArray:
	var slot: Slot = slots[frame % slots.size()]
	if slot.frame != frame or slot.generation != generation:
		return PackedByteArray()
	return slot.checksum.duplicate()


func generation_at(frame: int) -> int:
	var slot: Slot = slots[frame % slots.size()]
	return slot.generation if slot.frame == frame else -1
