extends "res://tests/unit/test_peer_drop_barrier.gd"

# Value: protects=fixed participants cannot diverge when a second peer leaves after READY but before COMMIT reaches every survivor;
# fails_when=the committed survivor keeps playing while the pending survivor ends the match; why_new=simultaneous coverage opens both before a certificate; seam=none
const Drop = preload("res://addons/fortress_rollback/core/peer_drop_barrier.gd")

const TARGET: int = 3
const PROPOSER: int = 0
const PENDING: int = 1
const SECOND: int = 2
const SURVIVORS: Array[int] = [PROPOSER, PENDING]
const PARTICIPANTS: Array[int] = [PROPOSER, PENDING, SECOND]


func cases() -> PackedStringArray:
	return PackedStringArray(["ready_commit_overlap", "asymmetric_ack_departure"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "asymmetric_ack_departure":
		_asymmetric_ack(context)
		context.finish()
		return
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


## A single lost follower-to-follower confirmation is repeated by its sender,
## so the follower becomes confirmed and a later serial departure keeps the
## one-member freeze instead of ending the match.
func _asymmetric_ack(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE, 8, 4, [], 250000, 64, 48)
	_play(context, mesh, 6, true)
	_leave(context, mesh, TARGET)
	var committed: int = _drive_all_commit(context, mesh)
	var key: String = _id(TARGET).hex_encode()
	for survivor: int in PARTICIPANTS:
		context.equal(mesh.peers[survivor]._drops.barrier(key).state, Drop.COMMITTED, "every participant committed before the departure")
		context.equal(_confirmed(mesh, survivor), true, "the repeated confirmation reaches every participant")
	context.equal(int(mesh.get("lost_confirmations", 0)), 1, "the first follower-to-follower confirmation was physically lost")
	context.equal(mesh.peers[SECOND].close(mesh.now, 7), I.Code.OK, "the acknowledged participant says goodbye")
	_deliver(context, mesh, _drain(mesh), true)
	var serial_cut: int = _serial_drop(context, mesh, 800000)
	context.equal(serial_cut >= 0, true, "the serial second departure completes after the lost confirmation")
	for survivor: int in SURVIVORS:
		context.equal(mesh.peers[survivor].status().lifecycle, Types.Lifecycle.RUNNING, "the serial departure keeps every survivor running")
		context.equal(mesh.peers[survivor]._core.frozen_frame(TARGET), committed, "the committed survivors keep their first certified freeze")
		context.equal(mesh.peers[survivor]._core.frozen_frame(SECOND), serial_cut, "the committed survivors freeze the serial departure")
	context.equal(mesh.reasons.count("participant_lost"), 0, "one lost confirmation does not end the match")


## Drive the drop until all three survivors commit and confirm, while the first
## second-follower COMMITTED report to the first follower is lost.
func _drive_all_commit(context: RefCounted, mesh: Dictionary) -> int:
	var waited: int = 0
	mesh["lost_confirmations"] = 0
	while waited < 800000:
		if _committed_count(mesh) == PARTICIPANTS.size() and _all_confirmed(mesh):
			var barrier: Variant = mesh.peers[PROPOSER]._drops.barrier(_id(TARGET).hex_encode())
			return int(barrier.cut)
		mesh.now += 1000
		waited += 1000
		for survivor: int in PARTICIPANTS:
			context.equal(mesh.peers[survivor].poll(mesh.now), I.Code.OK, "poll a participant before the asymmetric departure")
		var packets: Array[Dictionary] = []
		for packet: Dictionary in _drain(mesh):
			if packet.from == TARGET or packet.to == TARGET:
				continue
			if packet.from == SECOND and packet.to == PENDING and _is_committed_report(packet):
				if int(mesh["lost_confirmations"]) == 0:
					mesh["lost_confirmations"] = 1
					continue
			packets.append(packet)
		_deliver(context, mesh, packets, true)
	context.equal(false, true, "every participant commits and confirms before the serial departure")
	return -1


## Keep the remaining survivors playing until they freeze the serial departure.
func _serial_drop(context: RefCounted, mesh: Dictionary, elapsed: int) -> int:
	var waited: int = 0
	while waited < elapsed:
		var shared: int = -1
		var done: bool = true
		for survivor: int in SURVIVORS:
			var frozen: int = mesh.peers[survivor]._core.frozen_frame(SECOND)
			if frozen < 0:
				done = false
			elif shared < 0:
				shared = frozen
			elif shared != frozen:
				done = false
		if done:
			return shared
		mesh.now += 1000
		waited += 1000
		for survivor: int in SURVIVORS:
			context.equal(mesh.peers[survivor].poll(mesh.now), I.Code.OK, "poll a survivor after the serial departure")
		var packets: Array[Dictionary] = []
		for packet: Dictionary in _drain(mesh):
			if SURVIVORS.has(packet.from) and SURVIVORS.has(packet.to):
				packets.append(packet)
		_deliver(context, mesh, packets, true)
	return -1


## True for one survivor's COMMITTED report.
func _is_committed_report(packet: Dictionary) -> bool:
	var decoded: T.Result = Codec.decode(packet.bytes, _limits(4))
	return decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER \
		and decoded.message.phase == Drop.Phase.REPORT and decoded.message.stage == Drop.Stage.COMMITTED


## True when the survivor confirms every acknowledgement it needs.
func _confirmed(mesh: Dictionary, survivor: int) -> bool:
	var barrier: Variant = mesh.peers[survivor]._drops.barrier(_id(TARGET).hex_encode())
	return barrier != null and barrier.state == Drop.COMMITTED \
		and mesh.peers[survivor]._drops._commit_confirmed(mesh.peers[survivor], barrier)


## True when every participant confirms the target's committed operation.
func _all_confirmed(mesh: Dictionary) -> bool:
	for survivor: int in PARTICIPANTS:
		if not _confirmed(mesh, survivor):
			return false
	return true


## The participants that already committed the target's barrier.
func _committed_count(mesh: Dictionary) -> int:
	var count: int = 0
	var key: String = _id(TARGET).hex_encode()
	for survivor: int in PARTICIPANTS:
		var barrier: Variant = mesh.peers[survivor]._drops.barrier(key)
		if barrier != null and barrier.state == Drop.COMMITTED:
			count += 1
	return count


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
