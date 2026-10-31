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
var _frozen_frames: PackedInt64Array = PackedInt64Array()
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
var _is_driver_notification: bool = false
var _has_confirmation_limit: bool = false
var _confirmation_limit: int = -1
var _exposed_confirmed_high_water: int = -1
var _trace: Trace = Trace.new()
var _statistics: Types.Statistics = Types.Statistics.new()
var _replay: Replay
var _replay_repair_frame: int = -1
var _capturing_replay_boundary: bool = false


## Creates owned validated configuration and fresh history; never replaces an open batch.
func configure(config: Config) -> int:
	if _is_driver_callback or _is_driver_notification or _batch != null:
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
	_frozen_frames.resize(config.player_count)
	_frozen_frames.fill(-1)
	_current = 0
	_time = -1
	_reason = Code.OK
	_failure_frame = -1
	_failure_kind = -1
	_originals.clear()
	_has_confirmation_limit = false
	_confirmation_limit = -1
	_exposed_confirmed_high_water = -1
	_statistics = Types.Statistics.new()
	_trace = Trace.new()
	_trace.configure(_config)
	_replay = null
	_replay_repair_frame = -1
	_capturing_replay_boundary = false
	if _config.replay_max_frames > 0:
		_replay = Replay.new()
		_replay._start(_config)
	return Code.OK


func poll(now_us: int) -> Types.Result:
	var code: int = _poll_code(now_us)
	if code == Code.OK:
		_time = now_us
	return Types.Result.new(code)


func _poll_code(now_us: int) -> int:
	var code: int = _mutation_code()
	if code != Code.OK:
		return code
	if now_us < 0 or now_us < _time:
		return Code.INVALID_TIME
	return Code.OK


## Checks local sample metadata and retained retries without changing input or receipt state.
## Queue capacity is checked only by submission.
func validate_local_input(player: int, sample_frame: int, bytes: PackedByteArray) -> int:
	var code: int = _mutation_code()
	if code != Code.OK:
		return code
	if player < 0 or player >= _queues.size() or player not in _config.local_players:
		return Code.INVALID_PLAYER
	if sample_frame != _current:
		return Code.INVALID_FRAME
	if bytes.size() != _config.input_width:
		return Code.INPUT_WIDTH
	if not _samples[player].is_empty() and _samples[player] != bytes:
		return Code.INPUT_ALREADY_SUBMITTED
	return Code.OK


## Identical current samples are idempotent while stalled; conflicts preserve input.
func submit_local_input(player: int, sample_frame: int, bytes: PackedByteArray) -> Types.Result:
	var code: int = validate_local_input(player, sample_frame, bytes)
	if code != Code.OK:
		var rejected: Types.Result = Types.Result.new(code)
		rejected.value = -1 if code == Code.INPUT_ALREADY_SUBMITTED else 0
		return rejected
	if not _samples[player].is_empty():
		var repeated: Types.Result = Types.Result.new(Code.OK)
		repeated.value = _received[player]
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
	if _frozen_frames[player] != -1:
		# A dropped slot ignores later inputs; the frozen value keeps every survivor aligned.
		return Types.Result.new(Code.OK)
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


## Check a remote donor's retained overlap and missing suffix without changing history.
## Frames must be at or above the global rollback floor and contain at most queue_capacity rows.
func validate_missing_backfill(player: int, start: int, inputs: Array[PackedByteArray]) -> int:
	var code: int = _mutation_code()
	if code != Code.OK:
		return code
	if player < 0 or player >= _queues.size() or player in _config.local_players:
		return Code.INVALID_PLAYER
	if _frozen_frames[player] != -1:
		return Code.UNSUPPORTED
	if start < _floor():
		return Code.INVALID_FRAME
	match _queues[player].validate_missing_backfill(start, inputs, _floor()):
		Queue.Code.OK:
			return Code.OK
		Queue.Code.FRAME_RANGE, Queue.Code.OUT_OF_ORDER:
			return Code.INVALID_FRAME
		Queue.Code.INPUT_WIDTH:
			return Code.INPUT_WIDTH
		Queue.Code.BEFORE_RETAINED, Queue.Code.NO_CONFIRMED_INPUT:
			return Code.HISTORY_UNAVAILABLE
		Queue.Code.CONFLICTING_INPUT:
			return Code.INPUT_ALREADY_SUBMITTED
	return Code.INPUT_FAILED


