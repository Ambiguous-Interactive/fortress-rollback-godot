extends "res://tests/unit/test_peer_drop_backfill.gd"

# Value: protects=only the fixed participant set may certify retained-history recovery; fails_when=losing a donor permits a partial cut;
# why_new=delivery-loss and participant-loss cases do not remove a selected donor with original history in flight; seam=none

const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")

const DONOR: int = 1
const TARGET: int = 3
const FIRST_MISSING: int = 8
const CAPACITY: int = 18
const WINDOW: int = 8
const NEAREST: int = FIRST_MISSING - 1 + 2 * WINDOW
const REUSED_INDEX: int = NEAREST % CAPACITY

var _cut: int = FIRST_MISSING
var _hold_history: bool = false
var _held_history: Dictionary = {}
var _commit_publications: int = 0
var _ready_publications: Array[int] = []


func cases() -> PackedStringArray:
	return PackedStringArray([
		"original_donor_chunk_arrives", "chosen_donor_leaves_before_history", "wrapped_donor_retains_history", "wrapped_donor_leaves_before_history",
	])


func run_case(name: String, context: RefCounted) -> void:
	_width = 4
	_missing_peer = -1
	_hold_history = true
	_held_history.clear()
	_commit_publications = 0
	_ready_publications.assign([0, 0, 0, 0])
	var wrapped: bool = name.begins_with("wrapped_")
	_cut = FIRST_MISSING
	var mesh: Dictionary = _recording_mesh(context, 64, Callable(), CAPACITY, 4)
	mesh.drop_failures = []
	_play(context, mesh, FIRST_MISSING if wrapped else 6, true)
	var retention: Dictionary = {}
	if wrapped:
		retention = _wrap_boundary(context, mesh)
	else:
		_leave(context, mesh, TARGET)
	_send_goodbye(context, mesh, TARGET)
	for turn: int in range(32):
		_service(context, mesh, [0, DONOR, 2])
		if _held_history.size() == 2:
			break
	var recipients: Array = _held_history.keys()
	recipients.sort()
	context.equal(recipients, [0, 2], "the selected donor published an original chunk to each recipient")
	if recipients != [0, 2]:
		context.finish()
		return
	var opening: Array[Dictionary] = []
	for recipient: int in [0, 2]:
		var barrier: Drop.Barrier = mesh.peers[recipient]._drops.barrier(_id(TARGET).hex_encode())
		context.equal(barrier != null, true, "the target's departure owns a pending agreement")
		if barrier == null:
			context.finish()
			return
		context.equal(barrier.state, Drop.PENDING, "both recipients wait for the donor")
		var certified: bool = barrier.certified or (barrier.role == Drop.Role.PROPOSER and barrier.digest != 0)
		context.equal(certified, false, "the recipient has no local certificate while original history is held")
		context.equal(barrier.history.donor, DONOR, "both participants adopted the original donor plan")
		context.equal([barrier.history.first, barrier.history.cut], [FIRST_MISSING, _cut], "the adopted plan names the missing interval")
		var decoded: T.Result = Codec.decode(_held_history[recipient].bytes, _limits(mesh.count))
		var chunk: T.Message = decoded.message
		context.equal([chunk.operation, chunk.coordinator, chunk.coordinator_generation], [barrier.operation, barrier.coordinator, barrier.coordinator_generation],
			"the held chunk names the adopted operation")
		context.equal([chunk.target_set_digest, chunk.participants_digest], [barrier.target_set_digest, barrier.roster_digest],
			"the held chunk names the fixed target and participant sets")
		context.equal(chunk.data, PackedByteArray([TARGET, barrier.generations[0] & 255, barrier.generations[0] >> 8]),
			"the held chunk carries the original target and era")
		context.equal(chunk.available_through, DONOR, "the held chunk names the selected donor")
		context.equal(mesh.peers[recipient]._core.received_frames()[TARGET], FIRST_MISSING - 1, "the recipient lacks the original target row")
		opening.append({
			"peer": recipient, "donor": barrier.history.donor, "coordinator": barrier.coordinator, "operation": barrier.operation,
			"receipt": mesh.peers[recipient]._core.received_frames()[TARGET], "first": barrier.history.first,
			"cut": barrier.history.cut, "bytes": chunk.bytes.hex_encode(), "certified": certified,
		})
	context.equal(mesh.peers[DONOR]._core.retained_input(TARGET, _cut), _sample(TARGET, _cut), "the donor retains the exact missing input")
	_hold_history = false
	var outcome: Dictionary
	if name.ends_with("leaves_before_history"):
		outcome = _check_refusal(context, mesh)
	else:
		outcome = _check_delivery(context, mesh)
	if wrapped:
		for index: int in range(2):
			var after: Array = outcome.peers[index].replay if outcome.has("peers") \
				else _check_original_replay(context, mesh.peers[index * 2], FIRST_MISSING - 1)
			context.equal(after, retention.exposed[index], "both outcomes preserve the earlier exposed original replay")
	var receipt: Dictionary = {"case": name, "opening": opening, "outcome": outcome}
	if wrapped:
		receipt.retention = retention
	print("FORTRESS_DONOR_DEPARTURE " + JSON.stringify(receipt))
	context.finish()


