extends RefCounted

# Value: protects=per-case progress of an interrupted run; fails_when=a rejected run cannot name the case that was executing;
# why_new=#132 needs the last executing case to tell a slow run from a failed one; seam=actual scenario runner
const Scenarios = preload("res://tests/runner/scenario_runner.gd")
const Suite = preload("res://tests/unit/test_frame_inputs.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["progress"])


func run_case(_name: String, context: RefCounted) -> void:
	var seen: Array[Dictionary] = []
	var result: Dictionary = Scenarios.new().execute([Suite], "unit", "", 1701, PackedStringArray(),
		func(value: Dictionary) -> void: seen.append(value))
	context.equal(result["passed"], true, "the observed suite passes")
	var expected: PackedStringArray = Suite.new().cases()
	context.equal(seen.size(), expected.size(), "every case reports its start")
	for index: int in range(mini(seen.size(), expected.size())):
		context.equal(seen[index]["case"], expected[index], "case %d is named in order" % index)
		context.equal(seen[index]["completed"], index, "case %d reports the completed count" % index)
		context.equal(seen[index]["suite"], "res://tests/unit/test_frame_inputs.gd", "case %d reports its suite" % index)
	context.finish()
