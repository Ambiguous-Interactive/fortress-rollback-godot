extends SceneTree

## Reproduce online example canonical downloads without the optional SDK or network.
const Player = preload("res://addons/fortress_rollback/core/diagnostic_player.gd")
const Game = preload("res://examples/offline/simulation.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const MAX_FILE_BYTES: int = 1048576


func _initialize() -> void:
	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	if arguments.size() != 1:
		_finish(Types.Code.INVALID_CONFIGURATION, {"error": "usage: -- <diagnostic.json>"})
		return
	var file: FileAccess = FileAccess.open(arguments[0], FileAccess.READ)
	if file == null or file.get_length() > MAX_FILE_BYTES:
		_finish(Types.Code.INVALID_CONFIGURATION, {"error": "unreadable or oversized diagnostic file"})
		return
	var parser: JSON = JSON.new()
	if parser.parse(file.get_as_text()) != OK or not parser.data is Dictionary:
		_finish(Types.Code.INVALID_CONFIGURATION, {"error": "invalid diagnostic JSON"})
		return
	var trace: Dictionary = parser.data
	if trace.has("trace"):
		if not trace.trace is Dictionary:
			_finish(Types.Code.INVALID_CONFIGURATION, {"error": "invalid trace object"})
			return
		trace = trace.trace
	if trace.get("application_version") != "fortress-online-integer-v1":
		_finish(Types.Code.INVALID_CONFIGURATION, {"error": "requires fortress-online-integer-v1 capture"})
		return
	var player: Player = Player.new()
	var code: int = player.configure(trace, Game.new(), Game.SNAPSHOT_BYTES)
	if code != Types.Code.OK:
		_finish(code, {"error": "requires a contiguous window with initial SAVE and later comparison state"})
		return
	for index: int in range(129):
		code = player.step()
		if code != Types.Code.OK:
			break
	_finish(code, player.report())


func _finish(code: int, report: Dictionary) -> void:
	report["code"] = code
	print("FORTRESS_DIAGNOSTIC_RESULT " + JSON.stringify(report))
	quit(0 if code == Types.Code.FRAME_EXHAUSTED and report.get("complete") == true else 1)
