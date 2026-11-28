extends "res://tests/unit/test_peer_drop_backfill.gd"

# Value: protects=only the fixed participant set may certify retained-history recovery; fails_when=losing a donor permits a partial cut;
# why_new=delivery-loss and participant-loss cases do not remove a selected donor with original history in flight; seam=none

const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")

const DONOR: int = 1
const TARGET: int = 3
const CUT: int = 8

var _hold_history: bool = false
var _held_history: Dictionary = {}


func cases() -> PackedStringArray:
	return PackedStringArray(["original_donor_chunk_arrives", "chosen_donor_leaves_before_history"])


func run_case(name: String, context: RefCounted) -> void:
	_width = 4
	_missing_peer = -1
	_hold_history = true
	_held_history.clear()
	var mesh: Dictionary = _recording_mesh(context, 64, Callable(), 18, 4)
	mesh.drop_failures = []
	_play(context, mesh, 6, true)
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
	for recipient: int in [0, 2]:
		var barrier: Drop.Barrier = mesh.peers[recipient]._drops.barrier(_id(TARGET).hex_encode())
		context.equal(barrier != null, true, "the target's departure owns a pending agreement")
		if barrier == null:
			context.finish()
			return
		context.equal(barrier.state, Drop.PENDING, "both recipients wait for the donor")
		context.equal(barrier.history.donor, DONOR, "both participants adopted the original donor plan")
		context.equal([barrier.history.first, barrier.history.cut], [CUT, CUT], "the adopted plan names exactly the missing row")
		var decoded: T.Result = Codec.decode(_held_history[recipient].bytes, _limits(mesh.count))
		var chunk: T.Message = decoded.message
		context.equal([chunk.operation, chunk.coordinator, chunk.coordinator_generation], [barrier.operation, barrier.coordinator, barrier.coordinator_generation],
			"the held chunk names the adopted operation")
		context.equal([chunk.target_set_digest, chunk.participants_digest], [barrier.target_set_digest, barrier.roster_digest],
			"the held chunk names the fixed target and participant sets")
		context.equal(chunk.data, PackedByteArray([TARGET, barrier.generations[0] & 255, barrier.generations[0] >> 8]),
			"the held chunk carries the original target and era")
		context.equal(chunk.available_through, DONOR, "the held chunk names the selected donor")
		context.equal(mesh.peers[recipient]._core.received_frames()[TARGET], CUT - 1, "the recipient lacks the original target row")
	context.equal(mesh.peers[DONOR]._core.retained_input(TARGET, CUT), _sample(TARGET, CUT), "the donor retains the exact missing input")
	_hold_history = false
	if name == "chosen_donor_leaves_before_history":
		_check_refusal(context, mesh)
	else:
		_check_delivery(context, mesh)
	context.finish()


func _send_goodbye(context: RefCounted, mesh: Dictionary, peer: int, terminal: bool = false) -> void:
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


func _service(context: RefCounted, mesh: Dictionary, active: Array[int]) -> void:
	mesh.now += 1000
	for peer: int in active:
		context.equal(mesh.peers[peer].poll(mesh.now), I.Code.OK, "poll the live survivor")
	_deliver(context, mesh, _without_peer(_drain(mesh), TARGET))


func _check_refusal(context: RefCounted, mesh: Dictionary) -> void:
	var before: Dictionary = {}
	for recipient: int in [0, 2]:
		before[recipient] = _snapshot(mesh, recipient)
	_send_goodbye(context, mesh, DONOR, true)
	_drain(mesh)
	var failed_peers: Array[int] = []
	for failure: Dictionary in mesh.drop_failures:
		if failure.target == _id(TARGET).hex_encode() and failure.reason == "participant_lost":
			failed_peers.append(failure.peer)
	context.equal(failed_peers, [0, 2], "both recipients reject the pending target operation on Goodbye")
	for recipient: int in [0, 2]:
		var peer: Peer = mesh.peers[recipient]
		context.equal(peer.status().lifecycle, Types.Lifecycle.TERMINATED, "Goodbye alone ends both recipients' matches")
		context.equal(_snapshot(mesh, recipient), before[recipient], "Goodbye preserves frame, confirmation, state and replay length")
		var chunk: Dictionary = _held_history[recipient]
		context.equal(peer.receive(chunk.bytes, _id(DONOR), mesh.now), I.Code.TERMINATED, "the late original chunk cannot reopen the operation")
		context.equal(peer.step(mesh.now, _inputs(mesh, recipient)).code, Types.Code.TERMINATED, "terminal recovery cannot advance gameplay")
		context.equal(peer._core.frozen_frame(TARGET), -1, "the original target stays unfrozen")
		context.equal(peer._core.frozen_frame(DONOR), -1, "the donor cannot be removed from the pending certificate")
		context.equal(peer._core.retained_input(TARGET, CUT).is_empty(), true, "the late chunk installs no original row")
		context.equal(_snapshot(mesh, recipient), before[recipient], "the late chunk preserves frame, confirmation, state and replay length")
		_check_original_replay(context, peer, mini(before[recipient][0] - 1, before[recipient][1]))
	_drain(mesh)
	context.equal(mesh.cuts.is_empty(), true, "no survivor publishes a partial freeze")


