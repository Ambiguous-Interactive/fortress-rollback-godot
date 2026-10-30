extends RefCounted

# Value: protects=downloaded spectator files reopen with the correct game; fails_when=viewer refuses or misinterprets them; why_new=online fixtures use another game; seam=none
const Demo = preload("res://examples/spectator/demo.gd")
const Game = preload("res://examples/integration/game.gd")
const Viewer = preload("res://examples/online/replay_viewer.gd")
const Scene = preload("res://examples/online/replay_scene.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const OnlineFixture = preload("res://tests/unit/test_replay_viewer.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["round_trip", "compatibility", "checksum_failure", "scene_controls"])


func run_case(name: String, context: RefCounted) -> void:
	call("_" + name, context)
	context.finish()


func _recording(context: RefCounted, count: int = 42) -> Dictionary:
	var demo: Demo = Demo.new()
	context.equal(demo.start(), Types.Code.OK, "start actual spectator export")
	for tick: int in count:
		var buttons: int = Game.RIGHT | (Game.FIRE if tick % 8 < 4 else Game.LEFT)
		context.equal(demo.tick(buttons), Types.Code.OK, "play original host inputs")
	context.equal(demo.finish_host(), Types.Code.OK, "finish original host")
	for tick: int in range(80):
		context.equal(demo.tick(0) in [Types.Code.OK, Types.Code.PREDICTION_STALL], true, "drain original confirmed tail")
	context.equal(demo.viewer.is_complete(), true, "exported viewing completed cleanly")
	var bytes: PackedByteArray = demo.replay_bytes()
	context.equal(bytes.is_empty(), false, "real spectator replay download exists")
	return {"bytes": bytes, "canonical": demo.game.canonical_bytes(), "frame": demo.game.frame}


func _round_trip(context: RefCounted) -> void:
	for count: int in [0, 42]:
		var original: Dictionary = _recording(context, count)
		var viewer: RefCounted = Viewer.new()
		var opened: bool = viewer.open_bytes(original.bytes)
		context.equal(opened, true, "open actual spectator download")
		if not opened:
			continue
		context.equal(viewer.game is Game, true, "explicit game identity selects spectator callbacks")
		if count > 0:
			context.equal(viewer.input_summary().contains("Right+Fire"), true, "spectator input names firing")
			context.equal(viewer.input_summary().contains("Up"), false, "spectator fire is never shown as online movement")
			viewer.step()
			context.equal(viewer.current_frame(), 1, "spectator single-frame playback")
			var first: PackedByteArray = viewer.game.canonical_bytes()
			context.equal(viewer.step_back(), true, "spectator navigation restores initial checkpoint")
			viewer.tick()
			context.bytes_equal(viewer.game.canonical_bytes(), Game.new().canonical_bytes(), 0, "back restores exact initial shot and cooldown state")
			viewer.step()
			context.bytes_equal(viewer.game.canonical_bytes(), first, 1, "repeat input reproduces movement and shots")
		context.equal(viewer.seek(count), true, "seek complete spectator prefix")
		viewer.tick()
		context.equal(viewer.has_failure(), false, "spectator original checksums all match")
		context.bytes_equal(viewer.game.canonical_bytes(), original.canonical, count, "offline replay equals original corrected viewing")
		context.equal(viewer.message.contains("including the final state"), true, "completion verifies exact exported final boundary")
		viewer.restart()
		context.equal(viewer.current_frame(), 0, "restart begins same identified game")
		viewer.toggle_play()
		for tick: int in range(count + 2):
			viewer.tick()
		context.bytes_equal(viewer.game.canonical_bytes(), original.canonical, count, "continuous playback agrees after restart")


func _compatibility(context: RefCounted) -> void:
	var original: Dictionary = _recording(context)
	var viewer: RefCounted = Viewer.new()
	var opened: bool = viewer.open_bytes(original.bytes)
	context.equal(opened, true, "valid spectator compatibility control")
	if not opened:
		return
	viewer.step()
	viewer.toggle_play()
	var retained_game: RefCounted = viewer.game
	var canonical: PackedByteArray = retained_game.canonical_bytes()
	for fault: String in ["version", "seed", "generic", "buttons"]:
		var incompatible: Replay = Replay.new()
		context.equal(incompatible.decode(original.bytes), Replay.DecodeCode.OK, "decode actual export for one-variable compatibility fault")
		match fault:
			"version":
				incompatible._text[4] += "-other"
			"seed":
				incompatible._text[3] += "-other"
			"generic":
				incompatible._text[3] = ""
				incompatible._text[4] = ""
			"buttons":
				incompatible._inputs[0] = 8
				var digest: PackedByteArray = incompatible.computed_input_digest(0)
				for index: int in Replay.DIGEST_BYTES:
					incompatible._digests[index] = digest[index]
		context.equal(viewer.open_bytes(incompatible.to_bytes()), false, "incompatible spectator identity or controls refused: " + fault)
		context.equal(viewer.game == retained_game, true, "failed import preserves selected game")
		context.equal(viewer.current_frame(), 1, "failed import preserves playback boundary")
		context.equal(viewer.is_playing, true, "failed import preserves playback control")
		context.bytes_equal(viewer.game.canonical_bytes(), canonical, 1, "failed import preserves displayed canonical state")
	var online: Replay = OnlineFixture.new().recording(5)
	context.equal(viewer.open_bytes(online.to_bytes()), true, "online recordings remain supported after spectator viewing")
	context.equal(viewer.game is Viewer.Simulation, true, "online identity selects its original game")
	viewer.step()
	context.equal(viewer.has_failure(), false, "online callbacks and snapshot width remain valid")
	context.equal(viewer.open_bytes(original.bytes), true, "switching back selects spectator game afresh")


func _checksum_failure(context: RefCounted) -> void:
	var original: Dictionary = _recording(context)
	var recording: Replay = Replay.new()
	context.equal(recording.decode(original.bytes), Replay.DecodeCode.OK, "decode spectator checksum fault fixture")
	recording._terminal_checksum[0] ^= 1
	var viewer: RefCounted = Viewer.new()
	var opened: bool = viewer.open_bytes(recording.to_bytes())
	context.equal(opened, true, "checksum corruption imports for owning-boundary playback comparison")
	if not opened:
		return
	context.equal(viewer.seek(original.frame), true, "navigate to corrupt final boundary")
	viewer.tick()
	context.equal(viewer.has_failure(), true, "spectator checksum mismatch stops playback")
	context.equal(viewer.message.contains("Recorded state checksum mismatch"), true, "spectator failure identifies state comparison")
	var report: Dictionary = JSON.parse_string(viewer.failure_report_bytes().get_string_from_utf8())
	context.equal(report.failure.frame, original.frame, "failure report identifies exact spectator boundary")
	context.equal(report.recording.game_version, recording.game_version(), "failure report retains selected game identity")
	context.bytes_equal(viewer.game.canonical_bytes(), original.canonical, original.frame, "corrupt evidence does not alter simulated original history")


func _scene_controls(context: RefCounted) -> void:
	var original: Dictionary = _recording(context)
	var scene: Node2D = Scene.new()
	scene._ready()
	var opened: bool = scene.viewer.open_bytes(original.bytes)
	context.equal(opened, true, "scene opens spectator download")
	if opened:
		scene.viewer.step()
		scene._refresh()
		context.equal(scene._status.text.contains("Fire"), true, "scene displays spectator-specific controls")
		var game: RefCounted = scene.viewer.game
		context.equal(game.shot_total > 0, true, "render path exercises recorded shot rings")
	scene._exit_tree()
	scene.free()
