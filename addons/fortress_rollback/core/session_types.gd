class_name FortressSessionTypes
extends RefCounted

enum Code {
	OK,
	READY,
	MISSING_LOCAL_INPUT,
	PREDICTION_STALL,
	BUSY,
	NOT_CONFIGURED,
	INVALID_CONFIGURATION,
	INVALID_PLAYER,
	INVALID_FRAME,
	INPUT_WIDTH,
	INPUT_ALREADY_SUBMITTED,
	INVALID_TIME,
	STALE_REQUEST,
	HISTORY_UNAVAILABLE,
	CALLBACK_FAILED,
	SNAPSHOT_FAILED,
	FRAME_EXHAUSTED,
	INPUT_FAILED,
	DESYNC,
	TERMINATED,
	EXPIRED_VIEW,
	NOT_SYNCHRONIZED,
	NETWORK_BACKPRESSURE,
	PROTOCOL_FAILED,
	UNSUPPORTED,
}
enum Kind { SAVE, LOAD, ADVANCE }
enum Lifecycle { RUNNING, TERMINATED }


class Result:
	extends RefCounted
	var code: int
	var batch: RefCounted
	var value: int = 0

	func _init(result_code: int, result_batch: RefCounted = null) -> void:
		code = result_code
		batch = result_batch


class Status:
	extends RefCounted
	var current_frame: int = 0
	var confirmed_frame: int = -1
	var lifecycle: int = Lifecycle.RUNNING
	var reason: int = Code.OK
	var failure_frame: int = -1
	var failure_kind: int = -1
	var pending_rollback_frame: int = -1


class Statistics:
	extends RefCounted
	var rollback_count: int = 0
	var resimulated_frames: int = 0
	var advanced_frames: int = 0
	var prediction_stalls: int = 0
	var last_rollback_depth: int = 0
	var max_rollback_depth: int = 0


class InputResult:
	extends RefCounted
	var frame: int = -1
	var code: int = Code.OK
	var bytes: PackedByteArray = PackedByteArray()
	var status: int = 0


class FrameInputs:
	extends RefCounted
	var _bytes: Array[PackedByteArray] = []
	var _statuses: PackedInt32Array = PackedInt32Array()
	var _live: bool = true

	func _init(input_bytes: Array[PackedByteArray] = [], input_statuses: PackedInt32Array = PackedInt32Array()) -> void:
		for bytes: PackedByteArray in input_bytes:
			_bytes.append(bytes.duplicate())
		_statuses = input_statuses.duplicate()

	func read(player: int) -> InputResult:
		var result: InputResult = InputResult.new()
		if not _live:
			result.code = Code.EXPIRED_VIEW
		elif player < 0 or player >= _bytes.size():
			result.code = Code.INVALID_PLAYER
		else:
			result.bytes = _bytes[player].duplicate()
			result.status = _statuses[player]
		return result

	func size() -> Result:
		var result: Result = Result.new(Code.OK if _live else Code.EXPIRED_VIEW)
		result.value = _bytes.size() if _live else 0
		return result

	func _expire() -> void:
		_live = false
		_bytes.clear()
		_statuses.clear()


class Request:
	extends RefCounted
	var kind: int
	var frame: int
	var batch_id: int
	var request_id: int
	var writer: RefCounted
	var reader: RefCounted
	var inputs: FrameInputs


class Batch:
	extends RefCounted
	var _session: WeakRef
	var _id: int

	func _init(session: RefCounted, identity: int) -> void:
		_session = weakref(session)
		_id = identity

	func next_request() -> Request:
		var session: RefCounted = _session.get_ref()
		return session._next_request(_id) if session != null else null
