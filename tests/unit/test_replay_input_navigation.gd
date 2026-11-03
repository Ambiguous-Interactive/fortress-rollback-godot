extends RefCounted

# Value: protects=input-change navigation reaches exact recorded controls and statuses through verified bounded seeks;
# fails_when=navigation skips status changes or corruption; why_new=checkpoint navigation ignores input transitions; seam=none
const Fixture = preload("res://tests/unit/test_replay_viewer.gd")
const Viewer = preload("res://examples/online/replay_viewer.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const Simulation = preload("res://examples/offline/simulation.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(
		[
			"status_navigation",
			"player_navigation",
			"input_change_navigation",
			"input_change_integrity",
			"input_change_controls",
			"checksum_navigation",
			"checksum_navigation_integrity",
			"checksum_navigation_controls"
		]
	)


func run_case(name: String, context: RefCounted) -> void:
	var viewer: Viewer = Viewer.new()
	context.equal(viewer.has_method("input_change_target"), true, "viewer exposes input-change destinations")
	if name.begins_with("checksum_"):
		context.equal(viewer.has_method("recorded_checksum_target"), true, "viewer exposes recorded-checksum destinations")
		if viewer.has_method("recorded_checksum_target"):
			call("_" + name, context)
	elif viewer.has_method("input_change_target"):
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


# Value: protects=sparse recorded state boundaries remain discoverable before they enter the cache;
# fails_when=checksum navigation uses visited checkpoints or skips terminal checks; why_new=input changes do not identify state evidence; seam=none
func _sparse_recording() -> Replay:
	var replay: Replay = Fixture.recording(900)
	for frame: int in replay.frame_count():
		if frame not in [0, 450, 700]:
			replay._flags[frame] = 0
	var final: Simulation = Simulation.new()
	for frame: int in replay.frame_count():
		final.simulate_frame(frame, replay.inputs(frame))
	replay._format_version = Replay.TERMINAL_VERSION
	replay._terminal_checksum = Simulation.checksum(final.canonical_bytes())
	return replay


func _checksum_navigation(context: RefCounted) -> void:
	var viewer: Viewer = Viewer.new()
	for forward: bool in [false, true]:
		context.equal(viewer.call("recorded_checksum_target", forward), -1, "empty viewer has no checksum boundary")
		context.equal(viewer.call("seek_recorded_checksum", forward), false, "empty viewer refuses checksum navigation")
	var replay: Replay = _sparse_recording()
	context.equal(viewer.open_bytes(replay.to_bytes()), true, "sparse recorded checksums open")
	context.equal(viewer.call("recorded_checksum_target", false), -1, "initial boundary has no preceding checksum")
	context.equal(viewer.checked_checksum_count(), 0, "destination discovery does not validate a state")
	for target: int in [450, 700, 900]:
		context.equal(viewer.call("recorded_checksum_target", true), target, "destination comes from recording rather than visited cache")
		context.equal(viewer.call("seek_recorded_checksum", true), true, "checksum navigation begins")
		if viewer.is_seeking():
			context.equal(viewer.call("recorded_checksum_target", false), -1, "active seek suspends checksum destinations")
			context.equal(viewer.call("seek_recorded_checksum", true), false, "second checksum seek preserves active navigation")
		_finish(context, viewer, replay, target)
		context.equal(viewer.current_state_coverage_message(), "State at frame %d: recorded checksum matched." % target, "destination state was verified during this visit")
	context.equal(viewer.call("recorded_checksum_target", true), -1, "terminal checksum has no successor")
	context.equal(viewer.checked_checksum_count(), 4, "only four distinct recorded checksums counted")
	for target: int in [700, 450, 0]:
		context.equal(viewer.call("seek_recorded_checksum", false), true, "backward checksum navigation begins")
		_finish(context, viewer, replay, target)
	context.equal(viewer.checked_checksum_count(), 4, "revisiting checksums does not inflate coverage")
	viewer.seek(500)
	_finish(context, viewer, replay, 500)
	context.equal(viewer.call("recorded_checksum_target", false), 450, "interior state finds preceding recorded checksum")
	context.equal(viewer.call("recorded_checksum_target", true), 700, "interior state finds following recorded checksum")
	viewer.seek(0)
	context.equal(viewer.open_bytes(PackedByteArray([0])), false, "malformed replacement refuses")
	context.equal(viewer.call("recorded_checksum_target", true), 450, "failed import preserves checksum index")
	viewer.open_bytes(_recording(10).to_bytes())
	for forward: bool in [false, true]:
		context.equal(viewer.call("recorded_checksum_target", forward), -1, "checksum-free recording clears previous destinations")
		context.equal(viewer.call("seek_recorded_checksum", forward), false, "checksum-free recording cannot invent evidence")
	viewer.open_bytes(Fixture.recording(1).to_bytes())
	context.equal(viewer.call("recorded_checksum_target", true), -1, "single initial checksum has no successor")
	viewer.step()
	context.equal(viewer.call("recorded_checksum_target", false), 0, "historical final state can return to its initial checksum")
	var initial_only: Replay = Fixture.recording(0)
	initial_only._format_version = Replay.TERMINAL_VERSION
	initial_only._terminal_checksum = Simulation.checksum(Simulation.new().canonical_bytes())
	viewer.open_bytes(initial_only.to_bytes())
	for forward: bool in [false, true]:
		context.equal(viewer.call("recorded_checksum_target", forward), -1, "initial-state-only checksum has no neighboring boundary")
		context.equal(viewer.call("seek_recorded_checksum", forward), false, "initial-state-only navigation preserves unchecked state")
	context.equal(viewer.checked_checksum_count(), 0, "absent destination does not validate the initial state")
	context.state(viewer.current_frame(), viewer.game.canonical_bytes())


