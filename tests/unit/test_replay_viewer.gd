extends RefCounted

# Value: protects=users can watch downloaded online recordings safely; fails_when=controls drift, imports accept incompatible games or checksum failures continue;
# why_new=core replay tests have no example loading or playback controls; seam=none
const Scene = preload("res://examples/online/replay.tscn")
const Viewer = preload("res://examples/online/replay_viewer.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(
		[
			"controls",
			"rejects_incompatible",
			"stops_at_divergence",
			"scene_controls",
			"navigation",
			"navigation_boundaries",
			"full_length_recording",
			"empty_terminal",
			"input_inspection",
			"dropped_file"
		]
	)


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"dropped_file":
			_dropped_file(context)
		"input_inspection":
			_input_inspection(context)
		"empty_terminal":
			_empty_terminal(context)
		"full_length_recording":
			_full_length_recording(context)
		"navigation_boundaries":
			_navigation_boundaries(context)
		"navigation":
			_navigation(context)
		"scene_controls":
			_scene_controls(context)
		"controls":
			_controls(context)
		"rejects_incompatible":
			_rejects_incompatible(context)
		"stops_at_divergence":
			_stops_at_divergence(context)
	context.finish()


# Value: protects=paused inspection names the selected recorded controls and finalized status; fails_when=inputs are hidden, stale or corrupt;
# why_new=scene status tests cover state checksums only; seam=none
func _input_inspection(context: RefCounted) -> void:
	var node: Node2D = Scene.instantiate()
	node._ready()
	context.equal(node.viewer.has_method("input_summary"), true, "viewer exposes recorded input inspection")
	if not node.viewer.has_method("input_summary"):
		node._exit_tree()
		node.free()
		return
	context.equal(node.viewer.input_summary(), "No recording loaded.", "empty viewer has no input")
	var names: PackedStringArray = PackedStringArray(
		[
			"Neutral",
			"Left",
			"Right",
			"Left+Right",
			"Up",
			"Left+Up",
			"Right+Up",
			"Left+Right+Up",
			"Down",
			"Left+Down",
			"Right+Down",
			"Left+Right+Down",
			"Up+Down",
			"Left+Up+Down",
			"Right+Up+Down",
			"Left+Right+Up+Down"
		]
	)
	for buttons: int in 16:
		for disconnected: bool in [false, true]:
			var replay: Replay = recording(3)
			replay._inputs[0] = buttons
			replay._statuses[0] = Queue.Status.DISCONNECTED if disconnected else Queue.Status.CONFIRMED
			var digest: PackedByteArray = replay.computed_input_digest(0)
			for index: int in Replay.DIGEST_BYTES:
				replay._digests[index] = digest[index]
			context.equal(node.viewer.open_bytes(replay.to_bytes()), true, "complete recorded input imports")
			var expected: String = "Next input at frame 0: P1 %s (%s) | P2 Left (confirmed)." % [names[buttons], "disconnected" if disconnected else "confirmed"]
			context.equal(node.viewer.input_summary(), expected, "inspection decodes every button mask and recorded player status")
			node._refresh()
			context.equal(node._status.text.contains(expected), true, "scene shows selected input without advancing or validating state")
			context.equal(node.viewer.checked_checksum_count(), 0, "reading input does not claim state validation")
	var replay: Replay = recording(3)
	context.equal(node.viewer.open_bytes(replay.to_bytes()), true, "navigation input fixture imports")
	node.viewer.step()
	context.equal(node.viewer.input_summary(), "Next input at frame 1: P1 Right (confirmed) | P2 Up (confirmed).", "stepping inspects the next unapplied row")
	node.viewer.seek(3)
	node.viewer.tick()
	context.equal(node.viewer.input_summary(), "No recorded input at final frame 3.", "final boundary does not reuse the last input")
	node.viewer.seek(0)
	node.viewer.tick()
	context.equal(node.viewer.input_summary(), "Next input at frame 0: P1 Right (confirmed) | P2 Left (confirmed).", "backward navigation restores the selected input")
	for fault: String in ["input", "digest"]:
		var corrupt: Replay = recording(3)
		if fault == "input":
			corrupt._inputs[0] ^= 1
		else:
			corrupt._digests[0] ^= 1
		context.equal(node.viewer.open_bytes(corrupt.to_bytes()), true, "input corruption remains a playback comparison")
		context.equal(node.viewer.input_summary(), "Recorded input at frame 0 is unavailable: input digest mismatch.", "unverified corrupt values are never displayed as controls")
		context.equal(node.viewer.has_failure(), false, "inspection alone does not change playback lifetime")
		node.viewer.step()
		context.equal(node.viewer.has_failure(), true, "playback independently refuses corrupt input")
	context.state(node.viewer.current_frame(), node.viewer.game.canonical_bytes())
	node._exit_tree()
	node.free()


