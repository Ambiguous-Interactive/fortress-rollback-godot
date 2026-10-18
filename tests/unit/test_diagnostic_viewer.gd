extends RefCounted

# Value: protects=canonical diagnostic files can be opened for offline inspection; fails_when=viewer rejects real downloads or loses metadata;
# why_new=canonical player tests exercise parsed traces without a file viewer; seam=none
const Scene = preload("res://examples/online/diagnostic.tscn")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Viewer = preload("res://examples/online/diagnostic_viewer.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Game = preload("res://examples/offline/simulation.gd")

func cases() -> PackedStringArray:
	return PackedStringArray(["imports", "controls", "divergence", "scene_controls"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"imports":
			_imports(context)
		"controls":
			_controls(context)
		"divergence":
			_divergence(context)
		"scene_controls":
			_scene_controls(context)
	context.finish()


static func encoded(trace: Dictionary) -> PackedByteArray:
	return JSON.stringify(trace).to_utf8_buffer()


func _imports(context: RefCounted) -> void:
	var viewer: Viewer = Viewer.new()
	var trace: Dictionary = capture()
	trace.first_divergence = {"frame": 4, "source": "peer_checksum", "snapshot_available": true}
	context.equal(viewer.open_bytes(encoded({"trace": trace})), true, "opens real canonical download report")
	context.equal(viewer.status().seed, "9223372036854775808", "preserves wide seed as descriptive text")
	context.equal(viewer.status().application_version, Viewer.GAME_VERSION, "identifies application build")
	context.equal(viewer.status().capture_failure, JSON.parse_string(JSON.stringify(trace.first_divergence)), "shows captured failure independently of reproduction")
	viewer.step()
	viewer.toggle_play()
	var expected: PackedByteArray = viewer.game.canonical_bytes()
	var mutations: Array[Dictionary] = [
		{}, {"trace": []}, {"trace": null}, {"application_version": "other-game"},
	]
	var input_only: Dictionary = trace.duplicate(true)
	input_only.frames[0].state_available = false
	input_only.frames[0].state = ""
	input_only.frames[0].checksum = ""
	mutations.append(input_only)
	var gap: Dictionary = trace.duplicate(true)
	gap.frames[1].frame += 1
	mutations.append(gap)
	var schema: Dictionary = trace.duplicate(true)
	schema.schema = "future-version"
	mutations.append(schema)
	for invalid: Dictionary in mutations:
		context.equal(viewer.open_bytes(encoded(invalid)), false, "rejects incompatible or unrestorable capture")
		context.equal(viewer.status().rows_consumed, 1, "failed import retains position")
		context.equal(viewer.is_playing, true, "failed import retains play state")
		context.bytes_equal(viewer.game.canonical_bytes(), expected, 3, "failed import retains game")
	context.equal(viewer.open_bytes("{malformed".to_utf8_buffer()), false, "rejects malformed JSON")
	var oversized: PackedByteArray = PackedByteArray()
	oversized.resize(Viewer.MAX_BYTES + 1)
	context.equal(viewer.open_bytes(oversized), false, "bounds import before JSON decoding")
	trace.seed = {"untrusted": "object"}
	trace.first_divergence = {"source": "x".repeat(1000), "frame": {"nested": "object"}}
	context.equal(viewer.open_bytes(encoded(trace)), true, "descriptive metadata cannot invalidate a canonical window")
	context.equal(viewer.status().seed, "(not recorded as text)", "does not coerce a seed object")
	context.equal(viewer.status().capture_failure.source.length(), 128, "bounds failure text in presentation")
	context.equal(viewer.status().capture_failure.has("frame"), false, "does not publish nested failure metadata")
	context.state(3, expected)


func _controls(context: RefCounted) -> void:
	var viewer: Viewer = Viewer.new()
	viewer.step()
	viewer.toggle_play()
	context.equal(viewer.can_step(), false, "no playback before import")
	context.equal(viewer.open_bytes(encoded(capture())), true, "opens trace-only capture")
	context.equal([viewer.status().first_boundary, viewer.status().last_boundary], [2, 9], "reports retained window rather than starting at zero")
	viewer.tick()
	context.equal(viewer.status().rows_consumed, 0, "opens paused")
	viewer.step()
	context.equal([viewer.game.frame, viewer.status().next_boundary], [3, 3], "restores and applies one captured row")
	viewer.toggle_play()
	viewer.tick()
	viewer.toggle_play()
	viewer.tick()
	context.equal(viewer.status().rows_consumed, 2, "pause prevents extra advance")
	viewer.restart()
	context.equal([viewer.status().rows_consumed, viewer.is_playing], [0, false], "restart resets row position and pauses")
	viewer.toggle_play()
	for index: int in range(128):
		viewer.tick()
	context.equal([viewer.status().validated_states, viewer.status().advanced_frames], [8, 8], "reproduces every retained state and input exactly once")
	context.equal([viewer.status().complete, viewer.is_playing, viewer.can_step()], [true, false, false], "completion disables playback")
	context.equal(viewer.status().next_boundary, -1, "no next boundary after bounded completion")
	context.state(viewer.game.frame, viewer.game.canonical_bytes())
	var trace: Dictionary = capture()
	trace.frames[-1].inputs = []
	context.equal(viewer.open_bytes(encoded(trace)), true, "accepts final SAVE without successful ADVANCE")
	viewer.toggle_play()
	for index: int in range(8):
		viewer.tick()
	context.equal([viewer.status().validated_states, viewer.status().advanced_frames], [8, 7], "does not invent final input")


func _divergence(context: RefCounted) -> void:
	var trace: Dictionary = capture()
	trace.frames[3].state = trace.frames[3].state.left(48) + "ff" + trace.frames[3].state.substr(50)
	var viewer: Viewer = Viewer.new()
	context.equal(viewer.open_bytes(encoded(trace)), true, "canonical corruption diagnosed during playback")
	viewer.toggle_play()
	for index: int in range(20):
		viewer.tick()
	context.equal(viewer.status().code, Types.Code.DESYNC, "stops at canonical mismatch")
	context.equal(viewer.status().failure, {"frame": 5, "kind": "state", "byte": 24, "expected_bytes": 136, "actual_bytes": 136}, "shows first differing state byte")
	context.equal([viewer.status().rows_consumed, viewer.status().advanced_frames], [3, 3], "does not apply mismatching row's inputs")
	context.equal(viewer.message.contains("boundary 5"), true, "failure boundary visible")
	context.equal([viewer.can_step(), viewer.is_playing], [false, false], "failure disables automatic and manual playback")
	viewer.restart()
	context.equal([viewer.can_step(), viewer.status().failure.is_empty()], [true, true], "restart clears latched failure")
	trace = capture()
	trace.frames[1].checksum = "00".repeat(16)
	viewer.open_bytes(encoded(trace))
	viewer.step()
	viewer.step()
	context.equal(viewer.status().failure.kind, "checksum", "distinguishes checksum failure from state failure")
	trace = capture()
	trace.frames[0].state = "00"
	viewer.open_bytes(encoded(trace))
	viewer.step()
	context.equal(viewer.status().failure.kind, "callback", "surfaces application restore failure separately")
	context.equal(viewer.status().advanced_frames, 0, "failed restore applies no inputs")


static func button(node: Node, caption: String) -> Button:
	for child: Node in node.find_children("*", "Button", true, false):
		if child is Button and child.text == caption:
			return child
	return null


func _scene_controls(context: RefCounted) -> void:
	var node: Node2D = Scene.instantiate()
	node._ready()
	context.equal(button(node, "Play").disabled, true, "scene initially disables playback")
	var bytes: PackedByteArray = encoded({"trace": capture()})
	node._web_file([Marshalls.raw_to_base64(bytes), ""])
	context.equal(button(node, "Play").disabled, false, "browser import callback enables playback")
	button(node, "Play").pressed.emit()
	button(node, "Step").pressed.emit()
	context.equal([node.viewer.is_playing, node.viewer.status().rows_consumed], [false, 1], "Step pauses playing scene and consumes one row")
	button(node, "Restart").pressed.emit()
	context.equal(node.viewer.status().rows_consumed, 0, "real Restart resets playback")
	button(node, "Play").pressed.emit()
	for index: int in range(10):
		node._physics_process(0.0)
	context.equal([button(node, "Play").disabled, button(node, "Step").disabled], [true, true], "completed scene disables advance controls")
	context.equal(button(node, "Restart").disabled, false, "completed scene permits replay")
	var visible: bool = false
	for child: Node in node.find_children("*", "Label", true, false):
		if child is Label and child.text.contains("Validated states: 8 | applied advances: 8") and child.text.contains("captured seed: 9223372036854775808"):
			visible = true
	context.equal(visible, true, "visible status includes seed and verification counts")
	if not OS.has_feature("web"):
		var path: String = "user://diagnostic-viewer-test.json"
		var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
		file.store_buffer(bytes)
		file.close()
		node._native_file(path)
		context.equal(node.viewer.status().rows_consumed, 0, "native file import starts paused")
		DirAccess.remove_absolute(path)
		node._native_file(path)
		context.equal(node.viewer.message, "Could not open the diagnostic file.", "native missing file is visible")
	node._exit_tree()
	node.free()


static func capture() -> Dictionary:
	var config: Config = Config.new()
	config.max_snapshot_bytes = Game.SNAPSHOT_BYTES
	config.storage_budget_bytes = 1048576
	config.diagnostic_trace_frames = 8
	config.diagnostic_version = Viewer.GAME_VERSION
	config.diagnostic_seed = "9223372036854775808"
	var session: Session = Session.new()
	session.configure(config)
	var driver: Driver = Driver.new(session, Game.new())
	for frame: int in range(10):
		var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, frame, PackedByteArray([2])), Driver.LocalInput.new(1, frame, PackedByteArray([1]))]
		driver.step(frame, samples)
	return session.diagnostic_trace()
