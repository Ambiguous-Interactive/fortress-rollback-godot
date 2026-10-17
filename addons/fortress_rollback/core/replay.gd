class_name FortressReplay
extends RefCounted

# gdlint: disable=max-returns

## Confirmed inputs for frames 0..frame_count() - 1, with optional 16-byte state checksums.
## Frame F's checksum covers the state before input F. Sessions record; FortressReplayPlayer plays back.
## Load a file with FortressReplay.new().decode(bytes). The layout is in docs/integration.md.

enum DecodeCode { OK, MALFORMED, UNSUPPORTED_VERSION, TOO_LARGE }

const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const MAGIC: String = "FRRP"
const FORMAT_VERSION: int = 2
const ADDON_VERSION: String = "0.1.0"
const UPSTREAM_REVISION: String = "fortress-rollback f13cd5c0f2815926785a395947e18da0dbea0dd8"
const FIXED_BYTES: int = 23
const TEXT_FIELDS: int = 5
const MAX_TEXT_BYTES: int = 128
const CHECKSUM_BYTES: int = 16
const MAX_FRAMES: int = 4194304
const MAX_BYTES: int = 268435456
const FLAG_CHECKSUM: int = 1
const FLAG_SKIPPED: int = 2

var _players: int = 0
var _width: int = 0
var _frames: int = 0
var _skipped: int = 0
var _input_delay: int = 0
var _max_prediction_frames: int = 0
var _sync_test: bool = false
var _neutral: PackedByteArray = PackedByteArray()
## Engine, addon, upstream, game seed, game version.
var _text: PackedStringArray = PackedStringArray(["", "", "", "", ""])
var _inputs: PackedByteArray = PackedByteArray()
var _checksums: PackedByteArray = PackedByteArray()
var _flags: PackedByteArray = PackedByteArray()


static func valid_shape(players: int, width: int, frames: int) -> bool:
	if players < 2 or players > 8 or width < 1 or width > 65536 or frames < 0 or frames > MAX_FRAMES:
		return false
	return FIXED_BYTES + width + TEXT_FIELDS * (1 + MAX_TEXT_BYTES) + frames * (players * width + 1 + CHECKSUM_BYTES) <= MAX_BYTES


## Metadata text is printable ASCII of at most MAX_TEXT_BYTES, so every stored string round-trips exactly.
static func valid_text(text: String) -> bool:
	return _printable(text.to_utf8_buffer())


static func _printable(bytes: PackedByteArray) -> bool:
	if bytes.size() > MAX_TEXT_BYTES:
		return false
	for value: int in bytes:
		if value < 0x20 or value > 0x7e:
			return false
	return true


## Replaces this replay only when the result is OK; any other DecodeCode leaves it unchanged.
## Nothing is allocated before the declared frame count is checked against the bytes actually present.
## Version 1 files are UNSUPPORTED_VERSION: they lack the metadata that version 2 requires.
func decode(bytes: PackedByteArray, max_bytes: int = MAX_BYTES) -> int:
	if bytes.size() > mini(max_bytes, MAX_BYTES):
		return DecodeCode.TOO_LARGE
	if bytes.size() < 6 or bytes.slice(0, 4) != MAGIC.to_ascii_buffer():
		return DecodeCode.MALFORMED
	if bytes.decode_u16(4) != FORMAT_VERSION:
		return DecodeCode.UNSUPPORTED_VERSION
	if bytes.size() < FIXED_BYTES:
		return DecodeCode.MALFORMED
	var players: int = bytes.decode_u8(6)
	var width: int = bytes.decode_u32(7)
	var frames: int = bytes.decode_u32(11)
	var skipped: int = bytes.decode_u32(15)
	var prediction: int = bytes.decode_u8(21)
	var sync_test: int = bytes.decode_u8(22)
	if not valid_shape(players, width, frames) or skipped > frames or prediction > 128 or sync_test > 1:
		return DecodeCode.MALFORMED
	var cursor: int = FIXED_BYTES + width
	if cursor > bytes.size():
		return DecodeCode.MALFORMED
	var neutral: PackedByteArray = bytes.slice(FIXED_BYTES, cursor)
	var text: PackedStringArray = PackedStringArray()
	for field: int in range(TEXT_FIELDS):
		var size: int = bytes[cursor] if cursor < bytes.size() else MAX_TEXT_BYTES + 1
		if size > MAX_TEXT_BYTES or cursor + 1 + size > bytes.size():
			return DecodeCode.MALFORMED
		var value: PackedByteArray = bytes.slice(cursor + 1, cursor + 1 + size)
		if not _printable(value):
			return DecodeCode.MALFORMED
		text.append(value.get_string_from_ascii())
		cursor += 1 + size
	var row: int = players * width
	if frames * (row + 1) > bytes.size() - cursor:
		return DecodeCode.MALFORMED
	var neutral_row: PackedByteArray = PackedByteArray()
	for player: int in range(players):
		neutral_row.append_array(neutral)
	var inputs: PackedByteArray = PackedByteArray()
	var checksums: PackedByteArray = PackedByteArray()
	var flags: PackedByteArray = PackedByteArray()
	var skipped_seen: int = 0
	for frame: int in range(frames):
		var flag: int = bytes[cursor + row] if cursor + row < bytes.size() else 0xff
		var end: int = cursor + row + 1 + (CHECKSUM_BYTES if flag == FLAG_CHECKSUM else 0)
		if (flag != 0 and flag != FLAG_CHECKSUM and flag != FLAG_SKIPPED) or end > bytes.size():
			return DecodeCode.MALFORMED
		var input_row: PackedByteArray = bytes.slice(cursor, cursor + row)
		if flag == FLAG_SKIPPED and input_row != neutral_row:
			return DecodeCode.MALFORMED
		skipped_seen += int(flag == FLAG_SKIPPED)
		inputs.append_array(input_row)
		flags.append(flag)
		if flag == FLAG_CHECKSUM:
			checksums.append_array(bytes.slice(cursor + row + 1, end))
		else:
			checksums.resize(checksums.size() + CHECKSUM_BYTES)
		cursor = end
	if cursor != bytes.size() or skipped_seen != skipped:
		return DecodeCode.MALFORMED
	_players = players
	_width = width
	_frames = frames
	_skipped = skipped
	_input_delay = bytes.decode_u16(19)
	_max_prediction_frames = prediction
	_sync_test = sync_test == 1
	_neutral = neutral
	_text = text
	_inputs = inputs
	_checksums = checksums
	_flags = flags
	return DecodeCode.OK