## Atomically install one validated donor chunk; retained identical retries are idempotent.
## New actual rows use the normal prediction correction path and advance the receipt frontier.
func install_missing_backfill(player: int, start: int, inputs: Array[PackedByteArray]) -> int:
	var code: int = validate_missing_backfill(player, start, inputs)
	if code != Code.OK:
		return code
	if _queues[player].install_missing_backfill(start, inputs, _floor()) != Queue.Code.OK:
		return Code.INPUT_FAILED
	if not inputs.is_empty():
		_received[player] = maxi(_received[player], start + inputs.size() - 1)
	return Code.OK


## Owned current submitted sample, available until its successful advance completes.
func scheduled_local_input(player: int) -> Types.InputResult:
	var result: Types.InputResult = Types.InputResult.new()
	result.code = _scheduled_local_input_code(player)
	if result.code == Code.OK:
		result.frame = _received[player]
		result.bytes = _samples[player].duplicate()
		result.status = Queue.Status.CONFIRMED
	return result


func _scheduled_local_input_code(player: int) -> int:
	if _config == null:
		return Code.NOT_CONFIGURED
	if player < 0 or player >= _queues.size() or player not in _config.local_players:
		return Code.INVALID_PLAYER
	return Code.MISSING_LOCAL_INPUT if _samples[player].is_empty() else Code.OK


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


## Freeze a remote slot at an agreed frame so the survivors keep playing.
## The slot repeats the value confirmed at that frame, stops holding back the confirmed
## frontier and reports a disconnected status. Confirmed history before the frame is unchanged.
func freeze_player(player: int, frame: int) -> int:
	var code: int = validate_player_freeze(player, frame)
	if code != Code.OK:
		return code
	if _frozen_frames[player] != -1:
		return Code.OK
	var result: int = _queues[player].freeze_at(frame)
	if result != Queue.Code.OK:
		return Code.INPUT_FAILED
	_frozen_frames[player] = frame
	if _replay != null:
		_replay._freeze_player(player, frame, _queues[player].simulated_input(frame + 1).bytes)
	return Code.OK


## The agreed freeze frame of a dropped slot, or -1 while the slot still plays.
func frozen_frame(player: int) -> int:
	if _config == null or player < 0 or player >= _frozen_frames.size():
		return -1
	return _frozen_frames[player]


## Freeze a dropped slot with an explicit certified value. The value replaces the
## retained row, so a survivor that already released the row still freezes on the
## same bytes as the other survivors.
func freeze_player_with_value(player: int, frame: int, bytes: PackedByteArray) -> int:
	var code: int = validate_player_freeze(player, frame)
	if code != Code.OK:
		return code
	if not bytes is PackedByteArray or bytes.size() != _config.input_width:
		return Code.INPUT_WIDTH
	if _frozen_frames[player] != -1:
		return Code.OK
	var result: int = _queues[player].freeze_with_value(frame, bytes)
	if result != Queue.Code.OK:
		return Code.INPUT_FAILED
	_frozen_frames[player] = frame
	if _replay != null:
		_replay._freeze_player(player, frame, _queues[player].simulated_input(frame + 1).bytes)
	return Code.OK


## Validate a freeze before changing any member of a departed endpoint's slot set.
## No cut may replace already exposed confirmed history; refusal leaves all queues intact.
func validate_player_freeze(player: int, frame: int) -> int:
	var code: int = _mutation_code()
	if code != Code.OK:
		return code
	if player < 0 or player >= _queues.size() or player in _config.local_players:
		return Code.INVALID_PLAYER
	if _frozen_frames[player] != -1:
		return Code.OK
	if frame < 0 or frame > Queue.FRAME_MAX or frame < confirmed_freeze_floor():
		return Code.INVALID_FRAME
	return Code.OK


## The earliest cut that preserves current and previously exposed confirmation.
func confirmed_freeze_floor() -> int:
	return maxi(_confirmed(), _exposed_confirmed_high_water)


## The global rollback floor: frames below it are no longer retained by any queue.
func rollback_floor() -> int:
	if _config == null:
		return 0
	return _floor()


## Owned actual bytes a local player scheduled for a retained frame, or empty when unavailable.
func retained_local_input(player: int, frame: int) -> PackedByteArray:
	if _config == null or player < 0 or player >= _queues.size() or player not in _config.local_players:
		return PackedByteArray()
	var retained: Queue.Result = _queues[player].retained_confirmed_input(frame)
	return retained.bytes.duplicate() if retained.code == Queue.Code.OK else PackedByteArray()


