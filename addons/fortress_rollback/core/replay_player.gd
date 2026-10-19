class_name FortressReplayPlayer
extends RefCounted

# gdlint: disable=max-returns

## Plays a FortressReplay through the same game callbacks as FortressDriver, without rollback or input.
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
var _validated_through_frame: int = -1
var _reason: int = Types.Code.OK
var _failure_frame: int = -1
var _failure_expected_checksum: PackedByteArray = PackedByteArray()
var _failure_actual_checksum: PackedByteArray = PackedByteArray()
var _is_stepping: bool = false


## A positive max_snapshot_bytes saves each recorded-checksum frame and stops at the first mismatch.
## Zero plays inputs only. The game needs simulate_frame, plus save_state when validating.
## Optional checkpoints also require load_state; interval and capacity must both be positive.
## Capacity includes the initial state, ranges from 2 to 1024, and retains at most 16 MiB.
## Cached boundaries save state even without a recorded checksum; configure clears the cache.
func configure(replay: Replay, game: RefCounted, max_snapshot_bytes: int = 0, checkpoint_interval: int = 0, checkpoint_capacity: int = 0) -> int:
	if _is_stepping:
		return Types.Code.BUSY
	if replay == null or game == null or not Driver.accepts_callback_arguments(game, "simulate_frame") or max_snapshot_bytes < 0 or max_snapshot_bytes > 16777216:
		return Types.Code.INVALID_CONFIGURATION
	if not Replay.valid_shape(replay.player_count(), replay.input_width(), replay.frame_count()):
		return Types.Code.INVALID_CONFIGURATION
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
	_checkpoint_interval = checkpoint_interval
	_checkpoint_capacity = checkpoint_capacity
	_checkpoints.clear()
	_replay = replay.owned_copy()
	_game = game
	_max_snapshot_bytes = max_snapshot_bytes
	_frame = 0
	_checked_checksum_count = 0
	_validated_through_frame = -1
	_reason = Types.Code.OK
	_failure_frame = -1
	_failure_expected_checksum.clear()
	_failure_actual_checksum.clear()
	return Types.Code.OK


## OK advanced one frame. FRAME_EXHAUSTED means every frame played. DESYNC and CALLBACK_FAILED stop
## playback at failure_frame(); SNAPSHOT_FAILED stops on invalid snapshot writes. Configure again to restart.
func step() -> int:
	if _is_stepping:
		return Types.Code.BUSY
	if _replay == null:
		return Types.Code.NOT_CONFIGURED
	if _reason != Types.Code.OK:
		return _reason
	if _frame >= _replay.frame_count():
		return Types.Code.FRAME_EXHAUSTED
	_is_stepping = true
	var code: int = _play_frame()
	_is_stepping = false
	if code != Types.Code.OK:
		_reason = code
		_failure_frame = _frame
		return code
	_frame += 1
	return Types.Code.OK


func _play_frame() -> int:
	var code: int = _validate_frame()
	if code != Types.Code.OK:
		return code
	var inputs: Types.FrameInputs = _replay.inputs(_frame)
	var ok: Variant = _game.simulate_frame(_frame, inputs)
	inputs._expire()
	return Types.Code.OK if (ok is bool) and ok else Types.Code.CALLBACK_FAILED


func _save_checkpoint(checkpoint: Checkpoint) -> int:
	var writer: Writer = Writer.new(_max_snapshot_bytes)
	var saved: Variant = _game.save_state(_frame, writer)
	var snapshot_code: int = writer.status()
	checkpoint.bytes = writer._written_copy()
	writer._expire()
	if not (saved is Driver.SaveResult) or not saved.ok:
		return Types.Code.CALLBACK_FAILED
	if snapshot_code != Writer.Code.OK:
		return Types.Code.SNAPSHOT_FAILED
	if saved.checksum.size() != Replay.CHECKSUM_BYTES:
		return Types.Code.DESYNC
	checkpoint.frame = _frame
	checkpoint.checksum = saved.checksum.duplicate()
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


