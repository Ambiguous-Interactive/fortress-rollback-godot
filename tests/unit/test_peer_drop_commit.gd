extends "res://tests/unit/test_peer_drop_barrier.gd"

const Drop = preload("res://addons/fortress_rollback/core/peer_drop_barrier.gd")
const SCENARIOS: Dictionary = {"clean_ack_quiescence": false, "lost_first_ack_recommits": true}


func cases() -> PackedStringArray:
	return PackedStringArray(
		(
			SCENARIOS.keys()
			+ [
				"malformed_committed_ack",
				"malformed_duplicate_commit",
				"early_committed_ack",
				"wrong_sender_commit",
				"commit_deadline",
				"duplicate_ready_control",
				"contradictory_ready_cut",
				"contradictory_ready_digest",
			]
		)
	)


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"duplicate_ready_control", "contradictory_ready_cut", "contradictory_ready_digest":
			_duplicate_ready(context, name)
		"malformed_committed_ack":
			_malformed_committed(context, true)
		"malformed_duplicate_commit":
			_malformed_committed(context, false)
		"early_committed_ack":
			_early_committed_ack(context)
		"wrong_sender_commit":
			_wrong_sender_commit(context)
		"commit_deadline":
			_commit_deadline(context)
		_:
			_commit_ack(context, bool(SCENARIOS[name]))
	context.finish()


# Value: protects=barrier expiry precedes buffered COMMIT; fails_when=receive commits at its deadline; why_new=poll-only timeout coverage; seam=none
func _commit_deadline(context: RefCounted) -> void:
	for offset: int in [-1, 0, 1]:
		var mesh: Dictionary = _held_fixture(context, Drop.Phase.COMMIT, Drop.Stage.NONE, 1)
		if mesh.held.is_empty():
			return
		var follower: Drop.Barrier = mesh.peers[1]._drops.barrier(_id(2).hex_encode())
		context.equal(follower.state, Drop.PENDING, "hold the real COMMIT before follower dispatch")
		context.equal(follower.certified, true, "the follower certified the held COMMIT")
		mesh.now = follower.started_us + 250000 + offset
		_release_original(context, mesh, mesh.held[0])
		_drain(mesh)
		context.equal(follower.state, Drop.COMMITTED if offset < 0 else Drop.FAILED, "deadline equality wins over buffered COMMIT, offset %d" % offset)
		context.equal(mesh.unconfirmed, 0 if offset < 0 else 1, "expiry publishes exactly one unconfirmed outcome, offset %d" % offset)
		context.equal(mesh.reasons, [] if offset < 0 else ["timeout"], "the expired operation keeps its timeout reason")
		context.equal(mesh.peers[1].status().lifecycle, Types.Lifecycle.RUNNING if offset < 0 else Types.Lifecycle.TERMINATED, "an expired certificate fails closed")
		mesh.now = follower.started_us + 250001
		_release_original(context, mesh, mesh.held[0], offset >= 0)
		var acknowledgements: int = 0
		for packet: Dictionary in _drain(mesh):
			var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
			if decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER:
				if decoded.message.phase == Drop.Phase.REPORT and decoded.message.stage == Drop.Stage.COMMITTED:
					acknowledgements += 1
		context.equal(acknowledgements, 1 if offset < 0 else 0, "only a committed operation re-ACKs after its deadline")
		context.equal(mesh.drop_events.get(1, []).size(), 1 if offset < 0 else 0, "late duplicates cannot repeat or fabricate a freeze notification")
		context.equal(mesh.unconfirmed, 0 if offset < 0 else 1, "late duplicates cannot repeat expiry")