func _checksum_navigation_integrity(context: RefCounted) -> void:
	for fault: String in ["input", "checksum", "terminal"]:
		var replay: Replay = _sparse_recording()
		if fault == "input":
			replay._inputs[240] ^= 1
		elif fault == "checksum":
			replay._checksums[450 * Replay.CHECKSUM_BYTES] ^= 1
		else:
			replay._terminal_checksum[0] ^= 1
		var viewer: Viewer = Viewer.new()
		context.equal(viewer.open_bytes(replay.to_bytes()), true, "shape-valid corruption remains playback-owned")
		for _destination: int in 3:
			if viewer.has_failure():
				break
			viewer.call("seek_recorded_checksum", true)
			while viewer.is_seeking():
				viewer.tick()
		var expected: int = {"input": 120, "checksum": 450, "terminal": 900}[fault]
		context.equal(viewer.current_frame(), expected, "checksum navigation stops at the owning corrupt boundary")
		context.equal(viewer.has_failure(), true, "navigation cannot skip input or state evidence")
		context.equal(viewer.call("recorded_checksum_target", false), -1, "failure hides checksum destinations")
		context.equal(viewer.call("seek_recorded_checksum", true), false, "failed navigation requires restart")
		context.state(viewer.current_frame(), viewer.game.canonical_bytes())


func _checksum_navigation_controls(context: RefCounted) -> void:
	var node: Node2D = Fixture.Scene.instantiate()
	node._ready()
	var previous: Button = Fixture._button(node, "Previous recorded checksum")
	var following: Button = Fixture._button(node, "Next recorded checksum")
	context.equal(previous != null and following != null, true, "scene exposes recorded-checksum actions")
	if previous != null and following != null:
		context.equal(previous.disabled and following.disabled, true, "empty scene disables checksum actions")
		node.viewer.open_bytes(_sparse_recording().to_bytes())
		node._refresh()
		context.equal(previous.disabled, true, "initial checksum has no preceding boundary")
		context.equal(following.disabled, false, "unvisited recorded checksum is navigable")
		following.pressed.emit()
		context.equal(previous.disabled and following.disabled, true, "ongoing seek disables both checksum actions")
		while node.viewer.is_seeking():
			node._physics_process(0.0)
		context.equal(node.viewer.current_frame(), 450, "button seeks to recorded boundary")
		previous.pressed.emit()
		context.equal(node.viewer.current_frame(), 0, "button restores initial recorded checksum")
		context.state(node.viewer.current_frame(), node.viewer.game.canonical_bytes())
	node._exit_tree()
	node.free()


