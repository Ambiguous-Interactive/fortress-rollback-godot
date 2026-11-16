extends RefCounted

# Value: protects=the trace driver's scenario-operation bound stays deliberate; fails_when=the
# #379 raise drifts on the Godot side while the Rust and Python validators keep theirs;
# why_new=#379 default-ring wrap floods; seam=p2p_trace's scenario grammar
const Trace = preload("res://tests/oracle/p2p_trace.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["operation_inventory_bound"])


func _scenario(count: int) -> Dictionary:
	var operations: Array = []
	for index: int in range(1, count + 1):
		operations.append({"kind": "poll", "peer": 0, "now_us": index})
	return {"format": 1, "players": 2, "input_delay": 0, "max_prediction": 4, "operations": operations}


func run_case(_name: String, context: RefCounted) -> void:
	var trace: SceneTree = Trace.new()
	context.equal(trace._valid(_scenario(20000)), true, "bound admits the eight-peer default-ring corpus scale")
	context.equal(trace._valid(_scenario(20001)), false, "bound refuses one operation above the corpus scale")
	# The probe instance is never the running tree; free it so the runner's leak
	# checks stay clean.
	trace.free()
	context.finish()
