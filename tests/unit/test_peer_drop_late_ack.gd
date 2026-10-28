extends "res://tests/unit/test_peer_drop_commit.gd"

# Value: protects=irreversible commits retry until acknowledged across negotiation expiry; fails_when=deadline disables committed retransmission;
# why_new=prior ACK tests stop before the original negotiation timeout; seam=none


func cases() -> PackedStringArray:
	return PackedStringArray(["late_ack_recovery", "late_ack_control", "late_ack_participant_loss", "late_ack_terminal", "late_ack_partial"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "late_ack_partial":
		_partial_ack(context)
		context.finish()
		return
	if name in ["late_ack_participant_loss", "late_ack_terminal"]:
		_stopped_retry(context, name == "late_ack_terminal")
		context.finish()
		return
	for offset: int in [-1, 0, 1]:
		_late_ack(context, name == "late_ack_recovery", offset)
	context.finish()


func _late_ack(context: RefCounted, lost: bool, offset: int) -> void:
	var mesh: Dictionary = _held_fixture(context, Drop.Phase.REPORT, Drop.Stage.COMMITTED, 0)
	if mesh.held.is_empty() or mesh.commits.is_empty():
		return
	var proposer: Drop.Barrier = _barrier(mesh)
	var follower: Drop.Barrier = mesh.peers[1]._drops.barrier(_id(2).hex_encode())
	var original: T.Message = mesh.commits[0].message
	context.equal(proposer.state, Drop.COMMITTED, "coordinator has irreversibly committed")
	context.equal(follower.state, Drop.COMMITTED, "follower committed before the original deadline")
	context.equal(proposer.acknowledged.is_empty(), true, "the real first acknowledgement remains undelivered")
	if not lost:
		_release_original(context, mesh, mesh.held[0])
		context.equal(proposer.acknowledged.has(_id(1).hex_encode()), true, "control delivers the original acknowledgement")
	mesh.hold_phase = -1
	var before: int = mesh.commits.size()
	var deadline: int = proposer.started_us + 250000
	for now_us: int in [deadline + offset, deadline + Drop.RETRY_US + offset, deadline + 2 * Drop.RETRY_US + offset]:
		mesh.now = now_us
		for survivor: int in [0, 1]:
			_keep_alive(context, mesh, 1 - survivor, survivor)
		_service_commit(context, mesh, now_us)
		if lost:
			context.equal(mesh.commits.size(), before + 1, "lost ACK recovers once and stops retries across the original deadline")
		else:
			context.equal(mesh.commits.size(), before, "delivered ACK keeps the control quiet across the original deadline")
		context.equal(proposer.acknowledged.has(_id(1).hex_encode()), true, "the committed operation retains its delivered ACK after negotiation expiry")
	for packet: Dictionary in mesh.commits:
		_same_commit(context, packet.message, original)
	for survivor: int in [0, 1]:
		context.equal(mesh.peers[survivor].status().lifecycle, Types.Lifecycle.RUNNING, "committed survivors remain live through ACK recovery")
		context.equal(mesh.drop_events.get(survivor, []), [original.cut], "retries preserve exactly one original freeze notification")
	context.equal(mesh.unconfirmed, 0, "negotiation expiry cannot revoke an irreversible commit")
	_healthy_after_commit(context, mesh, original)


func _keep_alive(context: RefCounted, mesh: Dictionary, sender: int, recipient: int) -> void:
	var live: T.Message = T.Message.new()
	live.kind = T.Kind.KEEP_ALIVE
	live.session_id = _id(90, 16)
	live.sender_id = _id(sender)
	live.connection_id = _id(sender + 20)
	var encoded: T.Result = Codec.encode(live, _limits(mesh.count))
	context.equal(encoded.code, T.Code.OK, "encode a live survivor's original identity")
	context.equal(mesh.peers[recipient].receive(encoded.bytes, _id(sender), mesh.now), I.Code.OK, "keep the actual survivor link live across negotiation expiry")


# Value: protects=committed retries stop for lost participants and terminal sessions; fails_when=late recovery bypasses lifecycle gates;
# why_new=deadline-crossing ACK recovery keeps both survivors live; seam=none
func _stopped_retry(context: RefCounted, local_terminal: bool) -> void:
	var mesh: Dictionary = _held_fixture(context, Drop.Phase.REPORT, Drop.Stage.COMMITTED, 0)
	if mesh.held.is_empty() or mesh.commits.is_empty():
		return
	var original: T.Message = mesh.commits[0].message
	var proposer: Drop.Barrier = _barrier(mesh)
	var closer: int = 0 if local_terminal else 1
	context.equal(mesh.peers[closer].close(mesh.now), I.Code.OK, "close the selected actual survivor before its missing ACK recovers")
	var goodbye: Array[Dictionary] = _drain(mesh)
	if not local_terminal:
		super._deliver(context, mesh, goodbye)
		_drain(mesh)
	context.equal(proposer.state, Drop.COMMITTED, "closure never revokes the original irreversible decision")
	mesh.now = proposer.started_us + 250000
	for turn: int in range(3):
		context.equal(mesh.peers[0].poll(mesh.now), I.Code.TERMINATED if local_terminal else I.Code.OK, "late polling respects local termination or current survivor membership")
		for packet: Peer.Packet in mesh.peers[0].drain_outbox():
			var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
			context.equal(decoded.code, T.Code.OK, "remaining bounded output retains valid framing")
			if decoded.message.kind == T.Kind.DROP_BARRIER:
				var original_commit: bool = decoded.message.phase == Drop.Phase.COMMIT and decoded.message.data == original.data
				context.equal(original_commit, false, "no COMMIT retry addresses a removed survivor or terminated session")
		mesh.now += Drop.RETRY_US


# Value: protects=each acknowledged survivor stops COMMIT traffic; fails_when=one lost ACK keeps healthy recipients retrying;
# why_new=single-follower recovery cannot observe partial acknowledgement; seam=none
func _partial_ack(context: RefCounted) -> void:
	var mesh: Dictionary = _held_fixture(context, Drop.Phase.REPORT, Drop.Stage.COMMITTED, 0, 4)
	if mesh.held.is_empty() or mesh.commits.is_empty():
		return
	var proposer: Drop.Barrier = _barrier(mesh)
	var original: T.Message = mesh.commits[0].message
	for packet: Dictionary in mesh.held:
		if packet.from == 1:
			_release_original(context, mesh, packet)
	context.equal(proposer.acknowledged.has(_id(1).hex_encode()), true, "first survivor's actual ACK is delivered")
	context.equal(proposer.acknowledged.has(_id(3).hex_encode()), false, "second survivor's actual ACK stays lost")
	for turn: int in range(3):
		mesh.now = proposer.started_us + 250000 + turn * Drop.RETRY_US
		for sender: int in [0, 1, 3]:
			for recipient: int in [0, 1, 3]:
				if sender != recipient:
					_keep_alive(context, mesh, sender, recipient)
		var before: int = mesh.commits.size()
		_service_commit(context, mesh, mesh.now)
		var recipients: Array[int] = []
		for packet: Dictionary in mesh.commits.slice(before):
			recipients.append(packet.to)
			_same_commit(context, packet.message, original)
		context.equal(recipients, [3], "only the unacknowledged survivor receives a late COMMIT retry")
	context.equal(proposer.acknowledged.has(_id(3).hex_encode()), false, "withheld ACK cannot complete by repeated send acceptance")
	for packet: Dictionary in mesh.held:
		if packet.from == 3:
			_release_original(context, mesh, packet)
			break
	context.equal(proposer.acknowledged.has(_id(3).hex_encode()), true, "second survivor's original ACK completes the operation")
	var before: int = mesh.commits.size()
	_service_commit(context, mesh, mesh.now + Drop.RETRY_US)
	context.equal(mesh.commits.size(), before, "all actual ACKs silence the complete operation")
	for survivor: int in [0, 1, 3]:
		context.equal(mesh.drop_events.get(survivor, []), [original.cut], "partial ACK recovery preserves one original freeze per survivor")
	context.equal(mesh.unconfirmed, 0, "partial ACK recovery does not revoke the commit")
