extends RefCounted

# Value: protects=saved-viewing coverage stays visible past recording cap; fails_when=scene implies entire displayed match is saved;
# why_new=recording API tests do not exercise spectator label or export controls; seam=none
const Scene = preload("res://examples/spectator/spectator.gd")
const Demo = preload("res://examples/spectator/demo.gd")
const Game = preload("res://examples/integration/game.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["recording_limit_feedback"])


func run_case(_name: String, context: RefCounted) -> void:
	var scene: Node2D = Scene.new()
	scene._ready()
	context.equal(scene._label.text.contains("Viewed replay: 0/36000 frames recorded"), true, "startup names bounded viewed recording")
	# Configure a smaller ordinary viewer to cross its real storage boundary without a ten-minute test.
	var config: Demo.Config = scene.demo.viewer._config.owned_copy()
	config.replay_max_frames = 3
	config.storage_budget_bytes = config.required_storage_bytes()
	context.equal(scene.demo.viewer.configure(config), Types.Code.OK, "small bounded recording")
	context.equal(scene.demo.viewer.set_playback(0, 0, 1), Types.Code.OK, "immediate confirmed playback")
	var samples: Array[Demo.Driver.LocalInput] = []
	for frame: int in range(5):
		var rows: Array[PackedByteArray] = [PackedByteArray([Game.RIGHT]), PackedByteArray([Game.LEFT])]
		context.equal(scene.demo.viewer.receive_host_frame(frame, rows).code, Types.Code.OK, "original confirmed viewer row")
		context.equal(scene.demo.driver.step(frame, samples).code, Types.Code.OK, "viewing continues across recording limit")
		scene._update_label()
		var recorded: int = mini(frame + 1, 3)
		context.equal(scene._label.text.contains("Viewed replay: %d/3 frames recorded" % recorded), true, "label reads actual finalized viewer prefix")
		if frame == 2:
			context.equal(scene._label.text.contains("Replay limit reached. Save now to include the displayed state."), true, "exact cap offers current-boundary save")
		elif frame > 2:
			context.equal(scene._label.text.contains("%d later viewed frames omitted" % (frame - 2)), true, "later displayed rows are explicitly outside export")
			context.equal(scene._label.text.contains("Saved replay ends before the displayed state."), true, "omitted history cannot imply final-state coverage")
			context.equal(scene._label.text.contains("Save now to include the displayed state."), false, "old exact-cap prompt cannot survive cap crossing")
		else:
			context.equal(scene._label.text.contains("Replay limit in %d viewed frames." % (2 - frame)), true, "advance warning counts viewed rather than host frames")
		var replay: Replay = Replay.new()
		context.equal(replay.decode(scene.demo.replay_bytes()), Replay.DecodeCode.OK, "save remains usable at and beyond cap")
		context.equal(replay.frame_count(), recorded, "saved portable prefix matches label")
	scene.demo.lose_host_connection()
	scene._update_label()
	context.equal(scene._label.text.contains("2 later viewed frames omitted"), true, "stopped playback preserves omitted-frame notice")
	context.equal(scene.demo.start(), Types.Code.OK, "restart creates fresh viewing lifetime")
	scene._update_label()
	context.equal(scene._label.text.contains("Viewed replay: 0/36000 frames recorded"), true, "restart resets visible recording progress")
	context.equal(scene._label.text.contains("omitted"), false, "restart clears prior omission notice")
	scene.free()
	context.finish()
