class_name FortressOnlineReplayViewer
extends RefCounted

const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const MAX_FRAMES: int = 36000
# Include every v5 checksum and the largest supported metadata header.
const MAX_BYTES: int = Replay.FIXED_BYTES + 1 + Replay.TEXT_FIELDS * (1 + Replay.MAX_TEXT_BYTES) + MAX_FRAMES * (5 + Replay.CHECKSUM_BYTES + Replay.DIGEST_BYTES)
const FILE_SIZE_MESSAGE: String = "Replay exceeds the viewer's file-size limit."
const SEEK_FRAMES_PER_TICK: int = 120
const COMPLETE_MESSAGE: String = "Replay complete. All available recorded checksums matched."
const GAME_VERSION: String = "fortress-online-integer-v1"

var game: Simulation = Simulation.new()
var message: String = "Open a fortress-online.frrp recording."
var is_playing: bool = false
var _speed_quarters: int = 4
var _playback_quarters: int = 0
var _seek_target: int = -1
var _recorded_checksum_count: int = 0
var _recording: Replay
var _player: Player = Player.new()


## Failed imports leave the current recording and playback state intact.
func open_bytes(bytes: PackedByteArray) -> bool:
	var recording: Replay = Replay.new()
	var code: int = recording.decode(bytes, MAX_BYTES)
	if code != Replay.DecodeCode.OK:
		message = _open_failure_message(code)
		return false
	if not _compatible(recording):
		message = "This viewer needs a complete online integer game recording (up to ten minutes)."
		return false
	_recording = recording
	_recorded_checksum_count = 0
	for frame: int in recording.frame_count():
		if not recording.checksum(frame).is_empty():
			_recorded_checksum_count += 1
	restart()
	return true


## The reason a file was refused, so an old recording names the rule that rejects it.
func _open_failure_message(code: int) -> String:
	match code:
		Replay.DecodeCode.UNSUPPORTED_VERSION:
			return "Could not open replay: this file uses another format version. A recording from an older release cannot be replayed; record the match again."
		Replay.DecodeCode.TOO_LARGE:
			return "Could not open replay: this file is larger than the viewer accepts."
		_:
			return "Could not open replay: this file is malformed or incomplete."


func _compatible(recording: Replay) -> bool:
	if recording.player_count() != 2 or recording.input_width() != 1 or recording.frame_count() < 1 or recording.frame_count() > MAX_FRAMES:
		return false
	if recording.game_version() != GAME_VERSION or recording.addon_version() != Replay.ADDON_VERSION or recording.upstream_revision() != Replay.UPSTREAM_REVISION:
		return false
	if recording.game_seed() != "1701" or recording.neutral_input() != PackedByteArray([0]) or recording.skipped_frames() != 0:
		return false
	for frame: int in range(recording.frame_count()):
		var inputs: Types.FrameInputs = recording.inputs(frame)
		for slot: int in 2:
			if inputs.read(slot).bytes[0] > 15:
				return false
	return true


func restart() -> void:
	if _recording == null:
		return
	_seek_target = -1
	_playback_quarters = 0
	game = Simulation.new()
	_player = Player.new()
	var code: int = _player.configure(_recording, game, Simulation.SNAPSHOT_BYTES, 300, 121)
	is_playing = false
	message = "Ready. Press Play; recorded checksums are validated." if code == Types.Code.OK else "Could not start playback (%d)." % code
	if code == Types.Code.OK and _recorded_checksum_count == 0:
		message = "Ready. Press Play; this recording has no checksums."


func toggle_play() -> void:
	if is_seeking() or not can_step():
		return
	_playback_quarters = 0
	is_playing = not is_playing
	if not is_playing:
		_finish_seek()
		return
	message = "Playing; recorded checksums are validated."
	if _recorded_checksum_count == 0:
		message = "Playing inputs; this recording has no checksums."


## Quarter-speed units: 1, 2, 4, 8, 16 select ¼×, ½×, 1×, 2×, 4×.
## Changing speed starts a fresh cadence; invalid values preserve the current cadence.
func set_playback_speed(quarters: int) -> bool:
	if quarters not in [1, 2, 4, 8, 16]:
		return false
	if quarters != _speed_quarters:
		_speed_quarters = quarters
		_playback_quarters = 0
	return true


