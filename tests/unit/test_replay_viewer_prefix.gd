extends RefCounted

# Value: protects=selected replay exports preserve original history and evidence; fails_when=exports use a later visited state or invent terminal checksums;
# why_new=core prefixes have no displayed-frame or viewer-lifetime boundary; seam=none
const Fixture = preload("res://tests/unit/test_replay_viewer.gd")
const Viewer = preload("res://examples/online/replay_viewer.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")


class ExportingGame:
	extends RefCounted
	var original: Simulation
	var viewer: WeakRef
	var boundary: int
	var attempts: int = 0
	var can_export: bool = true
	var exported: PackedByteArray = PackedByteArray([1])

	func _attempt(kind: int) -> void:
		if boundary != kind:
			return
		attempts += 1
		var owner: RefCounted = viewer.get_ref()
		can_export = owner.can_export_prefix()
		exported = owner.prefix_bytes()

	func save_state(frame: int, writer: RefCounted) -> Driver.SaveResult:
		_attempt(Types.Kind.SAVE)
		return original.save_state(frame, writer)

	func load_state(frame: int, reader: RefCounted) -> bool:
		_attempt(Types.Kind.LOAD)
		return original.load_state(frame, reader)

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		_attempt(Types.Kind.ADVANCE)
		return original.simulate_frame(frame, inputs)


