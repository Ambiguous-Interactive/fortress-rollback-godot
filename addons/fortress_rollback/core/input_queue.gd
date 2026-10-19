class_name FortressInputQueue
extends RefCounted

# gdlint: disable=max-returns

## Bounded raw queue matching the pinned Rust queue's ordinary input path.
## Samples are sequential; duplicate idempotence belongs to the session boundary.
## Discard moves the logical tail; confirmed_input can read old tags until overwritten.
## A global rollback floor can reclaim full rings while retaining that floor in one side slot.
enum Code {
	OK,
	NOT_CONFIGURED,
	INVALID_CONFIGURATION,
	FRAME_RANGE,
	INPUT_WIDTH,
	OUT_OF_ORDER,
	CAPACITY,
	NO_CONFIRMED_INPUT,
	BEFORE_RETAINED,
	PREDICTION_MISMATCH,
	DELAY_DECREASE_UNSUPPORTED,
}
enum Status { NONE, CONFIRMED, PREDICTED }

const FRAME_MAX: int = 2147483647
const MAX_CAPACITY: int = 65536
const MAX_INPUT_BYTES: int = 65536
const MAX_STORAGE_BYTES: int = 16777216


class Result:
	extends RefCounted
	var code: int
	var frame: int
	var bytes: PackedByteArray
	var status: int

	func _init(result_code: int, result_frame: int = -1, result_bytes: PackedByteArray = PackedByteArray(), result_status: int = Status.NONE) -> void:
		code = result_code
		frame = result_frame
		bytes = result_bytes.duplicate()
		status = result_status


var _capacity: int = 0
var _neutral: PackedByteArray = PackedByteArray()
var _frames: PackedInt64Array = PackedInt64Array()
var _slots: Array[PackedByteArray] = []
var _tail_frame: int = 0
var _length: int = 0
var _last_added: int = -1
var _delay: int = 0
var _last_actual: PackedByteArray = PackedByteArray()
var _prediction_frame: int = -1
var _prediction_bytes: PackedByteArray = PackedByteArray()
var _first_incorrect: int = -1
var _last_requested: int = -1
var _reclaimed_frame: int = -1
var _reclaimed_bytes: PackedByteArray = PackedByteArray()


## Allocate fixed-width history. Invalid reconfiguration preserves existing state.
## Capacity and width are at most 65536; ring plus side-slot byte storage is at most 16 MiB.
func configure(capacity: int, neutral: PackedByteArray) -> int:
	if capacity < 2 or capacity > MAX_CAPACITY or neutral.is_empty() or neutral.size() > MAX_INPUT_BYTES:
		return Code.INVALID_CONFIGURATION
	if (capacity + 1) * neutral.size() > MAX_STORAGE_BYTES:
		return Code.INVALID_CONFIGURATION
	_capacity = capacity
	_neutral = neutral.duplicate()
	_frames.resize(capacity)
	_frames.fill(-1)
	_slots.resize(capacity)
	for index: int in range(capacity):
		_slots[index] = _neutral.duplicate()
	_tail_frame = 0
	_length = 0
	_last_added = -1
	_delay = 0
	_last_actual = _neutral.duplicate()
	_reclaimed_frame = -1
	_reclaimed_bytes = _neutral.duplicate()
	reset_prediction()
	return Code.OK


## Increase delay by immediately inserting repeat-latest actual frames.
## Capacity and frame-range rejection are atomic. Decrease after an add is unsupported.
func set_frame_delay(delay: int) -> int:
	return _set_frame_delay(delay, -1)


## The supplied floor comes from the session global rollback window, never local arrivals.
func set_frame_delay_with_reclaim_floor(delay: int, reclaim_floor: int) -> int:
	if _capacity == 0:
		return Code.NOT_CONFIGURED
	if not _valid_frame(reclaim_floor):
		return Code.FRAME_RANGE
	return _set_frame_delay(delay, reclaim_floor)


func _set_frame_delay(delay: int, reclaim_floor: int) -> int:
	if _capacity == 0:
		return Code.NOT_CONFIGURED
	if delay < 0 or delay >= _capacity:
		return Code.INVALID_CONFIGURATION
	if delay == _delay or _last_added == -1:
		_delay = delay
		return Code.OK
	if delay < _delay:
		return Code.DELAY_DECREASE_UNSUPPORTED
	var delta: int = delay - _delay
	var code: int = _append_check(delta, reclaim_floor)
	if code != Code.OK:
		return code
	var repeated: PackedByteArray = _last_actual.duplicate()
	for index: int in range(delta):
		_append(_last_added + 1, repeated, reclaim_floor)
	_delay = delay
	return Code.OK


## Initial missing frames use neutral bytes; later skipped samples are rejected.
func add_input(sample_frame: int, bytes: PackedByteArray) -> Result:
	return _add_input(sample_frame, bytes, -1)


## Reclaim only when full, evicting through the global floor and preserving its actual bytes.
func add_input_with_reclaim_floor(sample_frame: int, bytes: PackedByteArray, reclaim_floor: int) -> Result:
	if _capacity == 0:
		return Result.new(Code.NOT_CONFIGURED)
	if not _valid_frame(reclaim_floor):
		return Result.new(Code.FRAME_RANGE)
	return _add_input(sample_frame, bytes, reclaim_floor)