# Value: protects=committed ACK stops retries and lost ACK is repeated; fails_when=dropped target bypasses dispatch; why_new=barrier tests omit ACK completion; seam=none
func _commit_ack(context: RefCounted, lose_first: bool) -> void:
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE)
	_play(context, mesh, 6, true)
	_leave(context, mesh, 2)
	mesh.monitor_commit = true
	mesh.lose_first = lose_first
	mesh.lost_acks = 0
	mesh.commits = []
	mesh.acks = []
	mesh.delivered_acks = 0
	if lose_first:
		_hold_packets(mesh, Drop.Phase.REPORT, Drop.Stage.READY, 0)
		_wait_for_held(context, mesh)
		context.equal(mesh.held.size(), 1, "capture READY to separate PREPARE and COMMIT clocks")
		if mesh.held.is_empty():
			return
		_service_commit(context, mesh, int(mesh.now) + 10000)
		mesh.hold_phase = -1
		_release_original(context, mesh, mesh.held[0])
		# Receiving READY can publish COMMIT immediately. Capture it at that
		# same clock, before a later poll would mislabel its publication time.
		for round_trip: int in range(6):
			_deliver(context, mesh, _drain(mesh))
	# Stop at the actual first COMMITTED packet, before any retry is due.
	for tick: int in range(500):
		if not mesh.acks.is_empty():
			break
		_service_commit(context, mesh)
	context.equal(mesh.commits.size(), 1, "the proposer sends one initial COMMIT")
	context.equal(mesh.acks.size(), 1, "the follower emits its first COMMITTED ACK")
	if mesh.commits.is_empty() or mesh.acks.is_empty():
		return
	var commit: T.Message = mesh.commits[0].message
	context.equal(mesh.commits[0].from, 0, "the coordinator proposes the COMMIT")
	context.equal(mesh.commits[0].to, 1, "the COMMIT addresses the surviving follower")
	context.equal(commit.cut >= 0 and commit.cut_digest != 0, true, "the COMMIT carries a certified frame and digest")
	context.equal(commit.data.size(), 3, "the COMMIT names exactly one slot and its era")
	context.equal(commit.data[0], 2, "the COMMIT targets the departed slot")
	var proposer: Drop.Barrier = mesh.peers[0]._drops.barrier(_id(2).hex_encode())
	var follower: Drop.Barrier = mesh.peers[1]._drops.barrier(_id(2).hex_encode())
	context.equal(commit.operation, proposer.operation, "the packet names the committed operation")
	context.equal(commit.cut, proposer.cut, "the packet names the committed frame")
	context.equal(commit.cut_digest, proposer.digest, "the packet names the committed value")
	context.equal(follower.operation, proposer.operation, "both survivors commit the same operation")
	context.equal(follower.cut, proposer.cut, "both survivors commit the same frame")
	context.equal(follower.digest, proposer.digest, "both survivors commit the same value")
	context.equal(mesh.lost_acks, int(lose_first), "only the requested first COMMITTED ACK is lost")
	context.equal(mesh.delivered_acks, 0 if lose_first else 1, "the first ACK has the scripted delivery outcome")
	if lose_first:
		context.equal(proposer.acknowledged.has(_id(1).hex_encode()), false, "an undelivered ACK cannot complete the operation")
		_service_commit(context, mesh, int(mesh.commits[0].now) + Drop.RETRY_US - 1)
		context.equal(mesh.commits.size(), 1, "no COMMIT retry one microsecond before the first COMMIT deadline")
		_service_commit(context, mesh, int(mesh.commits[0].now) + Drop.RETRY_US)
		context.equal(mesh.commits.size(), 2, "loss causes one actual COMMIT retransmission")
		if mesh.commits.size() >= 2:
			context.equal(mesh.commits[1].now, int(mesh.commits[0].now) + Drop.RETRY_US, "COMMIT retry occurs at the exact deadline")
		context.equal(mesh.acks.size(), 2, "the follower re-ACKs the duplicate COMMIT")
		context.equal(mesh.delivered_acks, 1, "the repeated COMMITTED ACK reaches the proposer")
	context.equal(proposer.acknowledged.has(_id(1).hex_encode()), true, "the proposer records the delivered COMMITTED ACK")
	var commits_after_ack: int = mesh.commits.size()
	var acks_after_ack: int = mesh.acks.size()
	# More than two retry intervals, still inside the original timeout: silence
	# must be caused by the delivered ACK rather than retry-policy expiration.
	for tick: int in range(2 * Drop.RETRY_US / 1000 + 10):
		_service_commit(context, mesh)
	context.equal(int(mesh.now) - proposer.started_us < 250000, true, "quiescence is measured before the barrier timeout")
	context.equal(mesh.commits.size(), commits_after_ack, "valid ACK stops actual COMMIT packets across retry intervals")
	context.equal(mesh.acks.size(), acks_after_ack, "ACK completion produces no further COMMITTED packets")
	for packet: Dictionary in mesh.commits:
		_same_commit(context, packet.message, commit)
	for packet: Dictionary in mesh.acks:
		context.equal(packet.from, 1, "COMMITTED ACK originates at the surviving follower")
		context.equal(packet.to, 0, "COMMITTED ACK addresses the coordinator")
		_same_commit(context, packet.message, commit)
	_healthy_after_commit(context, mesh, commit)
	context.equal(mesh.commits.size(), commits_after_ack, "continuing gameplay does not restart COMMIT retries")
	for survivor: int in [0, 1]:
		context.equal(mesh.drop_events.get(survivor, []), [commit.cut], "each survivor publishes exactly one drop at the committed frame")
	context.equal(mesh.unconfirmed, 0, "ACK recovery never falls back to an unconfirmed drop")


