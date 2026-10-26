class_name FortressReplay
extends RefCounted

# gdlint: disable=max-returns

## Confirmed inputs for frames 0..frame_count() - 1, with optional 16-byte state checksums.
## Frame F's checksum covers the state before input F; optional v6 terminal evidence covers boundary frame_count().
## Sessions record; FortressReplayPlayer plays back.
## Every frame carries a 16-byte digest of its own input row, so every recorded row is covered
## and player statuses independently of the state checksums.
## Load a file with FortressReplay.new().decode(bytes). The layout is in docs/integration.md.

enum DecodeCode { OK, MALFORMED, UNSUPPORTED_VERSION, TOO_LARGE }

const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const MAGIC: String = "FRRP"
const FORMAT_VERSION: int = 5
const TERMINAL_VERSION: int = 6
const ADDON_VERSION: String = "0.1.0"
const UPSTREAM_REVISION: String = "fortress-rollback f13cd5c0f2815926785a395947e18da0dbea0dd8"
const FIXED_BYTES: int = 23
const TEXT_FIELDS: int = 5
const MAX_TEXT_BYTES: int = 128
const CHECKSUM_BYTES: int = 16
const DIGEST_BYTES: int = 16
const MAX_FRAMES: int = 4194304
const MAX_BYTES: int = 268435456
const FLAG_CHECKSUM: int = 1
const FLAG_SKIPPED: int = 2

var _terminal_checksum: PackedByteArray = PackedByteArray()
var _format_version: int = FORMAT_VERSION
var _statuses: PackedByteArray = PackedByteArray()
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
var _digests: PackedByteArray = PackedByteArray()


static func valid_shape(players: int, width: int, frames: int, version: int = FORMAT_VERSION) -> bool:
	if players < 2 or players > 8 or width < 1 or width > 65536 or frames < 0 or frames > MAX_FRAMES:
		return false
	var row: int = players * (width + (1 if version >= 5 else 0))
	return (
		(CHECKSUM_BYTES if version == TERMINAL_VERSION else 0) + FIXED_BYTES + width + TEXT_FIELDS * (1 + MAX_TEXT_BYTES) + frames * (row + 1 + CHECKSUM_BYTES + DIGEST_BYTES)
		<= MAX_BYTES
	)


## Validate metadata and backing-array bounds before copying a caller-owned recording.
## Input digests and state checksums remain playback comparisons at their owning frame.
func is_valid() -> bool:
	if _format_version not in [4, FORMAT_VERSION, TERMINAL_VERSION] or not valid_shape(_players, _width, _frames, _format_version):
		return false
	if _input_delay < 0 or _input_delay > 65535 or _max_prediction_frames < 0 or _max_prediction_frames > 128 or _skipped < 0 or _skipped > _frames:
		return false
	if _neutral.size() != _width or _text.size() != TEXT_FIELDS:
		return false
	for text: String in _text:
		if not valid_text(text):
			return false
	if (
		_inputs.size() != _frames * _players * _width
		or _statuses.size() != _frames * _players
		or _flags.size() != _frames
		or _checksums.size() != _frames * CHECKSUM_BYTES
		or _digests.size() > _frames * DIGEST_BYTES
	):
		return false
	if _format_version == TERMINAL_VERSION:
		if _terminal_checksum.size() != CHECKSUM_BYTES or _skipped != 0:
			return false
	elif not _terminal_checksum.is_empty():
		return false
	var skipped_seen: int = 0
	for frame: int in _frames:
		var flag: int = _flags[frame]
		if flag not in [0, FLAG_CHECKSUM, FLAG_SKIPPED]:
			return false
		skipped_seen += int(flag == FLAG_SKIPPED)
		for player: int in _players:
			var status: int = _statuses[frame * _players + player]
			if status not in [Queue.Status.CONFIRMED, Queue.Status.DISCONNECTED]:
				return false
			if status != Queue.Status.CONFIRMED and (_format_version == 4 or flag == FLAG_SKIPPED):
				return false
			if flag == FLAG_SKIPPED:
				var offset: int = (frame * _players + player) * _width
				for index: int in _width:
					if _inputs[offset + index] != _neutral[index]:
						return false
	return skipped_seen == _skipped


