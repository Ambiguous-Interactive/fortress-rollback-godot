class_name FortressReplayPlayer
extends RefCounted

# gdlint: disable=max-returns

## Plays a FortressReplay through game callbacks or ordered expert requests, without rollback or input.
## Start from the same initial game state the recording session started from.

const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Reader = preload("res://addons/fortress_rollback/core/snapshot_reader.gd")
const Writer = preload("res://addons/fortress_rollback/core/snapshot_writer.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")


class Checkpoint:
	extends RefCounted
	var frame: int
	var bytes: PackedByteArray
	var checksum: PackedByteArray


var _checkpoint_interval: int = 0
var _checkpoint_capacity: int = 0
var _checkpoints: Array[Checkpoint] = []
var _replay: Replay
var _game: RefCounted
var _max_snapshot_bytes: int = 0
var _frame: int = 0
var _checked_checksum_count: int = 0
var _terminal_validated: bool = false
var _validated_through_frame: int = -1
var _reason: int = Types.Code.OK
var _failure_frame: int = -1
var _failure_kind: int = -1
var _failure_comparison: String = ""
var _failure_expected_checksum: PackedByteArray = PackedByteArray()
var _failure_actual_checksum: PackedByteArray = PackedByteArray()
var _is_stepping: bool = false
var _batch: Types.Batch
var _batch_id: int = 0
var _request_id: int = 0
var _active: Types.Request
var _active_kind: int = -1
var _validation_only: bool = false
var _restoring: Checkpoint
var _writer: Writer
var _reader: Reader
var _inputs: Types.FrameInputs


## A positive max_snapshot_bytes saves each recorded-checksum frame and stops at the first mismatch.
## Zero plays inputs only. The game needs simulate_frame, plus save_state when validating.
## Optional checkpoints also require load_state; interval and capacity must both be positive.
## Capacity includes the initial state, ranges from 2 to 1024, and retains at most 16 MiB.
## Cached boundaries save state even without a recorded checksum; configure clears the cache.
## A supplied config refuses a recording that does not match the running game.
func configure(replay: Replay, game: RefCounted, max_snapshot_bytes: int = 0, checkpoint_interval: int = 0, checkpoint_capacity: int = 0, config: RefCounted = null) -> int:
	if _is_stepping or _batch != null:
		return Types.Code.BUSY
	if replay == null or game == null or not Driver.accepts_callback_arguments(game, "simulate_frame") or max_snapshot_bytes < 0 or max_snapshot_bytes > 16777216:
		return Types.Code.INVALID_CONFIGURATION
	if not replay.is_valid():
		return Types.Code.INVALID_CONFIGURATION
	if config != null and not replay.matches_config(config):
		return Types.Code.INCOMPATIBLE_RECORDING
	if max_snapshot_bytes > 0 and not Driver.accepts_callback_arguments(game, "save_state"):
		return Types.Code.INVALID_CONFIGURATION
	if checkpoint_interval < 0 or checkpoint_capacity < 0 or checkpoint_capacity > 1024:
		return Types.Code.INVALID_CONFIGURATION
	if (checkpoint_interval == 0) != (checkpoint_capacity == 0):
		return Types.Code.INVALID_CONFIGURATION
	if checkpoint_capacity > 0 and (max_snapshot_bytes == 0 or checkpoint_capacity < 2 or not Driver.accepts_callback_arguments(game, "load_state")):
		return Types.Code.INVALID_CONFIGURATION
	if checkpoint_capacity * max_snapshot_bytes > 16777216:
		return Types.Code.INVALID_CONFIGURATION
	_reset(replay, game, max_snapshot_bytes, checkpoint_interval, checkpoint_capacity)
	return Types.Code.OK


func _reset(replay: Replay, game: RefCounted, max_snapshot_bytes: int, checkpoint_interval: int, checkpoint_capacity: int) -> void:
	_restoring = null
	_checkpoint_interval = checkpoint_interval
	_checkpoint_capacity = checkpoint_capacity
	_checkpoints.clear()
	_replay = replay.owned_copy()
	_game = game
	_max_snapshot_bytes = max_snapshot_bytes
	_frame = 0
	_checked_checksum_count = 0
	_terminal_validated = false
	_validated_through_frame = -1
	_reason = Types.Code.OK
	_failure_frame = -1
	_failure_kind = -1
	_failure_comparison = ""
	_failure_expected_checksum.clear()
	_failure_actual_checksum.clear()


