extends RefCounted

# Value: protects=users distinguish verified replay boundaries from unchecked playback; fails_when=missing checksums report full verification;
# why_new=viewer tests use a checksum at every frame and cannot expose unverified recordings; seam=none
const Fixture = preload("res://tests/unit/test_replay_viewer.gd")
const Viewer = preload("res://examples/online/replay_viewer.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Scene = preload("res://examples/online/replay.tscn")


func cases() -> PackedStringArray:
	return PackedStringArray(["coverage", "counting", "unchecked_seek"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "unchecked_seek":
		_unchecked_seek(context)
	elif name == "counting":
		_counting(context)
	else:
		_coverage(context)
	context.finish()


func _coverage(context: RefCounted) -> void:
	for interval: int in [0, 1, 3]:
		var replay: Replay = Fixture.recording(12)
		for frame: int in replay.frame_count():
			if interval == 0 or frame % interval != 0:
				replay._flags[frame] = 0
		var count: int = 0 if interval == 0 else 12 / interval
		var node: Node2D = Scene.instantiate()
		node._ready()
		context.equal(node.viewer.open_bytes(replay.to_bytes()), true, "valid checksum coverage imports")
		context.equal(node.viewer.recorded_checksum_count(), count, "only recorded checksums count")
		node._refresh()
		context.equal(_has_coverage(node, 0, count), true, "visible status distinguishes sparse and absent checksums")
		node.viewer.toggle_play()
		for tick: int in 12:
			node._physics_process(0.0)
		context.equal(node.viewer.current_frame(), 12, "missing checksums do not prevent input playback")
		context.equal(_has_coverage(node, count, count), true, "completion preserves checksum coverage")
		context.equal(node.viewer.message.contains("could not be verified"), interval == 0, "completion discloses wholly unchecked playback")
		context.equal(node.viewer.open_bytes(PackedByteArray([0])), false, "invalid import rejected")
		context.equal(node.viewer.recorded_checksum_count(), count, "failed import preserves prior coverage")
		context.equal(node.viewer.checked_checksum_count(), count, "failed import preserves verified checksums")
		node.viewer.restart()
		context.equal(node.viewer.recorded_checksum_count(), count, "restart preserves coverage")
		context.equal(node.viewer.checked_checksum_count(), 0, "restart requires fresh verification")
		context.state(interval, node.viewer.game.canonical_bytes())
		node._exit_tree()
		node.free()


func _has_coverage(node: Node, checked: int, count: int) -> bool:
	for label: Node in node.find_children("*", "Label", true, false):
		if label.text.contains("Checksums checked: %d / %d recorded" % [checked, count]):
			return true
	return false


func _counting(context: RefCounted) -> void:
	for validates: bool in [false, true]:
		var player: Player = Player.new()
		var replay: Replay = Fixture.recording(12)
		context.equal(
			player.configure(replay, Simulation.new(), Simulation.SNAPSHOT_BYTES if validates else 0, 3 if validates else 0, 4 if validates else 0),
			Types.Code.OK,
			"configure bounded checksum validation or input-only playback"
		)
		for frame: int in 12:
			context.equal(player.step(), Types.Code.OK, "play each recorded frame")
		context.equal(player.checked_checksum_count(), 12 if validates else 0, "only compared checksums count")
		if validates:
			context.equal(player.restore_before(4), Types.Code.OK, "restore previously validated checkpoint")
			context.equal(player.current_frame(), 3, "restore nearest cached boundary")
			context.equal(player.validate_current_frame(), Types.Code.OK, "recheck cached checksum")
			for frame: int in range(3, 12):
				context.equal(player.step(), Types.Code.OK, "replay validated prefix")
			context.equal(player.checked_checksum_count(), 12, "navigation and repeat validation never double-count")
		context.equal(player.configure(Replay.new(), Simulation.new()), Types.Code.INVALID_CONFIGURATION, "refused configure")
		context.equal(player.checked_checksum_count(), 12 if validates else 0, "refused configure preserves count")
		context.equal(player.configure(replay, Simulation.new(), Simulation.SNAPSHOT_BYTES), Types.Code.OK, "new playback lifetime")
		context.equal(player.checked_checksum_count(), 0, "configure clears prior verified coverage")
	var viewer: Viewer = Viewer.new()
	var replay: Replay = Fixture.recording(12)
	replay._checksums[8 * 16] ^= 1
	viewer.open_bytes(replay.to_bytes())
	viewer.seek(12)
	viewer.tick()
	context.equal(viewer.current_frame(), 8, "control reaches mismatch")
	context.equal(viewer.checked_checksum_count(), 8, "failed comparison is excluded from verified coverage")
	context.equal(viewer.recorded_checksum_count(), 12, "failure keeps total recorded coverage")
	viewer.seek(3)
	viewer.tick()
	context.equal(viewer.checked_checksum_count(), 4, "recovering from failure starts a fresh verified prefix")
	context.state(viewer.current_frame(), viewer.game.canonical_bytes())


func _unchecked_seek(context: RefCounted) -> void:
	var replay: Replay = Fixture.recording(130)
	replay._flags.fill(0)
	var viewer: Viewer = Viewer.new()
	context.equal(viewer.open_bytes(replay.to_bytes()), true, "unchecked long recording imports")
	context.equal(viewer.message.contains("no checksums"), true, "ready message discloses absent verification")
	viewer.toggle_play()
	context.equal(viewer.message.contains("no checksums"), true, "playing message discloses absent verification")
	context.equal(viewer.seek(130), true, "unchecked long seek accepted")
	context.equal(viewer.message.contains("no checksums"), true, "seeking message discloses absent verification")
	viewer.tick()
	context.equal(viewer.current_frame(), 120, "unchecked seeking retains bounded tick work")
	context.equal(viewer.message.contains("no checksums"), true, "ongoing seek preserves truthful verification message")
	viewer.cancel_seek()
	context.equal(viewer.checked_checksum_count(), 0, "cancel cannot claim unchecked boundaries verified")
	viewer.seek(130)
	viewer.tick()
	context.equal(viewer.message.contains("could not be verified"), true, "seek completion discloses absent verification")
	context.equal(viewer.checked_checksum_count(), 0, "seek completion never counts cache snapshots as recorded comparisons")
	context.state(viewer.current_frame(), viewer.game.canonical_bytes())