func player_count() -> int:
	return _players


func input_width() -> int:
	return _width


func frame_count() -> int:
	return _frames


## Frames recorded as neutral input because their confirmed input was no longer retained.
func skipped_frames() -> int:
	return _skipped


func is_skipped_frame(frame: int) -> bool:
	return frame >= 0 and frame < _frames and _flags[frame] == FLAG_SKIPPED


## The recording session's neutral input, which skipped frames hold for every player.
func neutral_input() -> PackedByteArray:
	return _neutral.duplicate()


## The recording session's configured starting delay; later set_input_delay changes are in the inputs.
func input_delay() -> int:
	return _input_delay


func max_prediction_frames() -> int:
	return _max_prediction_frames


func sync_test() -> bool:
	return _sync_test


## Godot version and commit of the recording build.
func engine_version() -> String:
	return _text[0]


func addon_version() -> String:
	return _text[1]


## The pinned fortress-rollback revision whose replay semantics this addon follows.
func upstream_revision() -> String:
	return _text[2]


## config.diagnostic_seed of the recording session.
func game_seed() -> String:
	return _text[3]


## config.diagnostic_version of the recording session.
func game_version() -> String:
	return _text[4]


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
	if frame < 0 or frame >= _frames or _flags[frame] != FLAG_CHECKSUM:
		return PackedByteArray()
	return _checksums.slice(frame * CHECKSUM_BYTES, (frame + 1) * CHECKSUM_BYTES)


func to_bytes() -> PackedByteArray:
	var bytes: PackedByteArray = MAGIC.to_ascii_buffer()
	bytes.resize(FIXED_BYTES)
	bytes.encode_u16(4, FORMAT_VERSION)
	bytes.encode_u8(6, _players)
	bytes.encode_u32(7, _width)
	bytes.encode_u32(11, _frames)
	bytes.encode_u32(15, _skipped)
	bytes.encode_u16(19, _input_delay)
	bytes.encode_u8(21, _max_prediction_frames)
	bytes.encode_u8(22, int(_sync_test))
	bytes.append_array(_neutral)
	for value: String in _text:
		bytes.append(value.length())
		bytes.append_array(value.to_ascii_buffer())
	var row: int = _players * _width
	for frame: int in range(_frames):
		bytes.append_array(_inputs.slice(frame * row, (frame + 1) * row))
		bytes.append(_flags[frame])
		if _flags[frame] == FLAG_CHECKSUM:
			bytes.append_array(_checksums.slice(frame * CHECKSUM_BYTES, (frame + 1) * CHECKSUM_BYTES))
	return bytes


func owned_copy() -> RefCounted:
	var copy: RefCounted = get_script().new()
	copy._players = _players
	copy._width = _width
	copy._frames = _frames
	copy._skipped = _skipped
	copy._input_delay = _input_delay
	copy._max_prediction_frames = _max_prediction_frames
	copy._sync_test = _sync_test
	copy._neutral = _neutral.duplicate()
	copy._text = _text.duplicate()
	copy._inputs = _inputs.duplicate()
	copy._checksums = _checksums.duplicate()
	copy._flags = _flags.duplicate()
	return copy


## Session recording from a validated FortressConfig: one confirmed row per frame, in frame order,
## with neutral rows for skipped frames.
func _start(config: RefCounted) -> void:
	var info: Dictionary = Engine.get_version_info()
	var engine: String = ("%d.%d.%d.%s %s" % [info.major, info.minor, info.patch, info.status, info.hash]).left(MAX_TEXT_BYTES)
	_players = config.player_count
	_width = config.input_width
	_input_delay = config.input_delay
	_max_prediction_frames = config.max_prediction_frames
	_sync_test = config.sync_test
	_neutral = config.neutral_input.duplicate()
	_text = PackedStringArray([engine if valid_text(engine) else "", ADDON_VERSION, UPSTREAM_REVISION, config.diagnostic_seed, config.diagnostic_version])


func _append(row: PackedByteArray, saved_checksum: PackedByteArray, skipped: bool) -> void:
	_inputs.append_array(row)
	var flag: int = FLAG_SKIPPED if skipped else (FLAG_CHECKSUM if saved_checksum.size() == CHECKSUM_BYTES else 0)
	_flags.append(flag)
	if flag == FLAG_CHECKSUM:
		_checksums.append_array(saved_checksum)
	else:
		_checksums.resize(_checksums.size() + CHECKSUM_BYTES)
	_frames += 1
	_skipped += int(skipped)