## Expert playback uses the same ordered requests as callback step(), without owning a game.
## A positive snapshot bound validates recorded checksums; zero plays inputs only.
## Callback navigation and step are unsupported in this mode. Use begin_restore_before for manual navigation.
## Optional checkpoints use the same interval, capacity and 16 MiB budget as callback playback.
## A supplied config refuses a recording that does not match the running game.
func configure_expert(replay: Replay, max_snapshot_bytes: int = 0, config: RefCounted = null, checkpoint_interval: int = 0, checkpoint_capacity: int = 0) -> int:
	if _is_stepping or _batch != null:
		return Types.Code.BUSY
	if replay == null or max_snapshot_bytes < 0 or max_snapshot_bytes > 16777216:
		return Types.Code.INVALID_CONFIGURATION
	if not replay.is_valid():
		return Types.Code.INVALID_CONFIGURATION
	if config != null and not replay.matches_config(config):
		return Types.Code.INCOMPATIBLE_RECORDING
	if checkpoint_interval < 0 or checkpoint_capacity < 0 or checkpoint_capacity > 1024:
		return Types.Code.INVALID_CONFIGURATION
	if (checkpoint_interval == 0) != (checkpoint_capacity == 0):
		return Types.Code.INVALID_CONFIGURATION
	if checkpoint_capacity > 0 and (max_snapshot_bytes == 0 or checkpoint_capacity < 2 or checkpoint_capacity * max_snapshot_bytes > 16777216):
		return Types.Code.INVALID_CONFIGURATION
	_reset(replay, null, max_snapshot_bytes, checkpoint_interval, checkpoint_capacity)
	return Types.Code.OK


## OK advances one frame; FRAME_EXHAUSTED means every input played. Failures latch at failure_frame().
func step() -> int:
	if _is_stepping or _batch != null:
		return Types.Code.BUSY
	if _replay == null:
		return Types.Code.NOT_CONFIGURED
	if _game == null:
		return Types.Code.UNSUPPORTED
	var advance: Types.Result = begin_advance()
	if advance.code != Types.Code.READY:
		return advance.code
	while true:
		var request: Types.Request = advance.batch.next_request()
		if request == null:
			return Types.Code.OK
		var batch_id: int = request.batch_id
		var request_id: int = request.request_id
		var checksum: PackedByteArray = PackedByteArray()
		var ok: bool = false
		_is_stepping = true
		if _active_kind == Types.Kind.SAVE:
			var saved: Variant = _game.save_state(_frame, _writer)
			if _reason == Types.Code.OK and saved is Driver.SaveResult:
				ok = saved.ok
				checksum = saved.checksum
		else:
			var simulated: Variant = _game.simulate_frame(_frame, _inputs)
			ok = simulated is bool and simulated
		_is_stepping = false
		var code: int = complete_request(batch_id, request_id, ok, checksum).code
		if code != Types.Code.OK:
			return code
	return Types.Code.OK


## Open one input frame. Consume and acknowledge SAVE, when needed, then ADVANCE in order.
## The exposed frame commits only after ADVANCE succeeds. A retained batch blocks reconfiguration.
func begin_advance() -> Types.Result:
	if _is_stepping or _batch != null:
		return Types.Result.new(Types.Code.BUSY)
	if _replay == null:
		return Types.Result.new(Types.Code.NOT_CONFIGURED)
	if _reason != Types.Code.OK:
		return Types.Result.new(_reason)
	if _frame >= _replay.frame_count():
		if _needs_terminal_validation():
			return _begin_batch(Types.Kind.SAVE, true)
		return Types.Result.new(Types.Code.FRAME_EXHAUSTED)
	var digest_code: int = _verify_input_digest()
	if digest_code != Types.Code.OK:
		return Types.Result.new(digest_code)
	return _begin_batch(Types.Kind.SAVE if _needs_save() else Types.Kind.ADVANCE, false)


