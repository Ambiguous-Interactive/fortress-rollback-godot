class_name FortressIntegrationGame
extends RefCounted

# gdlint: disable=max-returns

## Smallest complete rollback game: two players move left/right and fire shots.
## Firing depends on input, so a mispredicted remote input can create a shot
## that rollback later removes. See effects.gd for how presentation handles it.

const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Writer = preload("res://addons/fortress_rollback/core/snapshot_writer.gd")
const Reader = preload("res://addons/fortress_rollback/core/snapshot_reader.gd")
const REPLAY_VERSION: String = "fortress-integration-v1"
const REPLAY_SEED: String = "fixed-initial-state-v1"
const LEFT: int = 1
const RIGHT: int = 2
const FIRE: int = 4
const FORMAT_VERSION: int = 1
const MAX_FRAME: int = 2147483647
const COOLDOWN: int = 6
const MIN_X: int = 0
const MAX_X: int = 400
## Must be at least the shots awaiting confirmation: 2 players x ceil((prediction 8 + 1) / 6) = 4.
const SHOT_SLOTS: int = 8
const SNAPSHOT_BYTES: int = (7 + SHOT_SLOTS) * 8

var frame: int = 0
var x: PackedInt64Array = PackedInt64Array([100, 300])
var cooldown: PackedInt64Array = PackedInt64Array([0, 0])
var shot_total: int = 0
# Scratch input copies are overwritten before use and never affect saved state.
var _input_sample: PackedByteArray = PackedByteArray([0])
var _buttons: PackedByteArray = PackedByteArray([0, 0])
## Ring of shot IDs. ID = frame * 2 + player + 1, so IDs increase with frame.
var shot_ids: PackedInt64Array = _empty_shots()


static func shot_frame(id: int) -> int:
	return (id - 1) >> 1


static func shot_player(id: int) -> int:
	return (id - 1) & 1


## Every field the simulation reads, as fixed-width little-endian integers.
func canonical_bytes() -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(SNAPSHOT_BYTES)
	var fields: Array[int] = [FORMAT_VERSION, frame, x[0], x[1], cooldown[0], cooldown[1], shot_total]
	for index: int in range(fields.size()):
		bytes.encode_s64(index * 8, fields[index])
	for slot: int in range(SHOT_SLOTS):
		bytes.encode_s64((fields.size() + slot) * 8, shot_ids[slot])
	return bytes


func save_state(saved_frame: int, writer: Writer) -> Driver.SaveResult:
	if saved_frame != frame:
		return Driver.SaveResult.new(false)
	var bytes: PackedByteArray = canonical_bytes()
	var hashing: HashingContext = HashingContext.new()
	hashing.start(HashingContext.HASH_MD5)
	hashing.update(bytes)
	# MD5 yields exactly the 16 checksum bytes the session expects; it is not a security boundary.
	return Driver.SaveResult.new(writer.write_bytes(bytes) == Writer.Code.OK, hashing.finish())


## Validate everything before changing state, so a bad snapshot leaves the game untouched.
func load_state(saved_frame: int, reader: Reader) -> bool:
	var result: Reader.ReadResult = reader.read_bytes(SNAPSHOT_BYTES)
	if result.code != Reader.Code.OK or not reader.is_complete():
		return false
	var bytes: PackedByteArray = result.bytes
	if bytes.decode_s64(0) != FORMAT_VERSION or bytes.decode_s64(8) != saved_frame or saved_frame < 0 or saved_frame > MAX_FRAME:
		return false
	for player: int in range(2):
		var position: int = bytes.decode_s64(16 + player * 8)
		var wait: int = bytes.decode_s64(32 + player * 8)
		if position < MIN_X or position > MAX_X or wait < 0 or wait >= COOLDOWN:
			return false
	# At most one shot per player per frame bounds the total; ring IDs rise from oldest to newest.
	var total: int = bytes.decode_s64(48)
	if total < 0 or total > saved_frame * 2:
		return false
	var previous_id: int = 0
	for age: int in range(SHOT_SLOTS):
		var count: int = total - SHOT_SLOTS + age
		var id: int = bytes.decode_s64(56 + posmod(count, SHOT_SLOTS) * 8)
		if count < 0:
			if id != 0:
				return false
		elif id <= previous_id or shot_frame(id) >= saved_frame:
			return false
		else:
			previous_id = id
	frame = saved_frame
	for player: int in range(2):
		x[player] = bytes.decode_s64(16 + player * 8)
		cooldown[player] = bytes.decode_s64(32 + player * 8)
	shot_total = total
	for slot: int in range(SHOT_SLOTS):
		shot_ids[slot] = bytes.decode_s64(56 + slot * 8)
	return true


func simulate_frame(input_frame: int, inputs: Types.FrameInputs) -> bool:
	if input_frame != frame or frame >= MAX_FRAME:
		return false
	if inputs.player_count() != 2:
		return false
	for player: int in range(2):
		if inputs.read_into(player, _input_sample) != Types.Code.OK or _input_sample[0] > 7:
			return false
		_buttons[player] = _input_sample[0]
	for player: int in range(2):
		var pressed: int = _buttons[player]
		x[player] = clampi(x[player] + 4 * (int(bool(pressed & RIGHT)) - int(bool(pressed & LEFT))), MIN_X, MAX_X)
		if cooldown[player] > 0:
			cooldown[player] -= 1
		elif pressed & FIRE:
			cooldown[player] = COOLDOWN - 1
			shot_ids[shot_total % SHOT_SLOTS] = frame * 2 + player + 1
			shot_total += 1
	frame += 1
	return true


static func _empty_shots() -> PackedInt64Array:
	var shots: PackedInt64Array = PackedInt64Array()
	shots.resize(SHOT_SLOTS)
	return shots
