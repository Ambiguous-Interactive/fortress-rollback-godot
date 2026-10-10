class_name FortressSnapshotStatus
extends RefCounted

enum Code { OK, NOT_CONFIGURED, INVALID_CONFIGURATION, FRAME_RANGE, BUSY, HISTORY_UNAVAILABLE, EXPIRED_VIEW, OVERFLOW, UNDERFLOW, TRAILING_BYTES, CALLBACK_FAILED, CHECKSUM_WIDTH }


class PositionResult:
	extends RefCounted
	var code: int
	var value: int

	func _init(result_code: int, result_value: int = 0) -> void:
		code = result_code
		value = result_value
