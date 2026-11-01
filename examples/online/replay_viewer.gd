class_name FortressOnlineReplayViewer
extends RefCounted

const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const IntegrationGame = preload("res://examples/integration/game.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const MAX_FRAMES: int = 36000
# Include every row and terminal checksum and the largest supported metadata header.
const MAX_BYTES: int = (
	Replay.CHECKSUM_BYTES + Replay.FIXED_BYTES + 1 + Replay.TEXT_FIELDS * (1 + Replay.MAX_TEXT_BYTES) + MAX_FRAMES * (5 + Replay.CHECKSUM_BYTES + Replay.DIGEST_BYTES)
)
const FILE_SIZE_MESSAGE: String = "Replay exceeds the viewer's file-size limit."
const SEEK_FRAMES_PER_TICK: int = 120
const COMPLETE_MESSAGE: String = "Replay complete. All available recorded checksums matched. The final state has no recorded checksum."
const MAX_FAILURE_REPORT_BYTES: int = 16384
const GAME_VERSION: String = "fortress-online-integer-v1"

# Both supported games provide the same state callbacks and canonical byte export.
var game: RefCounted = Simulation.new()
var message: String = "Open an online or spectator .frrp recording."
var is_playing: bool = false
var _speed_quarters: int = 4
var _playback_quarters: int = 0
var _seek_target: int = -1
var _recorded_checksums: PackedInt64Array = PackedInt64Array()
var _input_changes: PackedInt64Array = PackedInt64Array()
var _recording_sha256: String = ""
var _recording_bytes: int = 0
var _recording: Replay
var _player: Player = Player.new()


## Failed or busy imports leave the current recording and playback state intact.
## Controls cannot change playback while a game callback or manual request owns the player.
func open_bytes(bytes: PackedByteArray) -> bool:
	if _is_busy():
		return false
	var recording: Replay = Replay.new()
	var code: int = recording.decode(bytes, MAX_BYTES)
	if code != Replay.DecodeCode.OK:
		message = _open_failure_message(code)
		return false
	var changes: Array[int] = []
	if not _compatible(recording, changes):
		message = "This viewer needs an identified online or spectator game recording (up to ten minutes)."
		return false
	var hash: HashingContext = HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	_recording_sha256 = hash.finish().hex_encode()
	_recording_bytes = bytes.size()
	_recording = recording
	_input_changes = PackedInt64Array(changes)
	_recorded_checksums.clear()
	for frame: int in range(recording.frame_count() + 1):
		if not recording.checksum(frame).is_empty():
			_recorded_checksums.append(frame)
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


func _compatible(recording: Replay, changes: Array[int]) -> bool:
	if recording.player_count() != 2 or recording.input_width() != 1 or recording.frame_count() > MAX_FRAMES:
		return false
	if recording.frame_count() == 0 and recording.checksum(0).is_empty():
		return false
	if recording.game_version() not in [GAME_VERSION, IntegrationGame.REPLAY_VERSION] or recording.addon_version() != Replay.ADDON_VERSION:
		return false
	if recording.upstream_revision() not in [Replay.UPSTREAM_REVISION, "fortress-rollback f13cd5c0f2815926785a395947e18da0dbea0dd8"]:
		return false
	var is_integration: bool = recording.game_version() == IntegrationGame.REPLAY_VERSION
	var seed: String = IntegrationGame.REPLAY_SEED if is_integration else "1701"
	if recording.game_seed() != seed or recording.neutral_input() != PackedByteArray([0]) or recording.skipped_frames() != 0:
		return false
	var previous: Types.FrameInputs
	for frame: int in range(recording.frame_count()):
		var inputs: Types.FrameInputs = recording.inputs(frame)
		var changed: bool = frame == 0
		for slot: int in 2:
			var sample: Types.InputResult = inputs.read(slot)
			if sample.bytes[0] > (7 if is_integration else 15):
				return false
			if previous != null:
				var prior: Types.InputResult = previous.read(slot)
				changed = changed or sample.bytes != prior.bytes or sample.status != prior.status
		if changed:
			changes.append(frame)
		previous = inputs
	return true


## The recording explicitly identifies the local movement-and-fire game; untagged files are refused.
func is_integration_game() -> bool:
	return _recording != null and _recording.game_version() == IntegrationGame.REPLAY_VERSION


## Restart from the initial state and retire the previous player; active game work leaves playback unchanged.
func restart() -> void:
	if _is_busy() or _recording == null:
		return
	_seek_target = -1
	_playback_quarters = 0
	_player.terminate()
	game = IntegrationGame.new() if is_integration_game() else Simulation.new()
	_player = Player.new()
	var snapshot_bytes: int = IntegrationGame.SNAPSHOT_BYTES if is_integration_game() else Simulation.SNAPSHOT_BYTES
	var code: int = _player.configure(_recording, game, snapshot_bytes, 300, 121)
	is_playing = false
	message = "Ready. Press Play; recorded checksums are validated." if code == Types.Code.OK else "Could not start playback (%d)." % code
	if code == Types.Code.OK and _recorded_checksums.is_empty():
		message = "Ready. Press Play; this recording has no checksums."


func toggle_play() -> void:
	if _is_busy() or is_seeking() or not can_step():
		return
	_playback_quarters = 0
	is_playing = not is_playing
	if not is_playing:
		_finish_seek()
		return
	message = "Playing; recorded checksums are validated."
	if _recorded_checksums.is_empty():
		message = "Playing inputs; this recording has no checksums."


## Quarter-speed units: 1, 2, 4, 8, 16 select ¼×, ½×, 1×, 2×, 4×.
## Changing speed starts a fresh cadence; invalid values preserve the current cadence.
func set_playback_speed(quarters: int) -> bool:
	if _is_busy() or quarters not in [1, 2, 4, 8, 16]:
		return false
	if quarters != _speed_quarters:
		_speed_quarters = quarters
		_playback_quarters = 0
	return true


func playback_speed_quarters() -> int:
	return _speed_quarters


## Playback advances at most four recorded frames per tick; seeking uses its own bounded batch.
func tick() -> void:
	if _is_busy():
		return
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
	if _is_busy() or is_seeking() or not can_step():
		return
	_playback_quarters = 0
	_advance()
	_finish_seek()


## Inspect the preceding state through validated checkpoint navigation, finishing paused.
## Long restores use tick's seek budget and can be canceled. A failed prefix is replayed again.
func step_back() -> bool:
	if _is_busy() or is_seeking() or current_frame() == 0:
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
	return _recorded_checksums.size()


func checked_checksum_count() -> int:
	return _player.checked_checksum_count()


## Recorded state coverage at the displayed boundary, independently of lifetime checksum totals.
## Input integrity and cache-only comparisons are separate from recorded state checksums.
func current_state_coverage_message() -> String:
	if _recording == null:
		return "No recording loaded."
	var prefix: String = "State at frame %d: " % current_frame()
	if has_failure():
		return prefix + "playback failed."
	if _player.is_current_state_validated():
		return prefix + "recorded checksum matched."
	if _recording.checksum(current_frame()).is_empty():
		return prefix + "no recorded checksum."
	return prefix + "recorded checksum not checked."


func current_frame() -> int:
	return _player.current_frame()


## The selected frame's recorded controls and finalized statuses, before applying its input.
## Verify its stored input digest before presenting values; inspection does not advance playback.
func input_summary() -> String:
	if _recording == null:
		return "No recording loaded."
	var frame: int = current_frame()
	if frame >= frame_count():
		return "No recorded input at final frame %d." % frame
	if _recording.computed_input_digest(frame) != _recording.input_digest(frame):
		return "Recorded input at frame %d is unavailable: input digest mismatch." % frame
	var inputs: Types.FrameInputs = _recording.inputs(frame)
	var players: PackedStringArray = PackedStringArray()
	for slot: int in inputs.player_count():
		var sample: Types.InputResult = inputs.read(slot)
		var directions: PackedStringArray = PackedStringArray()
		var names: PackedStringArray = PackedStringArray(["Left", "Right", "Fire"] if is_integration_game() else ["Left", "Right", "Up", "Down"])
		for bit: int in names.size():
			if sample.bytes[0] & (1 << bit):
				directions.append(names[bit])
		var controls: String = "Neutral" if directions.is_empty() else "+".join(directions)
		var status: String = "disconnected" if sample.status == Queue.Status.DISCONNECTED else "confirmed"
		players.append("P%d %s (%s)" % [slot + 1, controls, status])
	return "Next input at frame %d: %s." % [frame, " | ".join(players)]


## Whether another recorded frame can advance, including while paused.
func can_step() -> bool:
	return _recording != null and not _player.is_complete() and _player.failure_frame() < 0


## Navigate from a previously validated checkpoint, replaying the remaining inputs and checksums.
## Checkpoints cover five-second boundaries within this recording. Navigation always finishes paused.
func seek(frame: int) -> bool:
	if _is_busy() or _recording == null or frame < 0 or frame > frame_count():
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
		if _recorded_checksums.is_empty():
			message = "Seeking to frame %d; this recording has no checksums." % frame
	else:
		_finish_seek()
	return true


## The nearest retained checkpoint strictly before or after the displayed boundary, or -1.
## A failed recording must restart before its checkpoints can be used again.
func checkpoint_target(forward: bool) -> int:
	if is_seeking() or _player.failure_frame() >= 0:
		return -1
	var target: int = -1
	for frame: int in _player.checkpoint_frames():
		if forward and frame > current_frame():
			return frame
		if not forward and frame < current_frame():
			target = frame
	return target


## Nearest earlier/later input change, including finalized-status changes; frame zero starts the first input.
## The index is built during bounded file import. Lookup is logarithmic and does not claim input verification.
## The final state has no input. Active seeks and failures expose no input-change destination.
func input_change_target(forward: bool) -> int:
	if is_seeking() or has_failure() or _input_changes.is_empty():
		return -1
	var index: int = _input_changes.bsearch(current_frame(), not forward)
	if not forward:
		index -= 1
	return _input_changes[index] if index >= 0 and index < _input_changes.size() else -1


## Inspect the nearest input change through normal verified navigation, finishing paused.
## A first visit still checks the entire preceding input history within tick's seek budget.
func seek_input_change(forward: bool) -> bool:
	var target: int = input_change_target(forward)
	return target >= 0 and seek(target)


## Nearest earlier/later recorded state checksum, including a recorded final boundary, or -1.
## Unlike cached checkpoints, destinations are available before their first verified visit.
## Active seeks and failed playback expose no destination; discovery alone claims no validation.
func recorded_checksum_target(forward: bool) -> int:
	if is_seeking() or has_failure() or _recorded_checksums.is_empty():
		return -1
	var index: int = _recorded_checksums.bsearch(current_frame(), not forward)
	if not forward:
		index -= 1
	return _recorded_checksums[index] if index >= 0 and index < _recorded_checksums.size() else -1


## Reach a recorded checksum through ordinary bounded navigation and finish paused after validation.
## Corrupt input or state in the required prefix stops navigation at its owning boundary.
func seek_recorded_checksum(forward: bool) -> bool:
	var target: int = recorded_checksum_target(forward)
	return target >= 0 and seek(target)


func seek_checkpoint(forward: bool) -> bool:
	var target: int = checkpoint_target(forward)
	return target >= 0 and seek(target)


func is_seeking() -> bool:
	return _seek_target >= 0


func cancel_seek() -> void:
	if not _is_busy() and is_seeking():
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
	if _recorded_checksums.is_empty():
		return "Replay complete. This recording has no checksums; playback could not be verified."
	if _player.is_final_state_validated():
		return "Replay complete. All recorded checksums matched, including the final state."
	return COMPLETE_MESSAGE


func _failure_message(frame: int, code: int, expected: PackedByteArray, actual: PackedByteArray) -> String:
	var text: String = "Replay stopped at frame %d (code %d)." % [frame, code]
	if code in [Types.Code.CALLBACK_FAILED, Types.Code.SNAPSHOT_FAILED]:
		var operations: Dictionary = {Types.Kind.SAVE: "saving state", Types.Kind.LOAD: "loading state", Types.Kind.ADVANCE: "simulating input"}
		text += " Failed while %s." % operations.get(_player.failure_kind(), "processing game state")
	var comparison: String = _player.failure_comparison()
	if not comparison.is_empty():
		var labels: Dictionary = {
			"input_digest": "Recorded input digest mismatch.",
			"input_digest_missing": "Recorded input digest is missing or incomplete.",
			"state_checksum": "Recorded state checksum mismatch.",
			"checkpoint_checksum": "Restored checkpoint checksum mismatch.",
			"checkpoint_bytes": "Restored checkpoint bytes mismatch.",
		}
		text += " " + labels[comparison]
	if not expected.is_empty():
		text += "\nExpected: %s\nActual: %s" % [expected.hex_encode(), actual.hex_encode()]
	return text


## Owned JSON evidence for a stopped replay, or empty while playback is healthy.
## The observed game state is diagnostic data, not a successfully validated boundary.
## Keep the identified .frrp file with this report; the report does not contain its input history.
func failure_report_bytes() -> PackedByteArray:
	if _recording == null or _player.failure_frame() < 0:
		return PackedByteArray()
	var report: Dictionary = {
		"schema": "fortress-replay-failure-v1",
		"playback_engine": Engine.get_version_info().string,
		"replay_sha256": _recording_sha256,
		"replay_bytes": _recording_bytes,
		"failure":
		{
			"frame": _player.failure_frame(),
			"code": _player.failure_code(),
			"request_kind": _player.failure_kind(),
			"comparison": _player.failure_comparison(),
			"expected": _player.failure_expected_checksum().hex_encode(),
			"actual": _player.failure_actual_checksum().hex_encode(),
		},
		"recording":
		{
			"engine": _recording.engine_version(),
			"addon": _recording.addon_version(),
			"upstream": _recording.upstream_revision(),
			"game_version": _recording.game_version(),
			"seed": _recording.game_seed(),
			"frames": _recording.frame_count(),
		},
		"observed_state": {"frame": current_frame(), "bytes": game.canonical_bytes().hex_encode()},
		"coverage": {"checked": checked_checksum_count(), "recorded": recorded_checksum_count()},
	}
	var bytes: PackedByteArray = JSON.stringify(report, "\t").to_utf8_buffer()
	return bytes if bytes.size() <= MAX_FAILURE_REPORT_BYTES else PackedByteArray()


func has_failure() -> bool:
	return _player.failure_frame() >= 0


## Whether the displayed boundary has a portable prefix this viewer can reopen.
## Active navigation and game work refuse export; failed playback may export its preceding history.
func can_export_prefix() -> bool:
	return (
		_recording != null
		and not _is_busy()
		and not is_seeking()
		and (current_frame() > 0 or (not _recording.checksum(_recording.frame_count()).is_empty() and not _recording.checksum(0).is_empty()))
	)


## Owned original inputs before the displayed frame, preserving original metadata and recorded evidence.
## No gameplay or checksum is generated. Existing v6 evidence at the selected ending is retained;
## historical formats retain their original final-state limits. Empty when export is unavailable.
func prefix_bytes() -> PackedByteArray:
	return _recording.owned_prefix(current_frame()).to_bytes() if can_export_prefix() else PackedByteArray()


## The source recording's identity and selected ending distinguish exported prefixes.
func prefix_filename() -> String:
	return "fortress-replay-prefix-%s-%d.frrp" % [_recording_sha256.left(12), current_frame()] if can_export_prefix() else ""


func _is_busy() -> bool:
	return _player._is_stepping or _player._batch != null
