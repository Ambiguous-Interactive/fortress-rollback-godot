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
	CONFLICTING_INPUT,
}
enum Status { NONE, CONFIRMED, PREDICTED, DISCONNECTED }

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
var _frozen: bool = false
var _frozen_frame: int = -1


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
	_frozen = false
	_frozen_frame = -1
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
	if _frozen:
		# A dropped slot stops accepting inputs; the frozen value keeps every survivor aligned.
		return Result.new(Code.OK, _frozen_frame)
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


## Validate an immutable retained overlap followed by a sequential missing suffix.
## At most capacity rows are accepted; no queue or prediction field changes on refusal.
func validate_missing_backfill(start: int, inputs: Array[PackedByteArray], reclaim_floor: int) -> int:
	if _capacity == 0:
		return Code.NOT_CONFIGURED
	if not _valid_frame(start) or not _valid_frame(reclaim_floor) or inputs.size() - 1 > FRAME_MAX - start:
		return Code.FRAME_RANGE
	if inputs.size() > _capacity:
		return Code.CAPACITY
	if _frozen and not inputs.is_empty():
		return Code.OUT_OF_ORDER
	for bytes: PackedByteArray in inputs:
		if bytes.size() != _neutral.size():
			return Code.INPUT_WIDTH
	var overlap: int = mini(inputs.size(), maxi(0, _last_added - start + 1))
	for index: int in range(overlap):
		var retained: Result = retained_confirmed_input(start + index)
		if retained.code != Code.OK:
			return retained.code
		if retained.bytes != inputs[index]:
			return Code.CONFLICTING_INPUT
	if overlap < inputs.size() and start + overlap != _last_added + 1:
		return Code.OUT_OF_ORDER
	return _append_check(inputs.size() - overlap, reclaim_floor)


## Install only the missing scheduled frames after checking the whole chunk.
## Delay is already applied by the donor; appending preserves ordinary mismatch bookkeeping.
func install_missing_backfill(start: int, inputs: Array[PackedByteArray], reclaim_floor: int) -> int:
	var code: int = validate_missing_backfill(start, inputs, reclaim_floor)
	if code != Code.OK:
		return code
	var overlap: int = mini(inputs.size(), maxi(0, _last_added - start + 1))
	for index: int in range(overlap, inputs.size()):
		_append(start + index, inputs[index], reclaim_floor)
	return Code.OK


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
	if _frozen and frame > _frozen_frame:
		return Result.new(Code.OK, frame, _last_actual, Status.DISCONNECTED)
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


## Exact contiguous logical actual interval, excluding stale physical tags and predictions.
## Verification reads at most capacity plus the one reclaimed frame, without copying payloads.
func retained_frame_range() -> PackedInt64Array:
	if _capacity == 0 or _length == 0:
		return PackedInt64Array()
	var first: int = _tail_frame
	if _reclaimed_frame != -1 and _reclaimed_frame + 1 == _tail_frame:
		first = _reclaimed_frame
	if _last_added < first or _last_added - first > _capacity:
		return PackedInt64Array()
	for frame: int in range(first, _last_added + 1):
		if frame != _reclaimed_frame and _frames[frame % _capacity] != frame:
			return PackedInt64Array()
	return PackedInt64Array([first, _last_added])


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


## Freeze the slot at an agreed frame. Frames past the frame repeat the value confirmed
## there and later inputs are ignored, so the survivors read one deterministic value.
## The agreed value must still be retained: without it the survivors would freeze on
## different bytes, so the freeze is refused instead.
func freeze_at(frame: int) -> int:
	if _capacity == 0:
		return Code.NOT_CONFIGURED
	if _frozen:
		return Code.OK
	if not _valid_frame(frame):
		return Code.FRAME_RANGE
	var agreed: Result = confirmed_input(frame)
	if agreed.code != Code.OK:
		return Code.NO_CONFIRMED_INPUT
	_frozen = true
	_frozen_frame = frame
	_last_actual = agreed.bytes.duplicate()
	# A simulated tail must adopt the frozen bytes and disconnected status, even
	# when its predicted bytes already matched the frozen value.
	# An earlier pending correction stays the earliest one, so a mismatch below the
	# agreed frame is not lost.
	if maxi(_last_added, _last_requested) > frame:
		_first_incorrect = frame + 1 if _first_incorrect == -1 else mini(_first_incorrect, frame + 1)
	return Code.OK


## Freeze the slot at an agreed frame with an explicit certified value. The value
## replaces the retained row, so a survivor that already released the row still
## freezes on the same bytes as the other survivors.
func freeze_with_value(frame: int, bytes: PackedByteArray) -> int:
	if _capacity == 0:
		return Code.NOT_CONFIGURED
	if _frozen:
		return Code.OK
	if not _valid_frame(frame):
		return Code.FRAME_RANGE
	if bytes.size() != _neutral.size():
		return Code.INPUT_WIDTH
	_frozen = true
	_frozen_frame = frame
	_last_actual = bytes.duplicate()
	# Both actual and predicted tails must adopt the certified value and status.
	if maxi(_last_added, _last_requested) > frame:
		_first_incorrect = frame + 1 if _first_incorrect == -1 else mini(_first_incorrect, frame + 1)
	return Code.OK


## The value the simulation used at a frame: the frozen value for a dropped slot past the
## agreed frame, otherwise the retained actual input.
func simulated_input(frame: int) -> Result:
	if _frozen and frame > _frozen_frame:
		return Result.new(Code.OK, frame, _last_actual, Status.DISCONNECTED)
	return confirmed_input(frame)


## The retained value the simulation used at a frame.
func retained_simulated_input(frame: int) -> Result:
	if _frozen and frame > _frozen_frame:
		return Result.new(Code.OK, frame, _last_actual, Status.DISCONNECTED)
	return retained_confirmed_input(frame)


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
