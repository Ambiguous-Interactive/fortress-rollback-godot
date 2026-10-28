extends "res://tests/unit/test_peer_drop_capacity.gd"

# Value: protects=remote donor retries healthy history despite refused certificates; fails_when=one READY refusal gates every donor chunk;
# why_new=existing donor fairness uses the coordinator as donor; seam=none
var _hold_chunks: bool = true
var _omitted_chunks: int = 0


func cases() -> PackedStringArray:
	return PackedStringArray(["refused_ready_preserves_remote_donor", "remote_donor_ready_control"])


func run_case(name: String, context: RefCounted) -> void:
	_mode = "remote_donor_pressure"
	_missing_peer = -1
	_width = 4
	_pressure_actor = -1
	_hold_ready = false
	_hold_chunks = true
	_omitted_chunks = 0
	var mesh: Dictionary = _wide_mesh(context, 4)
	_play(context, mesh, 6, true)
	_leave(context, mesh, 3)
	for peer: int in [0, 2]:
		context.equal(mesh.peers[peer]._core.received_frames()[3], 7, "both recipients genuinely lack the final original input")
	context.equal(mesh.peers[1]._core.received_frames()[3], 8, "only the remote donor retains the original cut input")
	var actor: Peer = mesh.peers[1]
	var barrier: Drop.Barrier = null
	for tick: int in range(90):
		mesh.now += 50000
		for survivor: int in [0, 1, 2]:
			for other: int in [0, 1, 2]:
				if survivor != other:
					_keep_alive(context, mesh, other, survivor)
			context.equal(mesh.peers[survivor].poll(mesh.now), I.Code.OK, "service the remote donor agreement with live survivor links")
		_deliver(context, mesh, _without_peer(_drain(mesh), 3))
		barrier = actor._drops.barrier(_id(3).hex_encode())
		if barrier != null and barrier.certified:
			break
	context.equal(barrier != null and barrier.certified, true, "the remote donor certifies while one recipient still lacks lost chunks")
	if barrier == null or not barrier.certified:
		context.finish()
		return
	context.equal(barrier.history.donor, 1, "the coordinator selects the sole complete remote donor")
	context.equal(_omitted_chunks > 0, true, "actual initial donor packets to the healthy recipient were lost")
	context.equal(mesh.peers[2]._core.received_frames()[3], 7, "the healthy recipient still needs an original donor retry")
	_drain(mesh)
	_hold_chunks = false
	mesh.now += Drop.RETRY_US
	var chunks: int = 0
	for turn: int in range(8):
		if name == "refused_ready_preserves_remote_donor":
			var payload: Dictionary = actor._drops._payload(barrier, Drop.Phase.REPORT, Drop.Stage.INVENTORY, 0)
			var coordinator: int = actor.peer_ids().find(_id(0))
			context.equal(actor._endpoint(coordinator).send_drop_barrier(payload, mesh.now), I.Code.OK, "bounded queued control refuses the coordinator's READY publication")
		context.equal(actor.poll(mesh.now), I.Code.OK, "retry retained donor work under certificate pressure")
		for packet: Peer.Packet in actor.drain_outbox():
			var decoded: T.Result = Codec.decode(packet.bytes, _limits(4))
			context.equal(decoded.code, T.Code.OK, "every published packet retains valid framing")
			if packet.to != _id(2):
				continue
			if decoded.message.kind == T.Kind.DROP_BARRIER and decoded.message.phase == Drop.Phase.BACKFILL and decoded.message.stage == Drop.Stage.HISTORY:
				chunks += 1
				context.equal(decoded.message.bytes, _sample(3, 8), "the healthy donor retry preserves original target bytes")
			context.equal(mesh.peers[2].receive(packet.bytes, _id(1), mesh.now), I.Code.OK, "deliver actual healthy-link donor retries")
	context.equal(chunks > 0, true, "refused certificate traffic cannot starve healthy retained history")
	context.equal(mesh.peers[2]._core.retained_input(3, 8), _sample(3, 8), "the healthy recipient repairs its original missing row before pressure clears")
	for tick: int in range(20):
		mesh.now += Drop.RETRY_US
		for survivor: int in [0, 1, 2]:
			for other: int in [0, 1, 2]:
				if survivor != other:
					_keep_alive(context, mesh, other, survivor)
			context.equal(mesh.peers[survivor].poll(mesh.now), I.Code.OK, "complete the original agreement after certificate pressure clears")
		_deliver(context, mesh, _without_peer(_drain(mesh), 3))
	for survivor: int in [0, 1, 2]:
		context.equal(mesh.peers[survivor]._core.frozen_frame(3), 8, "all survivors freeze after recovering complete original history")
	_play(context, mesh, 6, true, [0, 1, 2], 3)
	var through: int = 2147483647
	for survivor: int in [0, 1, 2]:
		through = mini(through, mesh.peers[survivor].status().confirmed_frame - 1)
	context.equal(through > 8, true, "the recovered match confirms continuing gameplay")
	var expected: WideGame = WideGame.new(4)
	for frame: int in range(through + 1):
		for player: int in range(4):
			for value: int in _sample(player, mini(frame, 8) if player == 3 else frame):
				expected.values[player] += value
	expected.frame = through + 1
	for survivor: int in [0, 1, 2]:
		context.equal(mesh.games[survivor].states[through], expected.bytes(), "each survivor preserves independently reconstructed canonical history")
	context.finish()


func _deliver(context: RefCounted, mesh: Dictionary, packets: Array[Dictionary], terminated: bool = false) -> void:
	var accepted: Array[Dictionary] = []
	for packet: Dictionary in packets:
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
		if decoded.code == T.Code.OK:
			if packet.from == 3 and packet.to in [0, 2] and decoded.message.kind == T.Kind.INPUT \
				and decoded.message.start_frame + decoded.message.frame_count - 1 > 7:
				continue
			if _hold_chunks and packet.from == 1 and packet.to == 2 and decoded.message.kind == T.Kind.DROP_BARRIER \
				and decoded.message.phase == Drop.Phase.BACKFILL and decoded.message.stage == Drop.Stage.HISTORY:
				_omitted_chunks += 1
				continue
		accepted.append(packet)
	super._deliver(context, mesh, accepted, terminated)