func _wrap_boundary(context: RefCounted, mesh: Dictionary) -> Dictionary:
	var donor: Peer = mesh.peers[DONOR]
	var queue: Queue = donor._core._queues[TARGET]
	var old_tag: int = queue._frames[REUSED_INDEX]
	context.equal(old_tag, REUSED_INDEX, "the donor starts with a live original target slot")
	# Refresh the last complete receipt while frame seven is still the latest wire row.
	mesh.now += 2000
	for player: int in range(4):
		context.equal(mesh.peers[player].recover(mesh.now).code, Types.Code.OK, "gossip the latest complete receipt before losing target inputs")
	for exchange: int in range(2):
		_deliver(context, mesh, _drain(mesh))
	var steps: Array[int] = []
	for turn: int in range(20):
		mesh.now += 2000
		for player: int in range(4):
			context.equal(mesh.peers[player].recover(mesh.now).code, Types.Code.OK, "service delayed receipts at the prediction boundary")
		for exchange: int in range(2):
			_deliver(context, mesh, _drain(mesh))
		mesh.now += 1000
		steps.clear()
		for player: int in range(4):
			var code: int = mesh.peers[player].step(mesh.now, _inputs(mesh, player)).code
			context.equal(code in [Types.Code.OK, Types.Code.PREDICTION_STALL], true, "the mesh runs to its actual prediction stop")
			steps.append(code)
		for exchange: int in range(2):
			_deliver(context, mesh, _drain(mesh))
	_cut = donor._core.received_frames()[TARGET]
	var original_index: int = FIRST_MISSING % CAPACITY
	var eligible: Array[Dictionary] = []
	for player: int in [0, DONOR, 2]:
		var peer: Peer = mesh.peers[player]
		var target_queue: Queue = peer._core._queues[TARGET]
		var actual: PackedByteArray = peer._core.retained_input(TARGET, FIRST_MISSING)
		eligible.append({
			"peer": player, "current": peer.status().current_frame, "confirmed": peer.status().confirmed_frame,
			"receipt": peer._core.received_frames()[TARGET], "floor": peer._core.rollback_floor(),
			"capacity": target_queue._frames.size(), "tag": target_queue._frames[original_index], "original": actual.hex_encode(),
		})
		context.equal(target_queue._frames.size(), CAPACITY, "every eligible survivor uses the negotiated minimum capacity")
		context.equal(peer.status().confirmed_frame, FIRST_MISSING - 1, "each eligible survivor reaches the contiguous receipt bound")
		context.equal(peer._core.rollback_floor(), FIRST_MISSING - 1, "the prediction limit makes the rollback floor reach the receipt bound")
		context.equal(steps[player], Types.Code.PREDICTION_STALL, "each eligible survivor reaches its actual prediction stop")
		context.equal(actual, _sample(TARGET, FIRST_MISSING) if player == DONOR else PackedByteArray(), "only the eligible donor holds the original row")
	var target: Peer = mesh.peers[TARGET]
	context.equal(steps[TARGET], Types.Code.PREDICTION_STALL, "the target reaches its real prediction stop")
	context.equal([target.status().current_frame, _cut], [NEAREST, NEAREST], "the staged target row reaches the two-window send bound")
	context.equal(queue._frames[REUSED_INDEX], NEAREST, "the newest target input physically replaces the older row at the same index")
	context.equal(queue._frames[original_index], FIRST_MISSING, "the original missing row still holds its own slot")
	var exposed: Array = []
	var gossip: Array[int] = []
	for recipient: int in [0, 2]:
		var peer: Peer = mesh.peers[recipient]
		var heard: int = donor._peers[_id(recipient).hex_encode()]._peer_received_frame(TARGET)
		context.equal(heard, FIRST_MISSING - 1, "the donor received the live recipient's contiguous target receipt")
		context.equal(peer.confirmed_inputs(FIRST_MISSING - 1) != null, true, "the live recipient already exposes its last original confirmed row")
		context.equal(peer.confirmed_inputs(FIRST_MISSING) == null, true, "the live recipient cannot expose the missing row")
		gossip.append(heard)
		exposed.append(_check_original_replay(context, peer, FIRST_MISSING - 1))
	return {
		"eligible": eligible, "old_tag": old_tag, "replacement_tag": queue._frames[REUSED_INDEX],
		"target_current": target.status().current_frame, "target_confirmed": target.status().confirmed_frame,
		"target_step": Types.Code.find_key(steps[TARGET]), "gossip": gossip, "exposed": exposed,
	}