# Value: protects=disconnect inspection skips ordinary changing controls while preserving verified history;
# fails_when=status-only navigation follows button changes or bypasses corruption; why_new=ordinary change navigation mixes both; seam=none
func _status_navigation(context: RefCounted) -> void:
	var viewer: Viewer = Viewer.new()
	context.equal(viewer.has_method("status_change_target"), true, "viewer exposes status-only destinations")
	if not viewer.has_method("status_change_target"):
		return
	context.equal(viewer.call("status_change_target", true), -1, "empty viewer has no status transition")
	var replay: Replay = _recording()
	viewer.open_bytes(replay.to_bytes())
	context.equal(viewer.call("input_change_target", true), 450, "ordinary navigation retains control changes")
	context.equal(viewer.call("status_change_target", true), 600, "status-only navigation skips changing controls")
	context.equal(viewer.call("seek_status_change", true), true, "status navigation uses normal verified seeking")
	context.equal(viewer.call("status_change_target", true), -1, "active seeking suspends status destinations")
	_finish(context, viewer, replay, 600)
	context.equal(viewer.input_summary().contains("disconnected"), true, "selected input identifies the departed player")
	context.equal(viewer.call("status_change_target", true), -1, "ordinary later control changes are not status transitions")
	viewer.seek(900)
	_finish(context, viewer, replay, 900)
	context.equal(viewer.call("status_change_target", false), 600, "final boundary can return to the disconnect")
	viewer.call("seek_status_change", false)
	_finish(context, viewer, replay, 600)
	context.equal(viewer.call("status_change_target", false), 0, "first input establishes the original statuses")
	context.equal(viewer.open_bytes(PackedByteArray([0])), false, "invalid replacement refuses")
	context.equal(viewer.call("status_change_target", false), 0, "invalid import preserves the status index")
	viewer.open_bytes(_recording(100).to_bytes())
	context.equal(viewer.call("status_change_target", true), -1, "successful replacement clears old disconnect destinations")
	var other_player: Replay = _recording()
	for frame: int in range(600, other_player.frame_count()):
		other_player._statuses[frame * 2] = Queue.Status.CONFIRMED
		other_player._statuses[frame * 2 + 1] = Queue.Status.DISCONNECTED
		var digest: PackedByteArray = other_player.computed_input_digest(frame)
		for index: int in Replay.DIGEST_BYTES:
			other_player._digests[frame * Replay.DIGEST_BYTES + index] = digest[index]
	viewer.open_bytes(other_player.to_bytes())
	context.equal(viewer.call("status_change_target", true), 600, "either player's status change is indexed")
	viewer.call("seek_status_change", true)
	_finish(context, viewer, other_player, 600)
	for fault_frame: int in [120, 600]:
		var damaged: Replay = _recording()
		damaged._digests[fault_frame * Replay.DIGEST_BYTES] ^= 1
		viewer.open_bytes(damaged.to_bytes())
		viewer.call("seek_status_change", true)
		while viewer.is_seeking():
			viewer.tick()
		context.equal(viewer.current_frame(), fault_frame, "status navigation checks the required prefix and destination input")
		context.equal(viewer.has_failure(), true, "corruption cannot be skipped by status navigation")
		context.equal(viewer.call("status_change_target", false), -1, "failure suspends status destinations")
	var node: Node2D = Fixture.Scene.instantiate()
	node._ready()
	var filter_button: CheckButton = node.find_child("StatusChangesOnly", true, false) as CheckButton
	context.equal(filter_button != null, true, "scene exposes a status-only navigation filter")
	if filter_button != null:
		node.viewer.open_bytes(replay.to_bytes())
		node._refresh()
		filter_button.button_pressed = true
		var following: Button = Fixture._button(node, "Next status change")
		context.equal(following != null, true, "filtered action names status changes")
		if following != null:
			following.pressed.emit()
			context.equal(filter_button.disabled, true, "active seek holds the filter")
			while node.viewer.is_seeking():
				node._physics_process(0.0)
			context.equal(node.viewer.current_frame(), 600, "visible action reaches the disconnect directly")
			context.equal(following.disabled, true, "status filter has no later disconnect")
			filter_button.button_pressed = false
			context.equal(following.text, "Next input change", "clearing the filter restores ordinary change navigation")
			context.equal(following.disabled, false, "later controls remain reachable after removing the filter")
			node._timeline_drag_started()
			context.equal(filter_button.disabled, true, "held timeline suspends the filter")
			following.pressed.emit()
			context.equal(node.viewer.current_frame(), 600, "held timeline refuses navigation")
			node._timeline_drag_ended(false)
			context.equal(filter_button.disabled, false, "released timeline restores the filter")
	context.state(node.viewer.current_frame(), node.viewer.game.canonical_bytes())
	node._exit_tree()
	node.free()


