class_name FortressNativeDriver
extends RefCounted

const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Writer = preload("res://addons/fortress_rollback/core/snapshot_writer.gd")
const Reader = preload("res://addons/fortress_rollback/core/snapshot_reader.gd")
# Mirrors the native binding receive codes.
enum ReceiveCode { ACCEPTED, REJECTED, FULL }

const INPUT_BYTES: int = 4
const WIRE_PROFILE: String = "fortress-native-d124c890-v1-u32"

var _native: RefCounted
var _game: RefCounted
var _local_players: PackedInt32Array
var _snapshot_limit: int
var _save_succeeded: Callable
var _status: Types.Status = Types.Status.new()
var _stats: Types.Statistics = Types.Statistics.new()
var _retained: PackedByteArray
var _callback_frame: int
var _request_frame: int = -1
var _request_kind: int = -1
var _active_view: RefCounted
var _terminal_detail: String
var _busy: bool = false
var _last_now: int = -1

## Requires the separately installed native addon.
static func available() -> bool:
	return ClassDB.class_exists(&"FortressNativeSession") and ClassDB.class_has_method(&"FortressNativeSession", &"wire_profile") \
		and ClassDB.class_has_method(&"FortressNativeSession", &"receive_from_result")


func configure(endpoints: PackedInt32Array, game: RefCounted, snapshot_limit: int, save_succeeded: Callable) -> int:
	if not available():
		return Types.Code.UNSUPPORTED
	if _native != null or game == null or snapshot_limit < 1 or snapshot_limit > 16777216:
		return Types.Code.INVALID_CONFIGURATION
	var native: RefCounted = ClassDB.instantiate(&"FortressNativeSession")
	if native == null or native.call("wire_profile") != WIRE_PROFILE:
		return Types.Code.UNSUPPORTED
	if not native.call("start_roster", endpoints):
		return Types.Code.INVALID_CONFIGURATION
	for slot: int in endpoints.size():
		if endpoints[slot] == 0:
			_local_players.append(slot)
	_native = native
	_game = game
	_snapshot_limit = snapshot_limit
	_save_succeeded = save_succeeded
	return Types.Code.OK


func _step(now_us: int, samples: Array[PackedByteArray]) -> int:
	if _busy:
		return Types.Code.BUSY
	if _status.lifecycle == Types.Lifecycle.TERMINATED:
		return _status.reason
	if now_us < 0 or now_us < _last_now:
		return Types.Code.INVALID_TIME
	if samples.size() != _local_players.size():
		return Types.Code.INVALID_CONFIGURATION
	var row: PackedByteArray = PackedByteArray()
	for index: int in samples.size():
		var sample: PackedByteArray = samples[index]
		if not _retained.is_empty():
			var retained: PackedByteArray = _retained.slice(index * INPUT_BYTES, (index + 1) * INPUT_BYTES)
			if not sample.is_empty() and sample != retained:
				return Types.Code.INPUT_ALREADY_SUBMITTED
			sample = retained
		if sample.size() != INPUT_BYTES:
			return Types.Code.MISSING_LOCAL_INPUT if sample.is_empty() else Types.Code.INPUT_WIDTH
		row.append_array(sample)
	_last_now = now_us
	_retained = row
	_busy = true
	var code: int = _native.call("step_roster", _retained, self)
	_busy = false
	if _status.lifecycle == Types.Lifecycle.TERMINATED:
		_native = null
		return _status.reason
	if code < 0:
		_terminal_detail = _native.call("terminal_reason")
		match _terminal_detail:
			"callback_failed":
				terminate(Types.Code.CALLBACK_FAILED)
			"desync":
				terminate(Types.Code.DESYNC)
			_:
				terminate(Types.Code.PROTOCOL_FAILED)
		return _status.reason
	_status.current_frame = _native.call("current_frame")
	_status.confirmed_frame = mini(int(_native.call("confirmed_frame")), _status.current_frame - 1)
	if code == 0:
		_stats.advanced_frames += 1
		_retained.clear()
		return Types.Code.OK
	if not _native.call("is_running"):
		return Types.Code.NOT_SYNCHRONIZED
	_stats.prediction_stalls += 1
	return Types.Code.PREDICTION_STALL


func receive_result(endpoint: int, bytes: PackedByteArray) -> int:
	if _native == null or _busy or _status.lifecycle != Types.Lifecycle.RUNNING:
		return ReceiveCode.REJECTED
	return _native.call("receive_from_result", endpoint, bytes)


func drain_packets() -> Array[Dictionary]:
	if _native == null or _busy or _status.lifecycle == Types.Lifecycle.TERMINATED:
		return []
	return _native.call("drain_routed_packets")