## Restore the nearest cached boundary at or before target, then call step to reach it.
## Only checkpoints validated by this player are eligible. Cache bytes are bounded by configure.
## A target ahead of the current state never moves backward. Failures stop playback.
func restore_before(target: int) -> int:
	if _is_stepping:
		return Types.Code.BUSY
	if _replay == null:
		return Types.Code.NOT_CONFIGURED
	if target < 0 or target > _replay.frame_count():
		return Types.Code.INVALID_FRAME
	if _reason != Types.Code.OK:
		return _reason
	var selected: Checkpoint
	for checkpoint: Checkpoint in _checkpoints:
		if checkpoint.frame <= target:
			selected = checkpoint
	if selected == null:
		return Types.Code.HISTORY_UNAVAILABLE
	if target >= _frame and selected.frame <= _frame:
		return Types.Code.OK
	_is_stepping = true
	var reader: Reader = Reader.new(selected.bytes, true)
	var loaded: Variant = _game.load_state(selected.frame, reader)
	var complete: bool = reader.is_complete()
	reader._expire()
	var code: int = Types.Code.OK
	if not (loaded is bool) or not loaded:
		code = Types.Code.CALLBACK_FAILED
	elif not complete:
		code = Types.Code.SNAPSHOT_FAILED
	else:
		_frame = selected.frame
		var restored: Checkpoint = Checkpoint.new()
		code = _save_checkpoint(restored)
		if code == Types.Code.OK:
			if restored.checksum != selected.checksum:
				code = _checksum_mismatch(selected.checksum, restored.checksum)
			elif restored.bytes != selected.bytes:
				code = Types.Code.DESYNC
	_is_stepping = false
	if code != Types.Code.OK:
		_reason = code
		_failure_frame = selected.frame
	return code


## Validate a paused state boundary without consuming its input. Uses the same bounded save callback
## as step; failures latch the frame and checksum evidence. Input-only playback and checksum-absent
## boundaries succeed without invoking save_state, except when checkpoint caching requires a save.
func validate_current_frame() -> int:
	if _is_stepping:
		return Types.Code.BUSY
	if _replay == null:
		return Types.Code.NOT_CONFIGURED
	if _reason != Types.Code.OK:
		return _reason
	_is_stepping = true
	var code: int = _validate_frame()
	_is_stepping = false
	if code != Types.Code.OK:
		_reason = code
		_failure_frame = _frame
	return code


func _validate_frame() -> int:
	var expected: PackedByteArray = _replay.checksum(_frame)
	var cache: bool = _checkpoint_interval > 0 and _frame < _replay.frame_count() and _frame % _checkpoint_interval == 0
	if _max_snapshot_bytes > 0 and (not expected.is_empty() or cache):
		var checkpoint: Checkpoint = Checkpoint.new()
		var code: int = _save_checkpoint(checkpoint)
		if code != Types.Code.OK:
			return code
		if not expected.is_empty() and checkpoint.checksum != expected:
			return _checksum_mismatch(expected, checkpoint.checksum)
		if not expected.is_empty() and _frame > _validated_through_frame:
			_checked_checksum_count += 1
		if cache:
			_retain_checkpoint(checkpoint)
	_validated_through_frame = maxi(_validated_through_frame, _frame)
	return Types.Code.OK


## Distinct recorded state boundaries whose checksums matched during this playback lifetime.
## Restoring or rechecking a boundary never counts it twice; input-only playback counts none.
func checked_checksum_count() -> int:
	return _checked_checksum_count


## The next frame to simulate.
func current_frame() -> int:
	return _frame


func is_complete() -> bool:
	return _replay != null and _reason == Types.Code.OK and _frame >= _replay.frame_count()


func failure_frame() -> int:
	return _failure_frame


## Owned 16-byte evidence for the first checksum comparison failure; empty for other failures.
## Expected is the recording's checksum during playback or the cached checksum during restore.
## Successful configure clears both values; failed configure preserves them.
func failure_expected_checksum() -> PackedByteArray:
	return _failure_expected_checksum.duplicate()


## Owned computed checksum paired with failure_expected_checksum(); empty for other failures.
func failure_actual_checksum() -> PackedByteArray:
	return _failure_actual_checksum.duplicate()


func _checksum_mismatch(expected: PackedByteArray, actual: PackedByteArray) -> int:
	_failure_expected_checksum = expected.duplicate()
	_failure_actual_checksum = actual.duplicate()
	return Types.Code.DESYNC
