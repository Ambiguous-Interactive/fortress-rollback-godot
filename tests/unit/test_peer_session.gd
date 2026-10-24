extends RefCounted

# Value: protects=mesh confirmation and retained retransmission; fails_when=partial publication advances or lost input never recovers; why_new=first byte session; seam=none
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const H = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const L = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")
const Game = preload("res://tests/oracle/p2p_game.gd")
const Reference = preload("res://tests/oracle/reference_game.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(
		[
			"mesh",
			"loss",
			"multiple_locals",
			"backpressure",
			"ingress",
			"partial_publication",
			"reentry",
			"begin_preflight",
			"long_runtime",
			"request_mismatch",
			"low_windows",
			"packet_service"
		]
	)


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"mesh":
			for count: int in range(2, 9):
				_run_mesh(context, count, 0, false)
		"loss":
			_run_mesh(context, 2, 2, true)
		"multiple_locals":
			_multiple(context)
		"backpressure":
			_backpressure(context)
		"ingress":
			_ingress(context)
		"partial_publication":
			_partial_publication(context)
		"reentry":
			_reentry(context)
		"begin_preflight":
			_begin_preflight(context)
		"long_runtime":
			_long_runtime(context)
		"request_mismatch":
			_request_mismatch(context)
		"low_windows":
			_low_windows(context)
		"packet_service":
			_packet_service(context)
	context.finish()


func _id(value: int, width: int = 8) -> PackedByteArray:
	var result: PackedByteArray = PackedByteArray()
	result.resize(width)
	result[0] = value + 1
	return result


func _build(context: RefCounted, count: int, delay: int = 0, multiple: bool = false, pending: int = 128, start: bool = true,
	reentry: bool = false, window: int = 8, lifecycle_options: Variant = null, checksum_interval: int = 60, trace_frames: int = 0, game_override: RefCounted = null,
	queue_capacity: int = 128) -> Dictionary:
	# Existing P3 fixtures isolate input/ACK traffic; lifecycle fixtures opt in.
	if lifecycle_options == null:
		lifecycle_options = L.Options.new()
		lifecycle_options.enabled = false
	var peers: Array[Peer] = []
	var games: Array[RefCounted] = []
	var owners: PackedInt32Array = PackedInt32Array()
	for slot: int in range(count):
		owners.append(slot / 2 if multiple else slot)
	var peer_count: int = (count + 1) / 2 if multiple else count
	for player: int in range(peer_count):
		var config: Config = Config.new()
		config.player_count = count
		config.local_players.clear()
		for slot: int in range(count):
			if owners[slot] == player:
				config.local_players.append(slot)
		config.input_width = 4
		config.neutral_input = PackedByteArray([0, 0, 0, 0])
		config.input_delay = delay
		config.queue_capacity = queue_capacity
		config.max_prediction_frames = window
		config.history_slots = window + 1
		config.check_distance = 0
		config.sync_test = false
		config.max_snapshot_bytes = 4 * (count + 3)
		config.storage_budget_bytes = 1048576
		config.diagnostic_trace_frames = trace_frames
		config.diagnostic_seed = "2"
		config.diagnostic_version = "p2p-reference-v1"
		config.diagnostic_replay_command = ""
		var local: T.Message = T.Message.new()
		local.kind = T.Kind.SYNC_REQUEST
		local.sender_id = _id(player)
		local.connection_id = _id(player + 20)
		local.session_id = _id(90, 16)
		local.config.player_count = count
		local.config.input_width = 4
		local.config.input_delay = delay
		local.config.queue_capacity = queue_capacity
		local.config.max_prediction = window
		local.config.desync_interval = checksum_interval
		local.config.neutral_input = config.neutral_input.duplicate()
		local.config.roster.clear()
		for owner: int in owners:
			local.config.roster.append(_id(owner))
		var handshake: H.Options = H.Options.new()
		handshake.roundtrips = 1
		var input: I.Options = I.Options.new()
		input.max_pending_frames = pending
		var game: RefCounted = ReentryGame.new(count) if reentry else Game.new(count)
		if player == 0 and game_override != null:
			game = game_override
		var peer: Peer = Peer.new()
		context.equal(peer.configure(config, local, game, handshake, input, lifecycle_options), I.Code.OK, "configure mesh")
		if reentry:
			game.peer = weakref(peer)
			game.context = context
		peers.append(peer)
		games.append(game)
		var tokens: Array[PackedByteArray] = []
		for remote: PackedByteArray in peer.peer_ids():
			tokens.append(_id(remote[0] + player * 8, 16))
		if start:
			context.equal(peer.begin(0, tokens), I.Code.OK, "begin mesh")
	var mesh: Dictionary = {"peers": peers, "games": games, "owners": owners, "now": 0}
	if not start:
		return mesh
	for iteration: int in range(6):
		_deliver(context, mesh, _drain(mesh))
	for peer: Peer in peers:
		context.equal(peer.network_status().state, "running", "handshake reached running")
		peer.drain_events()
	return mesh