func _same_commit(context: RefCounted, actual: T.Message, commit: T.Message) -> void:
	for field: String in ["operation", "data", "target_set_digest", "coordinator", "coordinator_generation", "cut", "cut_digest"]:
		context.equal(actual.get(field), commit.get(field), "COMMIT/ACK preserves exact %s" % field)


func _service_commit(context: RefCounted, mesh: Dictionary, now_us: int = -1) -> void:
	mesh.now = now_us if now_us >= 0 else int(mesh.now) + 1000
	for survivor: int in range(mesh.peers.size()):
		if survivor == 2:
			continue
		context.equal(mesh.peers[survivor].poll(mesh.now), I.Code.OK, "poll the surviving session")
	for round_trip: int in range(6):
		_deliver(context, mesh, _drain(mesh))


## Capture notifications before helpers can collapse repeated drops into one cut.
func _drain(mesh: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not mesh.has("drop_events"):
		mesh.drop_events = {}
	for source: int in range(mesh.peers.size()):
		for packet: Peer.Packet in mesh.peers[source].drain_outbox():
			result.append({"from": source, "to": packet.to[0] - 1, "bytes": packet.bytes})
		mesh.peers[source].drain_transitions()
		for event: Dictionary in mesh.peers[source].drain_events():
			if event.kind == "peer_dropped":
				mesh.cuts[source] = event.frame
				if not mesh.drop_events.has(source):
					mesh.drop_events[source] = []
				mesh.drop_events[source].append(event.frame)
			elif event.kind == "peer_drop_unconfirmed":
				mesh.unconfirmed += 1
				mesh.reasons.append(event.reason)
	return result


## Only one genuine encoded COMMITTED packet is discarded; all other survivor traffic flows.
func _deliver(context: RefCounted, mesh: Dictionary, packets: Array[Dictionary], terminated: bool = false) -> void:
	if not bool(mesh.get("monitor_commit", false)):
		super._deliver(context, mesh, packets, terminated)
		return
	var accepted: Array[Dictionary] = []
	for packet: Dictionary in _without_peer(packets, 2):
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
		context.equal(decoded.code, T.Code.OK, "decode the real session packet")
		if decoded.code != T.Code.OK:
			continue
		var message: T.Message = decoded.message
		if message.kind == T.Kind.DROP_BARRIER:
			var captured: Dictionary = {"from": packet.from, "to": packet.to, "bytes": packet.bytes.duplicate(), "message": message, "now": mesh.now}
			if message.phase == int(mesh.get("hold_phase", -1)) and message.stage == int(mesh.get("hold_stage", -1)) and packet.to == int(mesh.get("hold_to", -1)):
				mesh.held.append(captured)
				continue
			if message.phase == Drop.Phase.COMMIT:
				mesh.commits.append(captured)
			elif message.phase == Drop.Phase.REPORT and message.stage == Drop.Stage.COMMITTED:
				mesh.acks.append(captured)
				if mesh.lose_first and mesh.lost_acks == 0:
					mesh.lost_acks += 1
					continue
				mesh.delivered_acks += 1
		accepted.append(packet)
	super._deliver(context, mesh, accepted, terminated)


func _healthy_after_commit(context: RefCounted, mesh: Dictionary, commit: T.Message) -> void:
	var before: Array[int] = []
	var confirmed_before: Array[int] = []
	for survivor: int in [0, 1]:
		before.append(mesh.peers[survivor].status().current_frame)
		confirmed_before.append(mesh.peers[survivor].status().confirmed_frame)
	_play(context, mesh, 12, true, [0, 1], 2)
	for survivor: int in [0, 1]:
		context.equal(mesh.peers[survivor].status().lifecycle, Types.Lifecycle.RUNNING, "the acknowledged drop keeps gameplay running")
		context.equal(mesh.peers[survivor].status().reason, Types.Code.OK, "the survivor has no terminal cause")
		context.equal(mesh.peers[survivor].status().current_frame, before[survivor] + 12, "the survivor advances every requested frame")
		context.equal(mesh.peers[survivor].status().confirmed_frame > confirmed_before[survivor], true, "the survivor confirms continuing gameplay")
	var shared: int = mini(mesh.peers[0].status().confirmed_frame, mesh.peers[1].status().confirmed_frame)
	context.equal(shared > before[0], true, "canonical comparison includes newly confirmed gameplay")
	var first: Dictionary = _rows(mesh.games[0])
	var second: Dictionary = _rows(mesh.games[1])
	for frame: int in range(before[0], shared):
		context.equal(first.has(frame) and second.has(frame), true, "both survivors simulate the continuing frame")
		if not first.has(frame) or not second.has(frame):
			continue
		for player: int in [0, 1]:
			context.equal(first[frame][player].bytes, _sample(player, frame).hex_encode(), "continuing inputs match the deterministic script")
			context.equal(second[frame][player].bytes, first[frame][player].bytes, "survivors simulate identical continuing inputs")
		context.equal(first[frame][2].bytes, _sample(2, mini(frame, commit.cut)).hex_encode(), "the departed slot preserves actual inputs through the raised cut")
		context.equal(second[frame][2].bytes, first[frame][2].bytes, "survivors retain the same frozen input")
		context.equal(first[frame][2].status, "disconnected" if frame > commit.cut else "confirmed", "disconnect starts strictly after the raised cut")
		context.equal(second[frame][2].status, "disconnected" if frame > commit.cut else "confirmed", "the follower preserves actual history through the cut")
	# Compare canonical state bytes after a shared confirmed frame, choosing the
	# latest simulation of that frame so any rollback correction is included.
	var states: Array[String] = []
	for survivor: int in [0, 1]:
		var canonical: String = ""
		for request: Dictionary in mesh.games[survivor].requests:
			if request.kind == "advance" and request.frame == shared - 1:
				canonical = request.state_bytes
		context.equal(canonical.is_empty(), false, "the confirmed canonical state was actually recorded")
		states.append(canonical)
	context.equal(states[0], states[1], "survivors agree canonical state bytes after ACK recovery")


func _hold_packets(mesh: Dictionary, phase: int, stage: int, recipient: int) -> void:
	mesh.hold_phase = phase
	mesh.hold_stage = stage
	mesh.hold_to = recipient
	mesh.held = []


func _wait_for_held(context: RefCounted, mesh: Dictionary) -> void:
	for tick: int in range(500):
		_service_commit(context, mesh)
		if not mesh.held.is_empty():
			return
	context.equal(false, true, "the real session emits the packet selected for holding")


func _release_original(context: RefCounted, mesh: Dictionary, packet: Dictionary, terminated: bool = false) -> void:
	var original: Array[Dictionary] = [packet]
	super._deliver(context, mesh, original, terminated)


func _held_fixture(context: RefCounted, phase: int, stage: int, recipient: int, count: int = 3) -> Dictionary:
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE, 8, count)
	_play(context, mesh, 6, true)
	_leave(context, mesh, 2)
	mesh.merge({"monitor_commit": true, "lose_first": false, "lost_acks": 0, "commits": [], "acks": [], "delivered_acks": 0})
	_hold_packets(mesh, phase, stage, recipient)
	_wait_for_held(context, mesh)
	return mesh


