class_name FortressOfflineSimulation
extends RefCounted

# gdlint: disable=max-returns

const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Writer = preload("res://addons/fortress_rollback/core/snapshot_writer.gd")
const Reader = preload("res://addons/fortress_rollback/core/snapshot_reader.gd")
const SNAPSHOT_BYTES: int = 136
const FORMAT_VERSION: int = 1
const MAX_FRAME: int = 2147483647
const LEFT: int = 1
const RIGHT: int = 2
const UP: int = 4
const DOWN: int = 8

var frame: int = 0
var rng_state: int = 1701
var x: PackedInt32Array = PackedInt32Array([120, 360])
var y: PackedInt32Array = PackedInt32Array([160, 160])
var pending_frame: PackedInt64Array = PackedInt64Array([-1, -1])
var pending_color: PackedInt32Array = PackedInt32Array([0, 0])
var event_id: PackedInt64Array = PackedInt64Array([0, 0])
var event_frame: PackedInt64Array = PackedInt64Array([-1, -1])
var color: PackedInt32Array = PackedInt32Array([0, 1])
# Scratch input copies are overwritten before use and never affect saved state.
var _input_sample: PackedByteArray = PackedByteArray([0])
var _samples: PackedByteArray = PackedByteArray([0, 0])


## Full fixed-width little-endian state, including delayed effects and random state.
func canonical_bytes() -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(SNAPSHOT_BYTES)
	bytes.encode_s64(0, FORMAT_VERSION)
	bytes.encode_s64(8, frame)
	bytes.encode_s64(16, rng_state)
	for player: int in range(2):
		var offset: int = 24 + player * 56
		var fields: Array[int] = [x[player], y[player], pending_frame[player], pending_color[player], event_id[player], event_frame[player], color[player]]
		for index: int in range(fields.size()):
			bytes.encode_s64(offset + index * 8, fields[index])
	return bytes


func save_state(saved_frame: int, writer: Writer) -> Driver.SaveResult:
	if saved_frame != frame:
		return Driver.SaveResult.new(false)
	var bytes: PackedByteArray = canonical_bytes()
	return Driver.SaveResult.new(writer.write_bytes(bytes) == Writer.Code.OK, checksum(bytes))


func load_state(saved_frame: int, reader: Reader) -> bool:
	var result: Reader.ReadResult = reader.read_bytes(SNAPSHOT_BYTES)
	if result.code != Reader.Code.OK or not reader.is_complete():
		return false
	var bytes: PackedByteArray = result.bytes
	if not _is_valid_snapshot(bytes, saved_frame):
		return false
	frame = saved_frame
	rng_state = bytes.decode_s64(16)
	for player: int in range(2):
		var offset: int = 24 + player * 56
		x[player] = bytes.decode_s64(offset)
		y[player] = bytes.decode_s64(offset + 8)
		pending_frame[player] = bytes.decode_s64(offset + 16)
		pending_color[player] = bytes.decode_s64(offset + 24)
		event_id[player] = bytes.decode_s64(offset + 32)
		event_frame[player] = bytes.decode_s64(offset + 40)
		color[player] = bytes.decode_s64(offset + 48)
	return true


func _is_valid_snapshot(bytes: PackedByteArray, saved_frame: int) -> bool:
	if saved_frame < 0 or saved_frame > MAX_FRAME or bytes.decode_s64(0) != FORMAT_VERSION or bytes.decode_s64(8) != saved_frame:
		return false
	var random_state: int = bytes.decode_s64(16)
	if random_state < 0 or random_state > 0x7fffffff:
		return false
	for player: int in range(2):
		var offset: int = 24 + player * 56
		var position_x: int = bytes.decode_s64(offset)
		var position_y: int = bytes.decode_s64(offset + 8)
		var pending: int = bytes.decode_s64(offset + 16)
		var pending_tint: int = bytes.decode_s64(offset + 24)
		var pulse_id: int = bytes.decode_s64(offset + 32)
		var pulse_frame: int = bytes.decode_s64(offset + 40)
		var tint: int = bytes.decode_s64(offset + 48)
		if position_x < 20 or position_x > 460 or position_y < 20 or position_y > 280:
			return false
		if pending_tint < 0 or pending_tint > 3 or tint < 0 or tint > 3:
			return false
		if pending != -1 and (pending < saved_frame or pending > saved_frame + 2 or pending % 20 != 3):
			return false
		if pulse_frame < -1 or pulse_frame >= saved_frame:
			return false
		if pulse_frame >= 0 and pulse_frame % 20 != 3:
			return false
		var expected_id: int = 0 if pulse_frame == -1 else pulse_frame * 2 + player + 1
		if pulse_id != expected_id:
			return false
	return true


func simulate_frame(input_frame: int, inputs: Types.FrameInputs) -> bool:
	if input_frame != frame or frame < 0 or frame >= MAX_FRAME:
		return false
	if inputs.player_count() != 2:
		return false
	for player: int in range(2):
		if inputs.read_into(player, _input_sample) != Types.Code.OK or _input_sample[0] > 15:
			return false
		_samples[player] = _input_sample[0]
	for player: int in range(2):
		var buttons: int = _samples[player]
		x[player] = clampi(x[player] + 2 * (int(bool(buttons & RIGHT)) - int(bool(buttons & LEFT))), 20, 460)
		y[player] = clampi(y[player] + 2 * (int(bool(buttons & DOWN)) - int(bool(buttons & UP))), 20, 280)
		if pending_frame[player] == frame:
			color[player] = pending_color[player]
			event_id[player] = frame * 2 + player + 1
			event_frame[player] = frame
			pending_frame[player] = -1
		# The 31-bit LCG product fits signed 64-bit; no global or engine RNG.
		rng_state = (rng_state * 1103515245 + 12345) & 0x7fffffff
		if frame % 20 == 0:
			pending_color[player] = (rng_state >> 16) % 4
			pending_frame[player] = frame + 3
	frame += 1
	return true


## Four specified FNV-1a 32-bit lanes form the driver's 16-byte checksum domain.
static func checksum(bytes: PackedByteArray) -> PackedByteArray:
	var result: PackedByteArray = PackedByteArray()
	result.resize(16)
	for lane: int in range(4):
		var value: int = (2166136261 + lane) & 0xffffffff
		for byte: int in bytes:
			value = ((value ^ byte) * 16777619) & 0xffffffff
		result.encode_u32(lane * 4, value)
	return result
