extends RefCounted

# A fixture suite with one deliberately slow case, used by the scenario runner
# test to prove that a slow case reports a long elapsed time while a fast case
# reports a bounded one. It burns deterministic integer work, so the case is
# slow for the same reason on every platform: the work is not optimized away
# and the runner reads a monotonic clock.

const WORK: int = 400000


func cases() -> PackedStringArray:
	return PackedStringArray(["slow", "fast"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "slow":
		var total: int = 0
		for index: int in range(WORK):
			total = (total * 31 + index) & 0x7FFFFFFF
		context.equal(total >= 0, true, "the slow case did its work")
	else:
		context.equal(1, 1, "the fast case did its work")
	context.finish()
