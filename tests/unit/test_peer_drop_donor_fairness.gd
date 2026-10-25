extends "res://tests/unit/test_peer_drop_capacity.gd"

# Value: protects=healthy survivors receive retained history under multi-link pressure; fails_when=first refused links exhaust every donor turn;
# why_new=prior donor pressure cases have fewer destinations than the per-poll work budget; seam=none
var _inventories: Dictionary = {}
var _hold_inventories: bool = false
var _omit_last: bool = false


func cases() -> PackedStringArray:
	return PackedStringArray(["healthy_donor_destination", "unpressured_donor_control"])


func run_case(name: String, context: RefCounted) -> void:
	_mode = "donor_fairness"
	_missing_peer = -1
	_width = 4
	_hold_inventories = true
	_omit_last = true
	_inventories.clear()
	var mesh: Dictionary = _wide_mesh(context, 8)
	_play(context, mesh, 6, true)
	_leave(context, mesh, 7)
	context.equal(mesh.peers[5]._core.received_frames()[7], 7, "the late survivor genuinely lacks original target row eight")
	for tick: int in range(60):
		mesh.now += Drop.RETRY_US
		for survivor: int in range(7):
			for other: int in range(7):
				if survivor != other:
					_keep_alive(context, mesh, other, survivor)
			context.equal(mesh.peers[survivor].poll(mesh.now), I.Code.OK, "detect only the actual departed endpoint")
		_deliver(context, mesh, _without_peer(_drain(mesh), 7))
		if _inventories.size() == 6:
			break
	context.equal(_inventories.size(), 6, "hold truthful inventories from every remote survivor")
	if _inventories.size() != 6:
		context.finish()
		return
	for survivor: int in range(1, 7):
		context.equal(mesh.peers[0].receive(_inventories[survivor].bytes, _id(survivor), mesh.now), I.Code.OK, "supply the original retained inventory")
	_drain(mesh)
	var host: Peer = mesh.peers[0]
	var barrier: Drop.Barrier = host._drops.barrier(_id(7).hex_encode())
	context.equal(barrier.history.first, 8, "the donor plan covers the genuinely missing original row")
	context.equal(barrier.history.donor, 0, "the coordinator retains the donor history")
	context.equal(host.poll(mesh.now), I.Code.OK, "publish the retained-history plan before data pressure")
	var plans: int = 0
	for packet: Peer.Packet in host.drain_outbox():
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(8))
		if decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER and decoded.message.stage == Drop.Stage.HISTORY:
			plans += 1
	context.equal(plans, 6, "all survivors accept the initial retained-history plan")
	var destinations: Dictionary = {}
	for turn: int in range(6):
		if name == "healthy_donor_destination":
			for index: int in range(4):
				var payload: Dictionary = host._drops._payload(barrier, Drop.Phase.PREPARE, Drop.Stage.NONE, 0)
				context.equal(host._endpoint(index).send_drop_barrier(payload, mesh.now), I.Code.OK, "real earlier-link control traffic occupies its one-packet publication queue")
		context.equal(host.poll(mesh.now), I.Code.OK, "service bounded donor work at the same protocol clock")
		var published: int = 0
		for packet: Peer.Packet in host.drain_outbox():
			var decoded: T.Result = Codec.decode(packet.bytes, _limits(8))
			context.equal(decoded.code, T.Code.OK, "every accepted packet retains valid framing")
			if decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER and decoded.message.phase == Drop.Phase.BACKFILL:
				published += 1
				destinations[packet.to[0] - 1] = true
				context.equal(decoded.message.bytes, _sample(7, 8), "donor publication preserves the exact original target bytes")
		context.equal(published <= 4, true, "fairness preserves the bounded chunk work per service call")
	context.equal(destinations.has(5), true, "earlier refused links cannot starve the survivor that needs history")
	context.equal(destinations.has(6), true, "the last healthy survivor also gets a bounded donor turn")
	if name == "unpressured_donor_control":
		context.equal(destinations.size(), 6, "the unpressured donor reaches every remote survivor")
	_hold_inventories = false
	_omit_last = false
	for tick: int in range(20):
		mesh.now += Drop.RETRY_US
		for survivor: int in range(7):
			for other: int in range(7):
				if survivor != other:
					_keep_alive(context, mesh, other, survivor)
			context.equal(mesh.peers[survivor].poll(mesh.now), I.Code.OK, "retry retained original plans and data after pressure drains")
		_deliver(context, mesh, _without_peer(_drain(mesh), 7))
	for survivor: int in range(7):
		context.equal(mesh.peers[survivor]._core.frozen_frame(7), 8, "every survivor certifies the recovered original cut")
		context.equal(mesh.peers[survivor]._core.retained_input(7, 8), _sample(7, 8), "all survivors retain the original cut input")
	_play(context, mesh, 6, true, [0, 1, 2, 3, 4, 5, 6], 7)
	var through: int = 2147483647
	for survivor: int in range(7):
		through = mini(through, mesh.peers[survivor].status().confirmed_frame - 1)
	context.equal(through > 8, true, "the recovered eight-player match confirms later gameplay")
	var expected: WideGame = WideGame.new(8)
	for frame: int in range(through + 1):
		for player: int in range(8):
			for value: int in _sample(player, mini(frame, 8) if player == 7 else frame):
				expected.values[player] += value
	expected.frame = through + 1
	for survivor: int in range(7):
		context.equal(mesh.games[survivor].states[through], expected.bytes(), "every survivor preserves the independent canonical history")
	context.finish()


func _deliver(context: RefCounted, mesh: Dictionary, packets: Array[Dictionary], terminated: bool = false) -> void:
	var accepted: Array[Dictionary] = []
	for packet: Dictionary in packets:
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
		if decoded.code == T.Code.OK:
			if _omit_last and packet.from == 7 and packet.to == 5 and decoded.message.kind == T.Kind.INPUT \
				and decoded.message.start_frame + decoded.message.frame_count - 1 > 7:
				continue
			if _hold_inventories and packet.to == 0 and decoded.message.kind == T.Kind.DROP_BARRIER \
				and decoded.message.phase == Drop.Phase.REPORT and decoded.message.stage == Drop.Stage.INVENTORY:
				_inventories[packet.from] = packet.duplicate(true)
				continue
		accepted.append(packet)
	super._deliver(context, mesh, accepted, terminated)
