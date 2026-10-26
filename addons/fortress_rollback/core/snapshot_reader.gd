class_name FortressSnapshotReader
extends RefCounted

const Status = preload("res://addons/fortress_rollback/core/snapshot_status.gd")
# Shared enum alias keeps error codes identical across history and views.
# gdlint: disable=constant-name
const Code = Status.Code
# gdlint: enable=constant-name


class ReadResult:
	extends RefCounted
	var code: int
	var bytes: PackedByteArray

	func _init(result_code: int) -> void:
		code = result_code
		bytes = PackedByteArray()


var _bytes: PackedByteArray = PackedByteArray()
var _cursor: int = 0
var _error: int = Code.OK
var _is_live: bool = false


func _init(bytes: PackedByteArray = PackedByteArray(), is_live: bool = false) -> void:
	_bytes = bytes.duplicate()
	_is_live = is_live


func read_bytes(count: int) -> ReadResult:
	var code: int = status()
	if code != Code.OK:
		return ReadResult.new(code)
	if count < 0 or count > _bytes.size() - _cursor:
		_error = Code.UNDERFLOW
		return ReadResult.new(_error)
	var result: ReadResult = ReadResult.new(Code.OK)
	result.bytes = _bytes.slice(_cursor, _cursor + count)
	_cursor += count
	return result


## Copy the next destination.size() bytes into caller-owned storage without a ReadResult wrapper.
## Rejection preserves destination and cursor. Underflow is sticky across both read APIs.
## Copies bytes in GDScript; read_bytes() can be faster for wide snapshots.
func read_into(destination: PackedByteArray) -> int:
	var code: int = status()
	if code != Code.OK:
		return code
	var count: int = destination.size()
	if count > _bytes.size() - _cursor:
		_error = Code.UNDERFLOW
		return _error
	for index: int in count:
		destination[index] = _bytes[_cursor + index]
	_cursor += count
	return Code.OK


func position() -> Status.PositionResult:
	return Status.PositionResult.new(status(), _cursor if _is_live else 0)


func status() -> int:
	return _error if _is_live else Code.EXPIRED_VIEW


## True only when a live, error-free reader has consumed the complete snapshot.
## Check before publishing restored game state; this does not complete the request.
func is_complete() -> bool:
	return status() == Code.OK and _cursor == _bytes.size()


func _completion_code() -> int:
	var code: int = status()
	if code == Code.OK and _cursor != _bytes.size():
		_error = Code.TRAILING_BYTES
		return _error
	return code


func _expire() -> void:
	_is_live = false
	_bytes = PackedByteArray()