## Validate the selected input digest without consuming input. READY supplies one ordered SAVE
## when a recorded checksum or checkpoint needs validation; otherwise OK completes without a batch.
## Callback and expert clients share checksum, bounded writer and failure-latching contracts.
func begin_validate_current_frame() -> Types.Result:
	if _is_stepping or _batch != null:
		return Types.Result.new(Types.Code.BUSY)
	if _replay == null:
		return Types.Result.new(Types.Code.NOT_CONFIGURED)
	if _reason != Types.Code.OK:
		return Types.Result.new(_reason)
	if _frame < _replay.frame_count():
		var digest_code: int = _verify_input_digest()
		if digest_code != Types.Code.OK:
			return Types.Result.new(digest_code)
	if _needs_save():
		return _begin_batch(Types.Kind.SAVE, true)
	_validated_through_frame = maxi(_validated_through_frame, _frame)
	return Types.Result.new(Types.Code.OK)


func _begin_batch(kind: int, validation_only: bool) -> Types.Result:
	if _batch_id == 9223372036854775807:
		return Types.Result.new(_fail(Types.Code.FRAME_EXHAUSTED))
	_batch_id += 1
	_request_id = 0
	_active_kind = kind
	_validation_only = validation_only
	_batch = Types.Batch.new(self, _batch_id)
	return Types.Result.new(Types.Code.READY, _batch)


func _next_request(batch_id: int) -> Types.Request:
	if _is_stepping or _batch == null or batch_id != _batch_id:
		return null
	if _active == null:
		_active = Types.Request.new()
		_active.kind = _active_kind
		_active.frame = _restoring.frame if _restoring != null else _frame
		_active.batch_id = _batch_id
		_active.request_id = _request_id
		if _active_kind == Types.Kind.SAVE:
			_writer = Writer.new(_max_snapshot_bytes)
			_active.writer = _writer
		elif _active_kind == Types.Kind.LOAD:
			_reader = Reader.new(_restoring.bytes, true)
			_active.reader = _reader
		else:
			_inputs = _replay.inputs(_frame)
			_active.inputs = _inputs
	return _active


## Invalid identities preserve the active request and its views. Failure expires views and stops playback.
## Public request metadata is descriptive; completion uses the authoritative request kind and frame.
func complete_request(batch_id: int, request_id: int, callback_ok: bool, checksum: PackedByteArray = PackedByteArray()) -> Types.Result:
	if _is_stepping:
		return Types.Result.new(Types.Code.BUSY)
	if _reason != Types.Code.OK:
		return Types.Result.new(_reason)
	if _batch == null or batch_id != _batch_id or request_id != _request_id or _active == null:
		return Types.Result.new(Types.Code.STALE_REQUEST)
	var code: int = Types.Code.CALLBACK_FAILED
	if callback_ok:
		code = Types.Code.OK
		if _active_kind == Types.Kind.SAVE:
			var checkpoint: Checkpoint = Checkpoint.new()
			code = _read_checkpoint(checkpoint, _writer, checksum, _restoring.frame if _restoring != null else _frame)
			if code == Types.Code.OK:
				if _restoring != null:
					code = _compare_checkpoint(_restoring, checkpoint)
				else:
					code = _accept_checkpoint(checkpoint)
		elif _active_kind == Types.Kind.LOAD and not _reader.is_complete():
			code = Types.Code.SNAPSHOT_FAILED
	_expire_request()
	if code != Types.Code.OK:
		return Types.Result.new(_fail(code, _active_kind))
	if _restoring != null:
		if _active_kind == Types.Kind.LOAD:
			_active_kind = Types.Kind.SAVE
			_request_id += 1
		else:
			_terminal_validated = false
			_frame = _restoring.frame
			_restoring = null
			_batch = null
	elif _validation_only:
		_batch = null
	elif _active_kind == Types.Kind.SAVE:
		_active_kind = Types.Kind.ADVANCE
		_request_id += 1
	else:
		_validated_through_frame = maxi(_validated_through_frame, _frame)
		_terminal_validated = false
		_frame += 1
		_batch = null
	return Types.Result.new(Types.Code.OK)


