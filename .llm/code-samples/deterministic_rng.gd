# Deterministic RNG sample.
#
# A PRNG whose ENTIRE state is a single integer, so it can be stored inside
# simulation state and round-tripped by save/load. Never use the global RNG
# (randf/randi/randomize) in simulation code - see
# .llm/skills/determinism/SKILL.md.
#
# xorshift on a 63-bit state (masked) keeps every operation inside GDScript's
# signed 64-bit int range, so behavior is identical on all platforms.
class_name DeterministicRng
extends RefCounted

const MASK: int = 0x7FFFFFFFFFFFFFFF

var _state: int


func _init(seed_value: int = 1) -> void:
	assert(seed_value != 0, "seed must be nonzero")
	_state = seed_value & MASK
	if _state == 0:
		_state = 1


func next_u63() -> int:
	# xorshift64*: returns a value in [0, 2^63)
	_state ^= (_state << 13) & MASK
	_state ^= _state >> 7
	_state ^= (_state << 17) & MASK
	return _state


func next_int_below(bound: int) -> int:
	# Unbiased-enough mapping for simulation use: modulo with rejection is
	# overkill here, but document the tiny skew if you rely on it.
	assert(bound > 0)
	return int(next_u63() % bound)


## Uniform float in [0, 1). Division of ints by a power-of-two float is
## IEEE-exact, so the result is bit-identical across platforms.
func next_unit_float() -> float:
	return float(next_u63()) / float(1 << 62)


## Snapshot support: the full RNG state is one int.
func save_state() -> int:
	return _state


func load_state(state: int) -> void:
	_state = state & MASK
	if _state == 0:
		_state = 1
