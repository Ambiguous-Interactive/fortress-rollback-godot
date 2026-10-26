extends "res://tests/unit/test_peer_drop_capacity.gd"

# Value: protects=history plan retries preserve each survivor's acceptance; fails_when=one pressured link floods healthy links;
# why_new=generic PREPARE retry controls do not exercise donor plans; seam=none
var _held_inventories: Dictionary = {}
var _split_delivery: bool = false


func cases() -> PackedStringArray:
	return PackedStringArray(["partial_history_plan_retry", "staggered_history_plan_retry", "complete_history_plan_control"])


func run_case(name: String, context: RefCounted) -> void:
	var pressured: bool = name != "complete_history_plan_control"
	var staggered: bool = name == "staggered_history_plan_retry"
	_mode = "history_pressure"
	_missing_peer = -1
	_width = 4
	_pressure_actor = 0
	_pressure_input.clear()
	_held_inventories.clear()
	_split_delivery = true
	var mesh: Dictionary = _wide_mesh(context, 4)
	_play(context, mesh, 6, true)
	_leave(context, mesh, 3)
	context.equal(mesh.peers[1]._core.received_frames()[3], 7, "one real survivor lacks the target's final changing input")
	context.equal(mesh.peers[0]._core.received_frames()[3], 8, "the coordinator retains the original missing row")
	for tick: int in range(60):
		mesh.now += 50000
		for survivor: int in [0, 1, 2]:
			for other: int in [0, 1, 2]:
				if survivor != other:
					_keep_alive(context, mesh, other, survivor)
			context.equal(mesh.peers[survivor].poll(mesh.now), I.Code.OK, "detect departure while every actual survivor stays live")
		_deliver(context, mesh, _without_peer(_drain(mesh), 3))
		if _held_inventories.size() == 2:
			break
	context.equal(_held_inventories.size(), 2, "hold the original inventory from both remote survivors")
	for sender: int in [1, 2]:
		if _held_inventories.has(sender):
			context.equal(mesh.peers[0].receive(_held_inventories[sender].bytes, _id(sender), mesh.now), I.Code.OK, "deliver each original truthful inventory")
	_drain(mesh)
	var barrier: Drop.Barrier = mesh.peers[0]._drops.barrier(_id(3).hex_encode())
	context.equal(barrier.history.first, 8, "actual missing history selects one bounded donor plan")
	context.equal(barrier.history.donor, 0, "the coordinator is the actual complete-history donor")
	if pressured:
		context.equal(mesh.peers[0].receive(_pressure_input.bytes, _id(1), mesh.now), I.Code.OK, "a real duplicate input reserves the pressured link for its ACK")
	else:
		context.equal(mesh.peers[0].poll(mesh.now), I.Code.OK, "the complete control publishes both plans without ACK pressure")
	context.equal(_plans(context, mesh.peers[0].drain_outbox()), PackedInt32Array([2] if pressured else [1, 2]), "healthy survivors accept the initial history plan")
	var accepted_at: int = mesh.now
	if pressured:
		context.equal(mesh.peers[0].receive(_pressure_input.bytes, _id(1), mesh.now), I.Code.OK, "sustained real ACK pressure refuses the original link again")
		context.equal(_plans(context, mesh.peers[0].drain_outbox()), PackedInt32Array(), "sustained refusal does not flood the already accepted survivor")
		if staggered:
			mesh.now += Drop.RETRY_US / 2
		context.equal(mesh.peers[0].poll(mesh.now), I.Code.OK, "retry the refused history plan after output drains")
		context.equal(_plans(context, mesh.peers[0].drain_outbox()), PackedInt32Array([1]), "only the refused survivor receives the immediate plan retry")
	context.equal(mesh.peers[0].poll(mesh.now), I.Code.OK, "service the retained journal after the original plan reaches every survivor")
	var chunks: PackedInt32Array = PackedInt32Array()
	for packet: Peer.Packet in mesh.peers[0].drain_outbox():
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(4))
		if decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER and decoded.message.stage == Drop.Stage.HISTORY \
			and decoded.message.phase == Drop.Phase.BACKFILL:
			chunks.append(packet.to[0] - 1)
	context.equal(chunks, PackedInt32Array([1, 2]), "healthy outboxes are available for exact retained donor chunks")
	context.equal(mesh.peers[0].poll(accepted_at + Drop.RETRY_US - 1), I.Code.OK, "service one tick before the accepted plan's retry deadline")
	context.equal(mesh.peers[0].drain_outbox().is_empty(), true, "accepted plans stay quiet before the deadline")
	mesh.now = accepted_at + Drop.RETRY_US
	context.equal(mesh.peers[0].poll(mesh.now), I.Code.OK, "service the exact retry deadline after the unacknowledged donor round")
	context.equal(_plans(context, mesh.peers[0].drain_outbox()), PackedInt32Array([2] if staggered else [1, 2]), "each accepted plan retries at its own deadline")
	_split_delivery = false
	for tick: int in range(20):
		mesh.now += Drop.RETRY_US
		for survivor: int in [0, 1, 2]:
			for other: int in [0, 1, 2]:
				if survivor != other:
					_keep_alive(context, mesh, other, survivor)
			context.equal(mesh.peers[survivor].poll(mesh.now), I.Code.OK, "retry omitted plans and chunks through actual survivor links")
		_deliver(context, mesh, _without_peer(_drain(mesh), 3))
	for survivor: int in [0, 1, 2]:
		context.equal(mesh.peers[survivor]._core.frozen_frame(3), 8, "every survivor commits the original receipt-raised cut after pressure")
	_play(context, mesh, 6, true, [0, 1, 2], 3)
	var through: int = 2147483647
	for survivor: int in [0, 1, 2]:
		through = mini(through, mesh.peers[survivor].status().confirmed_frame - 1)
	context.equal(through > 8, true, "the recovered match confirms frames beyond the departed player's cut")
	var expected: WideGame = WideGame.new(4)
	for frame: int in range(through + 1):
		for player: int in range(4):
			for value: int in _sample(player, mini(frame, 8) if player == 3 else frame):
				expected.values[player] += value
	expected.frame = through + 1
	for survivor: int in [0, 1, 2]:
		context.equal(mesh.games[survivor].states[through], expected.bytes(), "each survivor preserves the independently reconstructed canonical history")
	context.finish()


func _plans(context: RefCounted, packets: Array[Peer.Packet]) -> PackedInt32Array:
	var plans: PackedInt32Array = PackedInt32Array()
	for packet: Peer.Packet in packets:
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(4))
		context.equal(decoded.code, T.Code.OK, "published history pressure packets retain valid framing")
		if decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER and decoded.message.stage == Drop.Stage.HISTORY \
			and decoded.message.phase == Drop.Phase.PREPARE:
			plans.append(packet.to[0] - 1)
	return plans


func _deliver(context: RefCounted, mesh: Dictionary, packets: Array[Dictionary], terminated: bool = false) -> void:
	var accepted: Array[Dictionary] = []
	for packet: Dictionary in packets:
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
		if _split_delivery and decoded.code == T.Code.OK:
			if packet.from == 3 and packet.to == 1 and decoded.message.kind == T.Kind.INPUT \
				and decoded.message.start_frame + decoded.message.frame_count - 1 > 7:
				continue
			if packet.to == 0 and decoded.message.kind == T.Kind.DROP_BARRIER and decoded.message.phase == Drop.Phase.REPORT \
				and decoded.message.stage == Drop.Stage.INVENTORY:
				_held_inventories[packet.from] = packet.duplicate(true)
				continue
		accepted.append(packet)
	super._deliver(context, mesh, accepted, terminated)
