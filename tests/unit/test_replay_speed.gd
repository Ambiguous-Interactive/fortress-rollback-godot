extends RefCounted

# Value: protects=users inspect replay at slow and fast speeds without changing recorded frames; fails_when=cadence skips validation or leaks across controls;
# why_new=viewer controls only cover one frame per tick; seam=none
const Fixture = preload("res://tests/unit/test_replay_viewer.gd")
const Viewer = preload("res://examples/online/replay_viewer.gd")
const Scene = preload("res://examples/online/replay.tscn")
const Simulation = preload("res://examples/offline/simulation.gd")


class FocusGame:
	extends Simulation

	var scene_ref: WeakRef
	var focus_during_save: bool = false
	var notified: bool = false
	var focus_frame: int = 0

	func save_state(saved_frame: int, writer: Writer) -> Driver.SaveResult:
		var result: Driver.SaveResult = super.save_state(saved_frame, writer)
		if focus_during_save:
			_notify_focus_loss(saved_frame)
		return result

	func simulate_frame(input_frame: int, inputs: Types.FrameInputs) -> bool:
		var result: bool = super.simulate_frame(input_frame, inputs)
		if not focus_during_save:
			_notify_focus_loss(input_frame)
		return result

	func _notify_focus_loss(at_frame: int) -> void:
		if not notified and at_frame == focus_frame:
			notified = true
			scene_ref.get_ref().notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)


func cases() -> PackedStringArray:
	return PackedStringArray(["cadence", "controls", "failure", "scene_speed", "backward_step", "scene_backward_step", "keyboard_controls", "focus_loss", "timeline"])


func run_case(name: String, context: RefCounted) -> void:
	var viewer: Viewer = Viewer.new()
	context.equal(viewer.has_method("set_playback_speed"), true, "playback speed can be selected")
	if viewer.has_method("set_playback_speed"):
		match name:
			"focus_loss":
				_focus_loss(context)
			"timeline":
				_timeline(context)
			"keyboard_controls":
				_keyboard_controls(context)
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


# Value: protects=keyboard inspection shares visible playback and navigation gates; fails_when=keys bypass checks or repeat unexpectedly;
# why_new=button tests do not dispatch keyboard input; seam=none
func _keyboard_controls(context: RefCounted) -> void:
	var node: Node2D = Scene.instantiate()
	node._ready()
	context.equal(node.has_method("_unhandled_key_input"), true, "viewer offers keyboard inspection")
	if not node.has_method("_unhandled_key_input"):
		node._exit_tree()
		node.free()
		return
	_key(node, KEY_P)
	context.equal(node.viewer.is_playing, false, "empty viewer cannot play from keyboard")
	node.viewer.open_bytes(Fixture.recording(900).to_bytes())
	node._refresh()
	_key(node, KEY_P)
	context.equal(node.viewer.is_playing, true, "P starts playback")
	for modified: String in ["echo", "released", "ctrl", "alt", "meta", "shift"]:
		_key(node, KEY_P, modified)
		context.equal(node.viewer.is_playing, true, "ignore " + modified + " shortcut")
	_key(node, KEY_N)
	context.equal([node.viewer.current_frame(), node.viewer.is_playing], [1, false], "N pauses and inspects exactly one next frame")
	_key(node, KEY_B)
	context.equal([node.viewer.current_frame(), node.viewer.is_playing], [0, false], "B restores preceding frame paused")
	_key(node, KEY_B)
	context.equal(node.viewer.current_frame(), 0, "initial frame cannot move backward")
	node.viewer.seek(900)
	node._physics_process(0.0)
	var reached: int = node.viewer.current_frame()
	_key(node, KEY_N)
	_key(node, KEY_B)
	_key(node, KEY_P)
	context.equal([node.viewer.current_frame(), node.viewer.is_seeking()], [reached, true], "seeking disables play and step shortcuts")
	_key(node, KEY_ESCAPE)
	context.equal([node.viewer.current_frame(), node.viewer.is_seeking(), node.viewer.is_playing], [reached, false, false], "Escape cancels seek at reached boundary")
	_key(node, KEY_R)
	context.equal([node.viewer.current_frame(), node.viewer.is_playing], [0, false], "R restarts paused")
	var corrupt: RefCounted = Fixture.recording()
	corrupt._inputs[2] ^= 1
	node.viewer.open_bytes(corrupt.to_bytes())
	node._refresh()
	_key(node, KEY_N)
	_key(node, KEY_N)
	context.equal(node.viewer.has_failure(), true, "keyboard inspection checks input integrity")
	_key(node, KEY_P)
	_key(node, KEY_N)
	context.equal([node.viewer.current_frame(), node.viewer.is_playing], [1, false], "failed replay cannot advance through shortcuts")
	context.state(node.viewer.current_frame(), node.viewer.game.canonical_bytes())
	node._exit_tree()
	node.free()


