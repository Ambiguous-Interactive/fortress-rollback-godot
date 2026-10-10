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


func position() -> Status.PositionResult:
	return Status.PositionResult.new(status(), _cursor if _is_live else 0)


func status() -> int:
	return _error if _is_live else Code.EXPIRED_VIEW


func _completion_code() -> int:
	var code: int = status()
	if code == Code.OK and _cursor != _bytes.size():
		_error = Code.TRAILING_BYTES
		return _error
	return code


func _expire() -> void:
	_is_live = false
	_bytes = PackedByteArray()
