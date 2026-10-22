extends SceneTree

const Scenarios = preload("res://tests/runner/scenario_runner.gd")
const PREFIX: String = "FORTRESS_TEST_RESULT "
const CASES_PREFIX: String = "FORTRESS_TEST_CASES "
const PROGRESS_PREFIX: String = "FORTRESS_TEST_PROGRESS "
const WATCH_PREFIX: String = "FORTRESS_TEST_ABORT_WATCH "

# Godot 4.7.2 hands a script error to a custom logger. The logger source is
# compiled at runtime, so the repository never holds a script that the older
# pinned engine cannot parse, and the exported browser build never compiles a
# logger it does not need. The class and the method are looked up by name,
# because naming the logger class in this file would make it unparseable on an
# engine that has no Logger.
const LOGGER_SOURCE: String = """extends Logger
var records: Array = []
func _log_error(_function: String, file: String, line: int, code: String, _rationale: String, _editor_notify: bool, error_type: int, _backtraces: Array) -> void:
	if error_type != ERROR_TYPE_SCRIPT:
		return
	records.append({"file": file, "line": line, "message": code})
"""

# The native runner injects a deterministic tick clock, so its progress output
# is byte-stable and the canonical result stays untouched. A browser host
# injects the real host clock instead.
var _ticks: int = 0

# The engine that can hand a script error to a custom logger reports an aborted
# case as failed. Godot 4.3 cannot, so the watch stays unavailable there and
# the Python launcher remains the gate.
var _logger: Object = null


func _clock() -> int:
	_ticks += 1
	return _ticks


# The progress record names the case that was executing and the case that
# completed before it. A host that is interrupted can tell a slow run from a
# failed one.
func _publish_progress(value: Dictionary) -> void:
	var record: Dictionary = value.duplicate()
	record["unit"] = "tick"
	print(PROGRESS_PREFIX + JSON.stringify(record))


func _initialize() -> void:
	_install_watch()
	var paths: Array[String] = []
	var category: String = "unit"
	var filter_text: String = ""
	var case_names: PackedStringArray = []
	var list_cases: bool = false
	var fixed_seed: int = 1701
	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	var index: int = 0
	while index < arguments.size():
		var option: String = arguments[index]
		if option == "--list-cases":
			list_cases = true
			index += 1
			continue
		if index + 1 >= arguments.size():
			_fail("missing_option_value")
			return
		var value: String = arguments[index + 1]
		match option:
			"--suite":
				paths.append(value)
			"--category":
				category = value
			"--filter":
				filter_text = value
			"--case":
				case_names.append(value)
			"--seed":
				if not value.is_valid_int() or str(value.to_int()) != value:
					_fail("invalid_seed")
					return
				fixed_seed = value.to_int()
			_:
				_fail("unknown_option")
				return
		index += 2
	if category not in ["unit", "determinism", "integration"]:
		_fail("invalid_category")
		return
	if paths.is_empty():
		if category == "unit":
			paths.append("res://tests/runner/self_suite.gd")
		_discover("res://tests/" + category, paths)
	paths.sort()
	var scripts: Array[Script] = []
	var seen: Dictionary = {}
	for path: String in paths:
		if seen.has(path) or not ResourceLoader.exists(path):
			_fail("missing_or_duplicate_suite: " + path)
			return
		seen[path] = true
		var resource: Resource = load(path)
		if not resource is Script:
			_fail("load_failure: " + path)
			return
		scripts.append(resource)
	if list_cases:
		_list(scripts)
		return
	var observer: Callable = Callable(self, "_watch_errors") if _logger != null else Callable()
	var result: Dictionary = Scenarios.new().execute(scripts, category, filter_text, fixed_seed, case_names, _publish_progress, _clock, observer)
	print(PREFIX + JSON.stringify(result))
	_publish_watch()
	_finish(0 if result["passed"] else 1)


# The watch record names the capability of this engine, so a host never claims
# an engine result that only one pinned engine provides.
func _publish_watch() -> void:
	print(WATCH_PREFIX + JSON.stringify({"available": _logger != null, "errors": _watch_errors().size()}))


# The script errors this engine reported so far, in the order it reported them.
# The suite, the case and the repetition are accepted and ignored, so a host can
# report an error for one identity.
func _watch_errors(_suite: String = "", _case: String = "", _repetition: int = -1) -> Array:
	if _logger == null:
		return []
	var records: Variant = _logger.get("records")
	return records if records is Array else []


# Install the watch only on an engine that hands a script error to a custom
# logger. A logger that is not installed leaves the engine's own verdict, and
# the Python launcher stays the gate there.
func _install_watch() -> void:
	if _logger != null:
		return
	if not ClassDB.class_exists("Logger") or not OS.has_method("add_logger"):
		return
	var script: GDScript = GDScript.new()
	script.source_code = LOGGER_SOURCE
	if script.reload() != OK:
		return
	var instance: Variant = script.new()
	if not instance is Object:
		return
	OS.call("add_logger", instance)
	_logger = instance


# Print each suite's case inventory so a launcher can run one case per process.
func _list(scripts: Array[Script]) -> void:
	var inventory: Dictionary = {}
	for script: Script in scripts:
		var suite: Variant = script.new() if script.can_instantiate() else null
		if not suite is RefCounted or not suite.has_method("cases") or not suite.cases() is PackedStringArray:
			_fail("invalid_suite: " + script.resource_path)
			return
		inventory[script.resource_path] = suite.cases()
	print(CASES_PREFIX + JSON.stringify(inventory))
	_publish_watch()
	_finish(0)


func _discover(path: String, paths: Array[String]) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var directory: DirAccess = DirAccess.open(path)
	if directory == null:
		paths.append(path + "/unreadable_suite.gd")
		return
	for child: String in directory.get_directories():
		_discover(path + "/" + child, paths)
	for file: String in directory.get_files():
		if file.begins_with("test_") and file.ends_with(".gd"):
			paths.append(path + "/" + file)


func _fail(reason: String) -> void:
	print(PREFIX + JSON.stringify({"format": 1, "complete": true, "passed": false, "count": 0, "records": [], "errors": [{"kind": reason}]}))
	_publish_watch()
	_finish(1)


# The engine holds every registered logger, and the logger holds the script it
# was compiled from. Releasing both before the process exits keeps the engine
# from reporting a resource that is still in use at exit.
func _finish(code: int) -> void:
	if _logger != null and OS.has_method("remove_logger"):
		OS.call("remove_logger", _logger)
	_logger = null
	quit(code)