## The digest of one recorded input row: the first 16 bytes of its SHA-256.
static func digest_row(row: PackedByteArray) -> PackedByteArray:
	var context: HashingContext = HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(row)
	return context.finish().slice(0, DIGEST_BYTES)


## Metadata text is printable ASCII of at most MAX_TEXT_BYTES, so every stored string round-trips exactly.
static func valid_text(text: String) -> bool:
	if text.length() > MAX_TEXT_BYTES:
		return false
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
## Version 4 reads with CONFIRMED statuses and retains its original byte-only digests.
## Version 6 adds exactly one final-boundary checksum to v5 rows and forbids substituted inputs.
## Version 1, version 2 and version 3 files are UNSUPPORTED_VERSION: version 1 lacks the metadata
## that version 2 requires, version 2 lacks the input digest that version 3 records, and version 3
## anchors only the final input row instead of every row.
func decode(bytes: PackedByteArray, max_bytes: int = MAX_BYTES) -> int:
	if bytes.size() > mini(max_bytes, MAX_BYTES):
		return DecodeCode.TOO_LARGE
	if bytes.size() < 6 or bytes.slice(0, 4) != MAGIC.to_ascii_buffer():
		return DecodeCode.MALFORMED
	var version: int = bytes.decode_u16(4)
	if version not in [4, FORMAT_VERSION, TERMINAL_VERSION]:
		return DecodeCode.UNSUPPORTED_VERSION
	if bytes.size() < FIXED_BYTES:
		return DecodeCode.MALFORMED
	var players: int = bytes.decode_u8(6)
	var width: int = bytes.decode_u32(7)
	var frames: int = bytes.decode_u32(11)
	var skipped: int = bytes.decode_u32(15)
	var prediction: int = bytes.decode_u8(21)
	var sync_test: int = bytes.decode_u8(22)
	if not valid_shape(players, width, frames, version) or skipped > frames or prediction > 128 or sync_test > 1:
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
	var status_bytes: int = players if version >= 5 else 0
	if frames * (row + status_bytes + 1 + DIGEST_BYTES) > bytes.size() - cursor:
		return DecodeCode.MALFORMED
	var neutral_row: PackedByteArray = PackedByteArray()
	for player: int in range(players):
		neutral_row.append_array(neutral)
	var inputs: PackedByteArray = PackedByteArray()
	var checksums: PackedByteArray = PackedByteArray()
	var flags: PackedByteArray = PackedByteArray()
	var digests: PackedByteArray = PackedByteArray()
	var statuses: PackedByteArray = PackedByteArray()
	var skipped_seen: int = 0
	for frame: int in range(frames):
		var flag: int = bytes[cursor + row + status_bytes] if cursor + row + status_bytes < bytes.size() else 0xff
		var end: int = cursor + row + status_bytes + 1 + (CHECKSUM_BYTES if flag == FLAG_CHECKSUM else 0)
		if (flag != 0 and flag != FLAG_CHECKSUM and flag != FLAG_SKIPPED) or end + DIGEST_BYTES > bytes.size():
			return DecodeCode.MALFORMED
		var input_row: PackedByteArray = bytes.slice(cursor, cursor + row)
		if flag == FLAG_SKIPPED and input_row != neutral_row:
			return DecodeCode.MALFORMED
		for player: int in range(players):
			var status: int = bytes[cursor + row + player] if version >= 5 else Queue.Status.CONFIRMED
			if status not in [Queue.Status.CONFIRMED, Queue.Status.DISCONNECTED] or (flag == FLAG_SKIPPED and status != Queue.Status.CONFIRMED):
				return DecodeCode.MALFORMED
			statuses.append(status)
		skipped_seen += int(flag == FLAG_SKIPPED)
		inputs.append_array(input_row)
		flags.append(flag)
		if flag == FLAG_CHECKSUM:
			checksums.append_array(bytes.slice(cursor + row + status_bytes + 1, end))
		else:
			checksums.resize(checksums.size() + CHECKSUM_BYTES)
		digests.append_array(bytes.slice(end, end + DIGEST_BYTES))
		cursor = end + DIGEST_BYTES
	var terminal: PackedByteArray = PackedByteArray()
	if version == TERMINAL_VERSION:
		if bytes.size() - cursor != CHECKSUM_BYTES or skipped > 0:
			return DecodeCode.MALFORMED
		terminal = bytes.slice(cursor)
		cursor += CHECKSUM_BYTES
	if cursor != bytes.size() or skipped_seen != skipped:
		return DecodeCode.MALFORMED
	_terminal_checksum = terminal
	_format_version = version
	_statuses = statuses
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
	_digests = digests
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


