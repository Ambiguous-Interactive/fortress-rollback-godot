extends RefCounted

# Value: protects=exhausted mesh recovers after ACK drainage; fails_when=status loses its last carrier; why_new=ordinary retries retain pending input; seam=none
const Reference = preload("res://tests/oracle/reference_game.gd")
const Fixture = preload("res://tests/unit/test_peer_session.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")

func cases() -> PackedStringArray:
	return PackedStringArray(["drained", "dropped_reordered", "missing_receipt", "step_recovery", "grouped_locals"])

func run_case(name: String, context: RefCounted) -> void:
	if name == "grouped_locals":
		_run(context, 6, "drained", true)
	else:
		for count: int in [3, 8]:
			_run(context, count, name)
	context.finish()

func _run(context: RefCounted, count: int, mode: String, multiple: bool = false) -> void:
	var fixture: RefCounted = Fixture.new()
	var mesh: Dictionary = fixture._build(context, count, 0, multiple)
	var identities: int = mesh.peers.size()
	var packets: Array[Dictionary] = []
	for frame: int in 8:
		mesh.now += 1
		fixture._tick(context, mesh)
		packets.append_array(fixture._drain(mesh))
	mesh.now += 1
	for index: int in identities:
		context.equal(mesh.peers[index].step(mesh.now, fixture._inputs(mesh, index)).code, Types.Code.PREDICTION_STALL, "exhausted prediction window")
	packets.append_array(fixture._drain(mesh))
	var held: Array[Dictionary] = []
	var delivered: Array[Dictionary] = []
	for packet: Dictionary in packets:
		if mode == "missing_receipt" and packet.from == 0 and packet.to == 1:
			held.append(packet)
		else:
			delivered.append(packet)
	fixture._deliver(context, mesh, delivered)
	fixture._deliver(context, mesh, fixture._drain(mesh))
	for peer: RefCounted in mesh.peers:
		context.equal(peer.status().current_frame, 8, "delivery preserves stalled frame")
		context.equal(peer.status().confirmed_frame, -1, "stale third-party gossip still binds")
		peer.drain_events()
		peer.drain_transitions()
	_poll(context, mesh, 200009)
	context.equal(fixture._drain(mesh).size(), 0, "strict last input interval excludes equality")
	if mode == "step_recovery":
		mesh.now = 200010
		for index: int in identities:
			context.equal(mesh.peers[index].step(mesh.now, fixture._inputs(mesh, index)).code, Types.Code.PREDICTION_STALL, "same sample services gossip during stall")
	else:
		_poll(context, mesh, 200010)
	var carriers: Array[Dictionary] = fixture._drain(mesh)
	context.equal(carriers.size(), (identities - 1) * (identities - 1) if mode == "missing_receipt" else identities * (identities - 1), "bounded single input carrier per link")
	var limits: T.Limits = T.Limits.new()
	limits.player_count = count
	limits.input_width = 4
	for packet: Dictionary in carriers:
		var decoded: T.Result = Codec.decode(packet.bytes, limits)
		context.equal(decoded.code, T.Code.OK, "valid status carrier")
		context.equal(decoded.message.kind, T.Kind.INPUT, "status uses input wire shape")
		if mode != "missing_receipt":
			context.equal(decoded.message.frame_count, 1, "acknowledged carrier holds one frame")
		if mode != "missing_receipt":
			context.equal(decoded.message.start_frame, 8, "carrier repeats last acknowledged frame")
			var expected_input: PackedByteArray = PackedByteArray()
			for slot: int in count:
				if mesh.owners[slot] == packet.from:
					expected_input.append_array(fixture._sample(slot, 8))
			context.equal(decoded.message.data, expected_input, "carrier owns original unchanged input")
	if mode == "dropped_reordered":
		_poll(context, mesh, 400010)
		context.equal(fixture._drain(mesh).size(), 0, "strict nudge interval excludes equality")
		_poll(context, mesh, 400011)
		var retry: Array[Dictionary] = fixture._drain(mesh)
		context.equal(retry.size(), carriers.size(), "dropped carrier recovers after pending stays empty")
		retry.reverse()
		fixture._deliver(context, mesh, retry)
		fixture._deliver(context, mesh, fixture._drain(mesh))
		carriers.reverse()
	if mode == "missing_receipt":
		var filtered: Array[Dictionary] = []
		for packet: Dictionary in carriers:
			if packet.from != 0 or packet.to != 1:
				filtered.append(packet)
		carriers = filtered
	fixture._deliver(context, mesh, carriers)
	fixture._deliver(context, mesh, fixture._drain(mesh))
	if mode == "missing_receipt":
		context.equal(mesh.peers[1]._core.received_frames()[0], -1, "remote status cannot manufacture actual receipt")
		context.equal(mesh.peers[1].status().confirmed_frame, -1, "missing input remains confirmation bound")
		context.equal(mesh.peers[1].step(mesh.now, fixture._inputs(mesh, 1)).code, Types.Code.PREDICTION_STALL, "missing actual input still stalls")
		fixture._deliver(context, mesh, held)
		fixture._deliver(context, mesh, fixture._drain(mesh))
		_poll(context, mesh, mesh.now + 200001)
		fixture._deliver(context, mesh, fixture._drain(mesh))
		fixture._deliver(context, mesh, fixture._drain(mesh))
	var expected: RefCounted = Reference.new(count, 2)
	for frame: int in 9:
		var inputs: Array[Dictionary] = []
		for slot: int in count:
			inputs.append({"player": slot, "bytes": fixture._sample(slot, frame).hex_encode(), "status": "confirmed"})
		context.equal(expected.advance(inputs), "", "independent confirmed replay")
	for index: int in identities:
		var peer: RefCounted = mesh.peers[index]
		context.equal(peer.status().confirmed_frame, 8, "fresh remote evidence confirms retained prefix")
		context.equal(peer.step(mesh.now, fixture._inputs(mesh, index)).code, Types.Code.OK, "identical retained sample resumes")
		context.equal(peer.status().current_frame, 9, "recovery advances exactly once")
		context.equal(mesh.games[index].game.bytes(), expected.bytes(), "rollback repaired original-input canonical state")
	context.state(9, expected.bytes())
	fixture._drain(mesh)
	_poll(context, mesh, mesh.now + 200001)
	context.equal(fixture._drain(mesh).size(), 0, "healthy room stops nudges without new input")

func _poll(context: RefCounted, mesh: Dictionary, now: int) -> void:
	mesh.now = now
	for peer: RefCounted in mesh.peers:
		context.equal(peer.poll(now), I.Code.OK, "service exhausted mesh")
		peer.drain_events()
		peer.drain_transitions()