# Value: protects=initial-state-only downloads reopen and validate; fails_when=zero rows imply no file;
# why_new=viewer fixtures previously required positive frame counts; seam=none
func _empty_terminal(context: RefCounted) -> void:
	var initial: Simulation = Simulation.new()
	for changed: bool in [false, true]:
		var replay: Replay = recording(0)
		var node: Node2D = Scene.instantiate()
		node._ready()
		context.equal(node.viewer.open_bytes(replay.to_bytes()), false, "ordinary empty history remains unavailable")
		replay._format_version = Replay.TERMINAL_VERSION
		replay._terminal_checksum = Simulation.checksum(initial.canonical_bytes())
		if changed:
			replay._terminal_checksum[0] ^= 1
		var opened: bool = node.viewer.open_bytes(replay.to_bytes())
		context.equal(opened, true, "terminal checksum makes the initial state a complete recording")
		if not opened:
			node._exit_tree()
			node.free()
			continue
		node._refresh()
		context.equal(node._step_button.disabled, false, "initial checksum can be checked without an input")
		context.equal(node._restart_button.disabled, false, "a valid zero-input recording can restart")
		context.equal(node.viewer.recorded_checksum_count(), 1, "initial boundary has one recorded checksum")
		context.equal(node.viewer.checked_checksum_count(), 0, "opening alone claims no validation")
		node._step_button.pressed.emit()
		context.equal(node.viewer.current_frame(), 0, "validation adds no simulated frame")
		context.equal(node.viewer.has_failure(), changed, "initial mismatch fails rather than reporting completion")
		context.equal(node.viewer.checked_checksum_count(), 0 if changed else 1, "only a matching initial checksum is counted")
		context.bytes_equal(node.viewer.game.canonical_bytes(), initial.canonical_bytes(), 0, "empty replay keeps the initial state")
		if changed:
			var failure: Dictionary = JSON.parse_string(node.viewer.failure_report_bytes().get_string_from_utf8())
			context.equal(failure.failure.frame, 0, "initial mismatch identifies boundary zero")
			context.equal(failure.failure.expected, replay.checksum(0).hex_encode(), "failure keeps expected initial checksum")
			context.equal(failure.failure.actual, Simulation.checksum(initial.canonical_bytes()).hex_encode(), "failure keeps actual initial checksum")
		else:
			context.equal(node.viewer.message.contains("Replay complete"), true, "matching initial validation completes")
			context.equal(node.viewer.message.contains("including the final state"), true, "zero-input completion identifies verified initial/final boundary")
			node._restart_button.pressed.emit()
			context.equal(node.viewer.checked_checksum_count(), 0, "restart clears previous validation coverage")
			node._step_button.pressed.emit()
			context.equal(node.viewer.checked_checksum_count(), 1, "restarted initial validation succeeds")
		node._exit_tree()
		node.free()