func cases() -> PackedStringArray:
	return PackedStringArray(["selected_prefix", "prefix_boundaries", "prefix_guards", "prefix_controls"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"selected_prefix":
			_selected_prefix(context)
		"prefix_boundaries":
			_prefix_boundaries(context)
		"prefix_guards":
			_prefix_guards(context)
		"prefix_controls":
			_prefix_controls(context)
	context.finish()


func _terminal(recording: Replay) -> Replay:
	var game: Simulation = Simulation.new()
	for frame: int in recording.frame_count():
		game.simulate_frame(frame, recording.inputs(frame))
	recording._format_version = Replay.TERMINAL_VERSION
	recording._terminal_checksum = Simulation.checksum(game.canonical_bytes())
	return recording


func _navigate(viewer: Viewer, frame: int) -> void:
	viewer.seek(frame)
	while viewer.is_seeking():
		viewer.tick()


func _check_export(context: RefCounted, viewer: Viewer, original: Replay, frame: int) -> Replay:
	var exported: PackedByteArray = viewer.prefix_bytes()
	var decoded: Replay = Replay.new()
	context.equal(decoded.decode(exported), Replay.DecodeCode.OK, "export is a complete portable recording")
	context.equal(decoded.frame_count(), frame, "prefix ends at the displayed state boundary")
	context.equal(decoded._text, original._text, "all original metadata remains exact")
	context.equal(decoded.neutral_input(), original.neutral_input(), "neutral input remains original")
	for index: int in frame:
		context.bytes_equal(decoded.input_digest(index), original.input_digest(index), index, "stored input digests remain original")
		context.bytes_equal(decoded.checksum(index), original.checksum(index), index, "stored state checksums remain original")
		for slot: int in original.player_count():
			context.bytes_equal(decoded.inputs(index).read(slot).bytes, original.inputs(index).read(slot).bytes, index, "export keeps original input bytes")
			context.equal(decoded.inputs(index).read(slot).status, original.inputs(index).read(slot).status, "export keeps finalized statuses")
	var game: Simulation = Simulation.new()
	var player: Player = Player.new()
	context.equal(player.configure(decoded, game, Simulation.SNAPSHOT_BYTES), Types.Code.OK, "export configures an independent callback player")
	while not player.is_complete() and player.failure_frame() < 0:
		context.equal(player.step(), Types.Code.OK, "exported history replays independently")
	var expected: Simulation = Simulation.new()
	for index: int in frame:
		expected.simulate_frame(index, original.inputs(index))
	context.bytes_equal(game.canonical_bytes(), expected.canonical_bytes(), frame, "export reproduces original canonical history")
	context.equal(player.is_complete(), true, "export reaches its own complete ending")
	context.state(frame, game.canonical_bytes())
	return decoded


func _selected_prefix(context: RefCounted) -> void:
	for terminal: bool in [false, true]:
		var replay: Replay = Fixture.recording(610)
		if terminal:
			replay = _terminal(replay)
		var viewer: Viewer = Viewer.new()
		context.equal(viewer.open_bytes(replay.to_bytes()), true, "original fixture imports")
		_navigate(viewer, 610)
		_navigate(viewer, 301)
		var prior: PackedByteArray = viewer.game.canonical_bytes()
		var decoded: Replay = _check_export(context, viewer, replay, 301)
		context.equal(decoded.checksum(301), replay.checksum(301) if terminal else PackedByteArray(), "only existing v6 boundary evidence survives trimming")
		context.equal(viewer.current_frame(), 301, "export does not revisit previously explored later frames")
		context.bytes_equal(viewer.game.canonical_bytes(), prior, 301, "export does not change displayed game state")
		var bytes: PackedByteArray = viewer.prefix_bytes()
		bytes[0] = 0
		context.equal(viewer.prefix_bytes(), decoded.to_bytes(), "exported bytes are owned and cannot mutate later exports")


func _prefix_boundaries(context: RefCounted) -> void:
	var viewer: Viewer = Viewer.new()
	context.equal(viewer.prefix_bytes(), PackedByteArray(), "empty viewer cannot export")
	var replay: Replay = Fixture.recording(4)
	viewer.open_bytes(replay.to_bytes())
	context.equal(viewer.can_export_prefix(), false, "historical zero-input prefix cannot reopen in this viewer")
	context.equal(viewer.prefix_bytes(), PackedByteArray(), "historical initial boundary has no downloadable prefix")
	_navigate(viewer, 4)
	_check_export(context, viewer, replay, 4)
	replay = _terminal(Fixture.recording(4))
	viewer.open_bytes(replay.to_bytes())
	context.equal(viewer.checked_checksum_count(), 0, "import has not validated the initial state")
	var initial: Replay = _check_export(context, viewer, replay, 0)
	context.equal(initial.checksum(0), replay.checksum(0), "initial-only export keeps its recorded evidence without claiming viewer validation")
	context.equal(viewer.checked_checksum_count(), 0, "export never claims state validation")
	_navigate(viewer, 4)
	var final: Replay = _check_export(context, viewer, replay, 4)
	context.equal(final.checksum(4), replay.checksum(4), "complete export retains the original terminal checksum")
	var sparse: Replay = _terminal(Fixture.recording(4))
	sparse._flags[2] = 0
	viewer.open_bytes(sparse.to_bytes())
	_navigate(viewer, 2)
	var unverified: Replay = _check_export(context, viewer, sparse, 2)
	context.equal(unverified.checksum(2), PackedByteArray(), "missing selected-ending evidence cannot become a terminal checksum")
	context.equal(unverified._format_version, Replay.FORMAT_VERSION, "sparse prefix retains the historical format when no final evidence exists")
	sparse._flags[0] = 0
	viewer.open_bytes(sparse.to_bytes())
	context.equal(viewer.can_export_prefix(), false, "v6 source alone cannot invent absent initial-state evidence")
	var empty: Replay = _terminal(Fixture.recording(0))
	viewer.open_bytes(empty.to_bytes())
	_check_export(context, viewer, empty, 0)
	var corrupt: Replay = Fixture.recording(8)
	corrupt._digests[4 * Replay.DIGEST_BYTES] ^= 1
	viewer.open_bytes(corrupt.to_bytes())
	_navigate(viewer, 8)
	context.equal(viewer.has_failure(), true, "original recording stops at corrupt row four")
	var report: PackedByteArray = viewer.failure_report_bytes()
	_check_export(context, viewer, corrupt, 4)
	context.equal(viewer.failure_report_bytes(), report, "exporting preceding history preserves failure evidence")


func _prefix_guards(context: RefCounted) -> void:
	for kind: int in [Types.Kind.SAVE, Types.Kind.LOAD, Types.Kind.ADVANCE]:
		var guarded: Viewer = Viewer.new()
		guarded.open_bytes(_terminal(Fixture.recording(4)).to_bytes())
		guarded.step()
		var game: ExportingGame = ExportingGame.new()
		game.original = guarded.game
		game.viewer = weakref(guarded)
		game.boundary = kind
		guarded._player._game = game
		if kind == Types.Kind.LOAD:
			guarded.seek(0)
		else:
			guarded.step()
		context.equal(game.attempts > 0, true, "real callback attempts prefix export")
		context.equal(game.can_export, false, "executing game callback blocks prefix eligibility")
		context.equal(game.exported, PackedByteArray(), "executing game callback cannot export a partially serviced boundary")
		context.equal(guarded.has_failure(), false, "refused export leaves ordinary callbacks healthy")
	var viewer: Viewer = Viewer.new()
	viewer.open_bytes(_terminal(Fixture.recording(310)).to_bytes())
	viewer.step()
	var result: Types.Result = viewer._player.begin_validate_current_frame()
	context.equal(result.code, Types.Code.READY, "manual validation owns the displayed boundary")
	context.equal(viewer.can_export_prefix(), false, "manual work blocks export eligibility")
	context.equal(viewer.prefix_bytes(), PackedByteArray(), "manual work blocks exported bytes")
	context.equal(viewer._player._batch, result.batch, "refused export preserves the open manual batch")
	viewer._player.terminate()
	viewer.restart()
	viewer.seek(310)
	context.equal(viewer.can_export_prefix(), false, "active seek blocks export eligibility")
	context.equal(viewer.prefix_bytes(), PackedByteArray(), "active seek cannot export an intermediate position")
	context.equal(viewer.is_seeking(), true, "refused export preserves the navigation target")
	viewer.cancel_seek()
	context.equal(viewer.can_export_prefix(), true, "cancelled seek exposes its actual selected boundary")


func _prefix_controls(context: RefCounted) -> void:
	var node: Node2D = Fixture.Scene.instantiate()
	node._ready()
	var button: Button = Fixture._button(node, "Download prefix")
	context.equal(button != null, true, "scene exposes prefix download")
	if button != null:
		context.equal(button.disabled, true, "empty scene disables prefix download")
		var recording: Replay = Fixture.recording(310)
		recording._text[0] = "prefix-file-test-%d" % (0 if OS.has_feature("web") else OS.get_process_id())
		node.viewer.open_bytes(recording.to_bytes())
		node._refresh()
		context.equal(button.disabled, true, "unusable historical initial prefix stays disabled")
		node.viewer.step()
		node._refresh()
		context.equal(button.disabled, false, "displayed original history enables export")
		var filename: String = node.viewer.prefix_filename()
		var path: String = "user://" + filename
		var expected: PackedByteArray = node.viewer.prefix_bytes()
		button.pressed.emit()
		var downloaded: PackedByteArray = expected
		var removed: int = OK
		if not OS.has_feature("web"):
			var file: FileAccess = FileAccess.open(path, FileAccess.READ)
			downloaded = file.get_buffer(file.get_length()) if file != null else PackedByteArray()
			if file != null:
				file.close()
			removed = DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		context.bytes_equal(downloaded, expected, 1, "real native download writes the selected portable bytes; browser requests the same controller bytes")
		context.equal(removed, OK, "native process-owned download is removed")
		var reopened: Viewer = Viewer.new()
		context.equal(reopened.open_bytes(downloaded), true, "download reopens through the actual game viewer")
		reopened.step()
		context.bytes_equal(reopened.game.canonical_bytes(), node.viewer.game.canonical_bytes(), 1, "download replays to the original displayed state")
		context.equal(not node._prefix_notice.is_empty(), true, "download reports its outcome")
		context.equal(node._prefix_notice.contains("Could not"), false, "successful native write or browser request is reported")
		node.viewer.step()
		node._refresh()
		context.equal(node._prefix_notice, "", "moving the displayed boundary clears the prior export notice")
		button.pressed.emit()
		if not OS.has_feature("web"):
			removed = DirAccess.remove_absolute(ProjectSettings.globalize_path("user://" + node.viewer.prefix_filename()))
		context.equal(removed, OK, "second process-owned native download is removed")
		node.viewer.restart()
		node._refresh()
		context.equal(node._prefix_notice, "", "restarting clears the prior export notice")
		node.viewer.step()
		node.viewer.seek(310)
		node._refresh()
		context.equal(button.disabled, true, "seek disables the download action")
		node.viewer.cancel_seek()
		node._is_scrubbing = true
		node._refresh()
		context.equal(button.disabled, true, "held timeline disables the download action")
		node._is_scrubbing = false
		node._refresh()
		context.equal(button.disabled, false, "released timeline restores export eligibility")
	node._exit_tree()
	node.free()