## Whether this recording can drive a session configured with config: the same roster, sample
## width, neutral input, game seed and game version. A mismatch means the recorded inputs cannot
## reproduce that game's states, so a player must refuse the recording.
## Only FortressConfig instances (including subclasses) are accepted; unrelated objects return false.
func matches_config(config: RefCounted) -> bool:
	# Config preloads Replay, so resolve its script here rather than creating a preload cycle.
	if config == null or not is_instance_of(config, load("res://addons/fortress_rollback/core/config.gd")) or _text.size() != TEXT_FIELDS:
		return false
	return (
		_players == config.player_count
		and _width == config.input_width
		and _neutral == config.neutral_input
		and _text[3] == config.diagnostic_seed
		and _text[4] == config.diagnostic_version
	)


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


## Fresh finalized inputs and confirmed/disconnected player statuses for one frame, in the same form simulate_frame receives during a session.
func inputs(frame: int) -> Types.FrameInputs:
	if frame < 0 or frame >= _frames:
		return null
	var bytes: Array[PackedByteArray] = []
	var statuses: PackedInt32Array = PackedInt32Array()
	var row: int = _players * _width
	for player: int in range(_players):
		bytes.append(_inputs.slice(frame * row + player * _width, frame * row + (player + 1) * _width))
		statuses.append(_statuses[frame * _players + player])
	return Types.FrameInputs.new(bytes, statuses)


## Empty when no state checksum was recorded at this boundary. Version 6 also permits frame_count().
func checksum(frame: int) -> PackedByteArray:
	if frame == _frames:
		return _terminal_checksum.duplicate()
	if frame < 0 or frame >= _frames or _flags[frame] != FLAG_CHECKSUM:
		return PackedByteArray()
	return _checksums.slice(frame * CHECKSUM_BYTES, (frame + 1) * CHECKSUM_BYTES)


## The digest recorded for one frame's input row. A decoded file keeps the digest it carried, so a
## corrupted row cannot silently agree with it.
func input_digest(frame: int) -> PackedByteArray:
	if frame < 0 or frame >= _frames:
		return PackedByteArray()
	return _digests.slice(frame * DIGEST_BYTES, (frame + 1) * DIGEST_BYTES)


## The digest computed from one frame's stored input row. It differs from the recorded digest
## exactly when the row or its recorded digest was changed after the file was written.
func computed_input_digest(frame: int) -> PackedByteArray:
	if frame < 0 or frame >= _frames:
		return PackedByteArray()
	var row: int = _players * _width
	var payload: PackedByteArray = _inputs.slice(frame * row, (frame + 1) * row)
	if _format_version >= 5:
		payload.append_array(_statuses.slice(frame * _players, (frame + 1) * _players))
	return digest_row(payload)