func _receive_copy(context: RefCounted, mesh: Dictionary, packet: Dictionary, fields: Dictionary, sender: int = -1, allow_terminal: bool = false) -> void:
	var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
	context.equal(decoded.code, T.Code.OK, "decode the held original")
	for field: String in fields:
		decoded.message.set(field, fields[field])
	if sender >= 0:
		decoded.message.sender_id = _id(sender)
		decoded.message.connection_id = _id(sender + 20)
	var encoded: T.Result = Codec.encode(decoded.message, _limits(mesh.count))
	context.equal(encoded.code, T.Code.OK, "mutation remains a valid encoded packet")
	context.equal(mesh.peers[packet.to].receive(encoded.bytes, _id(sender if sender >= 0 else int(packet.from)), mesh.now), I.Code.OK, "receive the mutated packet")
	for round_trip: int in range(6):
		_deliver(context, mesh, _drain(mesh), allow_terminal)


func _committed_mutations(message: T.Message) -> Array[Dictionary]:
	var mutations: Array[Dictionary] = []
	for field: String in ["cut", "cut_digest", "operation", "coordinator", "coordinator_generation", "target_set_digest"]:
		mutations.append({field: int(message.get(field)) + 1})
	var targets: PackedByteArray = message.data.duplicate()
	targets[1] += 1
	mutations.append({"data": targets})
	return mutations


