extends "res://tests/unit/test_peer_drop_barrier.gd"

const Drop = preload("res://addons/fortress_rollback/core/peer_drop_barrier.gd")
const Reference = preload("res://tests/oracle/reference_game.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(
		[
			"follower_lost_before_commit",
			"coordinator_lost_before_commit",
			"reported_participant_loss",
			"buffered_commit_after_loss",
			"buffered_commit_after_coordinator_loss",
			"follower_lost_after_commit"
		]
	)


func run_case(name: String, context: RefCounted) -> void:
	if name.begins_with("buffered_commit_after_"):
		_buffered_commit_after_loss(context, 0 if name == "buffered_commit_after_coordinator_loss" else 2)
		context.finish()
		return
	_participant_loss(context, name != "follower_lost_after_commit", 0 if name == "coordinator_lost_before_commit" else 2, name == "reported_participant_loss")
	context.finish()


# Value: protects=pending drop cannot change its participant set; fails_when=lost participant is silently omitted; why_new=sequential tests lose peers after commit; seam=none
func _participant_loss(context: RefCounted, pending: bool, departed: int, reported: bool) -> void:
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE, 8, 4)
	mesh.drop_events = {}
	mesh.active = [0, 1, 2, 3]
	mesh.hold_ready = pending
	mesh.held_ready = 0
	mesh.reported_loss = reported
	_play(context, mesh, 6, true)
	_close_departure(context, mesh, 3)
	for tick: int in range(100):
		_service_survivors(context, mesh)
		var initial: Drop.Barrier = mesh.peers[0]._drops.barrier(_id(3).hex_encode())
		if initial == null:
			continue
		if pending and mesh.held_ready > 0:
			break
		if not pending and initial.state == Drop.COMMITTED:
			break
	var first: Drop.Barrier = mesh.peers[0]._drops.barrier(_id(3).hex_encode())
	context.equal(first != null, true, "the initial departure starts a barrier")
	if first == null:
		return
	context.equal(first.state, Drop.PENDING if pending else Drop.COMMITTED, "participant loss occurs in the selected phase")
	if pending:
		context.equal(mesh.held_ready > 0, true, "a real certificate was withheld before participant loss")
	_close_departure(context, mesh, departed)
	mesh.hold_ready = false
	if pending:
		for turn: int in range(3):
			_deliver(context, mesh, _drain(mesh), true)
		for survivor: int in mesh.active:
			context.equal(mesh.peers[survivor].poll(mesh.now), I.Code.TERMINATED, "pending participant loss closes the unsafe match")
			context.equal(mesh.reasons_by_peer.get(survivor, []).has("participant_lost"), true, "each survivor records the missing participant")
			context.equal(mesh.peers[survivor].status().reason, Types.Code.PROTOCOL_FAILED, "the terminal cause is protocol failure")
			var initial: Drop.Barrier = mesh.peers[survivor]._drops.barrier(_id(3).hex_encode())
			context.equal(initial.state, Drop.FAILED, "the original participant certificate is aborted")
			context.equal(mesh.peers[survivor]._drops.is_dropped(_id(3).hex_encode()), false, "an uncommitted target is never frozen on participant loss")
		context.equal(mesh.reasons.has("participant_lost"), true, "the missing participant is recorded explicitly")
		return
	for tick: int in range(100):
		_service_survivors(context, mesh)
	context.equal(mesh.unconfirmed, 0, "postcommit loss does not revoke the committed agreement")
	var cuts: Dictionary = {}
	for target: int in [2, 3]:
		for survivor: int in mesh.active:
			var barrier: Drop.Barrier = mesh.peers[survivor]._drops.barrier(_id(target).hex_encode())
			context.equal(barrier != null, true, "each departure owns a survivor agreement")
			if barrier == null:
				continue
			context.equal(barrier.state, Drop.COMMITTED, "the remaining survivors commit both departures")
			if survivor == 0:
				cuts[target] = barrier.cut
			else:
				context.equal(barrier.cut, cuts[target], "both survivors agree each departed slot's frame")
			context.equal(mesh.drop_events.get("%d:%d" % [survivor, target], []), [barrier.cut], "each departure publishes once per survivor")
	var before: int = mesh.peers[0].status().current_frame
	for frame: int in range(12):
		mesh.now += 1000
		for survivor: int in mesh.active:
			context.equal(mesh.peers[survivor].step(mesh.now, _inputs(mesh, survivor)).code, Types.Code.OK, "the surviving match advances")
		for turn: int in range(3):
			_deliver(context, mesh, _drain(mesh))
	for survivor: int in mesh.active:
		context.equal(mesh.peers[survivor].status().current_frame, before + 12, "all requested survivor frames advance")
		context.equal(mesh.peers[survivor].status().lifecycle, Types.Lifecycle.RUNNING, "the match remains running")
	var shared: int = mini(mesh.peers[0].status().confirmed_frame, mesh.peers[1].status().confirmed_frame)
	context.equal(shared > before, true, "both survivors confirm new gameplay")
	var reference: RefCounted = Reference.new(4, 2)
	var expected: Dictionary = {}
	for frame: int in range(shared):
		var row: Array[Dictionary] = []
		for slot: int in range(4):
			var frozen: bool = cuts.has(slot) and frame > int(cuts[slot])
			row.append({"player": slot, "bytes": _sample(slot, int(cuts[slot]) if frozen else frame).hex_encode(), "status": "disconnected" if frozen else "confirmed"})
		context.equal(reference.advance(row), "", "the independent surviving history advances")
		expected[frame] = reference.bytes().hex_encode()
	for survivor: int in mesh.active:
		var states: Dictionary = {}
		for request: Dictionary in mesh.games[survivor].requests:
			if request.kind == "advance":
				states[request.frame] = request.state_bytes
		for frame: int in range(shared):
			context.equal(states.get(frame, ""), expected[frame], "every confirmed state preserves the original input history")


