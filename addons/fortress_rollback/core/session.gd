class_name FortressSession
extends RefCounted

# gdlint: disable=constant-name,max-returns
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const History = preload("res://addons/fortress_rollback/core/snapshot_history.gd")
const Trace = preload("res://addons/fortress_rollback/core/diagnostic_trace.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Code = Types.Code
const Kind = Types.Kind
const Lifecycle = Types.Lifecycle

var _config: Config
var _queues: Array[Queue] = []
var _history: History
var _samples: Array[PackedByteArray] = []
var _received: PackedInt64Array = PackedInt64Array()
var _current: int = 0
var _time: int = -1
var _reason: int = Code.OK
var _failure_frame: int = -1
var _failure_kind: int = -1
var _batch_id: int = 0
var _batch: Types.Batch
var _plan: Array[Vector2i] = []
var _index: int = 0
var _active: Types.Request
var _writer: RefCounted
var _reader: RefCounted
var _inputs: Types.FrameInputs
var _target: int = 0
var _outcome: int = Code.OK
var _originals: Dictionary = {}
var _is_driver_callback: bool = false
var _has_confirmation_limit: bool = false
var _confirmation_limit: int = -1
var _trace: Trace = Trace.new()
var _statistics: Types.Statistics = Types.Statistics.new()
var _replay: Replay


## Creates owned validated configuration and fresh history; never replaces an open batch.
func configure(config: Config) -> int:
	if _is_driver_callback or _batch != null:
		return Code.BUSY
	if config == null or config.validate() != Code.OK:
		return Code.INVALID_CONFIGURATION
	var history: History = History.new()
	if (
		history.configure(
			config.history_slots, config.max_snapshot_bytes, config.max_prediction_frames, config.check_distance, config.storage_budget_bytes, config.checksums_enabled
		)
		!= History.Code.OK
	):
		return Code.INVALID_CONFIGURATION
	var queues: Array[Queue] = []
	for player: int in range(config.player_count):
		var queue: Queue = Queue.new()
		if (
			queue.configure(config.queue_capacity, config.neutral_input) != Queue.Code.OK
			or queue.set_frame_delay(config.input_delay if player in config.local_players else 0) != Queue.Code.OK
		):
			return Code.INVALID_CONFIGURATION
		queues.append(queue)
	_config = config.owned_copy()
	_history = history
	_queues = queues
	_samples.resize(config.player_count)
	for player: int in range(config.player_count):
		_samples[player] = PackedByteArray()
	_received.resize(config.player_count)
	_received.fill(-1)
	_current = 0
	_time = -1
	_reason = Code.OK
	_failure_frame = -1
	_failure_kind = -1
	_originals.clear()
	_has_confirmation_limit = false
	_confirmation_limit = -1
	_statistics = Types.Statistics.new()
	_trace = Trace.new()
	_trace.configure(_config)
	_replay = null
	if _config.replay_max_frames > 0:
		_replay = Replay.new()
		_replay._start(_config.player_count, _config.input_width)
	return Code.OK


func poll(now_us: int) -> Types.Result:
	var code: int = _mutation_code()
	if code != Code.OK:
		return Types.Result.new(code)
	if now_us < 0 or now_us < _time:
		return Types.Result.new(Code.INVALID_TIME)
	_time = now_us
	return Types.Result.new(Code.OK)


## Identical current samples are idempotent while stalled; conflicts preserve input.
func submit_local_input(player: int, sample_frame: int, bytes: PackedByteArray) -> Types.Result:
	var code: int = _mutation_code()
	if code != Code.OK:
		return Types.Result.new(code)
	if player < 0 or player >= _queues.size() or player not in _config.local_players:
		return Types.Result.new(Code.INVALID_PLAYER)
	if sample_frame != _current:
		return Types.Result.new(Code.INVALID_FRAME)
	if bytes.size() != _config.input_width:
		return Types.Result.new(Code.INPUT_WIDTH)
	if not _samples[player].is_empty():
		var repeated: Types.Result = Types.Result.new(Code.OK if _samples[player] == bytes else Code.INPUT_ALREADY_SUBMITTED)
		repeated.value = _received[player] if repeated.code == Code.OK else -1
		return repeated
	var result: Queue.Result = _queues[player].add_input_with_reclaim_floor(sample_frame, bytes, _floor())
	if result.code != Queue.Code.OK:
		return Types.Result.new(Code.INPUT_FAILED)
	_samples[player] = bytes.duplicate()
	_received[player] = result.frame
	var submitted: Types.Result = Types.Result.new(Code.OK)
	submitted.value = result.frame
	return submitted


## External-input core seam, without transport or P2P handshake guarantees.
## Actual remote frames are sequential and immutable; retained identical repeats are idempotent.
func receive_input(player: int, frame: int, bytes: PackedByteArray) -> Types.Result:
	var code: int = _mutation_code()
	if code != Code.OK:
		return Types.Result.new(code)
	if player < 0 or player >= _queues.size() or player in _config.local_players:
		return Types.Result.new(Code.INVALID_PLAYER)
	if frame < 0 or frame > Queue.FRAME_MAX or frame < _floor():
		return Types.Result.new(Code.INVALID_FRAME)
	if bytes.size() != _config.input_width:
		return Types.Result.new(Code.INPUT_WIDTH)
	if frame <= _received[player]:
		var existing: Queue.Result = _queues[player].retained_confirmed_input(frame)
		return Types.Result.new(Code.OK if existing.code == Queue.Code.OK and existing.bytes == bytes else Code.INPUT_ALREADY_SUBMITTED)
	if frame != _received[player] + 1 and not (_received[player] == -1 and frame == _config.input_delay):
		return Types.Result.new(Code.INVALID_FRAME)
	# Input delay applies to local samples, not already scheduled remote frames.
	var result: Queue.Result = _queues[player].add_input_with_reclaim_floor(frame - _queues[player].frame_delay(), bytes, _floor())
	if result.code != Queue.Code.OK:
		return Types.Result.new(Code.INPUT_FAILED)
	_received[player] = result.frame
	return Types.Result.new(Code.OK)


## Owned current submitted sample, available until its successful advance completes.
func scheduled_local_input(player: int) -> Types.InputResult:
	var result: Types.InputResult = Types.InputResult.new()
	if _config == null:
		result.code = Code.NOT_CONFIGURED
	elif player < 0 or player >= _queues.size() or player not in _config.local_players:
		result.code = Code.INVALID_PLAYER
	elif _samples[player].is_empty():
		result.code = Code.MISSING_LOCAL_INPUT
	else:
		result.frame = _received[player]
		result.bytes = _samples[player].duplicate()
		result.status = Queue.Status.CONFIRMED
	return result


## Local delay now in effect, or -1 for an unconfigured session or a slot that is not local.
func input_delay(player: int) -> int:
	if _config == null or player < 0 or player >= _queues.size() or player not in _config.local_players:
		return -1
	return _queues[player].frame_delay()


## Before the player's first sample any delay that fits the queue applies. After it, only increases:
## the new frames repeat the latest actual input, so no scheduled frame changes meaning.
## Allowed between steps and while stalled. The value is the player's last scheduled frame.
func set_input_delay(player: int, delay: int) -> Types.Result:
	var code: int = _mutation_code()
	if code != Code.OK:
		return Types.Result.new(code)
	if player < 0 or player >= _queues.size() or player not in _config.local_players:
		return Types.Result.new(Code.INVALID_PLAYER)
	if delay < 0 or delay + maxi(_config.max_prediction_frames, _config.check_distance) + 2 > _config.queue_capacity:
		return Types.Result.new(Code.INVALID_CONFIGURATION)
	var queue: Queue = _queues[player]
	var added: int = delay - queue.frame_delay()
	if _received[player] != -1 and added < 0:
		return Types.Result.new(Code.UNSUPPORTED)
	if queue.set_frame_delay_with_reclaim_floor(delay, _floor()) != Queue.Code.OK:
		return Types.Result.new(Code.INPUT_FAILED)
	if _received[player] != -1:
		_received[player] += added
	var changed: Types.Result = Types.Result.new(Code.OK)
	changed.value = _received[player]
	return changed


## Owned actual bytes a local player scheduled for a retained frame, or empty when unavailable.
func retained_local_input(player: int, frame: int) -> PackedByteArray:
	if _config == null or player < 0 or player >= _queues.size() or player not in _config.local_players:
		return PackedByteArray()
	var retained: Queue.Result = _queues[player].retained_confirmed_input(frame)
	return retained.bytes.duplicate() if retained.code == Queue.Code.OK else PackedByteArray()


## Per-slot actual scheduled receipt bounds for transport gossip; never prediction frames.
func received_frames() -> PackedInt64Array:
	return _received.duplicate()


## Completed saved boundaries only. Hide snapshots affected by pending repairs and active callbacks.
## Sending may include the confirmed boundary; comparison requires strictly earlier frames.
func confirmed_checksums(include_boundary: bool = false) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if _mutation_code() != Code.OK or not _config.checksums_enabled:
		return result
	var ceiling: int = mini(_current, _confirmed() if include_boundary else _confirmed() - 1)
	for queue: Queue in _queues:
		var incorrect: int = queue.first_incorrect_frame()
		if incorrect != -1:
			# State at f precedes input f; only later snapshots require repair.
			ceiling = mini(ceiling, incorrect)
	for saved: Dictionary in _history.retained_checksums():
		if saved.frame <= ceiling:
			result.append(saved)
	return result


## Fixed-membership mesh confirmation; enable before simulation, then advance monotonically.
## Transport owns the endpoint gossip fold; this engine validates its local receipt ceiling.
func set_confirmation_limit(frame: int) -> Types.Result:
	var code: int = _mutation_code()
	if code != Code.OK:
		return Types.Result.new(code)
	if _config.sync_test:
		return Types.Result.new(Code.INVALID_CONFIGURATION)
	if frame < -1 or frame > Queue.FRAME_MAX or frame > _receipt_minimum():
		return Types.Result.new(Code.INVALID_FRAME)
	if frame < _confirmed() or (_has_confirmation_limit and frame < _confirmation_limit) or (not _has_confirmation_limit and _current != 0):
		return Types.Result.new(Code.INVALID_FRAME)
	_has_confirmation_limit = true
	_confirmation_limit = frame
	return Types.Result.new(Code.OK)


func begin_advance() -> Types.Result:
	var code: int = _mutation_code()
	if code != Code.OK:
		return Types.Result.new(code)
	if _current == Queue.FRAME_MAX or _batch_id == 9223372036854775807:
		return _fatal(Code.FRAME_EXHAUSTED)
	for player: int in _config.local_players:
		if _samples[player].is_empty():
			return Types.Result.new(Code.MISSING_LOCAL_INPUT)
	if _config.sync_test and not _consistent():
		return _fatal(Code.DESYNC)
	var rollback: int = -1
	for queue: Queue in _queues:
		var mismatch: int = queue.first_incorrect_frame()
		if mismatch != -1:
			rollback = mismatch if rollback == -1 else mini(rollback, mismatch)
	if _config.sync_test and _config.check_distance > 0 and _current > _config.check_distance:
		rollback = _current - _config.check_distance
	if rollback >= _current:
		for queue: Queue in _queues:
			queue.reset_prediction()
		rollback = -1
	_plan.clear()
	if rollback != -1:
		if _current - rollback > _config.max_prediction_frames or _history.inspect(rollback).code != History.Code.OK:
			return _fatal(Code.HISTORY_UNAVAILABLE)
		for player: int in range(_queues.size()):
			if _received[player] >= rollback and _queues[player].retained_confirmed_input(rollback).code != Queue.Code.OK:
				return _fatal(Code.HISTORY_UNAVAILABLE, rollback, Kind.LOAD)
		_plan.append(Vector2i(Kind.LOAD, rollback))
		for queue: Queue in _queues:
			queue.reset_prediction()
		for frame: int in range(rollback, _current):
			if frame > rollback:
				_plan.append(Vector2i(Kind.SAVE, frame))
			_plan.append(Vector2i(Kind.ADVANCE, frame))
	var can_advance: bool = _config.sync_test or _can_advance()
	var save_mesh_boundary: bool = _has_confirmation_limit and _config.max_prediction_frames > 0
	if not can_advance and _plan.is_empty() and not save_mesh_boundary:
		_count_stall()
		return Types.Result.new(Code.PREDICTION_STALL)
	if can_advance or save_mesh_boundary:
		if (_config.sync_test and _config.check_distance > 0) or (not _config.sync_test and (_config.max_prediction_frames > 0 or _config.capture_confirmed_snapshots)):
			_plan.append(Vector2i(Kind.SAVE, _current))
	if can_advance:
		_plan.append(Vector2i(Kind.ADVANCE, _current))
	_target = _current + 1 if can_advance else _current
	_outcome = Code.OK if can_advance else Code.PREDICTION_STALL
	_batch_id += 1
	_index = 0
	_batch = Types.Batch.new(self, _batch_id)
	return Types.Result.new(Code.READY, _batch)


func complete_request(batch_id: int, request_id: int, callback_ok: bool, checksum: PackedByteArray = PackedByteArray()) -> Types.Result:
	if _is_driver_callback:
		return Types.Result.new(Code.BUSY)
	if _reason != Code.OK:
		return Types.Result.new(Code.TERMINATED)
	if _batch == null or batch_id != _batch_id or request_id != _index or _active == null:
		return Types.Result.new(Code.STALE_REQUEST)
	var kind: int = _plan[_index].x
	var frame: int = _plan[_index].y
	if not callback_ok:
		return _fatal(Code.CALLBACK_FAILED, frame, kind)
	var snapshot_code: int = History.Code.OK
	if kind == Kind.SAVE:
		snapshot_code = _history.finish_save(_writer, true, checksum)
	elif kind == Kind.LOAD:
		snapshot_code = _history.finish_load(_reader, true)
	if snapshot_code != History.Code.OK:
		return _fatal(Code.SNAPSHOT_FAILED, frame, kind)
	if _config.diagnostic_trace_frames > 0:
		if kind == Kind.SAVE:
			var saved_trace: History.Inspection = _history.inspect(frame)
			_trace.save(frame, saved_trace.bytes, saved_trace.checksum)
		elif kind == Kind.LOAD:
			_trace.load_frame(frame)
		elif kind == Kind.ADVANCE:
			_trace.advance(frame, _inputs)
	if kind == Kind.LOAD:
		_statistics.rollback_count = _increment(_statistics.rollback_count)
		_statistics.last_rollback_depth = _current - frame
		_statistics.max_rollback_depth = maxi(_statistics.max_rollback_depth, _current - frame)
	elif kind == Kind.ADVANCE:
		if frame < _current:
			_statistics.resimulated_frames = _increment(_statistics.resimulated_frames)
		else:
			_statistics.advanced_frames = _increment(_statistics.advanced_frames)
	if kind == Kind.SAVE and _config.sync_test and not _originals.has(frame):
		_originals[frame] = _history.inspect(frame)
	_expire_request()
	_index += 1
	if _index == _plan.size():
		if _outcome == Code.PREDICTION_STALL:
			_count_stall()
		_current = _target
		_batch = null
		if _outcome == Code.OK:
			for player: int in _config.local_players:
				_samples[player] = PackedByteArray()
		_record_replay()
		for queue: Queue in _queues:
			queue.discard_confirmed_frames(_floor())
		return Types.Result.new(_outcome)
	return Types.Result.new(Code.OK)


func status() -> Types.Status:
	var result: Types.Status = Types.Status.new()
	result.current_frame = _current
	result.confirmed_frame = _confirmed()
	result.lifecycle = Lifecycle.RUNNING if _reason == Code.OK else Lifecycle.TERMINATED
	result.reason = _reason
	result.failure_frame = _failure_frame
	result.failure_kind = _failure_kind
	for queue: Queue in _queues:
		var incorrect: int = queue.first_incorrect_frame()
		if incorrect != -1:
			result.pending_rollback_frame = incorrect if result.pending_rollback_frame == -1 else mini(result.pending_rollback_frame, incorrect)
	return result


## Owned completed-callback counters, outside game snapshots. Counts saturate at signed-64 maximum.
## A repair-only batch counts one stall when completed; rejected and aborted calls do not.
func statistics() -> Types.Statistics:
	var result: Types.Statistics = Types.Statistics.new()
	result.rollback_count = _statistics.rollback_count
	result.resimulated_frames = _statistics.resimulated_frames
	result.advanced_frames = _statistics.advanced_frames
	result.prediction_stalls = _statistics.prediction_stalls
	result.last_rollback_depth = _statistics.last_rollback_depth
	result.max_rollback_depth = _statistics.max_rollback_depth
	return result


## Explicitly opted-in canonical payloads; fresh JSON-compatible caller-owned evidence.
func diagnostic_trace() -> Dictionary:
	return _trace.report()


## Caller-owned copy of the confirmed frames recorded by completed steps; null unless replay_max_frames > 0.
func replay() -> Replay:
	return _replay.owned_copy() if _replay != null else null


## Runs after each completed batch, which leaves no repair pending. Records frames whose actual inputs
## every player has received and that are already simulated. The mesh confirmation limit can trail
## receipts in lockstep; receipts never trail the discard floor, so no frame is lost.
func _record_replay() -> void:
	if _replay == null:
		return
	var last: int = mini(mini(_receipt_minimum(), _current - 1), _config.replay_max_frames - 1)
	var saved: Dictionary = {}
	if _config.checksums_enabled:
		for entry: Dictionary in _history.retained_checksums():
			saved[entry.frame] = entry.checksum
	for frame: int in range(_replay.frame_count(), last + 1):
		var row: PackedByteArray = PackedByteArray()
		var neutral: PackedByteArray = PackedByteArray()
		for queue: Queue in _queues:
			var input: Queue.Result = queue.retained_confirmed_input(frame)
			row.append_array(input.bytes if input.code == Queue.Code.OK else PackedByteArray())
			neutral.append_array(_config.neutral_input)
		# Defensive: a missing input keeps frame alignment with a neutral, checksum-free row, as upstream does.
		var skipped: bool = row.size() != neutral.size()
		_replay._append(neutral if skipped else row, PackedByteArray() if skipped else saved.get(frame, PackedByteArray()), skipped)


func _freeze_diagnostic_trace(frame: int, peer_index: int, local: PackedByteArray, remote: PackedByteArray) -> void:
	_trace.freeze(frame, peer_index, local, remote)


func _count_stall() -> void:
	_statistics.prediction_stalls = _increment(_statistics.prediction_stalls)


func _increment(value: int) -> int:
	return value + 1 if value < 9223372036854775807 else value


func drain_events() -> Array[RefCounted]:
	return []


## Termination is final until explicit configure creates a new session.
func terminate(reason: int = Code.TERMINATED, frame: int = -1) -> void:
	if _reason == Code.OK:
		_fatal(reason if reason != Code.OK else Code.TERMINATED, frame if frame >= 0 and frame <= Queue.FRAME_MAX else -1)


func _next_request(batch_id: int) -> Types.Request:
	if _batch == null or batch_id != _batch_id:
		return null
	if _active != null:
		return _active
	var step: Vector2i = _plan[_index]
	var request: Types.Request = Types.Request.new()
	request.kind = step.x
	request.frame = step.y
	request.batch_id = _batch_id
	request.request_id = _index
	if step.x == Kind.SAVE:
		var saved: History.SaveRequest = _history.begin_save(step.y)
		if saved.code != History.Code.OK:
			_fatal(Code.SNAPSHOT_FAILED, step.y, step.x)
			return null
		_writer = saved.writer
		request.writer = _writer
	elif step.x == Kind.LOAD:
		var loaded: History.LoadRequest = _history.begin_load(step.y)
		if loaded.code != History.Code.OK:
			_fatal(Code.HISTORY_UNAVAILABLE, step.y, step.x)
			return null
		_reader = loaded.reader
		request.reader = _reader
	else:
		var input_bytes: Array[PackedByteArray] = []
		var input_statuses: PackedInt32Array = PackedInt32Array()
		for queue: Queue in _queues:
			var input: Queue.Result = queue.input(step.y)
			if input.code != Queue.Code.OK:
				_fatal(Code.HISTORY_UNAVAILABLE, step.y, step.x)
				return null
			input_bytes.append(input.bytes)
			input_statuses.append(input.status)
		_inputs = Types.FrameInputs.new(input_bytes, input_statuses)
		request.inputs = _inputs
	_active = request
	return request


func _consistent() -> bool:
	var floor: int = maxi(0, _current - _config.check_distance)
	var frames: Array = _originals.keys()
	frames.sort()
	for frame: int in frames:
		if frame < floor:
			_originals.erase(frame)
		else:
			var saved: History.Inspection = _history.inspect(frame)
			var original: History.Inspection = _originals[frame]
			if saved.code != History.Code.OK or saved.bytes != original.bytes or (_config.checksums_enabled and saved.checksum != original.checksum):
				_failure_frame = frame
				_trace.freeze(frame, -1, saved.checksum, original.checksum, "sync_test_snapshot")
				return false
	return true


func _can_advance() -> bool:
	if _config.max_prediction_frames == 0:
		for queue: Queue in _queues:
			if queue.retained_confirmed_input(_current).code != Queue.Code.OK:
				return false
		return true
	var confirmed: int = _confirmed()
	var ahead: int = _current if confirmed == -1 else _current - confirmed
	return ahead < _config.max_prediction_frames


func _confirmed() -> int:
	return mini(_receipt_minimum(), _confirmation_limit) if _has_confirmation_limit else _receipt_minimum()


func _receipt_minimum() -> int:
	var confirmed: int = Queue.FRAME_MAX
	for frame: int in _received:
		confirmed = mini(confirmed, frame)
	return confirmed


func _floor() -> int:
	return maxi(0, _current - _config.max_prediction_frames)


func _mutation_code() -> int:
	if _is_driver_callback:
		return Code.BUSY
	if _config == null:
		return Code.NOT_CONFIGURED
	if _reason != Code.OK:
		return Code.TERMINATED
	return Code.BUSY if _batch != null else Code.OK


func _expire_request() -> void:
	if _inputs != null:
		_inputs._expire()
	_inputs = null
	_writer = null
	_reader = null
	_active = null


func _fatal(code: int, frame: int = -1, kind: int = -1) -> Types.Result:
	if _reason == Code.OK:
		_reason = code
		if frame != -1:
			_failure_frame = frame
		_failure_kind = kind
	if _history != null:
		_history.terminate_views()
	_expire_request()
	_batch = null
	return Types.Result.new(code)


## Separate from the batch guard: terminate may clear a batch during a callback.
func _begin_driver_callback() -> int:
	if _is_driver_callback:
		return Code.BUSY
	if _active == null or _batch == null:
		return Code.STALE_REQUEST
	_is_driver_callback = true
	return Code.OK


func _end_driver_callback() -> void:
	_is_driver_callback = false