func _add_input(sample_frame: int, bytes: PackedByteArray, reclaim_floor: int) -> Result:
	if _capacity == 0:
		return Result.new(Code.NOT_CONFIGURED)
	if not _valid_frame(sample_frame) or _delay > FRAME_MAX - sample_frame:
		return Result.new(Code.FRAME_RANGE)
	if bytes.size() != _neutral.size():
		return Result.new(Code.INPUT_WIDTH)
	var scheduled: int = sample_frame + _delay
	if _last_added != -1 and scheduled != _last_added + 1:
		return Result.new(Code.OUT_OF_ORDER)
	var required: int = scheduled - _last_added
	var code: int = _append_check(required, reclaim_floor)
	if code != Code.OK:
		return Result.new(code)
	while _last_added + 1 < scheduled:
		_append(_last_added + 1, _neutral, reclaim_floor)
	_append(scheduled, bytes, reclaim_floor)
	return Result.new(Code.OK, scheduled)


## Return actual input outside prediction episodes, or frozen repeat-latest bytes.
## Mismatch refuses all reads until reset_prediction; confirmed_input remains available.
func input(frame: int) -> Result:
	if _capacity == 0:
		return Result.new(Code.NOT_CONFIGURED)
	if not _valid_frame(frame):
		return Result.new(Code.FRAME_RANGE)
	if _first_incorrect != -1:
		return Result.new(Code.PREDICTION_MISMATCH)
	# Rust records this request even if the frame predates the logical tail.
	_last_requested = frame
	if frame == _reclaimed_frame:
		return Result.new(Code.OK, frame, _reclaimed_bytes, Status.CONFIRMED)
	if frame < _tail_frame:
		return Result.new(Code.BEFORE_RETAINED)
	if _prediction_frame == -1:
		if _length > 0 and frame <= _last_added:
			return Result.new(Code.OK, frame, _slots[frame % _capacity], Status.CONFIRMED)
		_prediction_frame = _last_added + 1
		_prediction_bytes = _last_actual.duplicate()
	return Result.new(Code.OK, frame, _prediction_bytes, Status.PREDICTED)


## Inspect a physical confirmed frame tag, including logically discarded slots.
func confirmed_input(frame: int) -> Result:
	if _capacity == 0:
		return Result.new(Code.NOT_CONFIGURED)
	if not _valid_frame(frame):
		return Result.new(Code.FRAME_RANGE)
	if frame == _reclaimed_frame:
		return Result.new(Code.OK, frame, _reclaimed_bytes, Status.CONFIRMED)
	var index: int = frame % _capacity
	if _frames[index] != frame:
		return Result.new(Code.NO_CONFIRMED_INPUT)
	return Result.new(Code.OK, frame, _slots[index], Status.CONFIRMED)


## Recovery accepts only the contiguous retained interval, excluding stale physical tags.
## Unlike input(), this exact actual lookup does not change prediction or request bookkeeping.
func retained_confirmed_input(frame: int) -> Result:
	if _capacity == 0:
		return Result.new(Code.NOT_CONFIGURED)
	if not _valid_frame(frame):
		return Result.new(Code.FRAME_RANGE)
	var first: int = _tail_frame
	if _reclaimed_frame != -1 and _reclaimed_frame + 1 == _tail_frame:
		first = _reclaimed_frame
	if _length == 0 or frame < first:
		return Result.new(Code.BEFORE_RETAINED)
	if frame > _last_added:
		return Result.new(Code.NO_CONFIRMED_INPUT)
	return confirmed_input(frame)


## Discard before frame, clamped to the latest request, always retaining newest.
## The -1 sentinel is a no-op; physical tags survive until reused.
func discard_confirmed_frames(frame: int) -> int:
	if _capacity == 0:
		return Code.NOT_CONFIGURED
	if frame < -1 or frame > FRAME_MAX:
		return Code.FRAME_RANGE
	if _length == 0 or frame == -1:
		return Code.OK
	var target: int = mini(frame, _last_added)
	if _last_requested != -1:
		target = mini(target, _last_requested)
	if _reclaimed_frame != -1 and _reclaimed_frame < target:
		_reclaimed_frame = -1
	if target > _tail_frame:
		_length -= target - _tail_frame
		_tail_frame = target
	return Code.OK


func reset_prediction() -> void:
	_prediction_frame = -1
	_prediction_bytes = PackedByteArray()
	_first_incorrect = -1
	_last_requested = -1


func first_incorrect_frame() -> int:
	return _first_incorrect


func frame_delay() -> int:
	return _delay


func _append_check(count: int, reclaim_floor: int) -> int:
	if count > FRAME_MAX - _last_added:
		return Code.FRAME_RANGE
	# Startup stays bounded and atomic, including when a caller supplies a floor.
	if _last_added == -1 and count > _capacity:
		return Code.CAPACITY
	var evictions: int = maxi(0, _length + count - _capacity)
	if evictions > 0 and (reclaim_floor == -1 or _tail_frame + evictions - 1 > reclaim_floor):
		return Code.CAPACITY
	return Code.OK


func _append(frame: int, bytes: PackedByteArray, reclaim_floor: int) -> void:
	if _length == _capacity:
		if _tail_frame == reclaim_floor:
			_reclaimed_frame = _tail_frame
			_reclaimed_bytes = _slots[_tail_frame % _capacity].duplicate()
		_tail_frame += 1
		_length -= 1
	var index: int = frame % _capacity
	_frames[index] = frame
	# Private slots are replaced, never mutated: one native copy also owns the latest actual.
	_last_actual = bytes.duplicate()
	_slots[index] = _last_actual
	_length += 1
	_last_added = frame
	if _prediction_frame != -1:
		if _first_incorrect == -1 and _prediction_bytes != bytes:
			_first_incorrect = frame
		if _prediction_frame == _last_requested and _first_incorrect == -1:
			_prediction_frame = -1
		else:
			# FRAME_MAX + 1 is private episode bookkeeping, never a public frame.
			_prediction_frame = frame + 1


func _valid_frame(frame: int) -> bool:
	return frame >= 0 and frame <= FRAME_MAX
