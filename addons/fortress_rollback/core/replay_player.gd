class_name FortressReplayPlayer
extends RefCounted

# gdlint: disable=max-returns

## Plays a FortressReplay through the same game callbacks as FortressDriver, without rollback or input.
## Start from the same initial game state the recording session started from.

const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Writer = preload("res://addons/fortress_rollback/core/snapshot_writer.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")

var _replay: Replay
var _game: RefCounted
var _max_snapshot_bytes: int = 0
var _frame: int = 0
var _reason: int = Types.Code.OK
var _failure_frame: int = -1
var _is_stepping: bool = false


## A positive max_snapshot_bytes saves each recorded-checksum frame and stops at the first mismatch.
## Zero plays inputs only. The game needs simulate_frame, plus save_state when validating.
func configure(replay: Replay, game: RefCounted, max_snapshot_bytes: int = 0) -> int:
	if _is_stepping:
		return Types.Code.BUSY
	if replay == null or game == null or not game.has_method("simulate_frame") or max_snapshot_bytes < 0 or max_snapshot_bytes > 16777216:
		return Types.Code.INVALID_CONFIGURATION
	if not Replay.valid_shape(replay.player_count(), replay.input_width(), replay.frame_count()):
		return Types.Code.INVALID_CONFIGURATION
	if max_snapshot_bytes > 0 and not game.has_method("save_state"):
		return Types.Code.INVALID_CONFIGURATION
	_replay = replay.owned_copy()
	_game = game
	_max_snapshot_bytes = max_snapshot_bytes
	_frame = 0
	_reason = Types.Code.OK
	_failure_frame = -1
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
	var expected: PackedByteArray = _replay.checksum(_frame)
	if _max_snapshot_bytes > 0 and not expected.is_empty():
		var writer: Writer = Writer.new(_max_snapshot_bytes)
		var saved: Variant = _game.save_state(_frame, writer)
		var snapshot_code: int = writer.status()
		writer._expire()
		if not (saved is Driver.SaveResult) or not saved.ok:
			return Types.Code.CALLBACK_FAILED
		if snapshot_code != Writer.Code.OK:
			return Types.Code.SNAPSHOT_FAILED
		if saved.checksum != expected:
			return Types.Code.DESYNC
	var inputs: Types.FrameInputs = _replay.inputs(_frame)
	var ok: Variant = _game.simulate_frame(_frame, inputs)
	inputs._expire()
	return Types.Code.OK if (ok is bool) and ok else Types.Code.CALLBACK_FAILED


## The next frame to simulate.
func current_frame() -> int:
	return _frame


func is_complete() -> bool:
	return _replay != null and _reason == Types.Code.OK and _frame >= _replay.frame_count()


func failure_frame() -> int:
	return _failure_frame