# Value: protects=committed handshake rejects foreign identity/value; fails_when=bad ACK completes or duplicate COMMIT re-ACKs; why_new=post-drop validation; seam=none
func _malformed_committed(context: RefCounted, is_ack: bool) -> void:
	var mesh: Dictionary = _held_fixture(context, Drop.Phase.REPORT, Drop.Stage.COMMITTED, 0)
	if mesh.held.is_empty() or mesh.commits.is_empty():
		return
	var ack: Dictionary = mesh.held[0]
	var commit: Dictionary = mesh.commits[0]
	var packet: Dictionary = ack if is_ack else commit
	var proposer: Drop.Barrier = _barrier(mesh)
	for fields: Dictionary in _committed_mutations(packet.message):
		_receive_copy(context, mesh, packet, fields)
		context.equal(proposer.acknowledged.has(_id(1).hex_encode()), false, "invalid %s cannot complete ACK: %s" % ["ACK" if is_ack else "COMMIT", fields.keys()])
		context.equal(mesh.held.size(), 1, "invalid committed packet generates no re-ACK: %s" % fields.keys())
	if is_ack:
		for tick: int in range(Drop.RETRY_US / 1000 + 10):
			_service_commit(context, mesh)
			if mesh.commits.size() >= 2:
				break
		context.equal(mesh.commits.size(), 2, "invalid ACKs leave the actual COMMIT retry armed")
	else:
		_receive_copy(context, mesh, commit, {})
	context.equal(mesh.held.size(), 2, "the valid duplicate COMMIT produces exactly one re-ACK")
	_release_original(context, mesh, ack)
	context.equal(proposer.acknowledged.has(_id(1).hex_encode()), true, "the valid original ACK completes after malformed copies")
	var sent: int = mesh.commits.size()
	for tick: int in range(2 * Drop.RETRY_US / 1000 + 10):
		_service_commit(context, mesh)
	context.equal(mesh.commits.size(), sent, "only the valid ACK stops real COMMIT retries")
	_healthy_after_commit(context, mesh, commit.message)
	for survivor: int in [0, 1]:
		context.equal(mesh.drop_events.get(survivor, []), [commit.message.cut], "malformed copies never duplicate the drop notification")
	context.equal(mesh.unconfirmed, 0, "malformed copies do not trigger fallback")