func playback_speed_quarters() -> int:
	return _speed_quarters


## Playback advances at most four recorded frames per tick; seeking uses its own bounded batch.
func tick() -> void:
	if is_seeking():
		for _frame: int in SEEK_FRAMES_PER_TICK:
			if not is_seeking():
				break
			_advance()
			if _player.failure_frame() >= 0:
				_seek_target = -1
			elif current_frame() == _seek_target:
				_finish_seek()
	elif is_playing:
		_playback_quarters += _speed_quarters
		while _playback_quarters >= 4 and is_playing:
			_playback_quarters -= 4
			_advance()


## Pause after one input and validate the selected state boundary without consuming its input.
func step() -> void:
	if is_seeking() or not can_step():
		return
	_playback_quarters = 0
	_advance()
	_finish_seek()


## Inspect the preceding state through validated checkpoint navigation, finishing paused.
## Long restores use tick's seek budget and can be canceled. A failed prefix is replayed again.
func step_back() -> bool:
	if is_seeking() or current_frame() == 0:
		return false
	return seek(current_frame() - 1)


func _advance() -> void:
	if not can_step():
		return
	var code: int = _player.step()
	if code not in [Types.Code.OK, Types.Code.FRAME_EXHAUSTED]:
		is_playing = false
		message = _failure_message(_player.failure_frame(), code, _player.failure_expected_checksum(), _player.failure_actual_checksum())
	elif _player.is_complete():
		is_playing = false
		message = _complete_message()


func frame_count() -> int:
	return _recording.frame_count() if _recording != null else 0


func recorded_checksum_count() -> int:
	return _recorded_checksum_count


func checked_checksum_count() -> int:
	return _player.checked_checksum_count()


func current_frame() -> int:
	return _player.current_frame()


## Whether another recorded frame can advance, including while paused.
func can_step() -> bool:
	return _recording != null and not _player.is_complete() and _player.failure_frame() < 0


## Navigate from a previously validated checkpoint, replaying the remaining inputs and checksums.
## Checkpoints cover five-second boundaries within this recording. Navigation always finishes paused.
func seek(frame: int) -> bool:
	if _recording == null or frame < 0 or frame > frame_count():
		return false
	_playback_quarters = 0
	if _player.failure_frame() >= 0:
		restart()
	var code: int = _player.restore_before(frame)
	if code == Types.Code.HISTORY_UNAVAILABLE and frame < current_frame():
		restart()
	elif code not in [Types.Code.OK, Types.Code.HISTORY_UNAVAILABLE]:
		is_playing = false
		_seek_target = -1
		message = _failure_message(_player.failure_frame(), code, _player.failure_expected_checksum(), _player.failure_actual_checksum())
		return false
	is_playing = false
	_seek_target = frame if frame != current_frame() else -1
	if is_seeking():
		message = "Seeking to frame %d; checksums are validated." % frame
		if _recorded_checksum_count == 0:
			message = "Seeking to frame %d; this recording has no checksums." % frame
	else:
		_finish_seek()
	return true


func is_seeking() -> bool:
	return _seek_target >= 0


func cancel_seek() -> void:
	if is_seeking():
		_finish_seek()


func _finish_seek() -> void:
	_seek_target = -1
	is_playing = false
	var code: int = _player.validate_current_frame()
	if code != Types.Code.OK:
		message = _failure_message(_player.failure_frame(), code, _player.failure_expected_checksum(), _player.failure_actual_checksum())
	else:
		message = _complete_message() if _player.is_complete() else "Paused."


func _complete_message() -> String:
	if _recorded_checksum_count == 0:
		return "Replay complete. This recording has no checksums; playback could not be verified."
	return COMPLETE_MESSAGE


func _failure_message(frame: int, code: int, expected: PackedByteArray, actual: PackedByteArray) -> String:
	var text: String = "Replay stopped at frame %d (code %d)." % [frame, code]
	if not expected.is_empty():
		text += "\nExpected: %s\nActual: %s" % [expected.hex_encode(), actual.hex_encode()]
	return text