func _key(node: Node, code: int, modified: String = "") -> void:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = code
	event.pressed = modified != "released"
	event.echo = modified == "echo"
	event.ctrl_pressed = modified == "ctrl"
	event.alt_pressed = modified == "alt"
	event.meta_pressed = modified == "meta"
	event.shift_pressed = modified == "shift"
	node.call("_unhandled_key_input", event)


# Value: protects=timeline selection uses bounded verified navigation and preserves drag intent;
# fails_when=refresh seeks recursively, dragging advances playback or corrupt prefixes are skipped; why_new=frame-entry tests have no timeline; seam=none
func _timeline(context: RefCounted) -> void:
	var node: Node2D = Scene.instantiate()
	node._ready()
	var sliders: Array[Node] = node.find_children("ReplayTimeline", "HSlider", true, false)
	context.equal(sliders.size(), 1, "viewer exposes a replay timeline")
	if sliders.is_empty():
		node._exit_tree()
		node.free()
		return
	var timeline: HSlider = sliders[0]
	context.equal(timeline.editable, false, "empty viewer cannot scrub")
	var replay: RefCounted = Fixture.recording(900)
	node.viewer.open_bytes(replay.to_bytes())
	node._refresh()
	context.equal([timeline.max_value, timeline.value, timeline.editable], [900.0, 0.0, true], "timeline spans every recorded state boundary")
	node.viewer.toggle_play()
	node._physics_process(0.0)
	context.equal(timeline.value, 1.0, "timeline follows playback without seeking")
	context.equal(node.viewer.is_playing, true, "refresh does not pause playback")
	timeline.drag_started.emit()
	for key: int in [KEY_P, KEY_N, KEY_B, KEY_R, KEY_ESCAPE]:
		_key(node, key)
		context.equal([node.viewer.current_frame(), node.viewer.is_playing, node.viewer.is_seeking()], [1, false, false], "drag owns playback against keyboard controls")
	for action: String in ["_toggle", "_step", "_back_one_frame", "_restart", "_seek", "_cancel_seek"]:
		node.call(action)
		context.equal([node.viewer.current_frame(), node.viewer.is_playing, node.viewer.is_seeking()], [1, false, false], "drag owns playback against direct composed controls")
	for action: String in ["_jump_checkpoint", "_jump_input_change", "_jump_recorded_checksum"]:
		node.call(action, true)
		context.equal([node.viewer.current_frame(), node.viewer.is_playing, node.viewer.is_seeking()], [1, false, false], "drag owns other navigation destinations")
	# The scene must also keep its service loop idle if a caller resumes the underlying player directly.
	node.viewer.toggle_play()
	node._physics_process(0.0)
	context.equal(node.viewer.current_frame(), 1, "drag blocks the scene playback service loop")
	timeline.drag_ended.emit(false)
	context.equal([node.viewer.current_frame(), node.viewer.is_playing], [1, false], "unchanged release remains paused")
	timeline.drag_started.emit()
	var selected_state: PackedByteArray = node.viewer.game.canonical_bytes()
	var checked: int = node.viewer.checked_checksum_count()
	for selected: int in [0, 1, 59, 60, 899, 900]:
		timeline.set_value_no_signal(selected)
		timeline.value_changed.emit(float(selected))
		@warning_ignore("integer_division")
		var seconds: int = selected / 60
		@warning_ignore("integer_division")
		var time: String = "%d:%02d" % [seconds / 60, seconds % 60]
		context.equal(
			node._status.text.begins_with("Selected frame %d (%s). Release to navigate." % [selected, time]), true, "drag immediately previews the selected frame and recorded time"
		)
		context.equal(node.viewer.current_frame(), 1, "selection preview does not move the displayed state")
		context.bytes_equal(node.viewer.game.canonical_bytes(), selected_state, 1, "selection preview preserves canonical state")
		context.equal(node._status.text.contains("Frame 1 / 900"), true, "playback status still identifies actual state rather than the preview")
	context.equal(node.viewer.checked_checksum_count(), checked, "selection preview does not claim additional recorded checksum coverage")
	timeline.set_value_no_signal(899)
	timeline.value_changed.emit(float(899))
	for tick: int in 3:
		node._physics_process(0.0)
	context.equal(node.viewer.current_frame(), 1, "dragging pauses playback before choosing a destination")
	context.equal(timeline.value, 899.0, "refresh preserves drag destination")
	context.equal(node._status.text.begins_with("Selected frame 899 (0:14). Release to navigate."), true, "service refresh preserves selection preview")
	timeline.drag_ended.emit(true)
	context.equal(node._timeline_label.text, "0:00 / 0:15", "release restores actual playback time while navigation runs")
	context.equal(node.viewer.is_seeking(), true, "release starts ordinary verified navigation")
	node._physics_process(0.0)
	context.equal(node.viewer.current_frame(), 121, "timeline seek keeps per-tick budget")
	timeline.set_value_no_signal(60)
	timeline.value_changed.emit(float(60))
	while node.viewer.is_seeking():
		node._physics_process(0.0)
	context.equal([node.viewer.current_frame(), node.viewer.is_playing], [60, false], "timeline can retarget an active seek and finishes paused")
	var expected: Simulation = Simulation.new()
	for frame: int in 60:
		expected.simulate_frame(frame, replay.inputs(frame))
	context.bytes_equal(node.viewer.game.canonical_bytes(), expected.canonical_bytes(), 60, "timeline preserves original canonical state")
	context.equal(node._timeline_label.text, "0:01 / 0:15", "timeline gives elapsed and total recorded time")
	timeline.set_value_no_signal(900)
	timeline.value_changed.emit(float(900))
	while node.viewer.is_seeking():
		node._physics_process(0.0)
	context.equal(node.viewer.current_frame(), 900, "last timeline position reaches final state")
	timeline.set_value_no_signal(0)
	timeline.value_changed.emit(float(0))
	context.equal(node.viewer.current_frame(), 0, "first timeline position returns to initial state")
	var corrupt: RefCounted = Fixture.recording(900)
	corrupt._inputs[14] ^= 1
	node.viewer.open_bytes(corrupt.to_bytes())
	node._refresh()
	timeline.set_value_no_signal(900)
	timeline.value_changed.emit(float(900))
	node._physics_process(0.0)
	context.equal(node.viewer.current_frame(), 7, "timeline cannot skip a corrupt prefix")
	context.equal(node.viewer.has_failure(), true, "timeline exposes playback failure")
	context.equal(timeline.value, 7.0, "failed navigation shows the actual stopped boundary")
	node.viewer.open_bytes(replay.to_bytes())
	node._refresh()
	var opened: RefCounted = node.viewer._player.begin_advance()
	context.equal(opened.batch != null, true, "retain ordinary expert replay work")
	timeline.drag_started.emit()
	context.equal(node._is_scrubbing, false, "active expert work refuses drag ownership before changing scene state")
	timeline.drag_ended.emit(true)
	context.equal([node.viewer.current_frame(), node.viewer.is_seeking()], [0, false], "refused drag release cannot navigate through retained work")
	node.viewer._player.terminate()
	node.viewer.open_bytes(replay.to_bytes())
	node._refresh()
	timeline.drag_started.emit()
	opened = node.viewer._player.begin_advance()
	context.equal(opened.batch != null, true, "independent expert work can own the paused player")
	node._physics_process(0.0)
	context.equal(timeline.editable, true, "held timeline stays editable so the real mouse release can retire drag ownership")
	timeline.drag_ended.emit(false)
	context.equal(node._is_scrubbing, false, "mouse release retires scene drag even while player is busy")
	context.equal(node.viewer.current_frame(), 0, "busy drag release never services retained player work")
	while true:
		var request: Viewer.Types.Request = opened.batch.next_request()
		if request == null:
			break
		var checksum: PackedByteArray = PackedByteArray()
		var ok: bool
		if request.kind == Viewer.Types.Kind.SAVE:
			var saved: RefCounted = node.viewer.game.save_state(request.frame, request.writer)
			ok = saved.ok
			checksum = saved.checksum
		else:
			ok = node.viewer.game.simulate_frame(request.frame, request.inputs)
		var completed: RefCounted = node.viewer._player.complete_request(request.batch_id, request.request_id, ok, checksum)
		context.equal(completed.code, Viewer.Types.Code.OK, "original expert owner completes normally")
	node.viewer.toggle_play()
	node._physics_process(0.0)
	context.equal(node.viewer.current_frame(), 2, "released busy drag cannot suppress later scene playback")
	context.state(node.viewer.current_frame(), node.viewer.game.canonical_bytes())
	node._exit_tree()
	node.free()