# Value: protects=no ACK before irreversible commit; fails_when=COMMITTED report pre-acks pending barrier; why_new=stage ordering; seam=none
func _early_committed_ack(context: RefCounted) -> void:
	var mesh: Dictionary = _held_fixture(context, Drop.Phase.REPORT, Drop.Stage.READY, 0)
	if mesh.held.is_empty():
		return
	var ready: Dictionary = mesh.held[0]
	var proposer: Drop.Barrier = _barrier(mesh)
	context.equal(proposer.state, Drop.PENDING, "the real READY is held before the proposer commits")
	context.equal(mesh.commits.size(), 0, "no COMMIT has been emitted before the early ACK")
	_receive_copy(context, mesh, ready, {"stage": Drop.Stage.COMMITTED})
	context.equal(proposer.acknowledged.has(_id(1).hex_encode()), false, "an exact-value early ACK cannot pre-ack the pending operation")
	_hold_packets(mesh, Drop.Phase.REPORT, Drop.Stage.COMMITTED, 0)
	_release_original(context, mesh, ready)
	_wait_for_held(context, mesh)
	if mesh.held.is_empty():
		return
	var ack: Dictionary = mesh.held[0]
	context.equal(proposer.acknowledged.has(_id(1).hex_encode()), false, "commit still requires its actual ACK after the early copy")
	for tick: int in range(Drop.RETRY_US / 1000 + 10):
		_service_commit(context, mesh)
		if mesh.commits.size() >= 2:
			break
	context.equal(mesh.commits.size(), 2, "early ACK does not suppress an actual COMMIT retry")
	_release_original(context, mesh, ack)
	context.equal(proposer.acknowledged.has(_id(1).hex_encode()), true, "the valid post-commit original ACK completes")


# Value: protects=only coordinator commits a certified follower; fails_when=survivor spoofs coordinator body; why_new=four-peer sender role; seam=none
func _wrong_sender_commit(context: RefCounted) -> void:
	var mesh: Dictionary = _held_fixture(context, Drop.Phase.COMMIT, Drop.Stage.NONE, 3, 4)
	if mesh.held.is_empty():
		return
	var commit: Dictionary = mesh.held[0]
	var follower: Drop.Barrier = mesh.peers[3]._drops.barrier(_id(2).hex_encode())
	context.equal(follower.certified, true, "follower three has certified the actual coordinator value")
	context.equal(follower.state, Drop.PENDING, "the coordinator COMMIT to follower three is held")
	var before: int = mesh.acks.size()
	_receive_copy(context, mesh, commit, {}, 1)
	context.equal(follower.state, Drop.PENDING, "survivor one cannot commit follower three using coordinator body bytes")
	context.equal(mesh.drop_events.get(3, []), [], "wrong-sender COMMIT publishes no drop")
	context.equal(mesh.acks.size(), before, "wrong-sender COMMIT emits no COMMITTED ACK")
	_release_original(context, mesh, commit)
	for round_trip: int in range(6):
		_deliver(context, mesh, _drain(mesh))
	context.equal(mesh.acks.size(), before + 2, "the valid coordinator original emits one COMMITTED report per other survivor")
	var recipients: Array[int] = []
	for packet: Dictionary in mesh.acks.slice(before):
		context.equal(packet.from, 3, "each valid ACK originates at follower three")
		recipients.append(packet.to)
		_same_commit(context, packet.message, commit.message)
	recipients.sort()
	context.equal(recipients, [0, 1], "the valid ACK reports address both other survivors exactly once")
	context.equal(_barrier(mesh).acknowledged.has(_id(3).hex_encode()), true, "the coordinator records follower three's valid ACK")
	_receive_copy(context, mesh, commit, {}, 1)
	context.equal(mesh.acks.size(), before + 2, "wrong-sender duplicate COMMIT also emits no re-ACK")
	context.equal(mesh.drop_events.get(3, []), [commit.message.cut], "follower three publishes exactly the valid coordinator drop")
	for survivor: int in [0, 1, 3]:
		context.equal(mesh.peers[survivor].status().lifecycle, Types.Lifecycle.RUNNING, "each survivor remains healthy after sender rejection")
	context.equal(mesh.unconfirmed, 0, "wrong-sender rejection does not trigger fallback")