func _sample(player: int, frame: int) -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray([0, 0, 0, 0])
	bytes.encode_s32(0, (mini(frame, 3) + 1) * (player + 1))
	return bytes


func _inputs(mesh: Dictionary, peer: int) -> Array[Driver.LocalInput]:
	var result: Array[Driver.LocalInput] = []
	var frame: int = mesh.peers[peer].status().current_frame
	for slot: int in range(mesh.owners.size()):
		if mesh.owners[slot] == peer:
			result.append(Driver.LocalInput.new(slot, frame, _sample(slot, frame)))
	return result


func _drain(mesh: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for source: int in range(mesh.peers.size()):
		for packet: Peer.Packet in mesh.peers[source].drain_outbox():
			result.append({"from": source, "to": packet.to[0] - 1, "bytes": packet.bytes})
	return result


func _deliver(context: RefCounted, mesh: Dictionary, packets: Array[Dictionary]) -> void:
	for packet: Dictionary in packets:
		context.equal(mesh.peers[packet.to].receive(packet.bytes, _id(packet.from), mesh.now), I.Code.OK, "deliver encoded packet")


func _tick(context: RefCounted, mesh: Dictionary) -> void:
	for index: int in range(mesh.peers.size()):
		context.equal(mesh.peers[index].step(mesh.now, _inputs(mesh, index)).code, Types.Code.OK, "advance peer")
	for game: RefCounted in mesh.games:
		game.requests.clear()


func _run_mesh(context: RefCounted, count: int, delay: int, loss: bool) -> void:
	var mesh: Dictionary = _build(context, count, delay)
	var lost: Array[Dictionary] = []
	for frame: int in range(7):
		mesh.now = (frame + 1) * 1000
		_tick(context, mesh)
		var packets: Array[Dictionary] = _drain(mesh)
		if loss and frame < 3:
			lost.append_array(packets)
		else:
			packets.reverse()
			_deliver(context, mesh, packets)
			_deliver(context, mesh, _drain(mesh))
	if loss:
		mesh.now = 300000
		for peer: Peer in mesh.peers:
			context.equal(peer.poll(mesh.now), I.Code.OK, "retry lost histories")
		_deliver(context, mesh, _drain(mesh))
		_deliver(context, mesh, _drain(mesh))
		_deliver(context, mesh, lost)
		_deliver(context, mesh, _drain(mesh))
	mesh.now += 1000
	_tick(context, mesh)
	_deliver(context, mesh, _drain(mesh))
	_deliver(context, mesh, _drain(mesh))
	var expected: RefCounted = Reference.new(count, 2)
	for frame: int in range(8):
		var inputs: Array[Dictionary] = []
		for slot: int in range(count):
			var bytes: PackedByteArray = _sample(slot, frame - delay) if frame >= delay else PackedByteArray([0, 0, 0, 0])
			inputs.append({"player": slot, "bytes": bytes.hex_encode(), "status": "confirmed"})
		context.equal(expected.advance(inputs), "", "independent confirmed execution")
	for game: RefCounted in mesh.games:
		context.equal(game.game.bytes(), expected.bytes(), "recovered canonical bytes match confirmed execution")
	for peer: Peer in mesh.peers:
		context.equal(peer.status().confirmed_frame >= 6 + delay, true, "mesh gossip confirms scheduled prefix")
	context.state(8, expected.bytes())


func _multiple(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, 4, 2, true)
	for frame: int in range(5):
		mesh.now += 1000
		_tick(context, mesh)
		_deliver(context, mesh, _drain(mesh))
		_deliver(context, mesh, _drain(mesh))
	context.equal(mesh.games[0].game.bytes(), mesh.games[1].game.bytes(), "two local slots retain correct packed order")
	context.equal(mesh.peers[0].status().confirmed_frame, 6, "multiple local delayed confirmation")


func _backpressure(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, 2, 0, false, 1)
	mesh.now = 1
	_tick(context, mesh)
	var packets: Array[Dictionary] = _drain(mesh)
	mesh.now = 2
	context.equal(mesh.peers[0].step(2, _inputs(mesh, 0)).code, Types.Code.NETWORK_BACKPRESSURE, "unacknowledged cap stops advance")
	context.equal(mesh.peers[0].status().current_frame, 1, "backpressure preserves game frame")
	_deliver(context, mesh, packets)
	_deliver(context, mesh, _drain(mesh))
	context.equal(mesh.peers[0].step(2, _inputs(mesh, 0)).code, Types.Code.OK, "same retained sample recovers after ACK")


func _ingress(context: RefCounted) -> void:
	var setup: Dictionary = _build(context, 2)
	for field: int in range(3):
		for malformed: Variant in [null, false, {}, [], RefCounted.new()]:
			if field == 2 and malformed == null:
				continue
			var handshake: Variant = malformed if field == 0 else H.Options.new()
			var inputs: Variant = malformed if field == 1 else I.Options.new()
			var lifecycle: Variant = malformed if field == 2 else L.Options.new()
			var peer: Peer = Peer.new()
			context.equal(peer.configure(setup.peers[0]._config, setup.peers[0]._endpoint(0)._local, Game.new(2), handshake, inputs, lifecycle), I.Code.INVALID_ARGUMENT,
				"malformed options fail at the public variant boundary")
			context.equal(peer.network_status().state, "unconfigured", "invalid options preserve fresh configuration")
			context.equal(peer.configure(setup.peers[0]._config, setup.peers[0]._endpoint(0)._local, Game.new(2), H.Options.new(), I.Options.new()), I.Code.OK,
				"valid retry succeeds after rejected options")
	var mesh: Dictionary = _build(context, 2)
	context.equal(mesh.peers[0].poll(true), I.Code.INVALID_ARGUMENT, "bool clock rejected")
	context.equal(mesh.peers[0].receive(PackedByteArray(), _id(7), 0), I.Code.WRONG_SOURCE, "unregistered transport source rejected")
	context.equal(mesh.peers[0].step(0, []).code, Types.Code.MISSING_LOCAL_INPUT, "missing sample cannot advance")
	var ids: Array[PackedByteArray] = mesh.peers[0].peer_ids()
	ids[0].fill(0)
	context.equal(mesh.peers[0].peer_ids()[0], _id(1), "peer identity accessor owns bytes")
	context.equal(mesh.peers[0].step(0, _inputs(mesh, 0)).code, Types.Code.OK, "invalid ingress did not poison session")


func _partial_publication(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, 3, 0, false, 1)
	mesh.now = 1
	_tick(context, mesh)
	var initial: Array[Dictionary] = _drain(mesh)
	var first_link: Array[Dictionary] = []
	for packet: Dictionary in initial:
		if packet.from == 0 and packet.to == 1:
			first_link.append(packet)
	_deliver(context, mesh, first_link)
	_deliver(context, mesh, _drain(mesh))
	context.equal(mesh.peers[0].network_status().peers[_id(1).hex_encode()].pending_frames, 0, "first endpoint ACK freed capacity")
	context.equal(mesh.peers[0].network_status().peers[_id(2).hex_encode()].pending_frames, 1, "second endpoint remains full")
	mesh.now = 100
	context.equal(mesh.peers[0].step(100, _inputs(mesh, 0)).code, Types.Code.NETWORK_BACKPRESSURE, "second endpoint blocks partial publication")
	context.equal(mesh.peers[0].status().current_frame, 1, "partial publication cannot advance game")
	var partial_status: Dictionary = mesh.peers[0].network_status()
	context.equal(partial_status.peers[_id(1).hex_encode()].last_submitted_frame, 1, "first endpoint owns next sample")
	context.equal(partial_status.peers[_id(2).hex_encode()].last_submitted_frame, 0, "second endpoint preserves earlier sample")
	context.equal(partial_status.last_now_us, 100, "partial operation consumes observed clock")
	var published: Array[Dictionary] = _drain(mesh)
	context.equal(published.size(), 1, "only first endpoint emitted next input")
	context.equal(mesh.peers[0].poll(2), I.Code.INVALID_ARGUMENT, "cannot backdate after partial commit")
	context.equal(mesh.peers[0].network_status().last_now_us, 100, "rejected backdated poll preserves authoritative clock")
	context.equal(mesh.peers[0].step(2, _inputs(mesh, 0)).code, Types.Code.INVALID_TIME, "backdated sample retry rejected")
	context.equal(mesh.peers[0].step(100, _inputs(mesh, 0)).code, Types.Code.NETWORK_BACKPRESSURE, "same clock retry preserves blocked sample")
	context.equal(_drain(mesh).size(), 0, "retry does not republish first endpoint sample")
	_deliver(context, mesh, initial)
	_deliver(context, mesh, _drain(mesh))
	_deliver(context, mesh, published)
	_deliver(context, mesh, _drain(mesh))
	context.equal(mesh.peers[0].step(100, _inputs(mesh, 0)).code, Types.Code.OK, "same retained sample recovers after remaining ACK")
	context.equal(mesh.peers[0].status().current_frame, 2, "recovered publication advances once")
	context.equal(mesh.games[0].game.frame, 2, "game callbacks advanced exactly twice")


func _begin_preflight(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, 3, 0, false, 128, false)
	var tokens: Array[PackedByteArray] = [_id(1, 16), PackedByteArray()]
	context.equal(mesh.peers[0].begin(100, tokens), I.Code.INVALID_ARGUMENT, "bad later endpoint token rejected before begin")
	context.equal(mesh.peers[0].drain_outbox().size(), 0, "preflight prevents first endpoint handshake")
	context.equal(mesh.peers[0].network_status().last_now_us, -1, "invalid preflight preserves clock")
	for endpoint: Dictionary in mesh.peers[0].network_status().peers.values():
		context.equal(endpoint.state, "initializing", "all endpoint handshakes remain fresh")
	tokens[1] = _id(2, 16)
	context.equal(mesh.peers[0].begin(2, tokens), I.Code.OK, "valid retry begins both endpoints")
	context.equal(mesh.peers[0].drain_outbox().size(), 2, "one request per endpoint after valid begin")


func _reentry(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, 2, 0, false, 128, true, true)
	mesh.now = 1
	_tick(context, mesh)
	for game: RefCounted in mesh.games:
		context.equal(game.probed, true, "real game save callback attempted reentry")
	for peer: Peer in mesh.peers:
		context.equal(peer.network_status().last_now_us, 1, "callback cannot move transport clock")
		context.equal(peer.status().current_frame, 1, "outer step finishes once")


class ReentryGame:
	extends Game
	var peer: WeakRef
	var context: RefCounted
	var probed: bool = false

	func _init(players: int) -> void:
		super(players)

	func save_state(frame: int, writer: RefCounted) -> Driver.SaveResult:
		probed = true
		var target: RefCounted = peer.get_ref()
		context.equal(target.poll(1000), I.Code.BUSY, "save callback cannot poll transport")
		context.equal(target.close(1000, 7), I.Code.BUSY, "save callback cannot close session")
		context.equal(target.step(1000, []).code, Types.Code.BUSY, "save callback cannot step session")
		context.equal(target.begin(1000, []), I.Code.BUSY, "save callback cannot begin handshake")
		context.equal(target.receive(PackedByteArray(), target.peer_ids()[0], 1000), I.Code.BUSY, "save callback cannot receive transport")
		context.equal(target.receive_and_poll(PackedByteArray(), target.peer_ids()[0], 1000), I.Code.BUSY, "save callback cannot service packet")
		context.equal(target.configure(null, null, null, null, null), I.Code.BUSY, "save callback cannot configure")
		context.equal(target.drain_outbox().size(), 0, "save callback cannot drain unpublished packets")
		context.equal(target.drain_events().size(), 0, "save callback cannot drain events")
		context.equal(target.drain_transitions().size(), 0, "save callback cannot drain diagnostic transitions")
		return super.save_state(frame, writer)


func _long_runtime(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, 2)
	var observed: int = 0
	for frame: int in range(400):
		mesh.now = frame + 1
		for index: int in range(mesh.peers.size()):
			var code: int = mesh.peers[index].step(mesh.now, _inputs(mesh, index)).code
			context.equal(code, Types.Code.OK, "diagnostic drains sustain frame " + str(frame))
			if code != Types.Code.OK:
				return
		_deliver(context, mesh, _drain(mesh))
		_deliver(context, mesh, _drain(mesh))
		for peer: Peer in mesh.peers:
			var transitions: Array[Dictionary] = peer.drain_transitions()
			observed += transitions.size()
			for transition: Dictionary in transitions:
				context.equal(transition.peer in peer.peer_ids(), true, "diagnostic identifies remote endpoint")
			context.equal(peer.drain_transitions().size(), 0, "diagnostic queue drained exactly once")
			peer.drain_events()
		for game: RefCounted in mesh.games:
			game.requests.clear()
	context.equal(observed > 1024, true, "crossed default transition capacity without freezing")
	context.equal(mesh.games[0].game.bytes(), mesh.games[1].game.bytes(), "long-running canonical gameplay remains identical")
	context.equal(mesh.peers[0].status().current_frame, 400, "long-running game completes every frame")


func _request_mismatch(context: RefCounted) -> void:
	for field: String in ["fps", "queue_capacity", "roster", "neutral_input"]:
		_request_mismatch_field(context, field)
	# Raises are bounded by queue capacity, so the advertised capacity must match the session's.
	var setup: Dictionary = _build(context, 2, 0, false, 128, false)
	var config: Config = setup.peers[0]._config.owned_copy()
	config.queue_capacity = 256
	context.equal(Peer.new().configure(config, setup.peers[0]._endpoint(0)._local, Game.new(2), H.Options.new(), I.Options.new()), I.Code.INVALID_ARGUMENT,
		"advertised queue capacity must match the session")


func _request_mismatch_field(context: RefCounted, field: String) -> void:
	var mesh: Dictionary = _build(context, 2, 0, false, 128, false)
	var tokens: Array[PackedByteArray] = [_id(1, 16)]
	context.equal(mesh.peers[0].begin(0, tokens), I.Code.OK, "begin before incompatible request")
	var message: T.Message = T.Message.new()
	message.kind = T.Kind.SYNC_REQUEST
	message.sender_id = _id(1)
	message.connection_id = _id(21)
	message.session_id = _id(90, 16)
	message.token = _id(10, 16)
	message.config.input_width = 4
	message.config.neutral_input = PackedByteArray([0, 0, 0, 0])
	message.config.roster = [_id(0), _id(1)]
	match field:
		"fps":
			message.config.fps = 61
		"queue_capacity":
			message.config.queue_capacity = 256
		"roster":
			message.config.roster = [_id(1), _id(0)]
		"neutral_input":
			message.config.neutral_input = PackedByteArray([1, 1, 1, 1])
	var limits: T.Limits = T.Limits.new()
	limits.input_width = 4
	var packet: T.Result = Codec.encode(message, limits)
	context.equal(packet.code, T.Code.OK, "encode semantically incompatible but valid request")
	context.equal(mesh.peers[0].receive(packet.bytes, _id(1), 1), I.Code.OK, "endpoint records request mismatch")
	context.equal(mesh.peers[0].network_status().state, "terminated", "request mismatch terminates gameplay facade")
	var report: Dictionary = mesh.peers[0].diagnostics()
	context.equal(report.failure.get("kind"), "incompatible", "terminal cause captured before an event drain")
	context.equal(report.failure.get("field"), field, "incompatible field without either negotiated value")
	mesh.peers[0].drain_events()
	report = mesh.peers[0].diagnostics()
	context.equal(report.failure.has("reason"), false, "incompatible report excludes raw negotiation payload")
	context.equal(report.failure.get("field"), field, "field survives normal event drains")
	report.failure["field"] = "changed"
	context.equal(mesh.peers[0].diagnostics().failure.get("field"), field, "returned mismatch cannot change retained evidence")
	context.equal(JSON.stringify(mesh.peers[0].diagnostics()).length() < 8192, true, "mismatch report stays bounded")
	context.equal(mesh.peers[0].status().reason, Types.Code.PROTOCOL_FAILED, "mismatch reports protocol failure")
	var stopped: Driver.StepResult = mesh.peers[0].step(1, _inputs(mesh, 0))
	context.equal(stopped.code, Types.Code.TERMINATED, "failed handshake cannot advance game")
	context.equal(stopped.reason, Types.Code.PROTOCOL_FAILED, "the stopped peer result keeps the exact cause")
	context.equal(mesh.peers[0].status().failure_frame, stopped.failure_frame, "the peer result and the session agree on the failing frame")


func _low_windows(context: RefCounted) -> void:
	for count: int in [2, 3, 8]:
		for window: int in [0, 1, 2]:
			for delay: int in [0, 2]:
				var config: Config = Config.new()
				config.player_count = count
				config.local_players = PackedInt32Array([0])
				config.sync_test = false
				config.check_distance = 0
				config.max_prediction_frames = window
				config.history_slots = window + 1
				config.input_delay = delay
				config.max_snapshot_bytes = 4 * (count + 3)
				config.storage_budget_bytes = 1048576
				var local: T.Message = T.Message.new()
				local.kind = T.Kind.SYNC_REQUEST
				local.sender_id = _id(0)
				local.connection_id = _id(10)
				local.session_id = _id(90, 16)
				local.config.player_count = count
				local.config.max_prediction = window
				local.config.input_delay = delay
				local.config.roster.clear()
				for slot: int in range(count):
					local.config.roster.append(_id(slot))
				var unsupported: bool = count > 2 and (window == 0 or (window == 1 and delay == 0))
				var expected: int = I.Code.INVALID_ARGUMENT if unsupported else I.Code.OK
				var peer: Peer = Peer.new()
				context.equal(
					peer.configure(config, local, Game.new(count), H.Options.new(), I.Options.new()),
					expected,
					"reject nonprogressing mesh count=%d window=%d delay=%d" % [count, window, delay]
				)

	for profile: Array in [[2, 0, 0], [2, 1, 0], [3, 1, 2]]:
		var mesh: Dictionary = _build(context, profile[0], profile[2], false, 128, true, false, profile[1])
		for tick: int in range(12):
			mesh.now += 1000
			for peer: int in range(mesh.peers.size()):
				var result: Driver.StepResult = mesh.peers[peer].step(mesh.now, _inputs(mesh, peer))
				context.equal(result.code in [Types.Code.OK, Types.Code.PREDICTION_STALL], true, "supported low window services inputs")
			_deliver(context, mesh, _drain(mesh))
			_deliver(context, mesh, _drain(mesh))
		for peer: Peer in mesh.peers:
			context.equal(peer.status().current_frame >= 5, true, "supported low window makes healthy progress")
		for game: RefCounted in mesh.games:
			context.equal(game.game.bytes(), mesh.games[0].game.bytes(), "supported low window canonical peer agreement")


func _packet_service(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, 4)
	mesh.now = 1
	_tick(context, mesh)
	_drain(mesh)
	context.equal(mesh.peers[0].poll(200001), I.Code.OK, "retry first dropped flight")
	var incoming: PackedByteArray = PackedByteArray()
	for packet: Peer.Packet in mesh.peers[0].drain_outbox():
		if packet.to == _id(1):
			incoming = packet.bytes
	context.equal(incoming.is_empty(), false, "actual retry delivered to peer one")
	var receiver: Peer = mesh.peers[1]
	context.equal(receiver.receive_and_poll(incoming, _id(0), 200002, null, [false]), I.Code.INVALID_ARGUMENT, "preflight retry tokens")
	context.equal(receiver.network_status().last_now_us, 1, "rejected service preserves clock")
	context.equal(receiver.receive_and_poll(incoming, _id(0), 200002), I.Code.OK, "one delivery services all timers")
	var limits: T.Limits = T.Limits.new()
	limits.player_count = 4
	limits.input_width = 4
	var retries: int = 0
	var acknowledgements: int = 0
	for packet: Peer.Packet in receiver.drain_outbox():
		var decoded: T.Result = Codec.decode(packet.bytes, limits)
		context.equal(decoded.code, T.Code.OK, "service emits valid owned packet")
		if decoded.code != T.Code.OK:
			return
		if decoded.message.kind == T.Kind.INPUT:
			retries += 1
			context.equal(decoded.message.statuses[0].last_frame, -1, "simultaneous retry uses pre-delivery receipt bank")
			context.equal(decoded.message.statuses[1].last_frame, 0, "local scheduled receipt remains visible")
		else:
			acknowledgements += 1
			context.equal(decoded.message.ack_frame, 0, "new input retained before inclusive ACK")
	context.equal(retries, 2, "other two links retry in the same service")
	context.equal(acknowledgements, 1, "accepted input acknowledged once")
	context.equal(receiver.poll(400003), I.Code.OK, "later standalone poll sees current receipts")
	var current: int = 0
	for packet: Peer.Packet in receiver.drain_outbox():
		var decoded: T.Result = Codec.decode(packet.bytes, limits)
		if decoded.message.kind == T.Kind.INPUT:
			current += 1
			context.equal(decoded.message.statuses[0].last_frame, 0, "later retry publishes accepted receipt")
	context.equal(current, 3, "all pending links retry at later boundary")
