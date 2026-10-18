extends RefCounted

# Value: protects=users can watch downloaded online recordings safely; fails_when=controls drift, imports accept incompatible games or checksum failures continue;
# why_new=core replay tests have no example loading or playback controls; seam=none
const Viewer = preload("res://examples/online/replay_viewer.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["controls", "rejects_incompatible", "stops_at_divergence"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"controls":
			_controls(context)
		"rejects_incompatible":
			_rejects_incompatible(context)
		"stops_at_divergence":
			_stops_at_divergence(context)
	context.finish()


static func recording(frames: int = 24) -> Replay:
	var config: Config = Config.new()
	config.diagnostic_version = Viewer.GAME_VERSION
	config.diagnostic_seed = "1701"
	var replay: Replay = Replay.new()
	replay._start(config)
	var game: Simulation = Simulation.new()
	for frame: int in range(frames):
		var row: PackedByteArray = PackedByteArray([2 if frame < 12 else 8, 1 if frame % 2 == 0 else 4])
		replay._append(row, Simulation.checksum(game.canonical_bytes()), false)
		game.simulate_frame(frame, replay.inputs(frame))
	return replay


func _controls(context: RefCounted) -> void:
	var viewer: Viewer = Viewer.new()
	viewer.step()
	viewer.toggle_play()
	context.equal(viewer.is_playing, false, "empty player stays paused")
	var replay: Replay = recording()
	context.equal(viewer.open_bytes(replay.to_bytes()), true, "opens online replay")
	context.equal(viewer.frame_count(), 24, "knows recorded length")
	viewer.tick()
	context.equal(viewer.current_frame(), 0, "opens paused")
	viewer.step()
	context.equal(viewer.current_frame(), 1, "single step")
	viewer.toggle_play()
	viewer.tick()
	viewer.toggle_play()
	viewer.tick()
	context.equal(viewer.current_frame(), 2, "play then pause")
	viewer.restart()
	context.equal([viewer.current_frame(), viewer.game.frame, viewer.is_playing], [0, 0, false], "restart resets both game and controls")
	var expected: Simulation = Simulation.new()
	viewer.toggle_play()
	for frame: int in range(24):
		viewer.tick()
		expected.simulate_frame(frame, replay.inputs(frame))
		context.bytes_equal(viewer.game.canonical_bytes(), expected.canonical_bytes(), frame, "same recorded canonical state")
	context.equal(viewer.is_playing, false, "completion pauses")
	context.equal(viewer.message.contains("Replay complete"), true, "completion visible")
	viewer.toggle_play()
	viewer.tick()
	context.equal(viewer.current_frame(), 24, "completed playback does not advance")
	context.state(24, viewer.game.canonical_bytes())


func _rejects_incompatible(context: RefCounted) -> void:
	var viewer: Viewer = Viewer.new()
	context.equal(viewer.open_bytes(recording().to_bytes()), true, "healthy control")
	viewer.step()
	viewer.toggle_play()
	var expected: PackedByteArray = viewer.game.canonical_bytes()
	for field: int in range(5):
		var replay: Replay = recording()
		match field:
			0:
				replay._text[4] = "unknown-game"
			1:
				replay._text[3] = "9223372036854775808"
			2:
				replay._text[1] = "incompatible-addon"
			3:
				replay._text[2] = "unknown-upstream"
			4:
				replay._inputs[0] = 255
		context.equal(viewer.open_bytes(replay.to_bytes()), false, "rejects incompatible field %d" % field)
		context.equal(viewer.current_frame(), 1, "failed import retains position")
		context.equal(viewer.is_playing, true, "failed import preserves play state")
		context.bytes_equal(viewer.game.canonical_bytes(), expected, 1, "failed import keeps state")
	var empty: Replay = recording(0)
	context.equal(viewer.open_bytes(empty.to_bytes()), false, "rejects empty file")
	var skipped: Replay = recording()
	skipped._flags[0] = Replay.FLAG_SKIPPED
	skipped._inputs[0] = 0
	skipped._inputs[1] = 0
	skipped._skipped = 1
	context.equal(viewer.open_bytes(skipped.to_bytes()), false, "rejects missing recorded inputs")
	context.equal(viewer.open_bytes(PackedByteArray([0, 1, 2])), false, "rejects malformed file")
	var oversized: PackedByteArray = PackedByteArray()
	oversized.resize(Viewer.MAX_BYTES + 1)
	context.equal(viewer.open_bytes(oversized), false, "bounds file bytes")
	context.state(viewer.current_frame(), viewer.game.canonical_bytes())


func _stops_at_divergence(context: RefCounted) -> void:
	var replay: Replay = recording()
	replay._inputs[2 * 7] = 1
	var viewer: Viewer = Viewer.new()
	context.equal(viewer.open_bytes(replay.to_bytes()), true, "shape-correct corrupt replay loads")
	viewer.toggle_play()
	for _tick: int in range(30):
		viewer.tick()
	context.equal(viewer.current_frame(), 8, "stops before first mismatching saved boundary")
	context.equal(viewer.is_playing, false, "divergence pauses")
	context.equal(viewer.message.contains("stopped at frame 8"), true, "identifies first failed checksum")
	var bytes: PackedByteArray = viewer.game.canonical_bytes()
	viewer.step()
	viewer.toggle_play()
	viewer.tick()
	context.bytes_equal(viewer.game.canonical_bytes(), bytes, 8, "failed replay remains stopped")
	viewer.restart()
	context.equal(viewer.current_frame(), 0, "can restart after failure")
	context.state(8, bytes)