# Value: protects=one survivor cannot replace its certificate while another is pending; fails_when=changed duplicate READY is ignored;
# why_new=existing conflicting certificates compare different survivors only; seam=none
func _duplicate_ready(context: RefCounted, name: String) -> void:
	var mesh: Dictionary = _held_fixture(context, Drop.Phase.REPORT, Drop.Stage.READY, 0, 4)
	if mesh.held.is_empty():
		return
	var ready: Dictionary = mesh.held[0]
	var proposer: Drop.Barrier = _barrier(mesh)
	var untouched: Dictionary = {}
	for slot: int in range(4):
		untouched[slot] = mesh.peers[0]._core.retained_input(slot, 5)
	_release_original(context, mesh, ready)
	context.equal(proposer.certificates.size(), 1, "one original certificate is accepted before another survivor answers")
	context.equal(proposer.state, Drop.PENDING, "the other survivor still prevents irreversible commit")
	var fields: Dictionary = {}
	if name == "contradictory_ready_cut":
		fields.cut = int(ready.message.cut) + 1
	elif name == "contradictory_ready_digest":
		fields.cut_digest = int(ready.message.cut_digest) ^ 1
	var conflicting: bool = not fields.is_empty()
	_receive_copy(context, mesh, ready, fields, -1, conflicting)
	context.equal(proposer.state, Drop.FAILED if conflicting else Drop.PENDING, "only a contradictory repeated certificate aborts the original agreement")
	context.equal(
		mesh.peers[0].status().lifecycle,
		Types.Lifecycle.TERMINATED if conflicting else Types.Lifecycle.RUNNING,
		"an identical retry is idempotent; a contradictory retry fails closed"
	)
	context.equal(proposer.certificates.size(), 1, "a duplicate never contributes another participant certificate")
	context.equal(mesh.peers[0]._core.frozen_frame(2), -1, "neither repeated certificate alone can freeze the target")
	if conflicting:
		context.equal(mesh.reasons.has("conflicting_history"), true, "a changed certificate publishes its specific failure reason")
		for slot: int in range(4):
			context.equal(mesh.peers[0]._core.retained_input(slot, 5), untouched[slot], "certificate contradiction preserves every retained original prefix")
		context.equal(mesh.drop_events.get(0, []), [], "a contradictory retry produces no misleading local drop event")
		return
	# Hold until both other survivors have published their original READY.
	for turn: int in range(20):
		_service_commit(context, mesh)
		var senders: Dictionary = {}
		for packet: Dictionary in mesh.held:
			senders[packet.from] = true
		if senders.size() == 2:
			break
	var certificates: Array = mesh.held.duplicate()
	mesh.hold_phase = -1
	for packet: Dictionary in certificates:
		_release_original(context, mesh, packet)
	for turn: int in range(6):
		_deliver(context, mesh, _drain(mesh))
	context.equal(proposer.state, Drop.COMMITTED, "the remaining original certificate completes the unchanged operation")
	for survivor: int in [0, 1, 3]:
		context.equal(mesh.drop_events.get(survivor, []), [ready.message.cut], "identical retries preserve one freeze notification per survivor")
	_play(context, mesh, 6, true, [0, 1, 3], 2)
	var through: int = 2147483647
	for survivor: int in [0, 1, 3]:
		through = mini(through, mesh.peers[survivor].status().confirmed_frame - 1)
	context.equal(through > int(ready.message.cut), true, "the idempotent retry control confirms gameplay beyond the original cut")
	var reference: RefCounted = preload("res://tests/oracle/reference_game.gd").new(4, 2)
	var expected: Dictionary = {}
	for frame: int in range(through + 1):
		var row: Array[Dictionary] = []
		for slot: int in range(4):
			var frozen: bool = slot == 2 and frame > int(ready.message.cut)
			row.append({"player": slot, "bytes": _sample(slot, int(ready.message.cut) if frozen else frame).hex_encode(), "status": "disconnected" if frozen else "confirmed"})
		context.equal(reference.advance(row), "", "the original canonical input history advances independently")
		expected[frame] = reference.bytes().hex_encode()
	for survivor: int in [0, 1, 3]:
		var actual: Dictionary = {}
		for request: Dictionary in mesh.games[survivor].requests:
			if request.kind == "advance":
				actual[request.frame] = request.state_bytes
		for frame: int in range(through + 1):
			context.equal(actual.get(frame, ""), expected[frame], "identical certificate retries preserve independent canonical history")
