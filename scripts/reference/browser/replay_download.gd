extends Node

# Value: protects=received replay prefix files reopen as the selected original history;
# fails_when=Web downloads use wrong bytes or refused import retains original playback; why_new=unit Web checks cannot receive downloads; seam=browser fixture
const Scene = preload("res://examples/online/replay.tscn")
const Fixture = preload("res://tests/unit/test_replay_viewer.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const CASES: Array[String] = ["interior", "terminal", "initial"]
const FRAMES: Array[int] = [301, 610, 0]
var scene: Node2D
var recording: Replay
var expected: PackedByteArray
var original: PackedByteArray
var selected: int = -1
var _command_callback: JavaScriptObject
var _open_button: Button
var _prior_player: RefCounted


func _ready() -> void:
	call_deferred("_start")


func _start() -> void:
	scene = Scene.instantiate()
	add_child(scene)
	scene.set_physics_process(false)
	_open_button = Fixture._button(scene, "Open replay")
	_command_callback = JavaScriptBridge.create_callback(_command)
	JavaScriptBridge.get_interface("window").fortressReplayDownloadCommand = _command_callback
	_select(0)


func _select(index: int) -> void:
	selected = index
	recording = Fixture.recording(610)
	var game: Simulation = Simulation.new()
	for frame: int in recording.frame_count():
		game.simulate_frame(frame, recording.inputs(frame))
	recording._format_version = Replay.TERMINAL_VERSION
	recording._terminal_checksum = Simulation.checksum(game.canonical_bytes())
	game = Simulation.new()
	for frame: int in FRAMES[index]:
		game.simulate_frame(frame, recording.inputs(frame))
	original = game.canonical_bytes()
	expected = recording.owned_prefix(FRAMES[index]).to_bytes()
	if not scene.viewer.open_bytes(recording.to_bytes()):
		push_error("replay download initial import refused")
		return
	scene.viewer.seek(FRAMES[index])
	while scene.viewer.is_seeking():
		scene.viewer.tick()
	scene._refresh()


func _command(arguments: Array) -> void:
	var command: String = str(arguments[0])
	match command:
		"prepare_import":
			_prior_player = scene.viewer._player
		"select":
			_select(int(arguments[1]))
		"seek":
			scene.viewer.restart()
			scene.viewer.seek(610)
		"cancel":
			scene._cancel_seek()
		"hold":
			scene._timeline_drag_started()
		"release":
			scene._timeline_drag_ended(false)
		"navigate":
			scene.viewer.seek(int(arguments[1]))
			while scene.viewer.is_seeking():
				scene.viewer.tick()
		"finish":
			while scene.viewer.is_seeking():
				scene.viewer.tick()
	scene._refresh()


func _process(_delta: float) -> void:
	if scene == null:
		return
	scene._refresh()
	var button: Rect2 = scene._prefix_download.get_global_rect()
	var open: Rect2 = _open_button.get_global_rect()
	var state: Dictionary = {
		"case": CASES[selected],
		"target": FRAMES[selected],
		"frame": scene.viewer.current_frame(),
		"seeking": scene.viewer.is_seeking(),
		"held": scene._is_scrubbing,
		"disabled": scene._prefix_download.disabled,
		"x": button.get_center().x,
		"y": button.get_center().y,
		"open_x": open.get_center().x,
		"open_y": open.get_center().y,
		"filename": scene.viewer.prefix_filename(),
		"expected": Marshalls.raw_to_base64(expected),
		"canonical": scene.viewer.game.canonical_bytes().hex_encode(),
		"original": original.hex_encode(),
		"failure": scene.viewer.has_failure(),
		"frames": scene.viewer.frame_count(),
		"import_replaced": _prior_player != null and scene.viewer._player != _prior_player,
		"source_sha256": scene.viewer._recording_sha256,
		"source_bytes": scene.viewer._recording_bytes,
		"message": scene.viewer.message,
	}
	JavaScriptBridge.eval("window.fortressReplayDownload = " + JSON.stringify(state))
