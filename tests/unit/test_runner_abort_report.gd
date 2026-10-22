extends RefCounted

# Value: protects=the runner's aborted-case report; fails_when=an aborted case is not failed, a healthy case is failed, or a repetition that died takes the other's verdict
# why_new=the engine reports an aborted case on the pins that expose the script error; seam=none
const Scenarios = preload("res://tests/runner/scenario_runner.gd")
const Suite = preload("res://tests/fixtures/runner/abort_suite.gd")
const SUITE_PATH: String = "res://tests/fixtures/runner/abort_suite.gd"


func cases() -> PackedStringArray:
	return PackedStringArray(["aborted_case_fails", "healthy_case_passes", "one_repetition_dies", "constructor_error_fails"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"aborted_case_fails":
			_aborted_case_fails(context)
		"healthy_case_passes":
			_healthy_case_passes(context)
		"one_repetition_dies":
			_one_repetition_dies(context)
		"constructor_error_fails":
			_constructor_error_fails(context)
	context.finish()


# The observer stands in for the engine's script error. The runner reads it once
# per repetition with the suite, the case and the repetition index, so the
# observer reports an error for one identity rather than for one read.
class Observer extends RefCounted:
	var records: Array = []
	var report_at: Array[int] = []

	func read(_suite: String, _case: String, repetition: int) -> Array:
		if report_at.has(repetition):
			records.append({"file": "res://tests/fixtures/runner/abort_suite.gd", "line": 12, "message": "boom"})
		return records


# A case that dies in both repetitions fails the run and names the abort.
func _aborted_case_fails(context: RefCounted) -> void:
	var observer: Observer = Observer.new()
	observer.report_at = [0, 1]
	var result: Dictionary = _run(observer)
	context.equal(result["passed"], false, "an aborted case fails the run")
	context.equal(result["errors"].size(), 1, "the run names the abort once")
	var entry: Dictionary = result["errors"][0]
	context.equal(entry["kind"], "case_aborted", "the run names the abort")
	context.equal(entry["case"], "aborted", "the entry names the case")
	context.equal(entry["suite"], SUITE_PATH, "the entry names the suite")
	context.equal(entry["file"], SUITE_PATH, "the entry names the aborting file")
	context.equal(entry["line"], 12, "the entry names the aborting line")
	context.equal(entry["message"], "boom", "the entry keeps the engine message")
	context.equal(entry["aborts"], 2, "the entry counts the repetitions that died")
	var runs: Array = result["records"][0]["runs"]
	context.equal(runs.size(), 2, "the case keeps both repetitions")
	for run: Dictionary in runs:
		context.equal(run["failures"].size(), 1, "the repetition carries the abort")
		context.equal(run["failures"][0]["kind"], "case_aborted", "the repetition names the abort")


# A case that records no script error keeps the engine's own verdict.
func _healthy_case_passes(context: RefCounted) -> void:
	var result: Dictionary = _run(Observer.new())
	context.equal(result["passed"], true, "a healthy case passes")
	context.equal(result["errors"], [], "a healthy run reports no error")
	context.equal(result["records"][0]["runs"][0]["failures"], [], "a healthy repetition reports no failure")


# A case that dies in one repetition and not in the other keeps that difference
# visible: the repetition that reached the end keeps its own verdict.
func _one_repetition_dies(context: RefCounted) -> void:
	var observer: Observer = Observer.new()
	observer.report_at = [0]
	var result: Dictionary = _run(observer)
	context.equal(result["passed"], false, "the case fails")
	var runs: Array = result["records"][0]["runs"]
	context.equal(runs[0]["failures"].size(), 1, "the repetition that died carries the abort")
	context.equal(runs[1]["failures"], [], "the repetition that finished keeps its verdict")
	context.equal(runs[0] != runs[1], true, "the difference between the repetitions stays visible")


# An error that arrives before the first repetition belongs to the case that is
# being prepared. The engine result must not report that case as passed.
func _constructor_error_fails(context: RefCounted) -> void:
	var observer: Observer = Observer.new()
	observer.records.append({"file": SUITE_PATH, "line": 3, "message": "boom"})
	var result: Dictionary = _run(observer)
	context.equal(result["passed"], false, "the case fails")
	context.equal(result["errors"].size(), 2, "the run names the abort and the divergence")
	context.equal(result["errors"][0]["kind"], "case_aborted", "the run names the abort")
	context.equal(result["errors"][1]["kind"], "repeat_divergence", "the run names the divergence")
	var runs: Array = result["records"][0]["runs"]
	context.equal(runs[0]["failures"].size(), 1, "the first repetition carries the abort")
	context.equal(runs[1]["failures"], [], "the second repetition keeps its verdict")


func _run(observer: Observer) -> Dictionary:
	var scripts: Array[Script] = [Suite]
	return Scenarios.new().execute(scripts, "unit", "", 1701, PackedStringArray(), Callable(), Callable(), Callable(observer, "read"))