## Owned actual bytes one slot holds for a frame, or empty when the row was released.
## The departed slot's row is the value the survivors freeze, so a survivor that
## already released it needs the certified value from the barrier's backfill.
func retained_input(player: int, frame: int) -> PackedByteArray:
	if _config == null or player < 0 or player >= _queues.size():
		return PackedByteArray()
	var retained: Queue.Result = _queues[player].retained_confirmed_input(frame)
	return retained.bytes.duplicate() if retained.code == Queue.Code.OK else PackedByteArray()


## Exact retained contiguous actual frame interval for one slot; empty means unavailable.
func retained_input_range(player: int) -> PackedInt64Array:
	if _config == null or player < 0 or player >= _queues.size():
		return PackedInt64Array()
	return _queues[player].retained_frame_range()


## Per-slot actual scheduled receipt bounds for transport gossip; never prediction frames.
func received_frames() -> PackedInt64Array:
	return _received.duplicate()


## Owned finalized input row for a simulated frame, or null when unavailable or under correction.
## Read before physical queue tags wrap. This export does not extend rollback retention.
func confirmed_inputs(frame: int) -> Types.FrameInputs:
	if _config == null or _batch != null or _is_driver_callback or frame < 0 or frame >= _current or frame > _confirmed():
		return null
	var pending: int = status().pending_rollback_frame
	if pending >= 0 and frame >= pending:
		return null
	var bytes: Array[PackedByteArray] = []
	var statuses: PackedInt32Array = PackedInt32Array()
	for player: int in range(_queues.size()):
		var actual: Queue.Result = _queues[player].simulated_input(frame)
		if actual.code != Queue.Code.OK:
			return null
		bytes.append(actual.bytes)
		statuses.append(_input_status(player, frame, actual.status))
	_exposed_confirmed_high_water = maxi(_exposed_confirmed_high_water, frame)
	return Types.FrameInputs.new(bytes, statuses)


## Completed saved boundaries only. Hide snapshots affected by pending repairs and active callbacks.
## Sending may include the confirmed boundary; comparison requires strictly earlier frames.
func confirmed_checksums(include_boundary: bool = false) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if _config == null or _reason != Code.OK or _batch != null or _is_driver_callback or not _config.checksums_enabled:
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
			_exposed_confirmed_high_water = maxi(_exposed_confirmed_high_water, saved.frame - 1)
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


## Capture the finalized recording's final boundary through one bounded SAVE, without input or advancement.
## PREDICTION_STALL requires confirmation/recovery first. HISTORY_UNAVAILABLE means the recording cap
## precedes the live state; capture at the cap before advancing beyond it. Disabled checksums are unsupported.
## Completion promotes this exact prefix to FRRP v6; failure never publishes a terminal checksum.
func begin_capture_replay_boundary() -> Types.Result:
	var code: int = _mutation_code()
	if code != Code.OK:
		return Types.Result.new(code)
	if _replay == null or not _config.checksums_enabled:
		return Types.Result.new(Code.UNSUPPORTED)
	if _current > _config.replay_max_frames:
		return Types.Result.new(Code.HISTORY_UNAVAILABLE)
	var prefix: Replay = replay()
	if prefix.frame_count() != _current:
		return Types.Result.new(Code.PREDICTION_STALL)
	if not Replay.valid_shape(prefix.player_count(), prefix.input_width(), prefix.frame_count(), Replay.TERMINAL_VERSION):
		return Types.Result.new(Code.INVALID_CONFIGURATION)
	if prefix.skipped_frames() > 0:
		return Types.Result.new(Code.HISTORY_UNAVAILABLE)
	if _batch_id == 9223372036854775807:
		return _fatal(Code.FRAME_EXHAUSTED)
	_plan.assign([Vector2i(Kind.SAVE, _current)])
	_target = _current
	_outcome = Code.OK
	_capturing_replay_boundary = true
	_batch_id += 1
	_index = 0
	_batch = Types.Batch.new(self, _batch_id)
	return Types.Result.new(Code.READY, _batch)


func begin_advance() -> Types.Result:
	return _begin_advance(true)


## Correct already simulated remote-input history without consuming or requiring a local sample.
## Leaves current_frame and staged local inputs unchanged. Idle recovery succeeds without callbacks.
## Sync-test and spectator sessions do not accept this operation.
func begin_recovery() -> Types.Result:
	var code: int = _recovery_code()
	return _begin_advance(false) if code == Code.OK else Types.Result.new(code)


