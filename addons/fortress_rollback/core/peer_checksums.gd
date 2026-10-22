class_name FortressPeerChecksums
extends RefCounted

# gdlint: disable=max-returns
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const FRAME_MAX: int = 2147483647
var interval: int = 60
var capacity: int = 128
var max_ahead: int = 128
var failure: Dictionary = {}
var _next: int = 60
var _local: Dictionary = {}
var _remote: Dictionary = {}
var _sent: Dictionary = {}
var _verified: Dictionary = {}
var _abandoned: Dictionary = {}


func configure(ids: Array[PackedByteArray], checksum_interval: int, limit: int, ahead: int) -> void:
	interval = checksum_interval
	capacity = limit
	max_ahead = ahead
	_next = interval
	for peer: PackedByteArray in ids:
		_remote[peer.hex_encode()] = {}
		_sent[peer.hex_encode()] = -1
		_verified[peer.hex_encode()] = 0


func receive(peer: PackedByteArray, frame: int, checksum: PackedByteArray, current: int) -> int:
	if interval == 0:
		return Types.Code.OK
	if _abandoned.has(peer.hex_encode()):
		# A departed peer reports frames the survivors resimulated.
		return Types.Code.OK
	if frame < 0 or frame > FRAME_MAX or checksum.size() != 16 or frame % interval != 0 or frame == 0:
		return _fail(Types.Code.PROTOCOL_FAILED, "invalid_checksum_report", peer, frame)
	if frame > mini(FRAME_MAX, current + max_ahead):
		return _fail(Types.Code.PROTOCOL_FAILED, "future_checksum_report", peer, frame)
	if frame < _floor():
		return Types.Code.OK
	var reports: Dictionary = _remote[peer.hex_encode()]
	if reports.has(frame):
		return Types.Code.OK if reports[frame] == checksum else _fail(Types.Code.PROTOCOL_FAILED, "conflicting_checksum_report", peer, frame)
	if reports.size() >= capacity:
		return _fail(Types.Code.PROTOCOL_FAILED, "checksum_capacity_exceeded", peer, frame)
	reports[frame] = checksum.duplicate()
	return Types.Code.OK


## Schedule only retained snapshots completed by the existing game driver.
func scheduled(core: RefCounted, confirmation_ceiling: int) -> Dictionary:
	if interval == 0 or _next > FRAME_MAX:
		return {}
	var status: RefCounted = core.status()
	if _next > mini(status.confirmed_frame, confirmation_ceiling) or _next > status.current_frame:
		return {}
	for saved: Dictionary in core.confirmed_checksums(true):
		if saved.frame != _next:
			continue
		if not _local.has(_next):
			if _local.size() >= capacity:
				var oldest: Array = _local.keys()
				oldest.sort()
				_local.erase(oldest[0])
			_local[_next] = saved.checksum.duplicate()
		return {"frame": _next, "checksum": _local[_next].duplicate()}
	if _next < status.current_frame:
		# A pending repair withholds the snapshots above the earliest incorrect
		# frame, because those states are not trustworthy until the next advance
		# resimulates them. The checksum is late, not lost: the match keeps
		# running and the next boundary is scheduled after the repair.
		if status.pending_rollback_frame != -1 and _next > status.pending_rollback_frame:
			return {}
		_fail(Types.Code.HISTORY_UNAVAILABLE, "checksum_history_unavailable", PackedByteArray(), _next)
	return {}


func needs_send(peer: PackedByteArray, frame: int) -> bool:
	return _sent[peer.hex_encode()] < frame


func sent(peer: PackedByteArray, frame: int) -> void:
	_sent[peer.hex_encode()] = frame
	for last: int in _sent.values():
		if last < frame:
			return
	_next = frame + interval
	# The facade compares eligible retained pairs before advancing this bounded window.
	# Unmatched reports below its floor are stale and cannot bind to evicted snapshots.
	var floor_frame: int = _floor()
	for reports: Dictionary in _remote.values():
		for old: int in reports.keys():
			if old < floor_frame:
				reports.erase(old)


## A departed peer never reports again and must not hold the shared window back.
## Its pending reports are dropped, because the frames it reported are resimulated.
func abandon(peer: PackedByteArray) -> void:
	_sent[peer.hex_encode()] = FRAME_MAX
	_remote[peer.hex_encode()].clear()
	_abandoned[peer.hex_encode()] = true


func compare(core: RefCounted, ids: Array[PackedByteArray], confirmation_ceiling: int) -> int:
	if interval == 0:
		return Types.Code.OK
	var eligible: Dictionary = {}
	# Only previously scheduled owned checksums enter this comparison domain.
	for frame: int in _local:
		if frame < mini(core.status().confirmed_frame, confirmation_ceiling):
			eligible[frame] = _local[frame]
	for peer: PackedByteArray in ids:
		if _abandoned.has(peer.hex_encode()):
			# A departed peer's reports belong to frames the survivors resimulated.
			continue
		var reports: Dictionary = _remote[peer.hex_encode()]
		var frames: Array = reports.keys()
		frames.sort()
		for frame: int in frames:
			if not eligible.has(frame):
				continue
			if eligible[frame] != reports[frame]:
				failure = {
					"kind": "desync_detected",
					"peer": peer.duplicate(),
					"frame": frame,
					"local_checksum": eligible[frame].duplicate(),
					"remote_checksum": reports[frame].duplicate()
				}
				return Types.Code.DESYNC
			reports.erase(frame)
			_verified[peer.hex_encode()] = mini(FRAME_MAX, _verified[peer.hex_encode()] + 1)
	return Types.Code.OK


func status() -> Dictionary:
	var remote: Dictionary = {}
	for key: String in _remote:
		remote[key] = _remote[key].size()
	return {"next_frame": _next, "local_frames": _local.size(), "remote_frames": remote, "verified_reports": _verified.duplicate()}


func _floor() -> int:
	return maxi(interval, _next - capacity * interval)


func _fail(code: int, kind: String, peer: PackedByteArray, frame: int) -> int:
	failure = {"kind": kind, "peer": peer.duplicate(), "frame": frame}
	return code
