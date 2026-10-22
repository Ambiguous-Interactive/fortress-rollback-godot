extends RefCounted

# A suite for the runner's abort report. The case never fails on its own: the
# abort is reported by the observer, which stands in for the engine's script
# error. Its resource path is the suite name the report carries.
func cases() -> PackedStringArray:
	return PackedStringArray(["aborted"])


func run_case(_name: String, context: RefCounted) -> void:
	context.equal(1, 1, "reaches the completion marker")
	context.finish()