func _recovery_code() -> int:
	var code: int = _mutation_code()
	if code != Code.OK:
		return code
	if _config.sync_test or _config.spectator:
		return Code.UNSUPPORTED
	return Code.OK


## Driver preflight shares terminal limits before it retains the current input samples.
func _check_advance_limits() -> int:
	var code: int = _mutation_code()
	if code != Code.OK:
		return code
	if _current == Queue.FRAME_MAX or _batch_id == 9223372036854775807:
		return _fatal(Code.FRAME_EXHAUSTED).code
	return Code.OK


func _begin_advance(allow_advance: bool) -> Types.Result:
	var code: int = _check_advance_limits()
	if code != Code.OK:
		return Types.Result.new(code)
	if allow_advance:
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
	_capturing_replay_boundary = false
	_plan.clear()
	if rollback != -1:
		if _current - rollback > _config.max_prediction_frames or _history.inspect(rollback).code != History.Code.OK:
			return _fatal(Code.HISTORY_UNAVAILABLE)
		for player: int in range(_queues.size()):
			if _received[player] >= rollback and _queues[player].retained_confirmed_input(rollback).code != Queue.Code.OK:
				return _fatal(Code.HISTORY_UNAVAILABLE, rollback, Kind.LOAD)
		_plan.append(Vector2i(Kind.LOAD, rollback))
		# Prediction markers reset before callbacks, but the replay tail stays
		# provisional until the complete repair batch succeeds.
		_replay_repair_frame = rollback if _replay_repair_frame == -1 else mini(_replay_repair_frame, rollback)
		for queue: Queue in _queues:
			queue.reset_prediction()
		for frame: int in range(rollback, _current):
			if frame > rollback:
				_plan.append(Vector2i(Kind.SAVE, frame))
			_plan.append(Vector2i(Kind.ADVANCE, frame))
	var can_advance: bool = allow_advance and (_config.sync_test or _can_advance())
	var save_mesh_boundary: bool = allow_advance and _has_confirmation_limit and _config.max_prediction_frames > 0
	if not allow_advance and _plan.is_empty():
		_record_replay()
		return Types.Result.new(Code.OK)
	if not can_advance and _plan.is_empty() and not save_mesh_boundary:
		_count_stall()
		return Types.Result.new(Code.PREDICTION_STALL)
	if can_advance or save_mesh_boundary or not allow_advance:
		if (_config.sync_test and _config.check_distance > 0) or (not _config.sync_test and (_config.max_prediction_frames > 0 or _config.capture_confirmed_snapshots)):
			_plan.append(Vector2i(Kind.SAVE, _current))
	if can_advance:
		_plan.append(Vector2i(Kind.ADVANCE, _current))
	_target = _current + 1 if can_advance else _current
	_outcome = Code.OK if can_advance or not allow_advance else Code.PREDICTION_STALL
	_batch_id += 1
	_index = 0
	_batch = Types.Batch.new(self, _batch_id)
	return Types.Result.new(Code.READY, _batch)


func complete_request(batch_id: int, request_id: int, callback_ok: bool, checksum: PackedByteArray = PackedByteArray()) -> Types.Result:
	if _is_driver_callback or _is_driver_notification:
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
			var restored_trace: History.Inspection = _history.inspect(frame)
			_trace.load_frame(frame, restored_trace.bytes, restored_trace.checksum)
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
		var advanced: bool = _target > _current
		_current = _target
		_batch = null
		_replay_repair_frame = -1
		if advanced:
			for player: int in _config.local_players:
				_samples[player] = PackedByteArray()
		_record_replay()
		if _capturing_replay_boundary:
			_replay._terminal_checksum = _history.inspect(_current).checksum
			_replay._format_version = Replay.TERMINAL_VERSION
			_capturing_replay_boundary = false
		for queue: Queue in _queues:
			queue.discard_confirmed_frames(_floor())
		return Types.Result.new(_outcome)
	return Types.Result.new(Code.OK)


func status() -> Types.Status:
	var result: Types.Status = Types.Status.new()
	result.current_frame = _current
	result.confirmed_frame = _confirmed()
	_exposed_confirmed_high_water = maxi(_exposed_confirmed_high_water, result.confirmed_frame)
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
## A stalled advance counts one stall when completed; explicit recovery, rejected and aborted calls do not.
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