# Value: protects=ten-minute online downloads reopen through the native viewer; fails_when=the file cap is below valid output size;
# why_new=existing imports contain at most 300 frames; seam=none
func _full_length_recording(context: RefCounted) -> void:
	var replay: Replay = recording(Viewer.MAX_FRAMES)
	replay._text[0] = "x".repeat(Replay.MAX_TEXT_BYTES)
	var bytes: PackedByteArray = replay.to_bytes()
	context.equal(bytes.size() > 1048576, true, "full checksummed recording exceeds the former 1 MiB cap")
	var process: int = 0 if OS.has_feature("web") else OS.get_process_id()
	var path: String = "user://test-full-length-replay-%d.frrp" % process
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	context.equal(file != null, true, "open process-owned replay import fixture")
	if file == null:
		return
	file.store_buffer(bytes)
	context.equal(file.get_error(), OK, "write complete replay import fixture")
	file.close()
	var node: Node2D = Scene.instantiate()
	node._ready()
	node._native_file(path)
	context.equal(node.viewer.frame_count(), Viewer.MAX_FRAMES, "native file chooser accepts all ten recorded minutes")
	context.equal(node.viewer.recorded_checksum_count(), Viewer.MAX_FRAMES, "full-length import preserves every recorded checksum")
	context.equal(node.viewer.input_change_target(true), 1, "full-rate maximum-length input changes remain navigable")
	node.viewer.step()
	context.equal(node.viewer.current_frame(), 1, "full-length recording starts normal validated playback")
	bytes.resize(Viewer.MAX_BYTES + 1)
	file = FileAccess.open(path, FileAccess.WRITE)
	context.equal(file != null, true, "open oversized replay import fixture")
	if file != null:
		file.store_buffer(bytes)
		context.equal(file.get_error(), OK, "write oversized replay import fixture")
		file.close()
		node._files_dropped(PackedStringArray([path]))
		context.equal(node.viewer.message, Viewer.FILE_SIZE_MESSAGE, "native file chooser rejects one byte beyond the bound")
		context.equal(node.viewer.current_frame(), 1, "refused oversized import preserves existing playback")
	context.state(node.viewer.current_frame(), node.viewer.game.canonical_bytes())
	node._exit_tree()
	node.free()
	context.equal(DirAccess.remove_absolute(ProjectSettings.globalize_path(path)), OK, "remove process-owned replay fixture")


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
	var original: Replay = recording()
	original._text[2] = "fortress-rollback f13cd5c0f2815926785a395947e18da0dbea0dd8"
	context.equal(viewer.open_bytes(original.to_bytes()), true, "dependency refresh preserves original-baseline recordings")
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
	context.equal(viewer.message.begins_with("Could not open replay"), true, "names the malformed reason")
	var older: PackedByteArray = recording().to_bytes()
	older.encode_u16(4, 2)
	context.equal(viewer.open_bytes(older), false, "rejects an older format version")
	context.equal(viewer.message.contains("another format version"), true, "names the version reason")
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
	context.equal(viewer.current_frame(), 7, "stops at the frame that owns the corrupted input")
	context.equal(viewer.is_playing, false, "divergence pauses")
	context.equal(viewer.message.contains("stopped at frame 7"), true, "identifies the frame with the corrupted input")
	var bytes: PackedByteArray = viewer.game.canonical_bytes()
	viewer.step()
	viewer.toggle_play()
	viewer.tick()
	context.bytes_equal(viewer.game.canonical_bytes(), bytes, 7, "failed replay remains stopped")
	viewer.restart()
	context.equal(viewer.current_frame(), 0, "can restart after failure")
	context.state(7, bytes)


static func _button(node: Node, caption: String) -> Button:
	for child: Node in node.find_children("*", "Button", true, false):
		if child is Button and child.text == caption:
			return child
	return null


func _scene_controls(context: RefCounted) -> void:
	var node: Node2D = Scene.instantiate()
	node._ready()
	context.equal(node.viewer.open_bytes(recording().to_bytes()), true, "open recording for real controls")
	node._refresh()
	_button(node, "Play").pressed.emit()
	context.equal(node.viewer.is_playing, true, "Play starts playback")
	_button(node, "Step").pressed.emit()
	context.equal(node.viewer.current_frame(), 1, "Step advances exactly one frame while playing")
	context.equal(node.viewer.is_playing, false, "Step pauses playback")
	context.equal(node.viewer.message, "Paused.", "Step updates paused status")
	var has_paused_label: bool = false
	for label: Node in node.find_children("*", "Label", true, false):
		if label is Label and label.text.begins_with("Paused.\nFrame 1 /"):
			has_paused_label = true
	context.equal(has_paused_label, true, "visible status agrees with paused playback")
	var recording_with_mismatch: Replay = recording()
	recording_with_mismatch._inputs[2 * 7] = 1
	context.equal(node.viewer.open_bytes(recording_with_mismatch.to_bytes()), true, "open recording with checksum disagreement")
	node._refresh()
	_button(node, "Play").pressed.emit()
	for tick: int in range(30):
		node._physics_process(0.0)
	context.equal(node.viewer.current_frame(), 7, "real scene stops at the frame with the corrupted input")
	context.equal(_button(node, "Play").disabled, true, "failed playback disables Play")
	context.equal(_button(node, "Step").disabled, true, "failed playback disables Step")
	context.equal(_button(node, "Restart").disabled, false, "failed playback permits restart")
	_button(node, "Restart").pressed.emit()
	context.equal(_button(node, "Play").disabled, false, "restart enables playback")
	context.equal(_button(node, "Step").disabled, false, "restart enables single stepping")
	context.equal(node.viewer.open_bytes(recording(1).to_bytes()), true, "single-frame boundary")
	node._refresh()
	_button(node, "Play").pressed.emit()
	_button(node, "Step").pressed.emit()
	context.equal(node.viewer.message.begins_with("Replay complete."), true, "completion overrides paused notice")
	context.equal(_button(node, "Play").disabled, true, "completed playback disables Play")
	context.equal(_button(node, "Step").disabled, true, "completed playback disables Step")
	context.state(node.viewer.current_frame(), node.viewer.game.canonical_bytes())
	node._exit_tree()
	node.free()