# Value: protects=leaving the application preserves the inspected replay boundary; fails_when=focus loss advances or resumes playback;
# why_new=keyboard controls do not deliver application lifecycle notifications; seam=none
func _focus_loss(context: RefCounted) -> void:
	for idle: String in ["empty", "ready", "paused", "complete"]:
		var idle_node: Node2D = Scene.instantiate()
		idle_node._ready()
		if idle != "empty":
			idle_node.viewer.open_bytes(Fixture.recording().to_bytes())
		if idle == "paused":
			idle_node.viewer.step()
		elif idle == "complete":
			idle_node.viewer.seek(idle_node.viewer.frame_count())
			while idle_node.viewer.is_seeking():
				idle_node._physics_process(0.0)
		idle_node._refresh()
		var idle_message: String = idle_node.viewer.message
		var idle_status: String = idle_node._status.text
		idle_node.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
		idle_node.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
		idle_node._physics_process(0.0)
		context.equal(idle_node.viewer.message, idle_message, "focus changes preserve " + idle + " playback notice")
		context.equal(idle_node._status.text, idle_status, "focus changes preserve " + idle + " displayed status")
		idle_node._exit_tree()
		idle_node.free()
	for during_save: bool in [false, true]:
		var callback_node: Node2D = Scene.instantiate()
		callback_node._ready()
		callback_node.viewer.open_bytes(Fixture.recording().to_bytes())
		var game: FocusGame = FocusGame.new()
		game.scene_ref = weakref(callback_node)
		game.focus_during_save = during_save
		callback_node.viewer.game = game
		callback_node.viewer._player.configure(callback_node.viewer._recording, game, Simulation.SNAPSHOT_BYTES, 300, 121)
		callback_node.viewer.set_playback_speed(16)
		callback_node.viewer.toggle_play()
		callback_node._physics_process(0.0)
		context.equal(game.notified, true, "actual game callback delivers focus loss")
		context.equal([callback_node.viewer.current_frame(), callback_node.viewer.is_playing], [1, false], "focus pause finishes one accepted owner before another fast-playback frame")
		context.equal(callback_node.viewer._player.is_current_state_validated(), true, "callback focus pause validates its completed displayed state")
		callback_node._physics_process(0.0)
		context.equal(callback_node.viewer.current_frame(), 1, "later background ticks retain the paused boundary")
		context.state(callback_node.viewer.current_frame(), callback_node.viewer.game.canonical_bytes())
		callback_node._exit_tree()
		callback_node.free()
	for ending: bool in [false, true]:
		var boundary_node: Node2D = Scene.instantiate()
		boundary_node._ready()
		boundary_node.viewer.open_bytes(Fixture.recording(900).to_bytes())
		var boundary_game: FocusGame = FocusGame.new()
		boundary_game.scene_ref = weakref(boundary_node)
		boundary_game.focus_during_save = true
		boundary_game.focus_frame = 2 if ending else 600
		boundary_node.viewer.game = boundary_game
		boundary_node.viewer._player.configure(boundary_node.viewer._recording, boundary_game, Simulation.SNAPSHOT_BYTES, 300, 121)
		boundary_node.viewer.set_repeat_range(0 if ending else 600, 2 if ending else 850)
		boundary_node.viewer.set_repeat_playback(true)
		boundary_node.viewer.set_playback_speed(16)
		boundary_node.viewer.toggle_play()
		boundary_node._physics_process(0.0)
		while boundary_node.viewer.is_seeking():
			boundary_node._physics_process(0.0)
		context.equal(boundary_game.notified, true, "actual selected-range boundary validation delivers focus loss")
		context.equal(
			[boundary_node.viewer.current_frame(), boundary_node.viewer.is_playing], [boundary_game.focus_frame, false],
			"focus during Repeat start or end validation prevents automatic resumption"
		)
		boundary_node._physics_process(0.0)
		context.equal(boundary_node.viewer.current_frame(), boundary_game.focus_frame, "Repeat boundary stays paused after its validation owner releases")
		boundary_node._exit_tree()
		boundary_node.free()
	for repeat: bool in [false, true]:
		var node: Node2D = Scene.instantiate()
		node._ready()
		node.viewer.open_bytes(Fixture.recording(900).to_bytes())
		node.viewer.set_repeat_playback(repeat)
		node.viewer.set_playback_speed(1)
		node.viewer.toggle_play()
		for tick: int in 3:
			node._physics_process(0.0)
		node.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
		context.equal(node.viewer.is_playing, false, "losing focus pauses ordinary and repeating playback immediately")
		for tick: int in 8:
			node._physics_process(0.0)
		context.equal(node.viewer.current_frame(), 0, "unfocused service preserves the displayed boundary")
		node.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
		node._physics_process(0.0)
		context.equal(node.viewer.is_playing, false, "returning focus requires explicit Play")
		_key(node, KEY_P)
		node._physics_process(0.0)
		context.equal(node.viewer.current_frame(), 0, "explicit resume starts fresh slow-motion cadence")
		for tick: int in 3:
			node._physics_process(0.0)
		context.equal(node.viewer.current_frame(), 1, "explicit resume can advance normally")
		node.viewer.seek(900)
		node._physics_process(0.0)
		node.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
		while node.viewer.is_seeking():
			node._physics_process(0.0)
		context.equal([node.viewer.current_frame(), node.viewer.is_playing], [900, false], "selected seek still finishes at its paused destination")
		context.state(node.viewer.current_frame(), node.viewer.game.canonical_bytes())
		node._exit_tree()
		node.free()
	for replacement: bool in [false, true]:
		var replaced: Viewer = Viewer.new()
		replaced.open_bytes(Fixture.recording().to_bytes())
		replaced.toggle_play()
		var pending: RefCounted = replaced._player.begin_advance()
		context.equal(pending.batch != null, true, "replacement control retains an accepted owner")
		replaced.request_pause()
		replaced._player.terminate()
		if replacement:
			replaced.open_bytes(Fixture.recording().to_bytes())
		else:
			replaced.restart()
		replaced.toggle_play()
		replaced.tick()
		context.equal([replaced.current_frame(), replaced.is_playing], [1, true], "restart and replacement discard the prior lifetime's requested pause")
		replaced.terminate()
	var repeat_node: Node2D = Scene.instantiate()
	repeat_node._ready()
	repeat_node.viewer.open_bytes(Fixture.recording(900).to_bytes())
	repeat_node.viewer.set_repeat_range(600, 850)
	repeat_node.viewer.set_repeat_playback(true)
	repeat_node.viewer.toggle_play()
	repeat_node._physics_process(0.0)
	context.equal([repeat_node.viewer.is_seeking(), repeat_node.viewer.is_playing], [true, false], "Repeat navigates to its selected start before playing")
	repeat_node.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	while repeat_node.viewer.is_seeking():
		repeat_node._physics_process(0.0)
	repeat_node.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	repeat_node._physics_process(0.0)
	context.equal([repeat_node.viewer.current_frame(), repeat_node.viewer.is_playing], [600, false], "focus loss prevents selected Repeat navigation from resuming playback")
	_key(repeat_node, KEY_P)
	repeat_node._physics_process(0.0)
	context.equal(repeat_node.viewer.current_frame(), 601, "explicit Play resumes after selected Repeat navigation")
	context.state(repeat_node.viewer.current_frame(), repeat_node.viewer.game.canonical_bytes())
	repeat_node._exit_tree()
	repeat_node.free()
	var node: Node2D = Scene.instantiate()
	node._ready()
	node.viewer.open_bytes(Fixture.recording().to_bytes())
	node.viewer.toggle_play()
	var opened: RefCounted = node.viewer._player.begin_advance()
	context.equal(opened.batch != null, true, "retain expert work during playback")
	node.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	context.equal(node.viewer.is_playing, true, "focus pause preserves active expert ownership")
	node._physics_process(0.0)
	context.equal(node.viewer.current_frame(), 0, "pending focus pause cannot service expert work")
	while true:
		var request: Viewer.Types.Request = opened.batch.next_request()
		if request == null:
			break
		var checksum: PackedByteArray = PackedByteArray()
		var ok: bool
		if request.kind == Viewer.Types.Kind.SAVE:
			var saved: RefCounted = node.viewer.game.save_state(request.frame, request.writer)
			ok = saved.ok
			checksum = saved.checksum
		else:
			ok = node.viewer.game.simulate_frame(request.frame, request.inputs)
		var completed: RefCounted = node.viewer._player.complete_request(request.batch_id, request.request_id, ok, checksum)
		context.equal(completed.code, Viewer.Types.Code.OK, "expert owner completes normally after focus loss")
	node._physics_process(0.0)
	context.equal([node.viewer.current_frame(), node.viewer.is_playing], [1, false], "deferred pause applies before another frame can advance")
	context.equal(node._status.text.contains("Press Play to resume"), true, "focus pause explains how to continue")
	context.state(node.viewer.current_frame(), node.viewer.game.canonical_bytes())
	var corrupt: RefCounted = Fixture.recording()
	corrupt._checksums[16] ^= 1
	node.viewer.open_bytes(corrupt.to_bytes())
	node.viewer.toggle_play()
	node._physics_process(0.0)
	node.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	context.equal(node.viewer.has_failure(), true, "focus pause validates the displayed recorded state")
	context.equal(node.viewer.current_frame(), 1, "failed pause validation preserves the displayed boundary")
	context.equal(node._status.text.contains("Recorded state checksum mismatch"), true, "focus prompt cannot hide a pause validation failure")
	node._exit_tree()
	node.free()
