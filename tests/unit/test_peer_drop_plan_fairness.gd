extends "res://tests/unit/test_peer_drop_history_pressure.gd"

# Value: protects=accepted donor plans progress despite another refused plan; fails_when=one link globally gates retained bytes;
# why_new=history pressure tests clear refusal before requesting donor data; seam=none


func cases() -> PackedStringArray:
	return PackedStringArray(
		[
			"refused_plan_preserves_healthy_data",
			"complete_plan_data_control",
			"half_retry_lost_chunk",
			"half_retry_lost_chunk_control",
			"equal_retry_lost_chunk",
			"equal_retry_lost_chunk_control",
		]
	)


func run_case(name: String, context: RefCounted) -> void:
	var pressured: bool = not name.ends_with("control")
	var lose_first: bool = name.contains("lost_chunk")
	var cadence: int = Drop.RETRY_US / 2 if name.begins_with("half_") else (Drop.RETRY_US if name.begins_with("equal_") else 0)
	_mode = "plan_fairness"
	_missing_peer = -1
	_width = 4
	_pressure_actor = 0
	_pressure_input.clear()
	_held_inventories.clear()
	_split_delivery = true
	var mesh: Dictionary = _wide_mesh(context, 4)
	_play(context, mesh, 6, true)
	_leave(context, mesh, 3)
	context.equal(mesh.peers[2]._core.received_frames()[3], 7, "healthy survivor genuinely lacks original target row eight")
	for tick: int in range(60):
		mesh.now += Drop.RETRY_US
		for survivor: int in [0, 1, 2]:
			for other: int in [0, 1, 2]:
				if survivor != other:
					_keep_alive(context, mesh, other, survivor)
			context.equal(mesh.peers[survivor].poll(mesh.now), I.Code.OK, "detect departure with every survivor live")
		_deliver(context, mesh, _without_peer(_drain(mesh), 3))
		if _held_inventories.size() == 2:
			break
	context.equal(_held_inventories.size(), 2, "capture each original retained inventory")
	for sender: int in [1, 2]:
		if _held_inventories.has(sender):
			context.equal(mesh.peers[0].receive(_held_inventories[sender].bytes, _id(sender), mesh.now), I.Code.OK, "deliver truthful retained inventories")
	_drain(mesh)
	var host: Peer = mesh.peers[0]
	var barrier: Drop.Barrier = host._drops.barrier(_id(3).hex_encode())
	context.equal(barrier.history.first, 8, "select the original missing row")
	context.equal(barrier.history.donor, 0, "coordinator retains the complete donor range")
	var healthy_chunks: int = 0
	var healthy_plans: int = 0
	for turn: int in range(8):
		mesh.now += cadence
		if pressured:
			context.equal(host.receive(_pressure_input.bytes, _id(1), mesh.now), I.Code.OK, "real duplicate input keeps only another survivor's plan refused")
		else:
			context.equal(host.poll(mesh.now), I.Code.OK, "service the unpressured donor control")
		for packet: Peer.Packet in host.drain_outbox():
			var decoded: T.Result = Codec.decode(packet.bytes, _limits(4))
			context.equal(decoded.code, T.Code.OK, "donor publication remains well formed")
			if pressured and decoded.code == T.Code.OK and packet.to == _id(1):
				context.equal(
					decoded.message.kind == T.Kind.DROP_BARRIER and decoded.message.stage == Drop.Stage.HISTORY and decoded.message.phase == Drop.Phase.BACKFILL,
					false,
					"the refused link gets no donor chunks before its plan is accepted"
				)
			if decoded.code != T.Code.OK or decoded.message.kind != T.Kind.DROP_BARRIER or packet.to != _id(2):
				continue
			if decoded.message.stage == Drop.Stage.HISTORY and decoded.message.phase == Drop.Phase.PREPARE:
				healthy_plans += 1
			elif decoded.message.stage == Drop.Stage.HISTORY and decoded.message.phase == Drop.Phase.BACKFILL:
				healthy_chunks += 1
				context.equal(healthy_plans > 0, true, "the healthy link accepts its plan before donor bytes")
				context.equal(decoded.message.bytes, _sample(3, 8), "healthy donor progress retains the exact original bytes")
			if lose_first and decoded.message.stage == Drop.Stage.HISTORY and decoded.message.phase == Drop.Phase.BACKFILL and healthy_chunks == 1:
				continue
			context.equal(mesh.peers[2].receive(packet.bytes, _id(0), mesh.now), I.Code.OK, "the healthy recipient actually accepts the retained packet")
	if cadence == 0:
		context.equal(healthy_plans, 1, "accepted healthy plans preserve their own retry interval")
		context.equal(healthy_chunks, 1, "a refused foreign link cannot block healthy retained history")
	else:
		context.equal(healthy_chunks >= 2, true, "healthy retained history retries after loss while another plan remains refused")
	context.equal(mesh.peers[2]._core.retained_input(3, 8), _sample(3, 8), "the healthy recipient installs its missing original row under sustained foreign pressure")
	_split_delivery = false
	for tick: int in range(20):
		mesh.now += Drop.RETRY_US
		for survivor: int in [0, 1, 2]:
			for other: int in [0, 1, 2]:
				if survivor != other:
					_keep_alive(context, mesh, other, survivor)
			context.equal(mesh.peers[survivor].poll(mesh.now), I.Code.OK, "resume the refused link after pressure clears")
		_deliver(context, mesh, _without_peer(_drain(mesh), 3))
	for survivor: int in [0, 1, 2]:
		context.equal(mesh.peers[survivor]._core.frozen_frame(3), 8, "every survivor still commits the complete original history")
	_play(context, mesh, 6, true, [0, 1, 2], 3)
	var through: int = 2147483647
	for survivor: int in [0, 1, 2]:
		through = mini(through, mesh.peers[survivor].status().confirmed_frame - 1)
	context.equal(through > 8, true, "confirmed gameplay resumes beyond the agreed cut")
	var expected: WideGame = WideGame.new(4)
	for frame: int in range(through + 1):
		for player: int in range(4):
			for value: int in _sample(player, mini(frame, 8) if player == 3 else frame):
				expected.values[player] += value
	expected.frame = through + 1
	for survivor: int in [0, 1, 2]:
		context.equal(mesh.games[survivor].states[through], expected.bytes(), "all survivors preserve independently reconstructed canonical history")
	context.finish()


func _deliver(context: RefCounted, mesh: Dictionary, packets: Array[Dictionary], terminated: bool = false) -> void:
	var accepted: Array[Dictionary] = []
	for packet: Dictionary in packets:
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
		if _split_delivery and decoded.code == T.Code.OK:
			if packet.from == 3 and packet.to == 2 and decoded.message.kind == T.Kind.INPUT and decoded.message.start_frame + decoded.message.frame_count - 1 > 7:
				continue
			if packet.to == 0 and decoded.message.kind == T.Kind.DROP_BARRIER and decoded.message.phase == Drop.Phase.REPORT and decoded.message.stage == Drop.Stage.INVENTORY:
				_held_inventories[packet.from] = packet.duplicate(true)
				continue
		accepted.append(packet)
	# Skip the parent's different missing-recipient filter while retaining its ACK capture.
	var previous: bool = _split_delivery
	_split_delivery = false
	super._deliver(context, mesh, accepted, terminated)
	_split_delivery = previous
