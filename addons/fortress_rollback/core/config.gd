class_name FortressConfig
extends RefCounted

# gdlint: disable=max-returns

const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const MAX_WINDOW: int = 128
const MAX_STORAGE_BYTES: int = 67108864

var player_count: int = 2
var local_players: PackedInt32Array = PackedInt32Array([0, 1])
var input_width: int = 1
var neutral_input: PackedByteArray = PackedByteArray([0])
var input_delay: int = 0
var max_prediction_frames: int = 8
var check_distance: int = 2
var queue_capacity: int = 128
var history_slots: int = 9
var max_snapshot_bytes: int = 0
var storage_budget_bytes: int = 0
var checksums_enabled: bool = true
var capture_confirmed_snapshots: bool = false
var sync_test: bool = true
## Canonical game payloads are private unless explicitly opted in with a positive bound.
var diagnostic_trace_frames: int = 0
var diagnostic_seed: String = ""
var diagnostic_version: String = ""
var diagnostic_replay_command: String = ""


## Validate bounded storage before allocating. Snapshot size and budget are explicit.
func validate() -> int:
	if diagnostic_trace_frames < 0 or diagnostic_trace_frames > MAX_WINDOW:
		return Types.Code.INVALID_CONFIGURATION
	if diagnostic_seed.to_utf8_buffer().size() > 128 or diagnostic_version.to_utf8_buffer().size() > 128 or diagnostic_replay_command.to_utf8_buffer().size() > 512:
		return Types.Code.INVALID_CONFIGURATION
	if player_count < 2 or player_count > 8 or input_width < 1 or input_width > 65536 or neutral_input.size() != input_width:
		return Types.Code.INVALID_CONFIGURATION
	if max_prediction_frames < 0 or max_prediction_frames > MAX_WINDOW or check_distance < 0 or check_distance > max_prediction_frames:
		return Types.Code.INVALID_CONFIGURATION
	if capture_confirmed_snapshots and (sync_test or not checksums_enabled):
		return Types.Code.INVALID_CONFIGURATION
	if not sync_test and check_distance != 0:
		return Types.Code.INVALID_CONFIGURATION
	if queue_capacity < 2 or queue_capacity > 65536 or input_delay < 0 or input_delay >= queue_capacity:
		return Types.Code.INVALID_CONFIGURATION
	if queue_capacity < input_delay + maxi(max_prediction_frames, check_distance) + 2:
		return Types.Code.INVALID_CONFIGURATION
	if history_slots < maxi(max_prediction_frames, check_distance) + 1 or history_slots > 65536:
		return Types.Code.INVALID_CONFIGURATION
	if max_snapshot_bytes < 1 or max_snapshot_bytes > 16777216 or storage_budget_bytes < 1 or storage_budget_bytes > MAX_STORAGE_BYTES:
		return Types.Code.INVALID_CONFIGURATION
	if (queue_capacity + 1) * input_width > 16777216 or required_storage_bytes() > storage_budget_bytes:
		return Types.Code.INVALID_CONFIGURATION
	if local_players.is_empty() or local_players.size() > player_count or (sync_test and local_players.size() != player_count):
		return Types.Code.INVALID_CONFIGURATION
	var seen: PackedByteArray = PackedByteArray()
	seen.resize(player_count)
	for player: int in local_players:
		if player < 0 or player >= player_count or seen[player] != 0:
			return Types.Code.INVALID_CONFIGURATION
		seen[player] = 1
	return Types.Code.OK


## Payload reservation includes snapshot staging/views and first-save comparison history.
## Runtime object metadata adds bounded overhead; this is not a heap-size guarantee.
func required_storage_bytes() -> int:
	return (
		diagnostic_trace_storage_bytes()
		+ (history_slots + 2) * max_snapshot_bytes
		+ history_slots * 40
		+ history_slots * (max_snapshot_bytes + 16)
		+ player_count * ((queue_capacity + 1) * input_width + queue_capacity * 8 + 6 * input_width)
	)


## Exact canonical payload ceiling; bounded object metadata is reserved separately.
func diagnostic_trace_payload_bytes() -> int:
	return diagnostic_trace_frames * (max_snapshot_bytes + 16 + player_count * input_width)


func diagnostic_trace_storage_bytes() -> int:
	if diagnostic_trace_frames == 0:
		return 0
	return diagnostic_trace_payload_bytes() + diagnostic_trace_frames * (40 + player_count * 16) + 1024


func owned_copy() -> RefCounted:
	var copy: RefCounted = get_script().new()
	copy.player_count = player_count
	copy.local_players = local_players.duplicate()
	copy.input_width = input_width
	copy.neutral_input = neutral_input.duplicate()
	copy.input_delay = input_delay
	copy.max_prediction_frames = max_prediction_frames
	copy.check_distance = check_distance
	copy.queue_capacity = queue_capacity
	copy.history_slots = history_slots
	copy.max_snapshot_bytes = max_snapshot_bytes
	copy.storage_budget_bytes = storage_budget_bytes
	copy.checksums_enabled = checksums_enabled
	copy.capture_confirmed_snapshots = capture_confirmed_snapshots
	copy.sync_test = sync_test
	copy.diagnostic_trace_frames = diagnostic_trace_frames
	copy.diagnostic_seed = diagnostic_seed
	copy.diagnostic_version = diagnostic_version
	copy.diagnostic_replay_command = diagnostic_replay_command
	return copy