func interrupted_endpoints() -> PackedInt32Array:
	return _native.call("interrupted_endpoints") if _native != null and not _busy else PackedInt32Array()


func terminal_detail() -> String:
	return _terminal_detail


func status() -> Types.Status:
	var copy: Types.Status = Types.Status.new()
	copy.current_frame = _status.current_frame
	copy.confirmed_frame = _status.confirmed_frame
	copy.lifecycle = _status.lifecycle
	copy.reason = _status.reason
	copy.failure_frame = _status.failure_frame
	copy.failure_kind = _status.failure_kind
	return copy


func statistics() -> Types.Statistics:
	var copy: Types.Statistics = Types.Statistics.new()
	copy.rollback_count = _stats.rollback_count
	copy.max_rollback_depth = _stats.max_rollback_depth
	copy.resimulated_frames = _stats.resimulated_frames
	copy.advanced_frames = _stats.advanced_frames
	copy.prediction_stalls = _stats.prediction_stalls
	copy.last_rollback_depth = _stats.last_rollback_depth
	return copy


func local_players() -> PackedInt32Array:
	return _local_players.duplicate()


func scheduled_local_input(slot: int) -> Types.InputResult:
	var result: Types.InputResult = Types.InputResult.new()
	var index: int = _local_players.find(slot)
	if index < 0:
		result.code = Types.Code.INVALID_PLAYER
	elif _retained.is_empty():
		result.code = Types.Code.MISSING_LOCAL_INPUT
	else:
		result.code = Types.Code.OK
		result.frame = _status.current_frame
		result.bytes = _retained.slice(index * INPUT_BYTES, (index + 1) * INPUT_BYTES)
	return result


func terminate(reason: int) -> void:
	if _status.lifecycle == Types.Lifecycle.RUNNING:
		_status.lifecycle = Types.Lifecycle.TERMINATED
		_status.reason = reason if reason != Types.Code.OK else Types.Code.TERMINATED
		_status.failure_frame = _request_frame if _request_kind >= 0 else _status.current_frame
		_status.failure_kind = _request_kind
		_retained.clear()
		if _active_view != null:
			_active_view._expire()
		if not _busy:
			_native = null


# Called synchronously by the native ordered request dispatcher.
func save_state(frame: int) -> Variant:
	if not _can_dispatch():
		return null
	var writer: Writer = Writer.new(_snapshot_limit)
	_begin_callback(frame, Types.Kind.SAVE, writer)
	var saved: Variant = _game.save_state(frame, writer)
	var ok: bool = _save_succeeded.call(saved) and writer.status() == Writer.Code.OK
	var bytes: PackedByteArray = writer._written_copy()
	if _end_callback(ok):
		return bytes
	return null


func load_state(frame: int, bytes: PackedByteArray) -> bool:
	if not _can_dispatch():
		return false
	_callback_frame = frame
	var reader: Reader = Reader.new(bytes, true)
	_begin_callback(frame, Types.Kind.LOAD, reader)
	var loaded: Variant = _game.load_state(frame, reader)
	if not _end_callback(loaded is bool and loaded and reader.is_complete()):
		return false
	_stats.rollback_count += 1
	_stats.last_rollback_depth = _status.current_frame - frame
	_stats.max_rollback_depth = maxi(_stats.max_rollback_depth, _stats.last_rollback_depth)
	return true


func advance_game(bytes: PackedByteArray, statuses: PackedByteArray) -> bool:
	if not _can_dispatch():
		return false
	var samples: Array[PackedByteArray] = []
	var mapped: PackedInt32Array = PackedInt32Array()
	for slot: int in statuses.size():
		samples.append(bytes.slice(slot * INPUT_BYTES, (slot + 1) * INPUT_BYTES))
		mapped.append(statuses[slot] + Types.Queue.Status.CONFIRMED)
	var view: Types.FrameInputs = Types.FrameInputs.new(samples, mapped)
	_begin_callback(_callback_frame, Types.Kind.ADVANCE, view)
	var advanced: Variant = _game.simulate_frame(_callback_frame, view)
	if not _end_callback(advanced is bool and advanced):
		return false
	if _callback_frame < _status.current_frame:
		_stats.resimulated_frames += 1
	_callback_frame += 1
	return true


func _can_dispatch() -> bool:
	return _busy and _active_view == null and _status.lifecycle == Types.Lifecycle.RUNNING


func _begin_callback(frame: int, kind: int, view: RefCounted) -> void:
	_request_frame = frame
	_request_kind = kind
	_active_view = view


func _end_callback(ok: bool) -> bool:
	_active_view._expire()
	_active_view = null
	if ok and _status.lifecycle == Types.Lifecycle.RUNNING:
		_request_kind = -1
		return true
	return false
