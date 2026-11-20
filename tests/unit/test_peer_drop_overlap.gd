extends "res://tests/unit/test_peer_drop_barrier.gd"

# Value: protects=fixed participants cannot diverge when a second peer leaves after READY but before COMMIT reaches every survivor;
# fails_when=the committed survivor keeps playing while the pending survivor ends the match; why_new=simultaneous coverage opens both before a certificate; seam=none
const Drop = preload("res://addons/fortress_rollback/core/peer_drop_barrier.gd")

const TARGET: int = 3
const PROPOSER: int = 0
const PENDING: int = 1
const SECOND: int = 2
const SURVIVORS: Array[int] = [PROPOSER, PENDING]


func cases() -> PackedStringArray:
	return PackedStringArray(["ready_commit_overlap"])


func run_case(_name: String, context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE, 8, 4, [], 250000, 64, 48)
	_play(context, mesh, 6, true)
	_leave(context, mesh, TARGET)
	var committed: int = _drive_to_commit(context, mesh)
	var key: String = _id(TARGET).hex_encode()
	var proposer: Variant = mesh.peers[PROPOSER]._drops.barrier(key)
	var pending: Variant = mesh.peers[PENDING]._drops.barrier(key)
	context.equal(proposer.state, Drop.COMMITTED, "the proposer commits its certified operation")
	context.equal(pending.state, Drop.PENDING, "the follower still waits for the commit")
	context.equal(bool(pending.certified), true, "the pending survivor already certified the same value")
	# The second departure lands after the follower's READY and before the
	# dropped COMMIT: the committed proposer and the pending follower must
	# reach one outcome instead of the proposer continuing alone.
	var goodbye: int = mesh.peers[SECOND].close(mesh.now, 7)
	context.equal(goodbye, I.Code.OK, "the second participant says goodbye")
	_deliver(context, mesh, _drain(mesh), true)
	_settle(context, mesh, 800000)
	for survivor: int in SURVIVORS:
		context.equal(mesh.peers[survivor].status().lifecycle, Types.Lifecycle.TERMINATED, "the READY-to-commit overlap ends every survivor")
		context.equal(mesh.peers[survivor].status().reason, Types.Code.PROTOCOL_FAILED, "the overlap names a protocol failure")
	context.equal(mesh.reasons.count("participant_lost"), SURVIVORS.size(), "every survivor names the lost participant")
	context.equal(mesh.peers[PROPOSER]._core.frozen_frame(TARGET), committed, "the committed survivor keeps its irreversible certified freeze")
	context.equal(mesh.peers[PENDING]._core.frozen_frame(TARGET), -1, "the pending survivor never freezes the target")
	for slot: int in [PENDING, SECOND]:
		context.equal(mesh.peers[PROPOSER]._core.frozen_frame(slot), -1, "the committed survivor freezes no later departure on its way out")
	context.finish()


## Drive the drop until the proposer commits while every COMMIT packet to the
## other survivors is withheld, leaving one follower certified but pending.
func _drive_to_commit(context: RefCounted, mesh: Dictionary) -> int:
	var waited: int = 0
	while waited < 800000 and not mesh.cuts.has(PROPOSER):
		mesh.now += 1000
		waited += 1000
		for survivor: int in [0, 1, 2]:
			var polled: int = mesh.peers[survivor].poll(mesh.now)
			context.equal(polled, I.Code.OK, "poll a survivor before the commit")
		var packets: Array[Dictionary] = []
		for packet: Dictionary in _drain(mesh):
			if packet.from == TARGET or packet.to == TARGET:
				continue
			if packet.from == PROPOSER:
				var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
				if decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER \
					and decoded.message.phase == Drop.Phase.COMMIT:
					continue
			packets.append(packet)
		_deliver(context, mesh, packets, true)
	context.equal(mesh.cuts.has(PROPOSER), true, "the proposer commits the certified operation")
	var barrier: Variant = mesh.peers[PROPOSER]._drops.barrier(_id(TARGET).hex_encode())
	return int(barrier.cut)


## Keep the two survivors alive until both stop.
func _settle(context: RefCounted, mesh: Dictionary, elapsed: int) -> void:
	var waited: int = 0
	while waited < elapsed:
		mesh.now += 1000
		waited += 1000
		var running: int = 0
		for survivor: int in SURVIVORS:
			var polled: int = mesh.peers[survivor].poll(mesh.now)
			if polled != I.Code.TERMINATED:
				context.equal(polled, I.Code.OK, "poll a survivor after the second departure")
				running += 1
		var packets: Array[Dictionary] = []
		for packet: Dictionary in _drain(mesh):
			if SURVIVORS.has(packet.from) and SURVIVORS.has(packet.to):
				packets.append(packet)
		_deliver(context, mesh, packets, true)
		if running == 0:
			return
