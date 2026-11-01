extends Node

# Value: protects=received replay prefix files reopen as the selected original history;
# fails_when=Web downloads use wrong bytes or refused import retains original playback; why_new=unit Web checks cannot receive downloads; seam=browser fixture
const Scene = preload("res://examples/online/replay.tscn")
const Fixture = preload("res://tests/unit/test_replay_viewer.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
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
var _statuses_valid: bool = false
var _statuses_checked: bool = false
var _original_valid: bool = false
var _download_original: Replay
var _download_frame: int = -1
var _disconnected_rows: int = 0


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
	_statuses_valid = false
	_statuses_checked = false
	_original_valid = false
	_disconnected_rows = 0
	for frame: int in range(17, 610):
		recording._statuses[frame * 2 + 1] = Queue.Status.DISCONNECTED
		var digest: PackedByteArray = recording.computed_input_digest(frame)
		for digest_index: int in Replay.DIGEST_BYTES:
			recording._digests[frame * Replay.DIGEST_BYTES + digest_index] = digest[digest_index]
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
		"prepare_download":
			_download_original = recording
			_download_frame = FRAMES[selected]
		"alter_metadata":
			scene.viewer._recording._text[0] += " altered"
		"verify_import":
			_statuses_valid = true
			_disconnected_rows = 0
			for frame: int in scene.viewer.frame_count():
				for slot: int in 2:
					var expected_status: int = Queue.Status.DISCONNECTED if slot == 1 and frame >= 17 else Queue.Status.CONFIRMED
					var actual_status: int = scene.viewer._recording.inputs(frame).read(slot).status
					_statuses_valid = _statuses_valid and actual_status == expected_status
					_disconnected_rows += int(actual_status == Queue.Status.DISCONNECTED)
			_original_valid = _matches_original(scene.viewer._recording)
			_statuses_checked = true
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


func _matches_original(actual: Replay) -> bool:
	if _download_original == null or actual == null or not actual.is_valid() or actual.frame_count() != _download_frame:
		return false
	if _identity(actual) != _identity(_download_original):
		return false
	var skipped: int = 0
	for frame: int in _download_frame:
		if actual.input_digest(frame) != _download_original.input_digest(frame) or actual.checksum(frame) != _download_original.checksum(frame):
			return false
		if actual.is_skipped_frame(frame) != _download_original.is_skipped_frame(frame):
			return false
		skipped += int(_download_original.is_skipped_frame(frame))
		var actual_inputs: Types.FrameInputs = actual.inputs(frame)
		var original_inputs: Types.FrameInputs = _download_original.inputs(frame)
		for slot: int in _download_original.player_count():
			if actual_inputs.read(slot).bytes != original_inputs.read(slot).bytes or actual_inputs.read(slot).status != original_inputs.read(slot).status:
				return false
	return actual.skipped_frames() == skipped and actual.checksum(_download_frame) == _download_original.checksum(_download_frame)


# Metadata and configuration getters return different scalar and packed-byte types.
func _identity(value: Replay) -> Array[Variant]:
	return [
		value.engine_version(),
		value.addon_version(),
		value.upstream_revision(),
		value.game_seed(),
		value.game_version(),
		value.player_count(),
		value.input_width(),
		value.neutral_input(),
		value.input_delay(),
		value.max_prediction_frames(),
		value.sync_test(),
	]


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
		"statuses_valid": _statuses_valid,
		"statuses_checked": _statuses_checked,
		"original_valid": _original_valid,
		"disconnected_rows": _disconnected_rows,
		"source_sha256": scene.viewer._recording_sha256,
		"source_bytes": scene.viewer._recording_bytes,
		"message": scene.viewer.message,
	}
	JavaScriptBridge.eval("window.fortressReplayDownload = " + JSON.stringify(state))