func _send_goodbye(context: RefCounted, mesh: Dictionary, peer: int, terminal: bool = false) -> Array:
	mesh.now += 1000
	context.equal(mesh.peers[peer].close(mesh.now), I.Code.OK, "the departing endpoint publishes Goodbye")
	var goodbyes: Array[Dictionary] = []
	var destinations: Dictionary = {}
	for packet: Dictionary in _drain(mesh):
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
		if packet.from == peer and decoded.code == T.Code.OK and decoded.message.kind == T.Kind.GOODBYE:
			goodbyes.append(packet)
			destinations[packet.to] = true
	var recipients: Array = destinations.keys()
	recipients.sort()
	context.equal(recipients, [0, 1, 2] if peer == TARGET else [0, 2], "the explicit departure is addressed to each live endpoint")
	_deliver(context, mesh, goodbyes, terminal)
	return recipients


func _service(context: RefCounted, mesh: Dictionary, active: Array[int]) -> void:
	mesh.now += 1000
	for peer: int in active:
		context.equal(mesh.peers[peer].poll(mesh.now), I.Code.OK, "poll the live survivor")
	_deliver(context, mesh, _without_peer(_drain(mesh), TARGET))


func _check_refusal(context: RefCounted, mesh: Dictionary) -> Dictionary:
	var before: Dictionary = {}
	for recipient: int in [0, 2]:
		before[recipient] = _snapshot(mesh, recipient)
	var goodbye: Array = _send_goodbye(context, mesh, DONOR, true)
	var goodbye_at: int = mesh.now
	_drain(mesh)
	var failed_peers: Array[int] = []
	for failure: Dictionary in mesh.drop_failures:
		if failure.target == _id(TARGET).hex_encode() and failure.reason == "participant_lost":
			failed_peers.append(failure.peer)
	context.equal(failed_peers, [0, 2], "both recipients reject the pending target operation on Goodbye")
	mesh.now += 1000
	var peers: Array[Dictionary] = []
	for recipient: int in [0, 2]:
		var peer: Peer = mesh.peers[recipient]
		var lifecycle: int = peer.status().lifecycle
		context.equal(lifecycle, Types.Lifecycle.TERMINATED, "Goodbye alone ends both recipients' matches")
		var terminal: Array = _snapshot(mesh, recipient)
		context.equal(terminal, before[recipient], "Goodbye preserves frame, confirmation, state and replay length")
		var chunk: Dictionary = _held_history[recipient]
		var receive_code: int = peer.receive(chunk.bytes, _id(DONOR), mesh.now)
		var step_code: int = peer.step(mesh.now, _inputs(mesh, recipient)).code
		context.equal(receive_code, I.Code.TERMINATED, "the late original chunk cannot reopen the operation")
		context.equal(step_code, Types.Code.TERMINATED, "terminal recovery cannot advance gameplay")
		context.equal(peer._core.frozen_frame(TARGET), -1, "the original target stays unfrozen")
		context.equal(peer._core.frozen_frame(DONOR), -1, "the donor cannot be removed from the pending certificate")
		context.equal(peer._core.retained_input(TARGET, FIRST_MISSING).is_empty(), true, "the late chunk installs no original row")
		var after: Array = _snapshot(mesh, recipient)
		context.equal(after, before[recipient], "the late chunk preserves frame, confirmation, state and replay length")
		var replay: Array = _check_original_replay(context, peer, mini(before[recipient][0] - 1, before[recipient][1]))
		peers.append({
			"peer": recipient, "before": before[recipient], "terminal": terminal, "after": after, "replay": replay,
			"lifecycle": Types.Lifecycle.find_key(lifecycle), "receive": I.Code.find_key(receive_code), "step": Types.Code.find_key(step_code),
			"frozen": [peer._core.frozen_frame(TARGET), peer._core.frozen_frame(DONOR)],
		})
	_drain(mesh)
	context.equal([_ready_publications[0], _ready_publications[2]], [0, 0], "neither missing recipient publishes READY")
	context.equal(_commit_publications, 0, "no survivor publishes COMMIT without the complete agreement")
	context.equal(mesh.cuts.is_empty(), true, "no survivor publishes a partial freeze")
	context.equal(mesh.peers[DONOR]._core.retained_input(TARGET, FIRST_MISSING), _sample(TARGET, FIRST_MISSING),
		"the departed donor still owns the row but can no longer contribute to the certificate")
	return {
		"goodbye": goodbye, "goodbye_at": goodbye_at, "late_at": mesh.now, "failures": mesh.drop_failures,
		"peers": peers, "cuts": mesh.cuts, "commit_publications": _commit_publications, "ready_publications": _ready_publications,
	}


