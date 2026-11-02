extends SceneTree

# Value: protects=portable diagnostic download bytes; fails_when=Godot-only escapes leak into JSON; seam=existing composed session and production byte export.
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Player = preload("res://addons/fortress_rollback/core/diagnostic_player.gd")
const Trace = preload("res://addons/fortress_rollback/core/diagnostic_trace.gd")
const Game = preload("res://examples/offline/simulation.gd")
const Scene = preload("res://examples/online/online.gd")
const Viewer = preload("res://examples/online/replay_viewer.gd")
const ReplayFixture = preload("res://tests/unit/test_replay_viewer.gd")


func _initialize() -> void:
	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	if arguments.size() != 2:
		quit(1)
		return
	var directory: String = arguments[1]
	if arguments[0] == "playback":
		_playback(directory)
		return
	var metadata: Array[String] = ["", "ordinary", "Unicode 日本語 café 😀", "quotes \" and slash \\ and literal \\v and \\\\v"]
	for code: int in range(1, 32):
		metadata.append(String.chr(code))
	metadata.append(String.chr(1).repeat(128))
	for index: int in range(metadata.size()):
		var config: Config = Config.new()
		config.max_snapshot_bytes = Game.SNAPSHOT_BYTES
		config.diagnostic_trace_frames = 4
		config.diagnostic_seed = metadata[index]
		config.diagnostic_version = metadata[index]
		config.diagnostic_replay_command = metadata[index].repeat(4) if index == metadata.size() - 1 else metadata[index]
		config.storage_budget_bytes = config.required_storage_bytes()
		var session: Session = Session.new()
		if session.configure(config) != Types.Code.OK:
			quit(2)
			return
		var driver: Driver = Driver.new(session, Game.new())
		for frame: int in 8:
			var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, frame, PackedByteArray([2])), Driver.LocalInput.new(1, frame, PackedByteArray([1]))]
			if driver.step(frame, samples).code != Types.Code.OK:
				quit(3)
				return
		var node: Node2D = Scene.new()
		node.controller.game_match.peer._core = session
		node.controller.game_match.peer._config = config
		node.controller.game_match.peer._diagnostic_failure = {"reason": metadata[index], "nested": [{metadata[index]: metadata[index]}]}
		var bytes: PackedByteArray = node.diagnostic_report_bytes()
		var compact: PackedByteArray = Trace.to_json(node.diagnostic_report(), false).to_utf8_buffer()
		node.free()
		if not _write(directory.path_join("report-%d.json" % index), bytes) or not _write(directory.path_join("compact-%d.json" % index), compact):
			return
	var recording: ReplayFixture.Replay = ReplayFixture.recording(12)
	recording._checksums[8 * ReplayFixture.Replay.CHECKSUM_BYTES] ^= 1
	var viewer: Viewer = Viewer.new()
	if not viewer.open_bytes(recording.to_bytes()):
		quit(4)
		return
	viewer.seek(12)
	viewer.tick()
	if not viewer.has_failure() or not _write(directory.path_join("replay-failure.json"), viewer.failure_report_bytes()):
		quit(5)
		return
	print("FORTRESS_DIAGNOSTIC_JSON_EXPORT ", metadata.size())
	quit(0)


func _playback(directory: String) -> void:
	for index: int in 36:
		var report: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(directory.path_join("decoded-%d.json" % index)))
		var game: Game = Game.new()
		var player: Player = Player.new()
		if player.configure(report.trace, game, Game.SNAPSHOT_BYTES) != Types.Code.OK:
			quit(6)
			return
		for frame: int in 4:
			if player.step() != Types.Code.OK:
				quit(7)
				return
		if not player.is_complete() or player.report().validated_states != 4 or game.frame != 8:
			quit(8)
			return
	print("FORTRESS_DIAGNOSTIC_JSON_PLAYBACK 36")
	quit(0)


func _write(path: String, bytes: PackedByteArray) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null or bytes.is_empty():
		quit(9)
		return false
	file.store_buffer(bytes)
	file.flush()
	if file.get_error() != OK:
		quit(10)
		return false
	return true
