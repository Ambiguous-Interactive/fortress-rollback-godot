extends RefCounted

# Value: protects=users inspect replay at slow and fast speeds without changing recorded frames; fails_when=cadence skips validation or leaks across controls;
# why_new=viewer controls only cover one frame per tick; seam=none
const Fixture = preload("res://tests/unit/test_replay_viewer.gd")
const Viewer = preload("res://examples/online/replay_viewer.gd")
const Scene = preload("res://examples/online/replay.tscn")
const Simulation = preload("res://examples/offline/simulation.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["cadence", "controls", "failure", "scene_speed"])


func run_case(name: String, context: RefCounted) -> void:
	var viewer: Viewer = Viewer.new()
	context.equal(viewer.has_method("set_playback_speed"), true, "playback speed can be selected")
	if viewer.has_method("set_playback_speed"):
		match name:
			"cadence":
				_cadence(context)
			"controls":
				_controls(context)
			"failure":
				_failure(context)
			"scene_speed":
				_scene_speed(context)
	context.finish()


func _cadence(context: RefCounted) -> void:
	var replay: RefCounted = Fixture.recording(19)
	for quarters: int in [1, 2, 4, 8, 16]:
		var viewer: Viewer = Viewer.new()
		viewer.open_bytes(replay.to_bytes())
		context.equal(viewer.call("set_playback_speed", quarters), true, "accept supported rate")
		viewer.toggle_play()
		for tick: int in range(1, 81):
			viewer.tick()
			@warning_ignore("integer_division")
			var expected_frame: int = mini(19, tick * quarters / 4)
			context.equal(viewer.current_frame(), expected_frame, "quarter-rate %d tick %d" % [quarters, tick])
		var expected: Simulation = Simulation.new()
		for frame: int in 19:
			expected.simulate_frame(frame, replay.inputs(frame))
		context.bytes_equal(viewer.game.canonical_bytes(), expected.canonical_bytes(), 19, "all speeds preserve canonical final state")
		context.equal(viewer.is_playing, false, "all speeds stop at completion")
		context.equal(viewer.message, Viewer.COMPLETE_MESSAGE, "completion remains visible")
		context.state(quarters, viewer.game.canonical_bytes())


func _controls(context: RefCounted) -> void:
	for quarters: int in [1, 2, 4, 8, 16]:
		var viewer: Viewer = Viewer.new()
		viewer.open_bytes(Fixture.recording(300).to_bytes())
		viewer.call("set_playback_speed", quarters)
		viewer.toggle_play()
		viewer.tick()
		viewer.toggle_play()
		var paused_frame: int = viewer.current_frame()
		for tick: int in 8:
			viewer.tick()
		context.equal(viewer.current_frame(), paused_frame, "pause consumes no frames")
		viewer.step()
		context.equal(viewer.current_frame(), paused_frame + 1, "single step ignores playback speed")
		context.equal(viewer.seek(30), true, "seek accepted at all rates")
		viewer.tick()
		context.equal([viewer.current_frame(), viewer.is_seeking(), viewer.is_playing], [30, false, false], "seek retains exact target and own budget")
		viewer.toggle_play()
		viewer.tick()
		@warning_ignore("integer_division")
		var first_tick_frames: int = quarters / 4
		context.equal(viewer.current_frame(), 30 + first_tick_frames, "resume starts a fresh playback cadence")
		for invalid: int in [-1, 0, 3, 17, 9223372036854775807]:
			context.equal(viewer.call("set_playback_speed", invalid), false, "unsupported rate rejected")
			context.equal(viewer.call("playback_speed_quarters"), quarters, "invalid rate preserves selected speed")
		viewer.restart()
		context.equal(viewer.call("playback_speed_quarters"), quarters, "restart retains user speed preference")
		viewer.toggle_play()
		viewer.tick()
		context.equal(viewer.current_frame(), first_tick_frames, "restart clears cadence remainder")
	var viewer: Viewer = Viewer.new()
	viewer.open_bytes(Fixture.recording().to_bytes())
	viewer.call("set_playback_speed", 1)
	viewer.toggle_play()
	for tick: int in 3:
		viewer.tick()
	viewer.toggle_play()
	viewer.toggle_play()
	viewer.tick()
	context.equal(viewer.current_frame(), 0, "pause discards partial slow frame")
	viewer.call("set_playback_speed", 2)
	viewer.tick()
	context.equal(viewer.current_frame(), 0, "speed change discards partial slow frame")
	viewer.tick()
	context.equal(viewer.current_frame(), 1, "changed speed uses new cadence")
	viewer.call("set_playback_speed", 1)
	for tick: int in 3:
		viewer.tick()
	context.equal(viewer.call("set_playback_speed", 3), false, "invalid rate rejected during partial frame")
	viewer.call("set_playback_speed", 1)
	viewer.tick()
	context.equal(viewer.current_frame(), 2, "invalid and unchanged rates preserve partial frame")
	for tick: int in 3:
		viewer.tick()
	viewer.step()
	viewer.tick()
	context.equal(viewer.current_frame(), 3, "single step discards partial slow frame")
	context.equal(viewer.open_bytes(Fixture.recording().to_bytes()), true, "new import accepted during slow playback")
	context.equal(viewer.call("playback_speed_quarters"), 1, "new import retains speed preference")
	viewer.toggle_play()
	viewer.tick()
	context.equal(viewer.current_frame(), 0, "new import starts fresh cadence")


func _failure(context: RefCounted) -> void:
	for quarters: int in [1, 2, 4, 8, 16]:
		var replay: RefCounted = Fixture.recording()
		replay._inputs[14] = 1
		var viewer: Viewer = Viewer.new()
		viewer.open_bytes(replay.to_bytes())
		viewer.call("set_playback_speed", quarters)
		viewer.toggle_play()
		for tick: int in 48:
			viewer.tick()
		context.equal(viewer.current_frame(), 8, "fast playback cannot skip first mismatch")
		context.equal(viewer.can_step(), false, "mismatch stops all speeds")
		context.equal(viewer.message.contains("stopped at frame 8"), true, "failure identifies recorded boundary")
		context.state(quarters, viewer.game.canonical_bytes())


func _scene_speed(context: RefCounted) -> void:
	var node: Node2D = Scene.instantiate()
	node._ready()
	node.viewer.open_bytes(Fixture.recording().to_bytes())
	node._refresh()
	var controls: Array[Node] = node.find_children("PlaybackSpeed", "OptionButton", true, false)
	context.equal(controls.size(), 1, "scene exposes speed selection")
	if not controls.is_empty():
		var speed: OptionButton = controls[0]
		context.equal(speed.get_item_text(speed.selected), "1×", "normal speed selected initially")
		for index: int in speed.item_count:
			speed.select(index)
			speed.item_selected.emit(index)
			context.equal(node.viewer.call("playback_speed_quarters"), [1, 2, 4, 8, 16][index], "visible selection sets player rate")
		Fixture._button(node, "Play").pressed.emit()
		node._physics_process(0.0)
		context.equal(node.viewer.current_frame(), 4, "scene services fast playback")
	node._exit_tree()
	node.free()
