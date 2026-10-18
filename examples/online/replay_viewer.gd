class_name FortressOnlineReplayViewer
extends RefCounted

const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const MAX_BYTES: int = 1048576
const MAX_FRAMES: int = 36000
const SEEK_FRAMES_PER_TICK: int = 120
const COMPLETE_MESSAGE: String = "Replay complete. All available recorded checksums matched."
const GAME_VERSION: String = "fortress-online-integer-v1"

var game: Simulation = Simulation.new()
var message: String = "Open a fortress-online.frrp recording."
var is_playing: bool = false
var _seek_target: int = -1
var _seek_failed: bool = false
var _recording: Replay
var _player: Player = Player.new()


## Failed imports leave the current recording and playback state intact.
func open_bytes(bytes: PackedByteArray) -> bool:
	var recording: Replay = Replay.new()
	var code: int = recording.decode(bytes, MAX_BYTES)
	if code != Replay.DecodeCode.OK:
		message = "Could not open replay (file code %d)." % code
		return false
	if not _compatible(recording):
		message = "This viewer needs a complete online integer game recording (up to ten minutes)."
		return false
	_recording = recording
	restart()
	return true


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
	_seek_failed = false
	game = Simulation.new()
	_player = Player.new()
	var code: int = _player.configure(_recording, game, Simulation.SNAPSHOT_BYTES, 300, 121)
	is_playing = false
	message = "Ready. Press Play; recorded checksums are validated." if code == Types.Code.OK else "Could not start playback (%d)." % code


func toggle_play() -> void:
	if is_seeking() or not can_step():
		return
	is_playing = not is_playing
	message = "Playing; recorded checksums are validated." if is_playing else "Paused."


## Playback advances one recorded frame per tick; seeking uses a bounded batch of recorded frames.
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
		step()


func step() -> void:
	if is_seeking():
		return
	_advance()


func _advance() -> void:
	if not can_step():
		return
	var code: int = _player.step()
	if code not in [Types.Code.OK, Types.Code.FRAME_EXHAUSTED]:
		is_playing = false
		message = "Replay stopped at frame %d (code %d)." % [_player.failure_frame(), code]
	elif _player.is_complete():
		is_playing = false
		message = COMPLETE_MESSAGE


func frame_count() -> int:
	return _recording.frame_count() if _recording != null else 0


func current_frame() -> int:
	return _player.current_frame()


## Whether another recorded frame can advance, including while paused.
func can_step() -> bool:
	return _recording != null and not _seek_failed and not _player.is_complete() and _player.failure_frame() < 0


## Navigate from a previously validated checkpoint, replaying the remaining inputs and checksums.
## Checkpoints cover five-second boundaries within this recording. Navigation always finishes paused.
func seek(frame: int) -> bool:
	if _recording == null or frame < 0 or frame > frame_count():
		return false
	if _seek_failed or _player.failure_frame() >= 0:
		restart()
	var code: int = _player.restore_before(frame)
	if code == Types.Code.HISTORY_UNAVAILABLE and frame < current_frame():
		restart()
	elif code not in [Types.Code.OK, Types.Code.HISTORY_UNAVAILABLE]:
		is_playing = false
		_seek_target = -1
		message = "Replay stopped at frame %d (code %d)." % [_player.failure_frame(), code]
		return false
	is_playing = false
	_seek_target = frame if frame != current_frame() else -1
	if is_seeking():
		message = "Seeking to frame %d; checksums are validated." % frame
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
	var expected: PackedByteArray = _recording.checksum(current_frame())
	if not expected.is_empty() and Simulation.checksum(game.canonical_bytes()) != expected:
		_seek_failed = true
		message = "Replay stopped at frame %d (code %d)." % [current_frame(), Types.Code.DESYNC]
	else:
		message = COMPLETE_MESSAGE if _player.is_complete() else "Paused."
