extends RefCounted

# Value: protects=input-change navigation reaches exact recorded controls and statuses through verified bounded seeks;
# fails_when=navigation skips status changes or corruption; why_new=checkpoint navigation ignores input transitions; seam=none
const Fixture = preload("res://tests/unit/test_replay_viewer.gd")
const Viewer = preload("res://examples/online/replay_viewer.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const Simulation = preload("res://examples/offline/simulation.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["input_change_navigation", "input_change_integrity", "input_change_controls"])


func run_case(name: String, context: RefCounted) -> void:
	var viewer: Viewer = Viewer.new()
	context.equal(viewer.has_method("input_change_target"), true, "viewer exposes input-change destinations")
	if viewer.has_method("input_change_target"):
		call("_" + name, context)
	context.finish()


func _recording(frames: int = 900) -> Replay:
	var replay: Replay = Fixture.recording(frames)
	replay._flags.fill(0)
	for frame: int in frames:
		replay._inputs[frame * 2] = 1 if frame >= 450 else 0
		replay._inputs[frame * 2 + 1] = 2 if frame >= 700 else 0
		if frame >= 600:
			replay._statuses[frame * 2] = Queue.Status.DISCONNECTED
		var digest: PackedByteArray = replay.computed_input_digest(frame)
		for index: int in Replay.DIGEST_BYTES:
			replay._digests[frame * Replay.DIGEST_BYTES + index] = digest[index]
	return replay


func _finish(context: RefCounted, viewer: Viewer, replay: Replay, target: int) -> void:
	while viewer.is_seeking():
		var before: int = viewer.current_frame()
		viewer.tick()
		context.equal(viewer.current_frame() - before <= Viewer.SEEK_FRAMES_PER_TICK, true, "input-change seek retains the per-tick work bound")
	context.equal(viewer.current_frame(), target, "input-change seek reaches the exact boundary")
	var expected: Simulation = Simulation.new()
	for frame: int in target:
		expected.simulate_frame(frame, replay.inputs(frame))
	context.bytes_equal(viewer.game.canonical_bytes(), expected.canonical_bytes(), target, "navigation preserves original canonical state")
	context.equal(viewer.is_playing, false, "input-change navigation finishes paused")


func _input_change_navigation(context: RefCounted) -> void:
	var viewer: Viewer = Viewer.new()
	context.equal(viewer.call("input_change_target", true), -1, "empty viewer has no changes")
	context.equal(viewer.call("seek_input_change", true), false, "empty viewer refuses navigation")
	var replay: Replay = _recording()
	context.equal(viewer.open_bytes(replay.to_bytes()), true, "input-change fixture opens")
	context.equal(viewer.call("input_change_target", false), -1, "initial boundary has no earlier input")
	for target: int in [450, 600, 700]:
		context.equal(viewer.call("input_change_target", true), target, "both control and status changes are indexed")
		context.equal(viewer.call("seek_input_change", true), true, "forward input change starts navigation")
		if viewer.is_seeking():
			context.equal(viewer.call("input_change_target", true), -1, "ongoing seeks suspend input-change navigation")
			context.equal(viewer.call("seek_input_change", false), false, "a second input-change request preserves the active seek")
		_finish(context, viewer, replay, target)
	context.equal(viewer.call("input_change_target", true), -1, "unchanged final tail has no later change")
	viewer.seek(500)
	_finish(context, viewer, replay, 500)
	context.equal(viewer.call("input_change_target", false), 450, "interior boundary finds preceding change")
	context.equal(viewer.call("input_change_target", true), 600, "interior boundary finds following status change")
	viewer.seek(700)
	_finish(context, viewer, replay, 700)
	context.equal(viewer.call("seek_input_change", true), false, "absent change preserves the displayed state")
	viewer.seek(900)
	_finish(context, viewer, replay, 900)
	for target: int in [700, 600, 450, 0]:
		context.equal(viewer.call("input_change_target", false), target, "backward navigation includes first input and excludes current boundary")
		context.equal(viewer.call("seek_input_change", false), true, "backward change starts navigation")
		_finish(context, viewer, replay, target)
	context.equal(viewer.open_bytes(PackedByteArray([0])), false, "malformed replacement refuses")
	context.equal(viewer.call("input_change_target", true), 450, "refused replacement preserves transition index")
	context.equal(viewer.open_bytes(_recording(1).to_bytes()), true, "single-input recording opens")
	context.equal(viewer.call("input_change_target", true), -1, "single-input recording has no later transition")
	viewer.step()
	context.equal(viewer.call("input_change_target", false), 0, "completed single-input recording can inspect its first input")
	var empty: Replay = _recording(0)
	empty._format_version = Replay.TERMINAL_VERSION
	empty._terminal_checksum = Simulation.checksum(Simulation.new().canonical_bytes())
	context.equal(viewer.open_bytes(empty.to_bytes()), true, "initial-state-only recording opens")
	for forward: bool in [false, true]:
		context.equal(viewer.call("input_change_target", forward), -1, "initial-state-only recording has no input changes")
		context.equal(viewer.call("seek_input_change", forward), false, "initial-only state cannot navigate nonexistent input")
	context.state(viewer.current_frame(), viewer.game.canonical_bytes())


func _input_change_integrity(context: RefCounted) -> void:
	for fault: String in ["row", "digest"]:
		var replay: Replay = _recording()
		if fault == "row":
			replay._inputs[240] = 3
		else:
			replay._digests[120 * Replay.DIGEST_BYTES] ^= 1
		var viewer: Viewer = Viewer.new()
		context.equal(viewer.open_bytes(replay.to_bytes()), true, "digest failures remain playback-owned")
		context.equal(viewer.call("seek_input_change", true), true, "input navigation begins through the original prefix")
		while viewer.is_seeking():
			viewer.tick()
		context.equal(viewer.current_frame(), 120, "navigation cannot skip corrupt input in the prefix or destination")
		context.equal(viewer.has_failure(), true, "corruption stops input-change navigation")
		context.equal(viewer.call("input_change_target", false), -1, "failure cannot advertise navigable transitions")
		context.equal(viewer.call("seek_input_change", true), false, "failed playback requires explicit restart or seek")
		context.equal(viewer.message.contains("input digest mismatch"), true, "the owning integrity diagnostic remains visible")
		context.state(viewer.current_frame(), viewer.game.canonical_bytes())


func _input_change_controls(context: RefCounted) -> void:
	var node: Node2D = Fixture.Scene.instantiate()
	node._ready()
	var previous: Button = Fixture._button(node, "Previous input change")
	var following: Button = Fixture._button(node, "Next input change")
	context.equal(previous != null and following != null, true, "scene exposes both input-change actions")
	if previous != null and following != null:
		context.equal(previous.disabled and following.disabled, true, "empty scene disables transition actions")
		var replay: Replay = _recording()
		node.viewer.open_bytes(replay.to_bytes())
		node._refresh()
		context.equal(previous.disabled, true, "initial state has no previous input change")
		context.equal(following.disabled, false, "later changes enable forward action")
		following.pressed.emit()
		context.equal(previous.disabled and following.disabled, true, "active seek disables both transition actions")
		while node.viewer.is_seeking():
			node._physics_process(0.0)
		context.equal(node.viewer.current_frame(), 450, "button seeks to the next control change")
		previous.pressed.emit()
		context.equal(node.viewer.current_frame(), 0, "button restores first input boundary")
		context.state(node.viewer.current_frame(), node.viewer.game.canonical_bytes())
	node._exit_tree()
	node.free()
