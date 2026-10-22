extends RefCounted

# Godot 4.3 cannot hand a script error to a logger, so the runner starts itself
# as a child process that writes its merged output to an engine log file. The
# parent publishes that file while the child runs, which keeps the progress
# record and the watchdog marker visible to a host that interrupts the run. The
# parent then attributes every script error to the case the child named, so the
# engine result reports an aborted case on both pinned engines.

const RESULT_PREFIX: String = "FORTRESS_TEST_RESULT "
const PROGRESS_PREFIX: String = "FORTRESS_TEST_PROGRESS "
const WATCH_PREFIX: String = "FORTRESS_TEST_ABORT_WATCH "

var _thread: Thread = null
var _status: int = -1
var _header: RegEx = null
var _location: RegEx = null


func _init() -> void:
	_header = RegEx.new()
	_header.compile("^\\s*(?:SCRIPT ERROR:|Parse Error:)\\s*(.*)$")
	_location = RegEx.new()
	_location.compile("^\\s*at:\\s[^(]*\\((?P<file>[^()]+):(?P<line>\\d+)\\)")


# Run the child and return the amended engine result, the script error count and
# the exit status. The child log is removed after it has been read.
func supervise(user_arguments: PackedStringArray) -> Dictionary:
	var directory: String = OS.get_cache_dir().path_join("fortress-runner")
	DirAccess.make_dir_recursive_absolute(directory)
	var path: String = directory.path_join(
		"run-%d-%d.log" % [OS.get_process_id(), Time.get_ticks_usec()])
	var command: PackedStringArray = PackedStringArray([
		OS.get_executable_path(), "--headless", "--path", ProjectSettings.globalize_path("res://"),
		"--log-file", path, "--script", "res://tests/runner/run_tests.gd", "--",
	])
	command.append_array(user_arguments)
	command.append("--abort-child")
	_thread = Thread.new()
	if _thread.start(_execute.bind(command)) != OK:
		return {"result": null, "errors": 0, "exit": 1}
	var published: int = 0
	while _thread.is_alive():
		published = _publish(path, published)
		OS.delay_msec(10)
	_thread.wait_to_finish()
	published = _publish(path, published)
	var text: String = FileAccess.get_file_as_string(path)
	DirAccess.remove_absolute(path)
	var result: Variant = _result(text)
	var errors: Array[Dictionary] = _script_errors(text)
	var exit: int = _status
	if result is Dictionary:
		_apply(result, errors)
		exit = 0 if bool(result.get("passed")) else 1
	return {"result": result, "errors": errors.size(), "exit": exit}


# The child keeps the same user arguments as the parent. Only the log file and
# the internal child marker are added, so the canonical result does not change.
func _execute(command: PackedStringArray) -> void:
	var output: Array = []
	_status = OS.execute(command[0], command.slice(1), output, true)


# Publish every complete line the child has written so far. The engine writes
# the log file as it runs, so an interrupted parent has already named the
# executing case and the watchdog marker stays visible to the host.
func _publish(path: String, offset: int) -> int:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return offset
	var length: int = file.get_length()
	if length <= offset:
		return offset
	file.seek(offset)
	var data: PackedByteArray = file.get_buffer(length - offset)
	var text: String = data.get_string_from_utf8()
	var cut: int = text.rfind("\n")
	if cut < 0:
		return offset
	var complete: String = text.substr(0, cut + 1)
	offset += complete.to_utf8_buffer().size()
	for raw: String in complete.split("\n"):
		if raw.is_empty():
			continue
		var line: String = raw.substr(5) if raw.begins_with("USER ") else raw
		if line.begins_with(RESULT_PREFIX) or line.begins_with(WATCH_PREFIX):
			continue
		print(line)
	return offset


