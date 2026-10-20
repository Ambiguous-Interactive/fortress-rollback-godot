extends RefCounted

# Value: protects=users inspect replay at slow and fast speeds without changing recorded frames; fails_when=cadence skips validation or leaks across controls;
# why_new=viewer controls only cover one frame per tick; seam=none
const Fixture = preload("res://tests/unit/test_replay_viewer.gd")
const Viewer = preload("res://examples/online/replay_viewer.gd")
const Scene = preload("res://examples/online/replay.tscn")
const Simulation = preload("res://examples/offline/simulation.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["cadence", "controls", "failure", "scene_speed", "backward_step", "scene_backward_step"])


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
			"backward_step":
				_backward_step(context)
			"scene_backward_step":
				_scene_backward_step(context)
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
		context.equal(viewer.current_frame(), 7, "fast playback cannot skip the corrupted input")
		context.equal(viewer.can_step(), false, "mismatch stops all speeds")
		context.equal(viewer.message.contains("stopped at frame 7"), true, "failure identifies the corrupted frame")
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


# Value: protects=one-frame backward inspection uses bounded validated navigation; fails_when=Back skips checks or resumes playback;
# why_new=existing navigation requires entering a frame number and does not cover the backward-step action; seam=none
func _backward_step(context: RefCounted) -> void:
	var probe: Viewer = Viewer.new()
	context.equal(probe.has_method("step_back"), true, "one-frame backward navigation is available")
	if not probe.has_method("step_back"):
		return
	context.equal(probe.call("step_back"), false, "empty viewer cannot go backward")
	var replay: RefCounted = Fixture.recording(900)
	for boundary: int in [1, 450, 900]:
		var viewer: Viewer = Viewer.new()
		viewer.open_bytes(replay.to_bytes())
		context.equal(viewer.call("step_back"), false, "initial state cannot go backward")
		viewer.seek(boundary)
		while viewer.is_seeking():
			viewer.tick()
		viewer.set_playback_speed(1)
		viewer.toggle_play()
		viewer.tick()
		context.equal(viewer.call("step_back"), true, "backward step accepted from playback or completion")
		context.equal(viewer.is_playing, false, "backward step pauses playback")
		if viewer.is_seeking():
			var before: int = viewer.current_frame()
			context.equal(viewer.call("step_back"), false, "active navigation cannot be replaced by another backward step")
			context.equal(viewer.current_frame(), before, "refused backward step keeps navigation position")
		while viewer.is_seeking():
			var before: int = viewer.current_frame()
			viewer.tick()
			context.equal(viewer.current_frame() - before <= Viewer.SEEK_FRAMES_PER_TICK, true, "backward step retains bounded per-tick replay work")
		var expected: Simulation = Simulation.new()
		for frame: int in range(boundary - 1):
			expected.simulate_frame(frame, replay.inputs(frame))
		context.equal(viewer.current_frame(), boundary - 1, "backward step reaches exactly the preceding boundary")
		context.bytes_equal(viewer.game.canonical_bytes(), expected.canonical_bytes(), boundary - 1, "backward step restores complete canonical state")
		context.equal(viewer.message, "Paused.", "backward step finishes paused")
		viewer.toggle_play()
		viewer.tick()
		context.equal(viewer.current_frame(), boundary - 1, "backward step clears partial slow-motion cadence")
		context.state(boundary - 1, viewer.game.canonical_bytes())
	var corrupt: RefCounted = Fixture.recording()
	corrupt._checksums[8 * 16] ^= 1
	probe.open_bytes(corrupt.to_bytes())
	probe.seek(8)
	probe.tick()
	context.equal(probe.can_step(), false, "control reaches checksum failure")
	context.equal(probe.call("step_back"), true, "failed playback can inspect its preceding healthy boundary")
	while probe.is_seeking():
		probe.tick()
	context.equal(probe.current_frame(), 7, "failed playback moves back exactly one frame")
	probe.seek(8)
	probe.tick()
	context.equal(probe.can_step(), false, "moving backward cannot bypass the original mismatch")
	context.equal(probe.message.contains("stopped at frame 8"), true, "repeated divergence remains visible")


func _scene_backward_step(context: RefCounted) -> void:
	var node: Node2D = Scene.instantiate()
	node._ready()
	var back: Button = Fixture._button(node, "Back one frame")
	context.equal(back != null, true, "scene exposes backward step")
	if back != null:
		context.equal(back.disabled, true, "empty viewer disables backward step")
		node.viewer.open_bytes(Fixture.recording(900).to_bytes())
		node._refresh()
		context.equal(back.disabled, true, "initial boundary disables backward step")
		node.viewer.seek(900)
		while node.viewer.is_seeking():
			node._physics_process(0.0)
		node._refresh()
		context.equal(back.disabled, false, "completion permits backward inspection")
		back.pressed.emit()
		context.equal(back.disabled, true, "active backward navigation disables repeated requests")
		context.equal(Fixture._button(node, "Cancel seek").disabled, false, "long backward step can be canceled")
		while node.viewer.is_seeking():
			node._physics_process(0.0)
		context.equal(node.viewer.current_frame(), 899, "scene action reaches preceding frame")
		context.equal(back.disabled, false, "paused destination enables another backward step")
		back.pressed.emit()
		node._physics_process(0.0)
		var paused_frame: int = node.viewer.current_frame()
		Fixture._button(node, "Cancel seek").pressed.emit()
		node._physics_process(0.0)
		context.equal(node.viewer.current_frame(), paused_frame, "canceling backward navigation preserves its reached boundary")
		context.equal(node.viewer.message, "Paused.", "canceled backward navigation finishes paused")
		context.equal(back.disabled, false, "canceled navigation permits further backward inspection")
		Fixture._button(node, "Restart").pressed.emit()
		context.equal(back.disabled, true, "restart returns to disabled initial boundary")
		var corrupt: RefCounted = Fixture.recording()
		corrupt._checksums[0] ^= 1
		node.viewer.open_bytes(corrupt.to_bytes())
		node.viewer.step()
		node._refresh()
		context.equal(back.disabled, true, "failure at initial state cannot step backward")
		context.state(node.viewer.current_frame(), node.viewer.game.canonical_bytes())
	node._exit_tree()
	node.free()
