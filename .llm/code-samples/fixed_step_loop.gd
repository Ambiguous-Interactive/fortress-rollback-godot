# Fixed-timestep driver sample.
#
# The simulation advances only in whole ticks. The engine loop may fire
# irregularly; the accumulator converts real time into an integer number of
# ticks. Simulation code never sees delta time - see
# .llm/skills/determinism/SKILL.md.
class_name FixedStepDriver
extends Node

const TICK_HZ: int = 60
## Clamp so a background stall cannot trigger a runaway catch-up spiral.
const MAX_TICKS_PER_FRAME: int = 5

signal tick_advanced(frame: int)

var _accumulator_ns: int = 0
var _frame: int = 0


func _process(delta: float) -> void:
	# `delta` is presentation-only; it is converted to whole ticks and then
	# discarded. Sim math itself never consumes it.
	_accumulator_ns += int(delta * 1_000_000_000.0)
	var ticks := mini(_accumulator_ns / (1_000_000_000 / TICK_HZ), MAX_TICKS_PER_FRAME)
	_accumulator_ns -= ticks * (1_000_000_000 / TICK_HZ)
	for i in ticks:
		_advance_tick()


func _advance_tick() -> void:
	# Real implementation: session.advance(gather_inputs(_frame)) which may
	# roll back and re-simulate before the new tick (see
	# .llm/skills/rollback-fundamentals/SKILL.md).
	_frame += 1
	tick_advanced.emit(_frame)


func current_frame() -> int:
	return _frame


## Snapshot support: the driver's own state is two integers. Any state your
## simulation adds must be captured the same way.
func save_state() -> Dictionary:
	return {"frame": _frame, "accumulator_ns": _accumulator_ns}


func load_state(state: Dictionary) -> void:
	_frame = state["frame"]
	_accumulator_ns = state["accumulator_ns"]