func _navigation(context: RefCounted) -> void:
	var viewer: Viewer = Viewer.new()
	context.equal(viewer.has_method("seek"), true, "frame navigation is available")
	if not viewer.has_method("seek"):
		return
	var replay: Replay = recording(300)
	context.equal(viewer.open_bytes(replay.to_bytes()), true, "open long recording")
	context.equal(viewer.call("seek", 299), true, "request distant frame")
	context.equal(viewer.current_frame(), 0, "seek starts without blocking")
	viewer.tick()
	context.equal(viewer.current_frame(), 120, "one tick has a bounded replay budget")
	context.equal(viewer.call("is_seeking"), true, "long seek continues later")
	viewer.call("cancel_seek")
	viewer.tick()
	context.equal(viewer.current_frame(), 120, "cancel pauses at a validated boundary")
	context.equal(viewer.call("seek", 30), true, "backward seek restarts sequential validation")
	viewer.tick()
	var expected: Simulation = Simulation.new()
	for frame: int in 30:
		expected.simulate_frame(frame, replay.inputs(frame))
	context.bytes_equal(viewer.game.canonical_bytes(), expected.canonical_bytes(), 30, "backward navigation canonical equality")
	context.equal(viewer.call("is_seeking"), false, "seek reaches exact target")
	context.equal(viewer.is_playing, false, "navigation finishes paused")
	for invalid: int in [-1, 301, 9223372036854775807]:
		context.equal(viewer.call("seek", invalid), false, "reject invalid target")
		context.equal(viewer.current_frame(), 30, "invalid target preserves frame")
	context.equal(viewer.call("seek", 300), true, "can navigate to final boundary")
	while viewer.call("is_seeking"):
		viewer.tick()
	context.equal(viewer.current_frame(), 300, "seek completes recording")
	context.equal(viewer.call("seek", 0), true, "return to initial boundary")
	context.equal(viewer.current_frame(), 0, "zero target resets immediately")
	replay._inputs[14] = 1
	context.equal(viewer.open_bytes(replay.to_bytes()), true, "load shape-correct corruption")
	viewer.call("seek", 300)
	viewer.tick()
	context.equal(viewer.current_frame(), 7, "seek cannot skip the corrupted input")
	context.equal(viewer.call("is_seeking"), false, "failure cancels seek")
	context.equal(viewer.can_step(), false, "failure remains terminal")
	context.equal(viewer.message.contains("stopped at frame 7"), true, "failure visible during navigation")
	context.state(7, viewer.game.canonical_bytes())
	var node: Node2D = Scene.instantiate()
	node._ready()
	node.viewer.open_bytes(recording(300).to_bytes())
	node._refresh()
	var target: SpinBox = node.find_children("*", "SpinBox", true, false)[0]
	target.get_line_edit().text = "299"
	_button(node, "Go").pressed.emit()
	context.equal(node.viewer.is_seeking(), true, "Go applies typed target")
	context.equal(_button(node, "Cancel seek").disabled, false, "seek exposes cancel")
	context.equal(_button(node, "Play").disabled, true, "seek disables playback controls")
	node._physics_process(0.0)
	context.equal(node.viewer.current_frame(), 120, "scene seek budget enforced")
	_button(node, "Cancel seek").pressed.emit()
	node._physics_process(0.0)
	context.equal(node.viewer.current_frame(), 120, "real cancel pauses")
	context.equal(_button(node, "Play").disabled, false, "cancel permits playback")
	context.equal(node.viewer.message, "Paused.", "cancel updates visible message")
	node._exit_tree()
	node.free()


