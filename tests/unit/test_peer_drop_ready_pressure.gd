extends "res://tests/unit/test_peer_drop_capacity.gd"

# Value: protects=certificate retries retain per-survivor acceptance; fails_when=one refused READY floods healthy links;
# why_new=existing partial-publication cases cover proposals and donor plans only; seam=none
var _certificate: Dictionary = {}


func cases() -> PackedStringArray:
	return PackedStringArray(["partial_ready_retry", "staggered_ready_retry", "complete_ready_control"])


func run_case(name: String, context: RefCounted) -> void:
	var pressured: bool = name != "complete_ready_control"
	var staggered: bool = name == "staggered_ready_retry"
	_mode = "ready_pressure"
	_missing_peer = -1
	_width = 4
	_pressure_actor = 1
	_pressure_input.clear()
	_hold_ready = true
	_certificate.clear()
	var mesh: Dictionary = _wide_mesh(context, 4)
	_play(context, mesh, 6, true)
	_leave(context, mesh, 3)
	for tick: int in range(60):
		mesh.now += Drop.RETRY_US
		for survivor: int in [0, 1, 2]:
			for other: int in [0, 1, 2]:
				if survivor != other:
					_keep_alive(context, mesh, other, survivor)
			context.equal(mesh.peers[survivor].poll(mesh.now), I.Code.OK, "service original survivor agreement")
		_deliver(context, mesh, _without_peer(_drain(mesh), 3))
		if not _certificate.is_empty():
			break
	context.equal(_certificate.is_empty(), false, "hold the actual follower certificate before coordinator receipt")
	context.equal(_pressure_input.is_empty(), false, "retain an original coordinator input for real ACK pressure")
	if _certificate.is_empty() or _pressure_input.is_empty():
		context.finish()
		return
	_drain(mesh)
	var actor: Peer = mesh.peers[1]
	context.equal(actor._drops.barrier(_id(3).hex_encode()).certified, true, "the follower has certified its immutable original history")
	mesh.now += Drop.RETRY_US
	if pressured:
		context.equal(actor.receive(_pressure_input.bytes, _id(0), mesh.now), I.Code.OK, "a real duplicate input refuses only the coordinator's certificate slot")
	else:
		context.equal(actor.poll(mesh.now), I.Code.OK, "the complete control retries both accepted destinations at equality")
	context.equal(_ready_destinations(context, actor.drain_outbox()), PackedInt32Array([2] if pressured else [0, 2]), "each healthy destination accepts the due certificate")
	var accepted_at: int = mesh.now
	if staggered:
		mesh.now += Drop.RETRY_US / 2
	context.equal(actor.poll(mesh.now), I.Code.OK, "repoll after output drains")
	context.equal(_ready_destinations(context, actor.drain_outbox()), PackedInt32Array([0] if pressured else []), "only a previously refused certificate retries immediately")
	context.equal(actor.poll(accepted_at + Drop.RETRY_US - 1), I.Code.OK, "service the last tick before the next certificate retry")
	context.equal(_ready_destinations(context, actor.drain_outbox()), PackedInt32Array(), "accepted certificates retain their own quiet retry interval")
	context.equal(actor.poll(accepted_at + Drop.RETRY_US), I.Code.OK, "service the exact next certificate retry boundary")
	context.equal(_ready_destinations(context, actor.drain_outbox()), PackedInt32Array([2] if staggered else [0, 2]), "each certificate retries at its own equality")
	if staggered:
		context.equal(actor.poll(mesh.now + Drop.RETRY_US - 1), I.Code.OK, "service the tick before the later acceptance deadline")
		context.equal(_ready_destinations(context, actor.drain_outbox()), PackedInt32Array(), "the later accepted link stays quiet before its own deadline")
		context.equal(actor.poll(mesh.now + Drop.RETRY_US), I.Code.OK, "service the later acceptance deadline")
		context.equal(_ready_destinations(context, actor.drain_outbox()), PackedInt32Array([0]), "pressure cannot move another survivor retry deadline")
	mesh.now += Drop.RETRY_US
	_hold_ready = false
	for tick: int in range(12):
		mesh.now += Drop.RETRY_US
		for survivor: int in [0, 1, 2]:
			for other: int in [0, 1, 2]:
				if survivor != other:
					_keep_alive(context, mesh, other, survivor)
			context.equal(mesh.peers[survivor].poll(mesh.now), I.Code.OK, "retry actual certificates through every surviving link")
		_deliver(context, mesh, _without_peer(_drain(mesh), 3))
	for survivor: int in [0, 1, 2]:
		context.equal(mesh.peers[survivor]._core.frozen_frame(3), 8, "all survivors commit the same original receipt-raised cut")
	_play(context, mesh, 6, true, [0, 1, 2], 3)
	var through: int = 2147483647
	for survivor: int in [0, 1, 2]:
		through = mini(through, mesh.peers[survivor].status().confirmed_frame - 1)
	context.equal(through > 8, true, "confirmation resumes beyond the committed cut")
	var expected: WideGame = WideGame.new(4)
	for frame: int in range(through + 1):
		for player: int in range(4):
			for value: int in _sample(player, mini(frame, 8) if player == 3 else frame):
				expected.values[player] += value
	expected.frame = through + 1
	for survivor: int in [0, 1, 2]:
		context.equal(mesh.games[survivor].states[through], expected.bytes(), "certificate pressure preserves independently reconstructed original history")
	context.finish()


func _ready_destinations(context: RefCounted, packets: Array[Peer.Packet]) -> PackedInt32Array:
	var destinations: PackedInt32Array = PackedInt32Array()
	for packet: Peer.Packet in packets:
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(4))
		context.equal(decoded.code, T.Code.OK, "certificate publication retains valid framing")
		if decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER \
			and decoded.message.phase == Drop.Phase.REPORT and decoded.message.stage == Drop.Stage.READY:
			destinations.append(packet.to[0] - 1)
	return destinations


func _deliver(context: RefCounted, mesh: Dictionary, packets: Array[Dictionary], terminated: bool = false) -> void:
	for packet: Dictionary in packets:
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
		if packet.from == 1 and packet.to == 0 and decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER \
			and decoded.message.phase == Drop.Phase.REPORT and decoded.message.stage == Drop.Stage.READY:
			_certificate = packet.duplicate(true)
	super._deliver(context, mesh, packets, terminated)