## Abandon any open batch and expire its views. Configure again to start a new playback lifetime.
## Termination during a game callback remains latched until that callback returns.
func terminate() -> void:
	_expire_request()
	if _reason == Types.Code.OK:
		_restoring = null
		_fail(Types.Code.TERMINATED)


func _expire_request() -> void:
	if _reader != null:
		_reader._expire()
	_reader = null
	if _writer != null:
		_writer._expire()
	if _inputs != null:
		_inputs._expire()
	_writer = null
	_inputs = null
	_active = null


func _fail(code: int, kind: int = -1) -> int:
	if _reason != Types.Code.OK:
		return _reason
	_reason = code
	_failure_frame = _restoring.frame if _restoring != null else _frame
	_failure_kind = kind
	_restoring = null
	_batch = null
	return code


func _save_checkpoint(checkpoint: Checkpoint, frame: int) -> int:
	var writer: Writer = Writer.new(_max_snapshot_bytes)
	_writer = writer
	var saved: Variant = _game.save_state(frame, writer)
	var code: int = _reason
	if code == Types.Code.OK:
		if not (saved is Driver.SaveResult) or not saved.ok:
			code = Types.Code.CALLBACK_FAILED
		else:
			code = _read_checkpoint(checkpoint, writer, saved.checksum, frame)
	writer._expire()
	_writer = null
	return code


func _read_checkpoint(checkpoint: Checkpoint, writer: Writer, checksum: PackedByteArray, frame: int) -> int:
	if writer.status() != Writer.Code.OK:
		return Types.Code.SNAPSHOT_FAILED
	if checksum.size() != Replay.CHECKSUM_BYTES:
		return Types.Code.DESYNC
	checkpoint.bytes = writer._written_copy()
	checkpoint.frame = frame
	checkpoint.checksum = checksum.duplicate()
	return Types.Code.OK


func _retain_checkpoint(checkpoint: Checkpoint) -> void:
	for retained: Checkpoint in _checkpoints:
		if retained.frame == checkpoint.frame:
			return
	# Preserve the initial state while evicting the oldest noninitial checkpoint.
	if _checkpoints.size() >= _checkpoint_capacity:
		_checkpoints.remove_at(1)
	_checkpoints.append(checkpoint)
	_checkpoints.sort_custom(func(first: Checkpoint, second: Checkpoint) -> bool: return first.frame < second.frame)


## Owned ascending frame numbers of retained, successfully validated checkpoints.
## Empty before the first cache save or when checkpoint caching is disabled. Evicted entries are absent.
## Failure stops restoration even while its diagnostic inventory remains available; configure clears it.
func checkpoint_frames() -> PackedInt64Array:
	var frames: PackedInt64Array = PackedInt64Array()
	for checkpoint: Checkpoint in _checkpoints:
		frames.append(checkpoint.frame)
	return frames


## Restore the nearest cached boundary at or before target, then call step to reach it.
## Only checkpoints validated by this player are eligible. Cache bytes are bounded by configure.
## A target ahead of the current state never moves backward. Failures stop playback.
func restore_before(target: int) -> int:
	if _is_stepping or _batch != null:
		return Types.Code.BUSY
	if _replay == null:
		return Types.Code.NOT_CONFIGURED
	if target < 0 or target > _replay.frame_count():
		return Types.Code.INVALID_FRAME
	if _game == null:
		return Types.Code.UNSUPPORTED
	if _reason != Types.Code.OK:
		return _reason
	var result: Types.Result = begin_restore_before(target)
	if result.code != Types.Code.READY:
		return result.code
	while true:
		var request: Types.Request = result.batch.next_request()
		if request == null:
			return Types.Code.OK
		var batch_id: int = request.batch_id
		var request_id: int = request.request_id
		var checksum: PackedByteArray = PackedByteArray()
		var ok: bool = false
		_is_stepping = true
		if _active_kind == Types.Kind.LOAD:
			var loaded: Variant = _game.load_state(request.frame, _reader)
			ok = loaded is bool and loaded
		else:
			var saved: Variant = _game.save_state(request.frame, _writer)
			if saved is Driver.SaveResult:
				ok = saved.ok
				checksum = saved.checksum
		_is_stepping = false
		var code: int = complete_request(batch_id, request_id, ok, checksum).code
		if code != Types.Code.OK:
			return code
	return Types.Code.OK


