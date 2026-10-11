class_name FortressOfflinePresentation
extends RefCounted

const Simulation = preload("res://examples/offline/simulation.gd")

var last_event_id: PackedInt64Array = PackedInt64Array([0, 0])
var pulse_count: int = 0


## Call after a successful driver step, never from a simulation callback.
## This bounded ledger counts cosmetic pulses; rendering reads corrected state.
func reconcile(simulation: Simulation) -> void:
	for player: int in range(2):
		if simulation.event_id[player] > last_event_id[player]:
			last_event_id[player] = simulation.event_id[player]
			pulse_count += 1