func _navigation_boundaries(context: RefCounted) -> void:
	for boundary: int in [0, 8, 120]:
		var replay: Replay = recording(300)
		if boundary == 0:
			replay._checksums[0] ^= 1
		else:
			replay._inputs[2 * (boundary - 1)] = 1
		var viewer: Viewer = Viewer.new()
		context.equal(viewer.open_bytes(replay.to_bytes()), true, "shape-correct corruption loads")
		viewer.seek(299 if boundary == 120 else boundary)
		viewer.tick()
		if boundary == 120:
			viewer.cancel_seek()
		# A corrupted input row is refused by the frame that owns it, one frame before the
		# boundary whose checksum used to report it.
		var failure: int = 0 if boundary == 0 else boundary - 1
		context.equal(viewer.current_frame(), failure, "navigation stops at the frame that owns the failure")
		context.equal(viewer.can_step(), false, "selected saved boundary must match")
		context.equal(viewer.message.contains("stopped at frame %d" % failure), true, "boundary mismatch visible")
		context.equal([viewer.is_playing, viewer.is_seeking()], [false, false], "boundary failure stops all work")
		var message: String = viewer.message
		viewer.cancel_seek()
		context.equal(viewer.message, message, "cancel cannot erase failure")
		context.equal(viewer.seek(-1), false, "invalid seek rejected after failure")
		context.equal(viewer.open_bytes(PackedByteArray([0])), false, "invalid import rejected after failure")
		context.equal(viewer.can_step(), false, "invalid operations preserve failure latch")
		viewer.restart()
		context.equal(viewer.can_step(), true, "restart clears navigation failure latch")
		if boundary > 0:
			viewer.seek(0)
			context.equal(viewer.can_step(), true, "earlier healthy boundary remains inspectable")
	var viewer: Viewer = Viewer.new()
	viewer.open_bytes(recording(1).to_bytes())
	viewer.seek(1)
	viewer.tick()
	viewer.seek(1)
	context.equal(viewer.message.begins_with("Replay complete."), true, "same final target preserves completion")


# Value: protects=dropped replays use bounded validated import; fails_when=drop wiring bypasses validation or replaces busy playback;
# why_new=file chooser tests never deliver a dropped file list; seam=real files
func _dropped_file(context: RefCounted) -> void:
	var node: Node2D = Scene.instantiate()
	node._ready()
	context.equal(node.has_method("_files_dropped"), true, "viewer accepts dropped files")
	if not node.has_method("_files_dropped"):
		node.free()
		return
	var process: int = 0 if OS.has_feature("web") else OS.get_process_id()
	var path: String = "user://test-dropped-replay-%d.frrp" % process
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(recording(8).to_bytes())
	file.close()
	node._files_dropped(PackedStringArray([path]))
	context.equal(node.viewer.frame_count(), 8, "drop opens identified recording")
	node.viewer.step()
	var original: PackedByteArray = node.viewer.game.canonical_bytes()
	for paths: PackedStringArray in [PackedStringArray(), PackedStringArray([path, path]), PackedStringArray([path + ".missing"])]:
		node._files_dropped(paths)
		context.equal(node.viewer.current_frame(), 1, "rejected drop preserves selected frame")
		context.bytes_equal(node.viewer.game.canonical_bytes(), original, 1, "rejected drop preserves canonical state")
	file = FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(PackedByteArray([0, 1, 2]))
	file.close()
	node._files_dropped(PackedStringArray([path]))
	context.equal(node.viewer.current_frame(), 1, "malformed dropped recording preserves playback")
	context.equal(node.viewer.message.contains("malformed"), true, "drop uses decoder's failure explanation")
	node._is_scrubbing = true
	var message: String = node.viewer.message
	node._files_dropped(PackedStringArray([path + ".missing"]))
	context.equal(node.viewer.message, message, "active scrub preserves controls and message")
	node._is_scrubbing = false
	var pending: RefCounted = node.viewer._player.begin_advance()
	context.equal(pending.code, Types.Code.READY, "manual request owns playback")
	node._files_dropped(PackedStringArray([path + ".missing"]))
	context.equal(node.viewer.message, message, "active game work preserves message")
	node.viewer._player.terminate()
	node._exit_tree()
	node.free()
	context.equal(DirAccess.remove_absolute(ProjectSettings.globalize_path(path)), OK, "remove owned drop fixture")