## Restore the nearest retained checkpoint at or before target through ordered LOAD then SAVE.
## Commit the selected frame only after exact state bytes and checksum match the cached boundary.
## OK without a batch leaves a forward target's current state unchanged; HISTORY_UNAVAILABLE means no eligible checkpoint.
func begin_restore_before(target: int) -> Types.Result:
	if _is_stepping or _batch != null:
		return Types.Result.new(Types.Code.BUSY)
	if _replay == null:
		return Types.Result.new(Types.Code.NOT_CONFIGURED)
	if target < 0 or target > _replay.frame_count():
		return Types.Result.new(Types.Code.INVALID_FRAME)
	if _reason != Types.Code.OK:
		return Types.Result.new(_reason)
	var selected: Checkpoint
	for checkpoint: Checkpoint in _checkpoints:
		if checkpoint.frame <= target:
			selected = checkpoint
	if selected == null:
		return Types.Result.new(Types.Code.HISTORY_UNAVAILABLE)
	if target >= _frame and selected.frame <= _frame:
		return Types.Result.new(Types.Code.OK)
	_restoring = selected
	return _begin_batch(Types.Kind.LOAD, false)


## Validate a paused state boundary and its input digest without consuming the input. Uses the same
## bounded save callback as step; failures latch the frame and evidence. Input-only and checksum-absent
## boundaries succeed without invoking save_state, except when checkpoint caching requires a save.
func validate_current_frame() -> int:
	if _is_stepping or _batch != null:
		return Types.Code.BUSY
	if _replay == null:
		return Types.Code.NOT_CONFIGURED
	if _game == null:
		return Types.Code.UNSUPPORTED
	if _reason != Types.Code.OK:
		return _reason
	_is_stepping = true
	var code: int = _validate_frame()
	_is_stepping = false
	if _reason != Types.Code.OK:
		return _reason
	if code != Types.Code.OK:
		return _fail(code, Types.Kind.SAVE)
	return code


func _needs_save() -> bool:
	return _max_snapshot_bytes > 0 and (not _replay.checksum(_frame).is_empty() or _is_cache_boundary())


func _is_cache_boundary() -> bool:
	return _checkpoint_interval > 0 and _frame < _replay.frame_count() and _frame % _checkpoint_interval == 0


## Every frame carries the digest of its own input row, so a corrupted row is refused at the
## frame that owns it. A recording without that digest cannot be verified and is refused.
func _verify_input_digest() -> int:
	var expected: PackedByteArray = _replay.input_digest(_frame)
	if expected.size() != Replay.DIGEST_BYTES:
		return _fail(Types.Code.DESYNC)
	var actual: PackedByteArray = _replay.computed_input_digest(_frame)
	if actual == expected:
		return Types.Code.OK
	_failure_comparison = "input_digest"
	_failure_expected_checksum = expected.duplicate()
	_failure_actual_checksum = actual.duplicate()
	return _fail(Types.Code.DESYNC)


func _validate_frame() -> int:
	if _frame < _replay.frame_count():
		var digest_code: int = _verify_input_digest()
		if digest_code != Types.Code.OK:
			return digest_code
	if _needs_save():
		var checkpoint: Checkpoint = Checkpoint.new()
		var code: int = _save_checkpoint(checkpoint, _frame)
		if code != Types.Code.OK:
			return code
		return _accept_checkpoint(checkpoint)
	_validated_through_frame = maxi(_validated_through_frame, _frame)
	return Types.Code.OK


