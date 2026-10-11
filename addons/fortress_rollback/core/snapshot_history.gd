class_name FortressSnapshotHistory
extends RefCounted

const Status = preload("res://addons/fortress_rollback/core/snapshot_status.gd")
const Writer = preload("res://addons/fortress_rollback/core/snapshot_writer.gd")
const Reader = preload("res://addons/fortress_rollback/core/snapshot_reader.gd")
# Shared enum alias keeps error codes identical across history and views.
# gdlint: disable=constant-name
const Code = Status.Code
# gdlint: enable=constant-name
const FRAME_MAX: int = 2147483647
const MAX_SLOTS: int = 65536
const MAX_BYTES: int = 16777216
const MAX_STORAGE: int = 67108864


class SaveRequest:
	extends RefCounted
	var code: int
	var frame: int = -1
	var generation: int = -1
	var writer: Writer

	func _init(result_code: int) -> void:
		code = result_code


class LoadRequest:
	extends RefCounted
	var code: int
	var frame: int = -1
	var generation: int = -1
	var checksum: PackedByteArray = PackedByteArray()
	var reader: Reader

	func _init(result_code: int) -> void:
		code = result_code


class Inspection:
	extends RefCounted
	var code: int
	var generation: int = -1
	var bytes: PackedByteArray = PackedByteArray()
	var checksum: PackedByteArray = PackedByteArray()

	func _init(result_code: int) -> void:
		code = result_code


class Slot:
	extends RefCounted
	var frame: int = -1
	var generation: int = -1
	var bytes: PackedByteArray = PackedByteArray()
	var checksum: PackedByteArray = PackedByteArray()


var _slots: Array[Slot] = []
var _max_bytes: int = 0
var _checksums_enabled: bool = true
var _next_generation: int = 0
var _writer: Writer
var _reader: Reader
var _save_frame: int = -1
var _save_generation: int = -1


## Budget reserves bounded slot payloads, checksum/tag metadata and two request copies.
## Invalid configuration leaves existing history intact.
func configure(slots: int, max_bytes: int, max_prediction: int, check_distance: int, storage_budget: int, checksums_enabled: bool = true) -> int:
	if _is_busy():
		return Code.BUSY
	if slots < 1 or slots > MAX_SLOTS or max_bytes < 1 or max_bytes > MAX_BYTES:
		return Code.INVALID_CONFIGURATION
	if max_prediction < 0 or max_prediction >= slots or check_distance < 0 or check_distance >= slots:
		return Code.INVALID_CONFIGURATION
	var required_bytes: int = (slots + 2) * max_bytes + slots * 40
	if storage_budget < required_bytes or storage_budget > MAX_STORAGE or required_bytes > MAX_STORAGE:
		return Code.INVALID_CONFIGURATION
	var new_slots: Array[Slot] = []
	for index: int in range(slots):
		new_slots.append(Slot.new())
	_slots = new_slots
	_max_bytes = max_bytes
	_checksums_enabled = checksums_enabled
	# Keep generations monotonic across reconfiguration to reject old identities.
	return Code.OK


func begin_save(frame: int) -> SaveRequest:
	var code: int = _access_code(frame)
	if code != Code.OK:
		return SaveRequest.new(code)
	if _next_generation == 9223372036854775807:
		return SaveRequest.new(Code.HISTORY_UNAVAILABLE)
	_next_generation += 1
	_save_frame = frame
	_save_generation = _next_generation
	_writer = Writer.new(_max_bytes)
	var result: SaveRequest = SaveRequest.new(Code.OK)
	result.frame = frame
	result.generation = _save_generation
	result.writer = _writer
	return result


func finish_save(writer: Writer, callback_ok: bool, checksum: PackedByteArray = PackedByteArray()) -> int:
	if writer == null or writer != _writer:
		return Code.EXPIRED_VIEW
	var code: int = writer.status()
	if code == Code.OK and not callback_ok:
		code = Code.CALLBACK_FAILED
	if code == Code.OK and _checksums_enabled and checksum.size() != 16:
		code = Code.CHECKSUM_WIDTH
	if code == Code.OK:
		var slot: Slot = _slots[_save_frame % _slots.size()]
		slot.bytes = writer._written_copy()
		slot.checksum = checksum.duplicate() if _checksums_enabled else PackedByteArray()
		slot.frame = _save_frame
		slot.generation = _save_generation
	writer._expire()
	_writer = null
	return code


func begin_load(frame: int, generation: int = -1) -> LoadRequest:
	var code: int = _access_code(frame)
	if code != Code.OK:
		return LoadRequest.new(code)
	var slot: Slot = _slot_for(frame, generation)
	if slot == null:
		return LoadRequest.new(Code.HISTORY_UNAVAILABLE)
	_reader = Reader.new(slot.bytes, true)
	var result: LoadRequest = LoadRequest.new(Code.OK)
	result.frame = frame
	result.generation = slot.generation
	result.checksum = slot.checksum.duplicate()
	result.reader = _reader
	return result


func finish_load(reader: Reader, callback_ok: bool) -> int:
	if reader == null or reader != _reader:
		return Code.EXPIRED_VIEW
	var code: int = reader._completion_code()
	if code == Code.OK and not callback_ok:
		code = Code.CALLBACK_FAILED
	reader._expire()
	_reader = null
	return code


func inspect(frame: int, generation: int = -1) -> Inspection:
	var code: int = _access_code(frame)
	if code != Code.OK:
		return Inspection.new(code)
	var slot: Slot = _slot_for(frame, generation)
	if slot == null:
		return Inspection.new(Code.HISTORY_UNAVAILABLE)
	var result: Inspection = Inspection.new(Code.OK)
	result.generation = slot.generation
	result.bytes = slot.bytes.duplicate()
	result.checksum = slot.checksum.duplicate()
	return result


## Owned checksum metadata only; never duplicates snapshot payloads.
func retained_checksums() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if _is_busy():
		return result
	for slot: Slot in _slots:
		if slot.frame >= 0 and slot.checksum.size() == 16:
			result.append({"frame": slot.frame, "generation": slot.generation, "checksum": slot.checksum.duplicate()})
	result.sort_custom(func(left: Dictionary, right: Dictionary) -> bool: return left.frame < right.frame)
	return result


func generation_for(frame: int) -> Inspection:
	return inspect(frame)


func terminate_views() -> void:
	if _writer != null:
		_writer._expire()
		_writer = null
	if _reader != null:
		_reader._expire()
		_reader = null


func _slot_for(frame: int, generation: int) -> Slot:
	var slot: Slot = _slots[frame % _slots.size()]
	if slot.frame != frame or (generation != -1 and slot.generation != generation):
		return null
	return slot


func _is_busy() -> bool:
	return _writer != null or _reader != null


func _access_code(frame: int) -> int:
	if _slots.is_empty():
		return Code.NOT_CONFIGURED
	if frame < 0 or frame > FRAME_MAX:
		return Code.FRAME_RANGE
	if _is_busy():
		return Code.BUSY
	return Code.OK
