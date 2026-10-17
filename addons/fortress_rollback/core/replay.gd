class_name FortressReplay
extends RefCounted

# gdlint: disable=max-returns

## Confirmed inputs for frames 0..frame_count() - 1, with optional 16-byte state checksums.
## Frame F's checksum covers the state before input F. Sessions record; FortressReplayPlayer plays back.
## Load a file with FortressReplay.new().decode(bytes).

const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const MAGIC: String = "FRRP"
const FORMAT_VERSION: int = 1
const HEADER_BYTES: int = 19
const CHECKSUM_BYTES: int = 16
const MAX_FRAMES: int = 4194304
const MAX_BYTES: int = 268435456

var _players: int = 0
var _width: int = 0
var _frames: int = 0
var _skipped: int = 0
var _inputs: PackedByteArray = PackedByteArray()
var _checksums: PackedByteArray = PackedByteArray()
var _has_checksum: PackedByteArray = PackedByteArray()


static func valid_shape(players: int, width: int, frames: int) -> bool:
	if players < 2 or players > 8 or width < 1 or width > 65536 or frames < 0 or frames > MAX_FRAMES:
		return false
	return HEADER_BYTES + frames * (players * width + 1 + CHECKSUM_BYTES) <= MAX_BYTES


## Replaces this replay only when the bytes are valid; false leaves it unchanged. Nothing is
## allocated before the declared frame count is checked against the bytes actually present.
func decode(bytes: PackedByteArray, max_bytes: int = MAX_BYTES) -> bool:
	if bytes.size() < HEADER_BYTES or bytes.size() > mini(max_bytes, MAX_BYTES) or bytes.slice(0, 4) != MAGIC.to_ascii_buffer():
		return false
	if bytes.decode_u16(4) != FORMAT_VERSION:
		return false
	var players: int = bytes.decode_u8(6)
	var width: int = bytes.decode_u32(7)
	var frames: int = bytes.decode_u32(11)
	var skipped: int = bytes.decode_u32(15)
	if not valid_shape(players, width, frames) or skipped > frames:
		return false
	var row: int = players * width
	if frames * (row + 1) > bytes.size() - HEADER_BYTES:
		return false
	var inputs: PackedByteArray = PackedByteArray()
	var checksums: PackedByteArray = PackedByteArray()
	var flags: PackedByteArray = PackedByteArray()
	var cursor: int = HEADER_BYTES
	for frame: int in range(frames):
		var flag: int = bytes[cursor + row] if cursor + row < bytes.size() else 2
		var end: int = cursor + row + 1 + (CHECKSUM_BYTES if flag == 1 else 0)
		if flag > 1 or end > bytes.size():
			return false
		inputs.append_array(bytes.slice(cursor, cursor + row))
		flags.append(flag)
		if flag == 1:
			checksums.append_array(bytes.slice(cursor + row + 1, end))
		else:
			checksums.resize(checksums.size() + CHECKSUM_BYTES)
		cursor = end
	if cursor != bytes.size():
		return false
	_players = players
	_width = width
	_frames = frames
	_skipped = skipped
	_inputs = inputs
	_checksums = checksums
	_has_checksum = flags
	return true


func player_count() -> int:
	return _players


func input_width() -> int:
	return _width


func frame_count() -> int:
	return _frames


## Frames recorded as neutral input because their confirmed input was no longer retained.
func skipped_frames() -> int:
	return _skipped


## Fresh confirmed inputs for one frame, in the same form simulate_frame receives during a session.
func inputs(frame: int) -> Types.FrameInputs:
	if frame < 0 or frame >= _frames:
		return null
	var bytes: Array[PackedByteArray] = []
	var statuses: PackedInt32Array = PackedInt32Array()
	var row: int = _players * _width
	for player: int in range(_players):
		bytes.append(_inputs.slice(frame * row + player * _width, frame * row + (player + 1) * _width))
		statuses.append(Queue.Status.CONFIRMED)
	return Types.FrameInputs.new(bytes, statuses)


## Empty when the recording session had no retained checksum for this frame.
func checksum(frame: int) -> PackedByteArray:
	if frame < 0 or frame >= _frames or _has_checksum[frame] == 0:
		return PackedByteArray()
	return _checksums.slice(frame * CHECKSUM_BYTES, (frame + 1) * CHECKSUM_BYTES)


## Little-endian v1: magic, version, players, width, frames, skipped, then inputs + checksum flag per frame.
func to_bytes() -> PackedByteArray:
	var bytes: PackedByteArray = MAGIC.to_ascii_buffer()
	bytes.resize(HEADER_BYTES)
	bytes.encode_u16(4, FORMAT_VERSION)
	bytes.encode_u8(6, _players)
	bytes.encode_u32(7, _width)
	bytes.encode_u32(11, _frames)
	bytes.encode_u32(15, _skipped)
	var row: int = _players * _width
	for frame: int in range(_frames):
		bytes.append_array(_inputs.slice(frame * row, (frame + 1) * row))
		bytes.append(_has_checksum[frame])
		if _has_checksum[frame] == 1:
			bytes.append_array(_checksums.slice(frame * CHECKSUM_BYTES, (frame + 1) * CHECKSUM_BYTES))
	return bytes


func owned_copy() -> RefCounted:
	var copy: RefCounted = get_script().new()
	copy._players = _players
	copy._width = _width
	copy._frames = _frames
	copy._skipped = _skipped
	copy._inputs = _inputs.duplicate()
	copy._checksums = _checksums.duplicate()
	copy._has_checksum = _has_checksum.duplicate()
	return copy


## Session recording: one confirmed row per frame, in frame order, with neutral rows for skipped frames.
func _start(players: int, width: int) -> void:
	_players = players
	_width = width


func _append(row: PackedByteArray, saved_checksum: PackedByteArray, skipped: bool) -> void:
	_inputs.append_array(row)
	_has_checksum.append(1 if saved_checksum.size() == CHECKSUM_BYTES else 0)
	if saved_checksum.size() == CHECKSUM_BYTES:
		_checksums.append_array(saved_checksum)
	else:
		_checksums.resize(_checksums.size() + CHECKSUM_BYTES)
	_frames += 1
	if skipped:
		_skipped += 1
