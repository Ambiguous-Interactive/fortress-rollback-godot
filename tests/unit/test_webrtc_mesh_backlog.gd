extends RefCounted

# Value: protects=slow mesh delivery; fails_when=receive work loses to retries and ACKs; why_new=isolated tests omit amplification; seam=PacketPeer public API
const Fixture = preload("res://tests/unit/test_signalfish_membership.gd")
const DirectFixture = preload("res://tests/unit/test_signalfish_webrtc.gd")
const Direct = preload("res://addons/fortress_rollback/transport/signalfish_webrtc.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const S = preload("res://addons/fortress_rollback/core/session_types.gd")

func cases() -> PackedStringArray:
	return PackedStringArray(["slow_mesh"])

func run_case(_name: String, context: RefCounted) -> void:
	var constrained: Dictionary = _run(context, 8)
	var sufficient: Dictionary = _run(context, 32)
	print("BACKLOG_CONTROL ", JSON.stringify({"eight": constrained, "thirty_two": sufficient}))
	context.equal(constrained.frames < 12, true, "eight receives misses fixed twenty-second frame deadline")
	context.equal(constrained.backlog > 128, true, "physical FIFO accumulates despite reliable delivery")
	context.equal(sufficient.frames, 12, "bounded larger receive work finishes same input log")
	context.equal(sufficient.backlog < 128, true, "receive work keeps the physical FIFO bounded")
	for received: int in sufficient.received:
		context.equal(received, 11, "actual inputs reach the entire tested prefix")
	for index: int in 8:
		context.equal(sufficient.confirmed[index], 11, "fresh gossip confirms the entire tested prefix")
		context.equal(sufficient.confirmed[index] <= sufficient.received[index], true, "confirmation never manufactures physical receipt")
	context.finish()

func _run(context: RefCounted, budget: int, target: int = 12) -> Dictionary:
	var helper: RefCounted = Fixture.new()
	var roster: PackedStringArray = PackedStringArray()
	for index: int in 8:
		roster.append("00000000-0000-0000-0000-%012x" % (index + 1))
	var links: Array[Dictionary] = []
	var wire: Dictionary = {}
	for index: int in 8:
		var membership: Fixture.M = helper._membership(context, roster[index], roster)
		var peer: Fixture.P = helper._peer(context, membership)
		var client: Client = Client.new()
		client.uuid = roster[index]
		var mesh: FakeMesh = FakeMesh.new()
		mesh.transport.uuid = roster[index]
		mesh.transport.wire = wire
		wire[Fixture.M.uuid_to_peer_id(roster[index])] = weakref(mesh.transport)
		var adapter: Fixture.A = Fixture.A.new()
		context.equal(adapter.attach(client, mesh, membership), OK, "full mesh attached")
		var plan: Fixture.Plan = Fixture.Plan.new()
		plan.data.peers = []
		for remote: int in 8:
			if remote != index:
				plan.data.peers.append({"player_id": roster[remote], "initiate": index < remote})
		client.session_plan.emit(plan)
		var options: Direct.Options = Direct.Options.new()
		options.max_sends_per_poll = 32
		options.max_receives_per_poll = budget
		var direct: Direct = Direct.new()
		context.equal(direct.configure(mesh, membership, adapter, peer, options), Direct.Code.OK, "real direct configured")
		links.append({"direct": direct, "peer": peer, "mesh": mesh, "adapter": adapter, "client": client, "membership": membership})
	for turn: int in 10:
		_service(context, links, turn)
	for link: Dictionary in links:
		context.equal(link.peer.network_status().state, "running", "handshake complete")
	var now: int = 10
	var frames: int = 0
	var maximum_backlog: int = 0
	for frame: int in target:
		var ready: bool = false
		for attempt: int in 20:
			now += 1000000
			_service(context, links, now)
			for link: Dictionary in links:
				maximum_backlog = maxi(maximum_backlog, link.mesh.transport.incoming.size())
			ready = _received(links, frame - 1)
			if ready:
				break
		if not ready:
			break
		for index: int in 8:
			var bytes: PackedByteArray = PackedByteArray([frame & 255, index, 0, 0])
			var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(index, frame, bytes)]
			context.equal(links[index].peer.step(now, samples).code, S.Code.OK, "actual delayed mesh step")
		frames += 1
		# Match the host's eight synchronous service turns before its next await.
		for turn: int in 8:
			now += 1000000
			_service(context, links, now)
	var received: Array[int] = []
	var confirmed: Array[int] = []
	for link: Dictionary in links:
		var floor: int = 2147483647
		for endpoint: Dictionary in link.peer.network_status().peers.values():
			floor = mini(floor, endpoint.last_received_frame)
		received.append(floor)
		confirmed.append(link.peer.status().confirmed_frame)
		context.equal(link.mesh.transport.overflow, false, "owned physical FIFO never silently drops")
		link.direct.detach()
		link.adapter.detach()
		link.client.free()
		link.mesh.free()
	return {"frames": frames, "backlog": maximum_backlog, "received": received, "confirmed": confirmed}

func _received(links: Array[Dictionary], frame: int) -> bool:
	for link: Dictionary in links:
		for endpoint: Dictionary in link.peer.network_status().peers.values():
			if endpoint.last_received_frame < frame:
				return false
	return true

func _service(context: RefCounted, links: Array[Dictionary], now: int) -> void:
	for link: Dictionary in links:
		context.equal(link.peer.poll(now), I.Code.OK, "retry service remains healthy")
		context.equal(link.direct.enqueue_batch(link.peer.drain_outbox()), Direct.Code.OK, "atomic outgoing ownership")
		context.equal(link.direct.poll(now).code, Direct.Code.OK, "physical FIFO service remains healthy")
		link.peer.drain_events()
		link.peer.drain_transitions()

class Client:
	extends Fixture.FakeClient
	var uuid: String = ""
	func get_player_id() -> String:
		return uuid

class FakeMesh:
	extends Fixture.FakeMesh
	var transport: Transport = Transport.new()
	func get_multiplayer_peer() -> Object:
		return transport

class Transport:
	extends DirectFixture.Transport
	var uuid: String = ""
	var wire: Dictionary = {}
	var overflow: bool = false
	func get_unique_id() -> int:
		return Fixture.M.uuid_to_peer_id(uuid)
	func put_packet(bytes: PackedByteArray) -> Error:
		var destination: Transport = wire[target].get_ref()
		if destination.incoming.size() >= 8192:
			overflow = true
			return ERR_BUSY
		destination.incoming.append({"source": get_unique_id(), "channel": channel_number, "mode": mode, "bytes": bytes.duplicate()})
		return OK