## Return a portable file, or empty for malformed storage or incomplete input digests.
## Preserve stored digest/checksum evidence without recomputing it; playback owns content comparisons.
func to_bytes() -> PackedByteArray:
	if not is_valid() or _digests.size() != _frames * DIGEST_BYTES:
		return PackedByteArray()
	var bytes: PackedByteArray = MAGIC.to_ascii_buffer()
	bytes.resize(FIXED_BYTES)
	bytes.encode_u16(4, _format_version)
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
		if _format_version >= 5:
			bytes.append_array(_statuses.slice(frame * _players, (frame + 1) * _players))
		bytes.append(_flags[frame])
		if _flags[frame] == FLAG_CHECKSUM:
			bytes.append_array(_checksums.slice(frame * CHECKSUM_BYTES, (frame + 1) * CHECKSUM_BYTES))
		bytes.append_array(_digests.slice(frame * DIGEST_BYTES, (frame + 1) * DIGEST_BYTES))
	if _format_version == TERMINAL_VERSION:
		bytes.append_array(_terminal_checksum)
	return bytes


func owned_copy() -> RefCounted:
	var copy: RefCounted = get_script().new()
	copy._format_version = _format_version
	copy._terminal_checksum = _terminal_checksum.duplicate()
	copy._statuses = _statuses.duplicate()
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
	copy._digests = _digests.duplicate()
	return copy


## Export only finalized history while keeping receipt-only rows private for later confirmation.
func owned_prefix(frames: int) -> RefCounted:
	var copy: RefCounted = owned_copy()
	copy._frames = clampi(frames, 0, _frames)
	copy._inputs.resize(copy._frames * _players * _width)
	copy._statuses.resize(copy._frames * _players)
	copy._checksums.resize(copy._frames * CHECKSUM_BYTES)
	copy._flags.resize(copy._frames)
	copy._digests.resize(copy._frames * DIGEST_BYTES)
	copy._skipped = copy._flags.count(FLAG_SKIPPED)
	if copy._frames != _frames:
		copy._terminal_checksum.clear()
		copy._format_version = FORMAT_VERSION if _format_version == TERMINAL_VERSION else _format_version
	return copy


## A coordinated drop may replace receipt-only rows beyond the mesh-confirmed cut.
## Preserve other players' retained bytes, including rows the live queue already released.
func _freeze_player(player: int, cut: int, value: PackedByteArray) -> void:
	if _frames > cut + 1:
		_terminal_checksum.clear()
		_format_version = FORMAT_VERSION
	for frame: int in range(cut + 1, _frames):
		if _flags[frame] == FLAG_SKIPPED:
			continue
		var offset: int = (frame * _players + player) * _width
		for index: int in range(_width):
			_inputs[offset + index] = value[index]
		_statuses[frame * _players + player] = Queue.Status.DISCONNECTED
		if frame > cut + 1:
			_flags[frame] = 0
		var digest: PackedByteArray = computed_input_digest(frame)
		for index: int in range(DIGEST_BYTES):
			_digests[frame * DIGEST_BYTES + index] = digest[index]


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


func _append(row: PackedByteArray, saved_checksum: PackedByteArray, skipped: bool, statuses: PackedByteArray = PackedByteArray()) -> void:
	_terminal_checksum.clear()
	_format_version = FORMAT_VERSION
	_inputs.append_array(row)
	for player: int in range(_players):
		_statuses.append(statuses[player] if not statuses.is_empty() and not skipped else Queue.Status.CONFIRMED)
	var flag: int = FLAG_SKIPPED if skipped else (FLAG_CHECKSUM if saved_checksum.size() == CHECKSUM_BYTES else 0)
	_flags.append(flag)
	if flag == FLAG_CHECKSUM:
		_checksums.append_array(saved_checksum)
	else:
		_checksums.resize(_checksums.size() + CHECKSUM_BYTES)
	# The digest covers the stored bytes, not the caller's array.
	_frames += 1
	_digests.append_array(computed_input_digest(_frames - 1))
	_skipped += int(skipped)
