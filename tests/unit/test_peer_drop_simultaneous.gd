extends "res://tests/unit/test_peer_drop_barrier.gd"

# Value: protects=fixed barrier participants cannot silently shrink when two peers go silent together;
# fails_when=a survivor omits the second departure from the open certificate or freezes a partial cut;
# why_new=existing second-departure coverage is serial; seam=none
const Drop = preload("res://addons/fortress_rollback/core/peer_drop_barrier.gd")

const TARGETS: Array[int] = [3, 4]
const SURVIVORS: Array[int] = [0, 1, 2]


func cases() -> PackedStringArray:
	return PackedStringArray(["simultaneous_departure"])


func run_case(_name: String, context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE, 8, 5, [], 250000, 64, 48)
	_play(context, mesh, 6, true)
	# Both departing peers finish their last exchanged frame, then go silent together.
	_leave(context, mesh, 3)
	_leave(context, mesh, 4)
	_wait_for_departures(context, mesh, 600000)
	for survivor: int in SURVIVORS:
		context.equal(mesh.peers[survivor].status().lifecycle, Types.Lifecycle.TERMINATED, "an overlapping departure ends the match explicitly")
		context.equal(mesh.peers[survivor].status().reason, Types.Code.PROTOCOL_FAILED, "the terminal cause is a protocol failure")
		for target: int in TARGETS:
			context.equal(mesh.peers[survivor]._core.frozen_frame(target), -1, "no survivor freezes a slot on an incomplete participant set")
			var barrier: Variant = mesh.peers[survivor]._drops.barrier(_id(target).hex_encode())
			context.equal(barrier == null or barrier.state != Drop.COMMITTED, true, "no overlapping certificate commits at survivor %d" % survivor)
	context.equal(mesh.reasons.count("participant_lost"), SURVIVORS.size(), "every survivor names the missing participant instead of a timeout")
	context.equal(mesh.cuts.is_empty(), true, "no survivor publishes a partial drop")
	context.finish()


func _wait_for_departures(context: RefCounted, mesh: Dictionary, elapsed: int) -> void:
	var waited: int = 0
	while waited < elapsed:
		mesh.now += 1000
		waited += 1000
		for survivor: int in SURVIVORS:
			var polled: int = mesh.peers[survivor].poll(mesh.now)
			if polled == I.Code.TERMINATED:
				continue
			context.equal(polled, I.Code.OK, "poll a surviving peer")
		var packets: Array[Dictionary] = []
		for packet: Dictionary in _drain(mesh):
			if SURVIVORS.has(packet.to) and SURVIVORS.has(packet.from):
				packets.append(packet)
		_deliver(context, mesh, packets, true)
