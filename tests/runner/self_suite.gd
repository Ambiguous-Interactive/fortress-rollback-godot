extends RefCounted

# Value: protects=runner assertions/reset/diagnostics;
# fails_when=release assertions vanish or fixtures are reused;
# why_new=first runner implementation; seam=none
const Context = preload("res://tests/runner/test_context.gd")
var calls: int = 0


func cases() -> PackedStringArray:
	return PackedStringArray(["assertions_and_fixture_reset"])


func run_case(_name: String, context: RefCounted) -> void:
	calls += 1
	var rows: Array[Dictionary] = [
		{"actual": calls, "expected": 1, "label": "fresh fixture"}, {"actual": str(context.seed).to_int(), "expected": context.seed, "label": "lossless seed"}
	]
	context.table(rows)
	var probe: RefCounted = Context.new(context.seed)
	probe.bytes_equal(PackedByteArray([1, 9]), PackedByteArray([1, 2]), 7, "byte")
	probe.bytes_equal(PackedByteArray([1]), PackedByteArray([1, 2]), 8, "length")
	context.equal(probe.failures[0]["byte"], 1, "first differing byte")
	context.equal(probe.failures[0]["frame"], 7, "first differing frame")
	context.equal(probe.failures[1]["byte"], 1, "truncated bytes")
	context.state(0, PackedByteArray([1, 2]))
	context.finish()
