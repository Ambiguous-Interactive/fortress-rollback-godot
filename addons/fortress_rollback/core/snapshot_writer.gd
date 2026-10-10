class_name FortressSnapshotWriter
extends RefCounted

const Status = preload("res://addons/fortress_rollback/core/snapshot_status.gd")
# Shared enum alias keeps error codes identical across history and views.
# gdlint: disable=constant-name
const Code = Status.Code
# gdlint: enable=constant-name
var _bytes: PackedByteArray = PackedByteArray()
var _cursor: int = 0
var _error: int = Code.OK
var _is_live: bool = false


func _init(capacity: int = 0) -> void:
	if capacity > 0 and capacity <= 16777216:
		_bytes.resize(capacity)
		_is_live = true


func write_bytes(bytes: PackedByteArray) -> int:
	var code: int = status()
	if code != Code.OK:
		return code
	if bytes.size() > _bytes.size() - _cursor:
		_error = Code.OVERFLOW
		return _error
	for index: int in range(bytes.size()):
		_bytes[_cursor + index] = bytes[index]
	_cursor += bytes.size()
	return Code.OK


func position() -> Status.PositionResult:
	return Status.PositionResult.new(status(), _cursor if _is_live else 0)


func status() -> int:
	return _error if _is_live else Code.EXPIRED_VIEW


func _expire() -> void:
	_is_live = false
	_bytes = PackedByteArray()


func _written_copy() -> PackedByteArray:
	return _bytes.slice(0, _cursor)
