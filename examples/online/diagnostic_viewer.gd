class_name FortressOnlineDiagnosticViewer
extends RefCounted

## Presentation controls for the shipped online game's bounded canonical captures.
const Player = preload("res://addons/fortress_rollback/core/diagnostic_player.gd")
const Game = preload("res://examples/offline/simulation.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const MAX_BYTES: int = 1048576
const GAME_VERSION: String = "fortress-online-integer-v1"

var game: Game = Game.new()
var is_playing: bool = false
var message: String = "Open a canonical diagnostic JSON capture."
var _trace: Dictionary = {}
var _session_failure: Dictionary = {}
var _player: Player = Player.new()
var _index: int = 0
var _code: int = Types.Code.NOT_CONFIGURED
var _servicing: bool = false


## Invalid imports preserve the current game, position and play state.
func open_bytes(bytes: PackedByteArray) -> bool:
	if _is_busy():
		return false
	if bytes.size() > MAX_BYTES:
		message = "Diagnostic file exceeds the 1 MiB limit."
		return false
	var parser: JSON = JSON.new()
	if parser.parse(bytes.get_string_from_utf8()) != OK or not parser.data is Dictionary:
		message = "Could not open diagnostic JSON."
		return false
	var report: Dictionary = parser.data
	var trace: Dictionary = report
	if trace.has("trace"):
		if not trace.trace is Dictionary:
			message = "Diagnostic report has no valid trace object."
			return false
		trace = trace.trace
	if trace.get("application_version") != GAME_VERSION:
		message = "This viewer needs a fortress-online-integer-v1 canonical capture."
		return false
	var game_candidate: Game = Game.new()
	var candidate: Player = Player.new()
	var code: int = candidate.configure(trace, game_candidate, Game.SNAPSHOT_BYTES)
	if code != Types.Code.OK:
		message = "Needs a contiguous window with an initial SAVE and a later saved boundary. Enable game state and inputs before Ready."
		return false
	_session_failure = _reported_session_failure(report)
	_trace = trace.duplicate(true)
	_player.terminate()
	game = game_candidate
	_player = candidate
	_opened()
	return true


func _opened() -> void:
	_index = 0
	_code = Types.Code.OK
	is_playing = false
	message = "Ready. Step restores the first captured boundary, then applies its inputs."


func restart() -> void:
	if _is_busy() or _trace.is_empty():
		return
	var candidate: Player = Player.new()
	var game_candidate: Game = Game.new()
	if candidate.configure(_trace, game_candidate, Game.SNAPSHOT_BYTES) != Types.Code.OK:
		return
	_player.terminate()
	game = game_candidate
	_player = candidate
	_opened()


## Retire the owned player when its scene leaves, preserving the first playback failure.
## Active callbacks keep their ownership guard until return; restart creates a fresh lifetime.
func terminate() -> void:
	_player.terminate()
	is_playing = false
	if _code == Types.Code.OK:
		_code = Types.Code.TERMINATED
		message = "Playback stopped. Restart to inspect again."


func can_step() -> bool:
	return _code == Types.Code.OK and not _player.is_complete()


func toggle_play() -> void:
	if not _is_busy() and can_step():
		is_playing = not is_playing
		message = "Playing captured local execution." if is_playing else "Paused."


## Presentation time never creates inputs: each tick consumes at most one retained row.
func tick() -> void:
	if not _is_busy() and is_playing:
		step()


func step() -> void:
	if _is_busy() or not can_step():
		return
	var player: Player = _player
	_servicing = true
	var code: int = player.step()
	_servicing = false
	if player != _player:
		return
	_code = code
	if _code != Types.Code.OK:
		is_playing = false
		var failure: Dictionary = _player.report().failure
		message = "Stopped at boundary %d: %s (code %d)." % [failure.get("frame", -1), failure.get("kind", "playback"), _code]
	elif _player.is_complete():
		_index += 1
		is_playing = false
		message = "Window complete. All available canonical states matched; the final advance may have no following SAVE."
	else:
		_index += 1


func _is_busy() -> bool:
	return _servicing or _player._busy


## Values describe retained evidence, not the original network divergence or seed correctness.
func status() -> Dictionary:
	var report: Dictionary = _player.report()
	var rows: Array = _trace.get("frames", [])
	return {
		"loaded": not rows.is_empty(),
		"playing": is_playing,
		"code": _code,
		"first_boundary": int(rows[0].frame) if not rows.is_empty() else -1,
		"last_boundary": int(rows[-1].frame) if not rows.is_empty() else -1,
		"next_boundary": int(rows[_index].frame) if _index < rows.size() else -1,
		"rows_consumed": _index,
		"row_count": rows.size(),
		"game_frame": game.frame,
		"seed": _metadata("seed"),
		"application_version": _metadata("application_version"),
		"capture_failure": _capture_failure(),
		"session_failure": _session_failure.duplicate(),
		"complete": report.complete,
		"validated_states": report.validated_states,
		"advanced_frames": report.advanced_frames,
		"failure": report.failure,
	}


func _metadata(field: String) -> String:
	# Metadata is descriptive only; never parse a wide seed as a JSON number or run replay_command.
	var value: Variant = _trace.get(field, "")
	return value.substr(0, 256) if value is String else "(not recorded as text)"


func _capture_failure() -> Dictionary:
	var value: Variant = _trace.get("first_divergence", {})
	if not value is Dictionary:
		return {}
	var result: Dictionary = {}
	for field: String in ["frame", "peer_index", "source", "snapshot_available", "local_checksum", "remote_checksum"]:
		var item: Variant = value.get(field)
		if item is String:
			result[field] = item.substr(0, 128)
		elif item is bool or item is int or item is float:
			result[field] = item
	return result


func _reported_session_failure(report: Dictionary) -> Dictionary:
	# JSON numbers can arrive as integer or floating-point variants.
	var kind: Variant = report.get("failure_kind", -1)
	var frame: Variant = report.get("failure_frame", -1)
	if not (kind is int or kind is float) or not is_finite(kind) or kind < 0 or kind > 2 or kind != int(kind):
		return {}
	if not (frame is int or frame is float) or not is_finite(frame) or frame < 0 or frame > 2147483647 or frame != int(frame):
		return {}
	return {"callback": ["save_state", "load_state", "simulate_frame"][int(kind)], "frame": int(frame)}
