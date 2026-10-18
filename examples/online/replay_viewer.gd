class_name FortressOnlineReplayViewer
extends RefCounted

const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const MAX_BYTES: int = 1048576
const MAX_FRAMES: int = 36000
const GAME_VERSION: String = "fortress-online-integer-v1"

var game: Simulation = Simulation.new()
var message: String = "Open a fortress-online.frrp recording."
var is_playing: bool = false
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
	game = Simulation.new()
	_player = Player.new()
	var code: int = _player.configure(_recording, game, Simulation.SNAPSHOT_BYTES)
	is_playing = false
	message = "Ready. Press Play; recorded checksums are validated." if code == Types.Code.OK else "Could not start playback (%d)." % code


func toggle_play() -> void:
	if _recording == null or _player.is_complete() or _player.failure_frame() >= 0:
		return
	is_playing = not is_playing
	message = "Playing; recorded checksums are validated." if is_playing else "Paused."


## One presentation tick advances at most one recorded frame; elapsed time never invents input.
func tick() -> void:
	if is_playing:
		step()


func step() -> void:
	if _recording == null or _player.failure_frame() >= 0:
		return
	var code: int = _player.step()
	if code not in [Types.Code.OK, Types.Code.FRAME_EXHAUSTED]:
		is_playing = false
		message = "Replay stopped at frame %d (code %d)." % [_player.failure_frame(), code]
	elif _player.is_complete():
		is_playing = false
		message = "Replay complete. All available recorded checksums matched."


func frame_count() -> int:
	return _recording.frame_count() if _recording != null else 0


func current_frame() -> int:
	return _player.current_frame()