func _snapshot(mesh: Dictionary, peer_index: int) -> Array:
	var peer: Peer = mesh.peers[peer_index]
	var status: Types.Status = peer.status()
	var recording: RefCounted = peer.replay()
	return [status.current_frame, status.confirmed_frame, mesh.games[peer_index].bytes().hex_encode(), recording.frame_count() if recording != null else -1]


func _check_original_replay(context: RefCounted, peer: Peer, through: int) -> Array:
	var rows: Array = []
	context.equal(through >= 4, true, "the exposed original prefix contains multiple frames")
	var recording: RefCounted = peer.replay()
	context.equal(recording != null, true, "the terminal peer keeps a replay")
	if recording == null:
		return rows
	for frame: int in range(through + 1):
		var row: Types.FrameInputs = recording.inputs(frame)
		context.equal(row != null, true, "each exposed original input row remains available")
		if row != null:
			var samples: Array = []
			for player: int in range(4):
				context.equal(row.read(player).bytes, _sample(player, frame), "the replay preserves the original sample")
				context.equal(row.read(player).status, Queue.Status.CONFIRMED, "the replay preserves the confirmed status")
				samples.append({"bytes": row.read(player).bytes.hex_encode(), "status": Queue.Status.find_key(row.read(player).status).to_lower()})
			rows.append({"frame": frame, "inputs": samples})
	return rows