# Value: protects=buffered commit cannot overtake observed participant loss; fails_when=receive checks only at next service; why_new=facade usually services immediately; seam=none
func _buffered_commit_after_loss(context: RefCounted, departed: int) -> void:
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE, 8, 4)
	mesh.drop_events = {}
	mesh.active = [0, 1, 2, 3]
	mesh.hold_ready = false
	mesh.held_ready = 0
	mesh.reported_loss = false
	mesh.held_commit = []
	_play(context, mesh, 6, true)
	_close_departure(context, mesh, 3)
	for tick: int in range(100):
		_service_survivors(context, mesh)
		if not mesh.held_commit.is_empty():
			break
	context.equal(mesh.held_commit.is_empty(), false, "capture an actual encoded COMMIT before follower dispatch")
	if mesh.held_commit.is_empty():
		return
	var survivor: Peer = mesh.peers[1]
	var original: Drop.Barrier = survivor._drops.barrier(_id(3).hex_encode())
	context.equal(original.state, Drop.PENDING, "the buffered COMMIT has not committed the follower")
	context.equal(original.certified, true, "the follower already certified this COMMIT's value")
	# Exercise the barrier's public observation/dispatch boundary before its next service.
	context.equal(survivor._drops.observed(survivor, survivor.peer_ids().find(_id(departed))), true, "observe the second departure before dispatching buffered control")
	var decoded: T.Result = Codec.decode(mesh.held_commit[0], _limits(4))
	context.equal(decoded.code, T.Code.OK, "decode the original buffered COMMIT")
	var event: Dictionary = {"slots": decoded.message.data}
	for field: String in ["phase", "stage", "operation", "coordinator", "coordinator_generation", "target_set_digest", "cut", "cut_digest"]:
		event[field] = decoded.message.get(field)
	survivor._drops.received(survivor, survivor.peer_ids().find(_id(0)), event)
	context.equal(survivor.status().lifecycle, Types.Lifecycle.TERMINATED, "the buffered COMMIT cannot revive the unsafe operation")
	context.equal(original.state, Drop.FAILED, "participant loss aborts before COMMIT dispatch")
	context.equal(survivor._drops.is_dropped(_id(3).hex_encode()), false, "the buffered COMMIT never freezes the uncertified participant set")
	_drain(mesh)
	context.equal(mesh.reasons_by_peer.get(1, []).has("participant_lost"), true, "dispatch records the missing participant")


func _close_departure(context: RefCounted, mesh: Dictionary, departed: int) -> void:
	mesh.now += 1000
	context.equal(mesh.peers[departed].close(mesh.now), I.Code.OK, "the participant publishes its real GOODBYE")
	_deliver(context, mesh, _drain(mesh))
	mesh.active.erase(departed)


func _service_survivors(context: RefCounted, mesh: Dictionary) -> void:
	mesh.now += 1000
	for survivor: int in mesh.active:
		context.equal(mesh.peers[survivor].poll(mesh.now), I.Code.OK, "poll the surviving endpoint")
	for turn: int in range(3):
		_deliver(context, mesh, _drain(mesh))


func _deliver(context: RefCounted, mesh: Dictionary, packets: Array[Dictionary], terminated: bool = false) -> void:
	# Startup exchanges include every endpoint; after departure only survivors receive.
	if not mesh.has("active"):
		super._deliver(context, mesh, packets, terminated)
		return
	var accepted: Array[Dictionary] = []
	for packet: Dictionary in packets:
		if not mesh.active.has(packet.from) or not mesh.active.has(packet.to):
			continue
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
		if mesh.reported_loss and packet.from == 2 and packet.to == 1 and decoded.code == T.Code.OK and decoded.message.kind == T.Kind.GOODBYE:
			continue
		if mesh.has("held_commit") and packet.from == 0 and packet.to == 1 and decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER:
			if decoded.message.phase == Drop.Phase.COMMIT:
				mesh.held_commit.append(packet.bytes.duplicate())
				continue
		if mesh.hold_ready and packet.from == 2 and decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER:
			if decoded.message.phase == Drop.Phase.REPORT and decoded.message.stage == Drop.Stage.READY:
				mesh.held_ready += 1
				continue
		accepted.append(packet)
	super._deliver(context, mesh, accepted, true)


func _drain(mesh: Dictionary) -> Array[Dictionary]:
	if not mesh.has("reasons_by_peer"):
		mesh.reasons_by_peer = {}
	var result: Array[Dictionary] = []
	for source: int in range(mesh.peers.size()):
		for packet: Peer.Packet in mesh.peers[source].drain_outbox():
			result.append({"from": source, "to": packet.to[0] - 1, "bytes": packet.bytes})
		mesh.peers[source].drain_transitions()
		for event: Dictionary in mesh.peers[source].drain_events():
			if event.kind == "peer_dropped":
				mesh.cuts[source] = event.frame
				var key: String = "%d:%d" % [source, event.peer[0] - 1]
				if not mesh.drop_events.has(key):
					mesh.drop_events[key] = []
				mesh.drop_events[key].append(event.frame)
			elif event.kind == "peer_drop_unconfirmed":
				mesh.unconfirmed += 1
				mesh.reasons.append(event.reason)
				if not mesh.reasons_by_peer.has(source):
					mesh.reasons_by_peer[source] = []
				mesh.reasons_by_peer[source].append(event.reason)
	return result
