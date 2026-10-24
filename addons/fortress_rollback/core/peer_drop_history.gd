class_name FortressPeerDropHistory
extends RefCounted

## One immutable, bounded donor journal for an operation. Chunks are byte slices
## of frame-major, slot-ordered fixed-width inputs, installed only after validation.
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const MAX_CHUNKS: int = 64
const MAX_CHUNK_BYTES: int = 1024
const RETRY_US: int = 50000
const WORK: int = 4

var first: int = -1
var cut: int = -1
var donor: int = -1
var chunk_bytes: int = 0
var installed: bool = false
var chunks: Dictionary = {}
var journal: Array[PackedByteArray] = []
var cursors: Dictionary = {}
var retry_us: int = -1
var plan_turn: bool = true
var plan_sent_to: Dictionary = {}


func configure(start: int, through: int, source: int, width: int, slots: int, budget: int) -> bool:
	if start < 0 or through < start or source < 0 or budget < 1 or budget > MAX_CHUNK_BYTES:
		return false
	var total: int = (through - start + 1) * width * slots
	if width < 1 or slots < 1 or total > budget * MAX_CHUNKS:
		return false
	if first != -1:
		return first == start and cut == through and donor == source and chunk_bytes == budget
	first = start
	cut = through
	donor = source
	chunk_bytes = budget
	return true


func count(width: int, slots: int) -> int:
	return ((cut - first + 1) * width * slots + chunk_bytes - 1) / chunk_bytes


func prepare(core: RefCounted, slots: PackedInt32Array, width: int) -> bool:
	if not journal.is_empty():
		return true
	var bytes: PackedByteArray = PackedByteArray()
	for frame: int in range(first, cut + 1):
		for slot: int in slots:
			var input: PackedByteArray = core.retained_input(slot, frame)
			if input.size() != width:
				return false
			bytes.append_array(input)
	for index: int in count(width, slots.size()):
		journal.append(bytes.slice(index * chunk_bytes, mini((index + 1) * chunk_bytes, bytes.size())))
	return true


## Reject a changed duplicate, shape, count or range before retaining any bytes.
func accept(index: int, total: int, bytes: PackedByteArray, width: int, slots: int) -> bool:
	var size: int = (cut - first + 1) * width * slots
	if first < 0 or total != count(width, slots) or index < 0 or index >= total:
		return false
	if bytes.size() != mini(chunk_bytes, size - index * chunk_bytes):
		return false
	if chunks.has(index):
		return chunks[index] == bytes
	chunks[index] = bytes.duplicate()
	return true


## Validate every target before installing any target. Released prefix rows are
## outside local recovery; retained overlaps and missing suffixes stay immutable.
func install(core: RefCounted, slots: PackedInt32Array, width: int) -> int:
	if installed or chunks.size() != count(width, slots.size()):
		return Types.Code.OK
	var bytes: PackedByteArray = PackedByteArray()
	for index: int in chunks.size():
		bytes.append_array(chunks[index])
	var first_retained: int = maxi(first, core.rollback_floor())
	var rows: Array = []
	var starts: PackedInt64Array = PackedInt64Array()
	var received: PackedInt64Array = core.received_frames()
	for target: int in slots.size():
		var start: int = maxi(first_retained, received[slots[target]] + 1)
		var inputs: Array[PackedByteArray] = []
		for frame: int in range(first_retained, cut + 1):
			var offset: int = ((frame - first) * slots.size() + target) * width
			var input: PackedByteArray = bytes.slice(offset, offset + width)
			if frame < start:
				if core.retained_input(slots[target], frame) != input:
					return Types.Code.INPUT_ALREADY_SUBMITTED
			else:
				inputs.append(input)
		if not inputs.is_empty():
			var code: int = core.validate_missing_backfill(slots[target], start, inputs)
			if code != Types.Code.OK:
				return code
		rows.append(inputs)
		starts.append(start)
	for target: int in slots.size():
		if not rows[target].is_empty():
			var code: int = core.install_missing_backfill(slots[target], starts[target], rows[target])
			if code != Types.Code.OK:
				return code
	installed = true
	return Types.Code.OK
