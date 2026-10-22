extends RefCounted

# Value: protects=the mesh checksum scheduler; fails_when=a pending repair ends the match or a lost snapshot passes
# why_new=a rollback correction withheld the checksum snapshot; seam=none
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Checksums = preload("res://addons/fortress_rollback/core/peer_checksums.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Game = preload("res://tests/oracle/p2p_game.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["pending_repair_is_not_a_loss", "lost_snapshot_still_fails", "lost_snapshot_under_a_repair_still_fails"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"pending_repair_is_not_a_loss":
			_pending_repair_is_not_a_loss(context)
		"lost_snapshot_still_fails":
			_lost_snapshot_still_fails(context)
		"lost_snapshot_under_a_repair_still_fails":
			_lost_snapshot_under_a_repair_still_fails(context)
	context.finish()


# The scheduler must not treat a snapshot that a pending repair withheld as a
# lost history. The next advance resimulates those frames, so the checksum is
# late, not lost, and the match keeps running.
func _pending_repair_is_not_a_loss(context: RefCounted) -> void:
	var core: Session = Session.new()
	context.equal(core.configure(_config()), Types.Code.OK, "configures")
	var driver: Driver = Driver.new()
	context.equal(driver.configure(core, Game.new(2)), Types.Code.OK, "configures the driver")
	# The remote confirms frames 0..5 with one value.
	for frame: int in range(6):
		core.receive_input(1, frame, PackedByteArray([2, 0, 0, 0]))
		context.equal(driver.step(frame, [Driver.LocalInput.new(0, frame, _neutral())]).code, Types.Code.OK, "advances frame %d" % frame)
	# The remote goes silent, so the session predicts the same value ahead.
	for frame: int in range(6, 12):
		context.equal(driver.step(frame, [Driver.LocalInput.new(0, frame, _neutral())]).code, Types.Code.OK, "predicts frame %d" % frame)
	context.equal(core.status().pending_rollback_frame, -1, "no repair is pending yet")
	# The remote delivers the same frames with a different value at frame 6.
	# The correction is a pending repair, not a lost history.
	core.receive_input(1, 6, PackedByteArray([3, 0, 0, 0]))
	for frame: int in range(7, 12):
		core.receive_input(1, frame, PackedByteArray([2, 0, 0, 0]))
	context.equal(core.status().pending_rollback_frame, 6, "the correction is pending")
	context.equal(core.status().current_frame, 12, "the session advanced past the boundary")
	context.equal(core.status().confirmed_frame, 11, "the remote confirmed the boundary")
	var checksums: Checksums = Checksums.new()
	checksums.configure([_peer()], 1, 128, 128)
	checksums.sent(_peer(), 10)
	context.equal(checksums.status().next_frame, 11, "the next boundary is the withheld frame")
	var scheduled: Dictionary = checksums.scheduled(core, core.status().confirmed_frame)
	context.equal(scheduled, {}, "the withheld checksum is not scheduled yet")
	context.equal(checksums.failure, {}, "a pending repair is not a lost history")


# A snapshot that no repair will restore is a lost history and must still end
# the match, so the repair cannot hide a real loss behind a retry.
func _lost_snapshot_still_fails(context: RefCounted) -> void:
	var checksums: Checksums = Checksums.new()
	checksums.configure([_peer()], 1, 128, 128)
	checksums.sent(_peer(), 10)
	var core: LostCore = LostCore.new()
	context.equal(checksums.scheduled(core, 100), {}, "no checksum is scheduled")
	context.equal(checksums.failure.get("kind"), "checksum_history_unavailable", "the lost history is reported")
	context.equal(checksums.failure.get("frame"), 11, "the lost frame is named")


# A pending repair must not hide a snapshot that the repair cannot restore. The
# scheduler waits for the repair, and the history loss is reported once the
# repair no longer explains the missing snapshot.
func _lost_snapshot_under_a_repair_still_fails(context: RefCounted) -> void:
	var core: LostCore = LostCore.new()
	core.repair_frame = 6
	var checksums: Checksums = Checksums.new()
	checksums.configure([_peer()], 1, 128, 128)
	checksums.sent(_peer(), 10)
	context.equal(checksums.scheduled(core, 100), {}, "the boundary waits for the repair")
	context.equal(checksums.failure, {}, "the pending repair is not a loss yet")
	core.repair_frame = -1
	context.equal(checksums.scheduled(core, 100), {}, "no checksum is scheduled")
	context.equal(checksums.failure.get("kind"), "checksum_history_unavailable", "the lost history is reported")
	context.equal(checksums.failure.get("frame"), 11, "the lost frame is named")


# A core whose snapshot at the boundary is gone and no repair will restore it.
class LostCore extends RefCounted:
	var repair_frame: int = -1

	func status() -> RefCounted:
		var result: Types.Status = Types.Status.new()
		result.current_frame = 12
		result.confirmed_frame = 11
		result.pending_rollback_frame = repair_frame
		return result


	func confirmed_checksums(_include_boundary: bool = false) -> Array[Dictionary]:
		return []


func _peer() -> PackedByteArray:
	return PackedByteArray([1, 2, 3, 4])


func _neutral() -> PackedByteArray:
	return PackedByteArray([0, 0, 0, 0])


func _config() -> Config:
	var config: Config = Config.new()
	config.sync_test = false
	config.check_distance = 0
	config.local_players = PackedInt32Array([0])
	config.input_width = 4
	config.neutral_input = PackedByteArray([0, 0, 0, 0])
	config.max_prediction_frames = 8
	config.queue_capacity = 128
	config.history_slots = 32
	config.checksums_enabled = true
	config.capture_confirmed_snapshots = true
	config.max_snapshot_bytes = 20
	config.storage_budget_bytes = 1048576
	return config
