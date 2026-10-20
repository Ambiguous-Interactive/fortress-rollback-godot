extends RefCounted

# Value: protects=per-case progress and the elapsed time of the last completed case;
# fails_when=a rejected run cannot name the case that was executing or how long the last completed case took;
# why_new=#153 needs the elapsed time per case; seam=actual scenario runner
const Scenarios = preload("res://tests/runner/scenario_runner.gd")
const Suite = preload("res://tests/unit/test_frame_inputs.gd")
const Timing = preload("res://tests/runner/timing_suite.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["progress", "elapsed_time", "canonical_result"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"progress":
			_progress(context)
		"elapsed_time":
			_elapsed_time(context)
		"canonical_result":
			_canonical_result(context)


# The progress record names every case in order, the number of completed cases
# and the case that was executing.
func _progress(context: RefCounted) -> void:
	var seen: Array[Dictionary] = []
	var result: Dictionary = Scenarios.new().execute([Suite], "unit", "", 1701, PackedStringArray(),
		func(value: Dictionary) -> void: seen.append(value), _tick_clock())
	context.equal(result["passed"], true, "the observed suite passes")
	var expected: PackedStringArray = Suite.new().cases()
	context.equal(seen.size(), expected.size() * 2, "every case reports its start and its completion")
	var starts: Array[Dictionary] = []
	for record: Dictionary in seen:
		if record["executing"] != null:
			starts.append(record)
	context.equal(starts.size(), expected.size(), "every case reports its start")
	for index: int in range(mini(starts.size(), expected.size())):
		context.equal(starts[index]["executing"]["case"], expected[index], "case %d is named in order" % index)
		context.equal(starts[index]["completed"], index, "case %d reports the completed count" % index)
		context.equal(starts[index]["executing"]["suite"], "res://tests/unit/test_frame_inputs.gd", "case %d reports its suite" % index)
	context.equal(seen[0]["last_completed"], null, "the first record has no completed case")
	var last: Dictionary = seen[seen.size() - 1]["last_completed"]
	context.equal(last["case"], expected[expected.size() - 1], "the last record names the last completed case")
	context.equal(seen[seen.size() - 1]["completed"], expected.size(), "the last record reports every completed case")
	context.equal(seen[seen.size() - 1]["executing"], null, "no case is executing after the run")
	context.finish()


# A deliberately slow case reports a long elapsed time, and a fast run reports
# a bounded one. The scripted clock proves that the runner measures the
# injected clock, and the real clock only orders the two cases.
func _elapsed_time(context: RefCounted) -> void:
	var readings: Array[int] = [0, 900, 1000, 1100]
	var reads: Array[int] = [0]
	var scripted: Callable = func() -> int:
		var index: int = reads[0]
		reads[0] = mini(index + 1, readings.size() - 1)
		return readings[index]
	var seen: Array[Dictionary] = []
	var result: Dictionary = Scenarios.new().execute([Timing], "unit", "", 1701, PackedStringArray(),
		func(value: Dictionary) -> void: seen.append(value), scripted)
	context.equal(result["passed"], true, "the timing suite passes")
	var elapsed: Dictionary = {}
	for record: Dictionary in seen:
		var completion: Variant = record["last_completed"]
		if completion != null:
			elapsed[completion["case"]] = completion["elapsed"]
	context.equal(elapsed.get("slow", -1), 900, "the slow case reports the injected elapsed time")
	context.equal(elapsed.get("fast", -1), 100, "the fast case reports the injected elapsed time")
	# The real clock orders the same two cases without a machine-dependent bound.
	var measured: Dictionary = {}
	var wall_seen: Array[Dictionary] = []
	var wall: Dictionary = Scenarios.new().execute([Timing], "unit", "", 1701, PackedStringArray(),
		func(value: Dictionary) -> void: wall_seen.append(value), _wall_clock())
	context.equal(wall["passed"], true, "the timing suite passes with the real clock")
	for record: Dictionary in wall_seen:
		var completion: Variant = record["last_completed"]
		if completion != null:
			measured[completion["case"]] = completion["elapsed"]
	context.equal(measured.has("slow") and measured.has("fast"), true, "the real clock reports both cases")
	context.equal(measured["slow"] > measured["fast"], true, "the slow case is reported as slower than the fast case")
	context.finish()


# The observation stays out of the canonical result.
func _canonical_result(context: RefCounted) -> void:
	var plain: Dictionary = Scenarios.new().execute([Suite], "unit", "", 1701)
	var observed: Dictionary = Scenarios.new().execute([Suite], "unit", "", 1701, PackedStringArray(),
		func(_value: Dictionary) -> void: pass, _tick_clock())
	context.equal(observed["records"], plain["records"], "the observed records are the canonical records")
	context.equal(observed["count"], plain["count"], "the observed count is the canonical count")
	context.equal(observed["passed"], plain["passed"], "the observed verdict is the canonical verdict")
	context.equal(observed["errors"], plain["errors"], "the observed errors are the canonical errors")
	context.finish()


# A deterministic clock: every reading is the next tick.
func _tick_clock() -> Callable:
	var ticks: Array[int] = [0]
	return func() -> int:
		ticks[0] += 1
		return ticks[0]


# The real monotonic host clock, in microseconds.
func _wall_clock() -> Callable:
	return func() -> int:
		return Time.get_ticks_usec()
