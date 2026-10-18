class_name FortressDiagnosticPlayer
extends RefCounted

# gdlint: disable=max-returns

## Offline canonical-window reproduction through the existing driver game callbacks.
## No network, input sampling, command execution, or writes to the captured artifact.
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Schema = preload("res://addons/fortress_rollback/core/diagnostic_trace_reader.gd")
const Reader = preload("res://addons/fortress_rollback/core/snapshot_reader.gd")
const Writer = preload("res://addons/fortress_rollback/core/snapshot_writer.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")

var _rows: Array[Dictionary] = []
var _game: RefCounted
var _capacity: int = 0
var _index: int = 0
var _reason: int = Types.Code.OK
var _failure: Dictionary = {}
var _busy: bool = false
var _restored: bool = false
var _validated: int = 0
var _advanced: int = 0


## The game must match the captured application version and supply save/load/simulate callbacks.
## Rejects malformed, discontinuous or input-only evidence before calling the game.
## Failure leaves any previously configured playback unchanged.
func configure(trace: Dictionary, game: RefCounted, max_snapshot_bytes: int, player_count: int = 2, input_width: int = 1) -> int:
	if _busy:
		return Types.Code.BUSY
	if game == null:
		return Types.Code.INVALID_CONFIGURATION
	for method: String in ["save_state", "load_state", "simulate_frame"]:
		if not game.has_method(method):
			return Types.Code.INVALID_CONFIGURATION
	var rows: Array[Dictionary] = Schema.decode(trace, player_count, input_width, max_snapshot_bytes)
	if rows.is_empty():
		return Types.Code.INVALID_CONFIGURATION
	_rows = rows
	_game = game
	_capacity = max_snapshot_bytes
	_index = 0
	_reason = Types.Code.OK
	_failure = {}
	_restored = false
	_validated = 0
	_advanced = 0
	return Types.Code.OK


## Restores the first boundary once, then validates and applies one retained row per call.
## DESYNC stops before applying that row's inputs. FRAME_EXHAUSTED ends the bounded window.
## A final input without a following SAVE can be applied but cannot be validated.
func step() -> int:
	if _busy:
		return Types.Code.BUSY
	if _rows.is_empty():
		return Types.Code.NOT_CONFIGURED
	if _reason != Types.Code.OK:
		return _reason
	if _index >= _rows.size():
		return Types.Code.FRAME_EXHAUSTED
	_busy = true
	var row: Dictionary = _rows[_index]
	var code: int = Types.Code.OK
	if not _restored:
		code = _restore(row)
		_restored = code == Types.Code.OK
	if code == Types.Code.OK and row.state_available:
		code = _compare(row)
	if code == Types.Code.OK and not row.inputs.is_empty():
		var inputs: Types.FrameInputs = Types.FrameInputs.new(row.inputs, row.statuses)
		var ok: Variant = _game.simulate_frame(row.frame, inputs)  # Application callback return type is validated at the boundary.
		inputs._expire()
		code = Types.Code.OK if ok is bool and ok else Types.Code.CALLBACK_FAILED
		if code == Types.Code.OK:
			_advanced += 1
	_busy = false
	if code != Types.Code.OK:
		_reason = code
		if _failure.is_empty():
			_failure = {"frame": row.frame, "kind": "callback" if code == Types.Code.CALLBACK_FAILED else "snapshot"}
		return code
	_index += 1
	return Types.Code.OK


func _restore(row: Dictionary) -> int:
	var reader: Reader = Reader.new(row.state, true)
	var ok: Variant = _game.load_state(row.frame, reader)
	var complete: bool = reader.is_complete()
	reader._expire()
	if not (ok is bool) or not ok:
		return Types.Code.CALLBACK_FAILED
	return Types.Code.OK if complete else Types.Code.SNAPSHOT_FAILED


func _compare(row: Dictionary) -> int:
	var writer: Writer = Writer.new(_capacity)
	var saved: Variant = _game.save_state(row.frame, writer)
	var status: int = writer.status()
	var actual: PackedByteArray = writer._written_copy()
	writer._expire()
	if not saved is Driver.SaveResult or not saved.ok:
		return Types.Code.CALLBACK_FAILED
	if status != Writer.Code.OK or saved.checksum.size() != 16:
		return Types.Code.SNAPSHOT_FAILED
	if actual != row.state:
		var offset: int = 0
		while offset < mini(actual.size(), row.state.size()) and actual[offset] == row.state[offset]:
			offset += 1
		_failure = {"frame": row.frame, "kind": "state", "byte": offset, "expected_bytes": row.state.size(), "actual_bytes": actual.size()}
		return Types.Code.DESYNC
	if not row.checksum.is_empty() and saved.checksum != row.checksum:
		_failure = {"frame": row.frame, "kind": "checksum", "expected": row.checksum.hex_encode(), "actual": saved.checksum.hex_encode()}
		return Types.Code.DESYNC
	_validated += 1
	return Types.Code.OK


## Counts only successful canonical comparisons and ADVANCE callbacks; no remote mismatch claim.
func report() -> Dictionary:
	return {"complete": is_complete(), "validated_states": _validated, "advanced_frames": _advanced, "failure": _failure.duplicate(true)}


func is_complete() -> bool:
	return not _rows.is_empty() and _reason == Types.Code.OK and _index == _rows.size()
