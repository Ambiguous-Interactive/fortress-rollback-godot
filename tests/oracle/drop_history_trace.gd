extends SceneTree

const Fixture = preload("res://tests/oracle/drop_history_fixture.gd")
const Context = preload("res://tests/runner/test_context.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")


func _initialize() -> void:
	var context: RefCounted = Context.new(1701)
	var status_control: int = -1
	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	var loss: bool = arguments.has("--drop-first-history")
	var corrupt: bool = arguments.has("--corrupt-interior-history")
	var multi: bool = arguments.has("--multi-row-history")
	if (corrupt and not multi) or arguments.size() != int(loss) + int(multi) + int(corrupt):
		if arguments.size() != 2 or arguments[0] != "--observer-status" or arguments[1] not in ["none", "predicted", "unknown"]:
			printerr("drop history: unknown observer control")
			quit(2)
			return
		match arguments[1]:
			"none": status_control = Queue.Status.NONE
			"predicted": status_control = Queue.Status.PREDICTED
			"unknown": status_control = 42
	var result: Dictionary = Fixture.new().observe(context, status_control, loss, 4 if multi else 1, corrupt)
	print("FORTRESS_DROP_HISTORY_RESULT " + JSON.stringify(result))
	quit(0 if context.failures.is_empty() else 1)
