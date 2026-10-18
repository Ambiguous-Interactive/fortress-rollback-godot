extends RefCounted

# Value: protects=slow mesh delivery; fails_when=receive work loses to retries and ACKs; why_new=isolated tests omit amplification; seam=PacketPeer public API
const Fixture = preload("res://tests/unit/test_signalfish_membership.gd")
const DirectFixture = preload("res://tests/unit/test_signalfish_webrtc.gd")
const Direct = preload("res://addons/fortress_rollback/transport/signalfish_webrtc.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const RelayFixture = preload("res://tests/unit/test_signalfish_relay.gd")
const Relay = preload("res://addons/fortress_rollback/transport/signalfish_relay.gd")
const Fallback = preload("res://addons/fortress_rollback/transport/signalfish_fallback.gd")
const S = preload("res://addons/fortress_rollback/core/session_types.gd")

# Each receive budget is its own case so the launcher can run them in parallel.
func cases() -> PackedStringArray:
	return PackedStringArray(["slow_mesh_eight_receives", "slow_mesh_thirty_two_receives"])

func run_case(name: String, context: RefCounted) -> void:
	if name == "slow_mesh_eight_receives":
		var constrained: Dictionary = _run(context, 8)
		print("BACKLOG_CONTROL ", JSON.stringify({"eight": constrained}))
		context.equal(constrained.frames < 12, true, "eight receives misses fixed twenty-second frame deadline")
		context.equal(constrained.backlog > 128, true, "physical FIFO accumulates despite reliable delivery")
		context.finish()
		return
	var sufficient: Dictionary = _run(context, 32)
	print("BACKLOG_CONTROL ", JSON.stringify({"thirty_two": sufficient}))
	context.equal(sufficient.frames, 12, "bounded larger receive work finishes same input log")
	context.equal(sufficient.backlog < 128, true, "receive work keeps the physical FIFO bounded")
	for received: int in sufficient.received:
		context.equal(received, 11, "actual inputs reach the entire tested prefix")
	for index: int in 8:
		context.equal(sufficient.confirmed[index], 11, "fresh gossip confirms the entire tested prefix")
		context.equal(sufficient.confirmed[index] <= sufficient.received[index], true, "confirmation never manufactures physical receipt")
	context.finish()

func _run(context: RefCounted, budget: int, target: int = 12, batch: int = 0) -> Dictionary:
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
		mesh.transport.delayed = batch > 0
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
		options.max_sends_per_poll = 32 if batch == 0 else 8
		options.max_receives_per_poll = budget
		var direct: Direct = Direct.new()
		context.equal(direct.configure(mesh, membership, adapter, peer, options), Direct.Code.OK, "real direct configured")
		var relay: Relay = Relay.new()
		var config: RelayFixture.SDKConfig = RelayFixture.SDKConfig.new()
		var info: RelayFixture.Info = RelayFixture.Info.new()
		var fallback: Fallback = Fallback.new()
		if batch > 0:
			var relay_options: Relay.Options = Relay.Options.new()
			relay_options.max_packet_bytes = 512
			context.equal(relay.configure(client, config, info, membership, adapter, peer, relay_options), 0, "default relay configured")
			context.equal(fallback.configure(direct, relay, membership, adapter, peer), 0, "default route work configured")
		links.append({"pending": [], "fallback": fallback if batch > 0 else null, "relay": relay, "config": config, "info": info,
			"direct": direct, "peer": peer, "mesh": mesh, "adapter": adapter, "client": client, "membership": membership})
	for turn: int in 10:
		_service(context, links, turn)
		_flush(links)
	for link: Dictionary in links:
		context.equal(link.peer.network_status().state, "running", "handshake complete")
	var now: int = 10
	var frames: int = 0
	var maximum_backlog: int = 0
	for frame: int in target:
		var ready: bool = false
		for attempt: int in (20 if batch == 0 else 67):
			now += 1000000 if batch == 0 else 300000
			for turn: int in maxi(1, batch):
				_service(context, links, now)
			ready = _received(links, frame - 1)
			if ready:
				break
			maximum_backlog = maxi(maximum_backlog, _flush(links))
		if not ready:
			break
		for index: int in 8:
			var bytes: PackedByteArray = PackedByteArray([frame & 255, index, 0, 0])
			var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(index, frame, bytes)]
			context.equal(links[index].peer.step(now, samples).code, S.Code.OK, "actual delayed mesh step")
		frames += 1
		# Match the host's eight synchronous service turns before its next await.
		for turn: int in 8:
			if batch == 0: now += 1000000
			_service(context, links, now)
		maximum_backlog = maxi(maximum_backlog, _flush(links))
	if batch > 0 and frames == target:
		for host_turn: int in 66:
			now += 300000
			for turn: int in batch:
				_service(context, links, now)
			var complete: bool = true
			for link: Dictionary in links:
				if link.peer.status().confirmed_frame < target - 1: complete = false
			if complete: break
			maximum_backlog = maxi(maximum_backlog, _flush(links))
	var received: Array[int] = []
	var confirmed: Array[int] = []
	for link: Dictionary in links:
		var floor: int = 2147483647
		for endpoint: Dictionary in link.peer.network_status().peers.values():
			floor = mini(floor, endpoint.last_received_frame)
		received.append(floor)
		confirmed.append(link.peer.status().confirmed_frame)
		context.equal(link.mesh.transport.overflow, false, "owned physical FIFO never silently drops")
		if link.fallback != null: link.fallback.detach()
		link.relay.detach()
		link.direct.detach()
		link.adapter.detach()
		link.client.free()
		link.mesh.free()
	return {"frames": frames, "backlog": maximum_backlog, "received": received, "confirmed": confirmed}