## Caller-owned copy of confirmed frames finalized by completed advances or recovery; null unless replay_max_frames > 0.
func replay() -> Replay:
	if _replay == null:
		return null
	var prefix: Replay = _replay.owned_prefix(_replay_prefix_frames())
	_exposed_confirmed_high_water = maxi(_exposed_confirmed_high_water, prefix.frame_count() - 1)
	return prefix


## Owned scalar progress without copying replay bytes or exposing confirmed history.
## Finalized frames equal the exportable prefix, including confirmation and correction fences.
## Available during callbacks and after termination; disabled/unconfigured recording returns zero fields.
func recording_status() -> Types.RecordingStatus:
	var result: Types.RecordingStatus = Types.RecordingStatus.new()
	if _replay == null:
		return result
	result.capacity_frames = _config.replay_max_frames
	result.finalized_frames = _replay_prefix_frames()
	result.pending_frames = mini(_current, result.capacity_frames) - result.finalized_frames
	result.omitted_frames = maxi(0, _current - result.capacity_frames)
	return result


func _replay_prefix_frames() -> int:
	var frames: int = mini(_current, _confirmed() + 1)
	if _replay_repair_frame >= 0:
		frames = mini(frames, _replay_repair_frame)
	for queue: Queue in _queues:
		var incorrect: int = queue.first_incorrect_frame()
		if incorrect >= 0:
			frames = mini(frames, incorrect)
	return clampi(frames, 0, _replay.frame_count())


## Stage simulated receipts before lockstep can discard them. Public export separately gates on
## mesh confirmation and pending repair; a later drop can rewrite this private provisional tail.
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
		var statuses: PackedByteArray = PackedByteArray()
		for player: int in range(_queues.size()):
			var input: Queue.Result = _queues[player].retained_simulated_input(frame)
			row.append_array(input.bytes if input.code == Queue.Code.OK else PackedByteArray())
			statuses.append(_input_status(player, frame, input.status))
			neutral.append_array(_config.neutral_input)
		# Defensive: a missing input keeps frame alignment with a neutral, checksum-free row, as upstream does.
		var skipped: bool = row.size() != neutral.size()
		_replay._append(neutral if skipped else row, PackedByteArray() if skipped else saved.get(frame, PackedByteArray()), skipped, statuses)


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
		for player: int in range(_queues.size()):
			var input: Queue.Result = _queues[player].input(step.y)
			if input.code != Queue.Code.OK:
				_fatal(Code.HISTORY_UNAVAILABLE, step.y, step.x)
				return null
			input_bytes.append(input.bytes)
			input_statuses.append(_input_status(player, step.y, input.status))
		_inputs = Types.FrameInputs.new(input_bytes, input_statuses)
		request.inputs = _inputs
	_active = request
	return request


## Specialized playback may supply finalized host statuses over the shared input-byte engine.
func _input_status(_player: int, _frame: int, queue_status: int) -> int:
	return queue_status


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
			# A frozen slot repeats its agreed value, so it never blocks a lockstep advance.
			if queue.retained_simulated_input(_current).code != Queue.Code.OK:
				return false
		return true
	var confirmed: int = _confirmed()
	var ahead: int = _current if confirmed == -1 else _current - confirmed
	return ahead < _config.max_prediction_frames


func _confirmed() -> int:
	return mini(_receipt_minimum(), _confirmation_limit) if _has_confirmation_limit else _receipt_minimum()


func _receipt_minimum() -> int:
	var confirmed: int = Queue.FRAME_MAX
	var open_slot: bool = false
	for index: int in range(_received.size()):
		if _frozen_frames[index] != -1:
			# A dropped slot no longer holds the confirmed frontier back.
			continue
		open_slot = true
		confirmed = mini(confirmed, _received[index])
	return confirmed if open_slot else _current


func _floor() -> int:
	return maxi(0, _current - _config.max_prediction_frames)


func _mutation_code() -> int:
	if _is_driver_callback or _is_driver_notification:
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
	if _is_driver_callback or _is_driver_notification:
		return Code.BUSY
	if _active == null or _batch == null:
		return Code.STALE_REQUEST
	_is_driver_callback = true
	return Code.OK


func _end_driver_callback() -> void:
	_is_driver_callback = false


func _has_driver_guard() -> bool:
	return _is_driver_callback or _is_driver_notification


## Presentation handlers share the session guard across every driver and expert facade.
func _begin_driver_notification() -> void:
	_is_driver_notification = true


func _end_driver_notification() -> void:
	_is_driver_notification = false
