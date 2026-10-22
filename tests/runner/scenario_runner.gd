extends RefCounted

const Context = preload("res://tests/runner/test_context.gd")


# No SceneTree, nodes, timers or filesystem discovery: browser hosts can call
# execute with the same scripts, category selection and scenario seed.
# A nonempty case_names runs only those exact case names, in inventory order.
# An optional progress callable receives the run's progress before and after each
# case runs, so a host that is interrupted can name the case that was executing
# and the case that completed before it, with the time that case took.
# An optional clock callable returns a monotonic integer count of its own unit.
# The host injects the clock, so the runner never reads a wall clock itself: a
# native suite keeps its deterministic clock and a browser host injects the real
# host clock. The observation never enters the canonical result: the case
# records and their assertion counts stay exactly as they are.
# An optional observer callable returns the script errors the host has recorded
# so far. A GDScript runtime error aborts the innermost function, so a case that
# dies inside a nested helper still reaches its completion marker and the engine
# reports that case as passed. A host that can see the script error reports the
# case as failed instead, and the observer is how the runner learns about it.
func execute(
	scripts: Array[Script],
	category: String,
	filter_text: String,
	fixed_seed: int,
	case_names: PackedStringArray = [],
	progress: Callable = Callable(),
	clock: Callable = Callable(),
	observer: Callable = Callable()
) -> Dictionary:
	var records: Array[Dictionary] = []
	var errors: Array[Dictionary] = []
	var completed: int = 0
	var last_completed: Variant = null
	for script: Script in scripts:
		if not script.can_instantiate():
			errors.append({"kind": "uninstantiable_suite", "suite": script.resource_path})
			continue
		# Dynamic suite protocol is intentionally checked at this plugin boundary.
		var inventory: Variant = script.new()
		if not inventory is RefCounted or not inventory.has_method("cases"):
			errors.append({"kind": "invalid_suite", "suite": script.resource_path})
			continue
		var names: Variant = inventory.cases()
		if not names is PackedStringArray:
			errors.append({"kind": "invalid_inventory", "suite": script.resource_path})
			continue
		var seen: Dictionary = {}
		for name: String in names:
			if name.is_empty() or seen.has(name):
				errors.append({"kind": "invalid_case_name", "suite": script.resource_path})
				continue
			seen[name] = true
			if not filter_text.is_empty() and not name.contains(filter_text):
				continue
			if not case_names.is_empty() and name not in case_names:
				continue
			var started: int = _read_clock(clock)
			_publish(progress, {"completed": completed, "executing": {"suite": script.resource_path, "case": name, "started": started}, "last_completed": last_completed})
			var runs: Array[Dictionary] = []
			var aborts: Array[Array] = []
			for repetition: int in range(2):
				var instance: Variant = script.new()
				var context: RefCounted = Context.new(fixed_seed)
				var before: int = _observed(observer).size()
				if not instance is RefCounted or not instance.has_method("run_case"):
					context.failures.append({"kind": "invalid_suite"})
				else:
					instance.run_case(name, context)
				if not context.is_complete:
					context.failures.append({"kind": "incomplete_case"})
				if context.assertions == 0:
					context.failures.append({"kind": "zero_assertions"})
				aborts.append(_observed(observer).slice(before))
				runs.append({"assertions": context.assertions, "failures": context.failures, "states": context.states})
			_report_abort(script.resource_path, name, runs, aborts, errors)
			if runs[0] != runs[1]:
				errors.append(_first_difference(script.resource_path, name, runs))
			records.append({"suite": script.resource_path, "case": name, "category": category, "seed": str(fixed_seed), "runs": runs})
			completed += 1
			var finished: int = _read_clock(clock)
			last_completed = {"suite": script.resource_path, "case": name, "started": started, "finished": finished, "elapsed": finished - started}
			_publish(progress, {"completed": completed, "executing": null, "last_completed": last_completed})
	for name: String in case_names:
		if not records.any(func(record: Dictionary) -> bool: return record["case"] == name):
			errors.append({"kind": "unknown_case", "case": name})
	if records.is_empty():
		errors.append({"kind": "zero_matching_cases"})
	var is_pass: bool = errors.is_empty()
	for record: Dictionary in records:
		for run: Dictionary in record["runs"]:
			is_pass = is_pass and run["failures"].is_empty()
	return {"format": 1, "complete": true, "passed": is_pass, "count": records.size(), "errors": errors, "records": records}


func _read_clock(clock: Callable) -> int:
	if not clock.is_valid():
		return 0
	return int(clock.call())


# The script errors the host has recorded so far. A host that cannot see them
# reports an empty list, so the runner keeps the engine's own verdict.
func _observed(observer: Callable) -> Array:
	if not observer.is_valid():
		return []
	var value: Variant = observer.call()
	return value if value is Array else []


# A case that died is a failure of that case, not of the run: the entry names
# the suite, the case, the aborting file, the line and the engine message, and
# only the repetitions that died carry it. A case that dies in one repetition
# and not in the other keeps that difference visible.
func _report_abort(suite: String, case_name: String, runs: Array[Dictionary], aborts: Array[Array], errors: Array[Dictionary]) -> void:
	var died: Array[int] = []
	for index: int in range(aborts.size()):
		if not aborts[index].is_empty():
			died.append(index)
	if died.is_empty():
		return
	var first: Dictionary = aborts[died[0]][0]
	var entry: Dictionary = {
		"kind": "case_aborted",
		"suite": suite,
		"case": case_name,
		"file": str(first.get("file", "")),
		"line": int(first.get("line", 0)),
		"message": str(first.get("message", "")),
		"aborts": died.size(),
	}
	for index: int in died:
		runs[index]["failures"].append(entry)
	errors.append(entry)


func _publish(progress: Callable, value: Dictionary) -> void:
	if progress.is_valid():
		progress.call(value)


func _first_difference(suite: String, case_name: String, runs: Array[Dictionary]) -> Dictionary:
	var result: Dictionary = {"kind": "repeat_divergence", "suite": suite, "case": case_name}
	var first: Array = runs[0]["states"]
	var second: Array = runs[1]["states"]
	for index: int in range(mini(first.size(), second.size())):
		if first[index] != second[index]:
			result["record"] = index
			result["frame"] = first[index]["frame"]
			var context: RefCounted = Context.new(0)
			context.bytes_equal(second[index]["bytes"].hex_decode(), first[index]["bytes"].hex_decode(), first[index]["frame"], "repeat")
			result["differences"] = context.failures
			return result
	result["record"] = mini(first.size(), second.size())
	return result
