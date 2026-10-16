class_name FortressDiagnosticTrace
extends RefCounted

## Opt-in local evidence only. Never participates in checksums, packets or simulation.
var _limit: int = 0
var _max_payload: int = 0
var _seed: String = ""
var _version: String = ""
var _command: String = ""
var _rows: Dictionary = {}
var _frontier: int = -1
var _failure: Dictionary = {}


func configure(config: RefCounted) -> void:
	_limit = config.diagnostic_trace_frames
	_max_payload = config.diagnostic_trace_payload_bytes()
	_seed = config.diagnostic_seed if _limit > 0 else ""
	_version = config.diagnostic_version if _limit > 0 else ""
	_command = config.diagnostic_replay_command if _limit > 0 else ""


func save(frame: int, bytes: PackedByteArray, checksum: PackedByteArray) -> void:
	if not _accept(frame):
		return
	_rows[frame] = {"state": bytes.duplicate(), "state_available": true, "checksum": checksum.duplicate(), "inputs": []}


func advance(frame: int, inputs: RefCounted) -> void:
	if not _accept(frame):
		return
	if not _rows.has(frame):
		_rows[frame] = {"state": PackedByteArray(), "state_available": false, "checksum": PackedByteArray(), "inputs": []}
	var applied: Array[Dictionary] = []
	for player: int in range(inputs.size().value):
		var input: RefCounted = inputs.read(player)
		applied.append({"player": player, "bytes": input.bytes.duplicate(), "status": input.status})
	_rows[frame].inputs = applied


## A restored boundary invalidates all later evidence, including speculative input statuses.
func load_frame(frame: int) -> void:
	if _limit == 0 or not _failure.is_empty():
		return
	for retained: int in _rows.keys():
		if retained > frame:
			_rows.erase(retained)
	if _rows.has(frame):
		_rows[frame].inputs = []


func freeze(frame: int, peer_index: int, local: PackedByteArray, remote: PackedByteArray, source: String = "peer_checksum") -> void:
	if _limit == 0 or not _failure.is_empty():
		return
	_failure = {
		"frame": frame,
		"peer_index": peer_index,
		"source": source,
		"local_checksum": local.hex_encode(),
		"remote_checksum": remote.hex_encode(),
		"snapshot_available": _rows.has(frame) and _rows[frame].state_available
	}


func report() -> Dictionary:
	if _limit == 0:
		return {}
	var frames: Array[Dictionary] = []
	var retained_payload: int = 0
	var keys: Array = _rows.keys()
	keys.sort()
	for frame: int in keys:
		var row: Dictionary = _rows[frame]
		var inputs: Array[Dictionary] = []
		retained_payload += row.state.size() + row.checksum.size()
		for input: Dictionary in row.inputs:
			inputs.append({"player": input.player, "bytes": input.bytes.hex_encode(), "status": input.status})
			retained_payload += input.bytes.size()
		frames.append({"frame": frame, "state": row.state.hex_encode(), "state_available": row.state_available, "checksum": row.checksum.hex_encode(), "inputs": inputs})
	return {
		"schema": "fortress-canonical-trace-v1",
		"seed": _seed,
		"application_version": _version,
		"replay_command": _command,
		"max_frames": _limit,
		"max_payload_bytes": _max_payload,
		"max_export_bytes": 2 * _max_payload + _limit * 1280 + 8192,
		"retained_payload_bytes": retained_payload,
		"first_divergence": _failure.duplicate(true),
		"frames": frames
	}


func _accept(frame: int) -> bool:
	if _limit == 0 or not _failure.is_empty():
		return false
	_frontier = maxi(_frontier, frame)
	var floor_frame: int = maxi(0, _frontier - _limit + 1)
	for retained: int in _rows.keys():
		if retained < floor_frame:
			_rows.erase(retained)
	return frame >= floor_frame