# Browser packet events become visible after the host yields, not during synchronous transport polls.
func _flush(links: Array[Dictionary]) -> int:
	for link: Dictionary in links:
		for packet: Dictionary in link.mesh.transport.staged:
			var destination: Transport = link.mesh.transport.wire[packet.target].get_ref()
			destination.incoming.append(packet.packet)
		link.mesh.transport.staged.clear()
	var maximum: int = 0
	for link: Dictionary in links:
		maximum = maxi(maximum, link.mesh.transport.incoming.size())
	return maximum

func _received(links: Array[Dictionary], frame: int) -> bool:
	for link: Dictionary in links:
		for endpoint: Dictionary in link.peer.network_status().peers.values():
			if endpoint.last_received_frame < frame:
				return false
	return true

func _service(context: RefCounted, links: Array[Dictionary], now: int) -> void:
	for link: Dictionary in links:
		if link.pending.is_empty():
			context.equal(link.peer.poll(now), I.Code.OK, "retry service remains healthy")
		if link.fallback == null:
			context.equal(link.direct.enqueue_batch(link.peer.drain_outbox()), Direct.Code.OK, "atomic outgoing ownership")
			context.equal(link.direct.poll(now).code, Direct.Code.OK, "physical FIFO service remains healthy")
		else:
			if link.pending.is_empty(): link.pending = link.peer.drain_outbox()
			var code: int = link.fallback.enqueue_batch(link.pending)
			context.equal(code in [0, Fallback.Code.BACKPRESSURE], true, "atomic composed output ownership")
			if code == 0: link.pending = []
			context.equal(link.fallback.poll(now).code in [0, Fallback.Code.BACKPRESSURE], true, "bounded default composed service")
		link.peer.drain_events()
		link.peer.drain_transitions()

class Client:
	extends RelayFixture.Client
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
	var staged: Array[Dictionary] = []
	var delayed: bool = false
	func get_unique_id() -> int:
		return Fixture.M.uuid_to_peer_id(uuid)
	func put_packet(bytes: PackedByteArray) -> Error:
		var destination: Transport = wire[target].get_ref()
		if destination.incoming.size() >= 8192:
			overflow = true
			return ERR_BUSY
		var packet: Dictionary = {"source": get_unique_id(), "channel": channel_number, "mode": mode, "bytes": bytes.duplicate()}
		if delayed: staged.append({"target": target, "packet": packet})
		else: destination.incoming.append(packet)
		return OK