func _result(text: String) -> Variant:
	var result: Variant = null
	for line: String in text.split("\n"):
		if not line.begins_with(RESULT_PREFIX):
			continue
		var value: Variant = JSON.parse_string(line.substr(RESULT_PREFIX.length()))
		if value is Dictionary:
			result = value
	return result


# A script error belongs to the case whose progress record preceded it. The
# location line that follows the header names the file and the line, exactly as
# the launcher and the 4.7.2 logger report them.
func _script_errors(text: String) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var executing: Dictionary = {}
	var pending: Dictionary = {}
	for raw: String in text.split("\n"):
		var line: String = raw.substr(5) if raw.begins_with("USER ") else raw
		if line.begins_with(PROGRESS_PREFIX):
			var value: Variant = JSON.parse_string(line.substr(PROGRESS_PREFIX.length()))
			var current: Variant = value.get("executing") if value is Dictionary else null
			executing = current if current is Dictionary else {}
			pending = {}
			continue
		var header: RegExMatch = _header.search(line)
		if header != null:
			pending = {"suite": str(executing.get("suite", "")), "case": str(executing.get("case", "")),
				"file": null, "line": null, "message": header.get_string(1).strip_edges()}
			entries.append(pending)
			continue
		var location: RegExMatch = _location.search(line)
		if not pending.is_empty() and location != null:
			pending["file"] = location.get_string("file")
			pending["line"] = int(location.get_string("line"))
			pending = {}
			continue
		pending = {}
	return entries


# Fail every case that died, naming the aborting file, the line and the message.
# The repetition that recorded fewer assertions is the one that died; when the
# repetitions are equal the abort came after the last assertion, so both carry
# the entry, as the 4.7.2 logger route does.
func _apply(result: Dictionary, errors: Array[Dictionary]) -> void:
	var grouped: Dictionary = {}
	var order: Array[String] = []
	for error: Dictionary in errors:
		var suite: String = str(error.get("suite", ""))
		var case_name: String = str(error.get("case", ""))
		if suite.is_empty() or case_name.is_empty():
			continue
		var key: String = suite + "\n" + case_name
		if not grouped.has(key):
			grouped[key] = []
			order.append(key)
		grouped[key].append(error)
	for key: String in order:
		var reports: Array = grouped[key]
		var first: Dictionary = reports[0]
		var entry: Dictionary = {"kind": "case_aborted", "suite": first["suite"], "case": first["case"],
			"file": first["file"], "line": first["line"], "message": first["message"], "aborts": reports.size()}
		var record: Variant = _record(result, first["suite"], first["case"])
		if not record is Dictionary:
			_add_error(result, entry)
			result["passed"] = false
			continue
		var runs: Array = record.get("runs", []) if record.get("runs") is Array else []
		var counts: Array[int] = []
		for run: Variant in runs:
			if run is Dictionary and typeof(run.get("assertions")) == TYPE_INT:
				counts.append(run["assertions"])
		var top: int = counts.max() if not counts.is_empty() else 0
		var targets: Array = runs.filter(
			func(run: Variant) -> bool: return run is Dictionary and typeof(run.get("assertions")) == TYPE_INT and run["assertions"] < top)
		if targets.is_empty():
			targets = runs
		for run: Variant in targets:
			if run is Dictionary and run.get("failures") is Array:
				run["failures"].append(entry)
		_add_error(result, entry)
		result["passed"] = false


func _record(result: Dictionary, suite: String, case_name: String) -> Variant:
	var records: Variant = result.get("records")
	if not records is Array:
		return null
	for record: Variant in records:
		if record is Dictionary and record.get("suite") == suite and record.get("case") == case_name:
			return record
	return null


func _add_error(result: Dictionary, entry: Dictionary) -> void:
	var errors: Variant = result.get("errors")
	if not errors is Array:
		return
	for item: Variant in errors:
		if item is Dictionary and item.get("kind") == "case_aborted" \
				and item.get("suite") == entry["suite"] and item.get("case") == entry["case"]:
			return
	errors.append(entry)