func _compare_checkpoint(retained: Checkpoint, actual: Checkpoint) -> int:
	if actual.checksum != retained.checksum:
		return _checksum_mismatch(retained.checksum, actual.checksum, "checkpoint_checksum")
	if actual.bytes != retained.bytes:
		_failure_comparison = "checkpoint_bytes"
		return Types.Code.DESYNC
	return Types.Code.OK


func _accept_checkpoint(checkpoint: Checkpoint) -> int:
	var expected: PackedByteArray = _replay.checksum(_frame)
	if not expected.is_empty() and checkpoint.checksum != expected:
		return _checksum_mismatch(expected, checkpoint.checksum)
	for retained: Checkpoint in _checkpoints:
		if retained.frame == checkpoint.frame:
			var code: int = _compare_checkpoint(retained, checkpoint)
			if code != Types.Code.OK:
				return code
	if not expected.is_empty() and _frame > _validated_through_frame:
		_checked_checksum_count += 1
	if _is_cache_boundary():
		_retain_checkpoint(checkpoint)
	if _frame == _replay.frame_count() and not expected.is_empty():
		_terminal_validated = true
	_validated_through_frame = maxi(_validated_through_frame, _frame)
	return Types.Code.OK


## Distinct recorded state boundaries whose checksums matched during this playback lifetime.
## Restoring or rechecking a boundary never counts it twice; input-only playback counts none.
func checked_checksum_count() -> int:
	return _checked_checksum_count


## Whether the currently displayed final boundary matched its recorded checksum.
## False for historical/input-only playback, before final validation, after restoring earlier state,
## during an open request or callback, after failure or termination, and in a new playback lifetime.
func is_final_state_validated() -> bool:
	return _reason == Types.Code.OK and _batch == null and not _is_stepping and _terminal_validated and _replay != null and _frame == _replay.frame_count()


## Recorded frames whose confirmed input was no longer retained when the file was written.
## Their input was replaced with the neutral sample, so the recording is not a faithful copy.
func skipped_frames() -> int:
	return _replay.skipped_frames() if _replay != null else 0


## The next frame to simulate.
func current_frame() -> int:
	return _frame


func _needs_terminal_validation() -> bool:
	return _max_snapshot_bytes > 0 and not _replay.checksum(_replay.frame_count()).is_empty() and not _terminal_validated


## Healthy playback at its final boundary, with no open request or game callback.
## Navigation and revalidation suspend completion until their ordered work succeeds.
func is_complete() -> bool:
	return (
		_replay != null and _reason == Types.Code.OK and _batch == null and not _is_stepping
		and _frame >= _replay.frame_count() and not _needs_terminal_validation()
	)


func failure_frame() -> int:
	return _failure_frame


## The latched playback failure, or OK while this playback lifetime remains healthy.
func failure_code() -> int:
	return _reason


## The SAVE, LOAD or ADVANCE request that failed, including snapshot or comparison failures.
## -1 means no failed request: healthy playback, input digest rejection or explicit termination.
## Callback and expert playback share this first-cause value; successful configure clears it.
func failure_kind() -> int:
	return _failure_kind


## The first failed comparison: input_digest, state_checksum, checkpoint_checksum or checkpoint_bytes.
## Empty when no comparison failed, including callback errors, invalid checksum lengths and termination.
## Successful configure clears it; later rejected operations preserve it.
func failure_comparison() -> String:
	return _failure_comparison


## Owned 16-byte evidence for the first checksum or input-digest comparison failure; empty for
## other failures. Expected is the recording's checksum during playback or the cached checksum
## during restore. Successful configure clears both values; failed configure preserves them.
func failure_expected_checksum() -> PackedByteArray:
	return _failure_expected_checksum.duplicate()


## Owned computed checksum paired with failure_expected_checksum(); empty for other failures.
func failure_actual_checksum() -> PackedByteArray:
	return _failure_actual_checksum.duplicate()


func _checksum_mismatch(expected: PackedByteArray, actual: PackedByteArray, comparison: String = "state_checksum") -> int:
	_failure_comparison = comparison
	_failure_expected_checksum = expected.duplicate()
	_failure_actual_checksum = actual.duplicate()
	return Types.Code.DESYNC