# Value: protects=inspection isolates one player's controls and disconnects without skipping verification;
# fails_when=another player's changes obscure the selected player; why_new=existing filters select event type only; seam=none
func _player_navigation(context: RefCounted) -> void:
	var viewer: Viewer = Viewer.new()
	context.equal(viewer.has_method("set_change_player"), true, "viewer can isolate one player's recorded changes")
	if not viewer.has_method("set_change_player"):
		return
	var replay: Replay = _recording()
	context.equal(viewer.open_bytes(replay.to_bytes()), true, "two-player navigation fixture opens")
	context.equal(viewer.call("change_player"), -1, "navigation initially includes every player")
	for slot: int in [0, 1]:
		context.equal(viewer.call("set_change_player", slot), true, "either recorded player can be selected")
		context.equal(viewer.input_change_target(true), 450 if slot == 0 else 700, "other player's controls are excluded")
		context.equal(viewer.status_change_target(true), 600 if slot == 0 else -1, "status-only navigation intersects the player selection")
	for invalid: int in [-2, 2, 2147483647]:
		context.equal(viewer.call("set_change_player", invalid), false, "out-of-range player filter refuses")
		context.equal(viewer.call("change_player"), 1, "invalid selection preserves the accepted player")
	context.equal(viewer.seek_input_change(true), true, "selected player uses ordinary verified navigation")
	context.equal(viewer.call("set_change_player", 0), false, "active seeking preserves selected player")
	_finish(context, viewer, replay, 700)
	context.equal(viewer.input_change_target(false), 0, "selected player skips the other's earlier changes")
	context.equal(viewer.call("set_change_player", 0), true, "idle inspection changes selected player without moving state")
	context.equal(viewer.input_change_target(false), 600, "selected player's disconnect counts as an input change")
	context.equal(viewer.seek_status_change(false), true, "selected status navigation reaches its own disconnect")
	_finish(context, viewer, replay, 600)
	context.equal(viewer.input_summary().contains("P1 Left (disconnected)"), true, "full selected input remains visible")
	context.equal(viewer.open_bytes(PackedByteArray([0])), false, "invalid replacement refuses")
	context.equal(viewer.call("change_player"), 0, "failed import preserves selected player")
	context.equal(viewer.status_change_target(false), 0, "failed import preserves player-specific indexes")
	viewer.restart()
	context.equal(viewer.call("change_player"), 0, "restart retains inspection preference")
	viewer.open_bytes(_recording(100).to_bytes())
	context.equal(viewer.input_change_target(true), -1, "new recording replaces player-specific indexes")
	context.equal(viewer.call("set_change_player", -1), true, "all-player navigation can be restored")
	var single: Replay = _recording(1)
	viewer.open_bytes(single.to_bytes())
	for slot: int in [-1, 0, 1]:
		viewer.call("set_change_player", slot)
		context.equal(viewer.input_change_target(true), -1, "single-row recording has no later player change")
		viewer.step()
		context.equal(viewer.input_change_target(false), 0, "final state can return to either player's first input")
		viewer.restart()
	var initial_only: Replay = Fixture.recording(0)
	initial_only._format_version = Replay.TERMINAL_VERSION
	initial_only._terminal_checksum = Simulation.checksum(Simulation.new().canonical_bytes())
	viewer.open_bytes(initial_only.to_bytes())
	for slot: int in [-1, 0, 1]:
		viewer.call("set_change_player", slot)
		context.equal(viewer.input_change_target(false), -1, "initial-state-only recording has no player's input")
		context.equal(viewer.status_change_target(true), -1, "initial-state-only recording has no player's status")
	var damaged: Replay = _recording()
	damaged._digests[120 * Replay.DIGEST_BYTES] ^= 1
	viewer.open_bytes(damaged.to_bytes())
	viewer.call("set_change_player", 1)
	viewer.seek_input_change(true)
	while viewer.is_seeking():
		viewer.tick()
	context.equal([viewer.current_frame(), viewer.has_failure()], [120, true], "player filter cannot skip corrupt preceding input")
	context.equal(viewer.input_change_target(true), -1, "failed playback exposes no player destination")
	var node: Node2D = Fixture.Scene.instantiate()
	node._ready()
	var selector: OptionButton = node.find_child("ChangePlayer", true, false) as OptionButton
	context.equal(selector != null, true, "scene exposes the recorded-player selector")
	if selector != null:
		node.viewer.open_bytes(replay.to_bytes())
		node._refresh()
		context.equal(selector.item_count, 3, "selector includes all players and both recorded slots")
		selector.select(2)
		selector.item_selected.emit(2)
		context.equal(node.viewer.call("change_player"), 1, "visible selector chooses Player 2")
		node._next_input_change.pressed.emit()
		context.equal(selector.disabled, true, "active navigation disables the player selector")
		while node.viewer.is_seeking():
			node._physics_process(0.0)
		context.equal(node.viewer.current_frame(), 700, "visible action reaches selected player's controls")
		node._status_changes_only.button_pressed = true
		context.equal(node._next_input_change.disabled, true, "selected player with no disconnect has no status destination")
		node._timeline_drag_started()
		selector.select(1)
		selector.item_selected.emit(1)
		context.equal(node.viewer.call("change_player"), 1, "held timeline preserves player selection")
		context.equal(selector.selected, 2, "refused selector change restores its visible accepted value")
		node._timeline_drag_ended(false)
		selector.select(1)
		selector.item_selected.emit(1)
		context.equal(node._previous_input_change.disabled, false, "other player's disconnect becomes available after release")
		node._previous_input_change.pressed.emit()
		while node.viewer.is_seeking():
			node._physics_process(0.0)
		context.equal(node.viewer.current_frame(), 600, "player and status filters combine through actual scene controls")
	context.state(node.viewer.current_frame(), node.viewer.game.canonical_bytes())
	node._exit_tree()
	node.free()