func _check_delivery(context: RefCounted, mesh: Dictionary) -> Dictionary:
	var chunks: Array[Dictionary] = [_held_history[0], _held_history[2]]
	_deliver(context, mesh, chunks)
	for turn: int in range(24):
		_service(context, mesh, [0, DONOR, 2])
	var installed: Array[Dictionary] = []
	for survivor: int in [0, DONOR, 2]:
		context.equal(mesh.peers[survivor]._core.frozen_frame(TARGET), _cut, "all survivors certify the receipt-raised cut")
		for frame: int in range(FIRST_MISSING, _cut + 1):
			context.equal(mesh.peers[survivor]._core.retained_input(TARGET, frame), _sample(TARGET, frame), "all survivors install every original donor row")
		installed.append({
			"peer": survivor, "cut": mesh.peers[survivor]._core.frozen_frame(TARGET),
			"bytes": mesh.peers[survivor]._core.retained_input(TARGET, _cut).hex_encode(),
		})
	_play(context, mesh, 16, true, [0, DONOR, 2], TARGET)
	var through: int = mesh.peers[DONOR].status().confirmed_frame - 1
	for recipient: int in [0, 2]:
		through = mini(through, mesh.peers[recipient].status().confirmed_frame - 1)
	context.equal(through > _cut, true, "the delivery control continues confirmed play")
	var expected: WideGame = WideGame.new(4)
	var canonical: Array = []
	for frame: int in range(through + 1):
		for slot: int in range(4):
			for byte: int in _sample(slot, mini(frame, _cut) if slot == TARGET else frame):
				expected.values[slot] += byte
		expected.frame = frame + 1
		var states: Array = []
		for survivor: int in [0, DONOR, 2]:
			var state: PackedByteArray = mesh.games[survivor].states.get(frame, PackedByteArray())
			context.equal(state, expected.bytes(), "each continuation preserves the original canonical prefix")
			states.append(state.hex_encode())
		canonical.append({"frame": frame, "states": states})
	return {"installed": installed, "cuts": mesh.cuts, "canonical": canonical}


func _drain(mesh: Dictionary) -> Array[Dictionary]:
	var packets: Array[Dictionary] = super._drain(mesh)
	for packet: Dictionary in packets:
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
		if decoded.code != T.Code.OK or decoded.message.kind != T.Kind.DROP_BARRIER:
			continue
		if decoded.message.phase == Drop.Phase.COMMIT:
			_commit_publications += 1
		elif decoded.message.phase == Drop.Phase.REPORT and decoded.message.stage == Drop.Stage.READY:
			_ready_publications[packet.from] += 1
	return packets


func _deliver(context: RefCounted, mesh: Dictionary, packets: Array[Dictionary], terminated: bool = false) -> void:
	var accepted: Array[Dictionary] = []
	for packet: Dictionary in packets:
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
		if decoded.code == T.Code.OK:
			var message: T.Message = decoded.message
			if packet.from == TARGET and packet.to != DONOR and message.kind == T.Kind.INPUT and message.start_frame + message.frame_count > FIRST_MISSING:
				continue
			if _hold_history and packet.from == DONOR and packet.to in [0, 2] and message.kind == T.Kind.DROP_BARRIER \
				and message.phase == Drop.Phase.BACKFILL and message.stage == Drop.Stage.HISTORY:
				context.equal([message.bound, message.cut, message.chunk_index, message.chunk_count], [FIRST_MISSING, _cut, 0, 1], "the held chunk spans the missing interval")
				var original: PackedByteArray = PackedByteArray()
				for frame: int in range(FIRST_MISSING, _cut + 1):
					original.append_array(_sample(TARGET, frame))
				context.equal(message.bytes, original, "the held chunk carries the original target rows")
				if _held_history.has(packet.to):
					context.equal(packet.bytes, _held_history[packet.to].bytes, "a duplicate preserves the first original chunk")
				else:
					_held_history[packet.to] = packet
				continue
		accepted.append(packet)
	super._deliver(context, mesh, accepted, terminated)