func _snapshot(mesh: Dictionary, peer_index: int) -> Array:
	var peer: Peer = mesh.peers[peer_index]
	var status: Types.Status = peer.status()
	var recording: RefCounted = peer.replay()
	return [status.current_frame, status.confirmed_frame, mesh.games[peer_index].bytes(), recording.frame_count() if recording != null else -1]


func _check_original_replay(context: RefCounted, peer: Peer, through: int) -> void:
	context.equal(through >= 4, true, "the exposed original prefix contains multiple frames")
	var recording: RefCounted = peer.replay()
	context.equal(recording != null, true, "the terminal peer keeps a replay")
	if recording == null:
		return
	for frame: int in range(through + 1):
		var row: Types.FrameInputs = recording.inputs(frame)
		context.equal(row != null, true, "each exposed original input row remains available")
		if row != null:
			for player: int in range(4):
				context.equal(row.read(player).bytes, _sample(player, frame), "the replay preserves the original sample")
				context.equal(row.read(player).status, Queue.Status.CONFIRMED, "the replay preserves the confirmed status")


func _check_delivery(context: RefCounted, mesh: Dictionary) -> void:
	var chunks: Array[Dictionary] = [_held_history[0], _held_history[2]]
	_deliver(context, mesh, chunks)
	for turn: int in range(24):
		_service(context, mesh, [0, DONOR, 2])
	for survivor: int in [0, DONOR, 2]:
		context.equal(mesh.peers[survivor]._core.frozen_frame(TARGET), CUT, "all survivors certify the receipt-raised cut")
		context.equal(mesh.peers[survivor]._core.retained_input(TARGET, CUT), _sample(TARGET, CUT), "all survivors retain the original cut bytes")
	_play(context, mesh, 16, true, [0, DONOR, 2], TARGET)
	var through: int = mesh.peers[DONOR].status().confirmed_frame - 1
	for recipient: int in [0, 2]:
		through = mini(through, mesh.peers[recipient].status().confirmed_frame - 1)
	context.equal(through > CUT, true, "the delivery control continues confirmed play")
	var expected: WideGame = WideGame.new(4)
	for frame: int in range(through + 1):
		for slot: int in range(4):
			for byte: int in _sample(slot, mini(frame, CUT) if slot == TARGET else frame):
				expected.values[slot] += byte
		expected.frame = frame + 1
		if frame >= CUT:
			for survivor: int in [0, DONOR, 2]:
				context.equal(mesh.games[survivor].states.get(frame), expected.bytes(), "each continuation preserves the original canonical prefix")


func _deliver(context: RefCounted, mesh: Dictionary, packets: Array[Dictionary], terminated: bool = false) -> void:
	var accepted: Array[Dictionary] = []
	for packet: Dictionary in packets:
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
		if decoded.code == T.Code.OK:
			var message: T.Message = decoded.message
			if packet.from == TARGET and packet.to != DONOR and message.kind == T.Kind.INPUT and message.start_frame + message.frame_count > CUT:
				continue
			if _hold_history and packet.from == DONOR and packet.to in [0, 2] and message.kind == T.Kind.DROP_BARRIER \
				and message.phase == Drop.Phase.BACKFILL and message.stage == Drop.Stage.HISTORY:
				context.equal([message.bound, message.cut, message.chunk_index, message.chunk_count], [CUT, CUT, 0, 1], "the held chunk spans exactly the missing row")
				context.equal(message.bytes, _sample(TARGET, CUT), "the held chunk carries the original target row")
				if _held_history.has(packet.to):
					context.equal(packet.bytes, _held_history[packet.to].bytes, "a duplicate preserves the first original chunk")
				else:
					_held_history[packet.to] = packet
				continue
		accepted.append(packet)
	super._deliver(context, mesh, accepted, terminated)
