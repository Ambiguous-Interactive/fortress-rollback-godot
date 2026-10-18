extends SceneTree

const Scenarios = preload("res://tests/runner/scenario_runner.gd")
const PREFIX: String = "FORTRESS_TEST_RESULT "
const CASES_PREFIX: String = "FORTRESS_TEST_CASES "


func _initialize() -> void:
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
	var result: Dictionary = Scenarios.new().execute(scripts, category, filter_text, fixed_seed, case_names)
	print(PREFIX + JSON.stringify(result))
	quit(0 if result["passed"] else 1)


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
	quit(0)


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
	quit(1)
