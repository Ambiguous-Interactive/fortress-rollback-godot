extends RefCounted

const Context = preload("res://tests/runner/test_context.gd")


# No SceneTree, nodes, timers or filesystem discovery: browser hosts can call
# execute with the same scripts, category selection and scenario seed.
func execute(
	scripts: Array[Script], category: String, filter_text: String, fixed_seed: int
) -> Dictionary:
	var records: Array[Dictionary] = []
	var errors: Array[Dictionary] = []
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
			var runs: Array[Dictionary] = []
			for repetition: int in range(2):
				var instance: Variant = script.new()
				var context: RefCounted = Context.new(fixed_seed)
				if not instance is RefCounted or not instance.has_method("run_case"):
					context.failures.append({"kind": "invalid_suite"})
				else:
					instance.run_case(name, context)
				if not context.is_complete:
					context.failures.append({"kind": "incomplete_case"})
				if context.assertions == 0:
					context.failures.append({"kind": "zero_assertions"})
				runs.append(
					{
						"assertions": context.assertions,
						"failures": context.failures,
						"states": context.states
					}
				)
			if runs[0] != runs[1]:
				errors.append(_first_difference(script.resource_path, name, runs))
			records.append(
				{
					"suite": script.resource_path,
					"case": name,
					"category": category,
					"seed": str(fixed_seed),
					"runs": runs
				}
			)
	if records.is_empty():
		errors.append({"kind": "zero_matching_cases"})
	var is_pass: bool = errors.is_empty()
	for record: Dictionary in records:
		for run: Dictionary in record["runs"]:
			is_pass = is_pass and run["failures"].is_empty()
	return {
		"format": 1,
		"complete": true,
		"passed": is_pass,
		"count": records.size(),
		"errors": errors,
		"records": records
	}


func _first_difference(suite: String, case_name: String, runs: Array[Dictionary]) -> Dictionary:
	var result: Dictionary = {"kind": "repeat_divergence", "suite": suite, "case": case_name}
	var first: Array = runs[0]["states"]
	var second: Array = runs[1]["states"]
	for index: int in range(mini(first.size(), second.size())):
		if first[index] != second[index]:
			result["record"] = index
			result["frame"] = first[index]["frame"]
			var context: RefCounted = Context.new(0)
			context.bytes_equal(
				second[index]["bytes"].hex_decode(),
				first[index]["bytes"].hex_decode(),
				first[index]["frame"],
				"repeat"
			)
			result["differences"] = context.failures
			return result
	result["record"] = mini(first.size(), second.size())
	return result
