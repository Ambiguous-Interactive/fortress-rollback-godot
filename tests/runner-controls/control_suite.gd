extends RefCounted

# Deliberate failures are outside automatic discovery. The launcher tests these
# at the actual Godot process boundary, never counting a timeout as rejection.
static var leaked_calls: int = 0


func cases() -> PackedStringArray:
	return PackedStringArray(["pass", "fail", "incomplete", "uncaught", "after_completion_error", "static_leak", "watchdog"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"pass":
			context.equal(1, 1, "known pass")
		"fail":
			context.bytes_equal(PackedByteArray([1, 9]), PackedByteArray([1, 2]), 7, "known fail")
		"incomplete":
			context.equal(1, 1, "incomplete")
			return
		"uncaught":
			var empty: Array[int] = []
			context.equal(empty[4], 0, "uncaught")
		"after_completion_error":
			context.equal(1, 1, "completed before engine error")
			context.finish()
			var empty: Array[int] = []
			context.equal(empty[4], 0, "uncaught after completion")
		"static_leak":
			leaked_calls += 1
			context.equal(leaked_calls, 1, "static leak")
			context.state(3, PackedByteArray([leaked_calls]))
		"watchdog":
			print("FORTRESS_WATCHDOG_ENTERED")
			while true:
				pass
	context.finish()
