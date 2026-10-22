extends RefCounted

# Value: the survivors of one coordinated drop agree one frame and one frozen value and keep one confirmed history;
# fails_when=the survivors disagree on the frame or the value, or the match ends; why_new=the coordinated drop needs two survivors;
# seam=none
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const H = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const L = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")
const Game = preload("res://tests/oracle/p2p_game.gd")

## Three players, so one departure leaves two survivors that must agree with each other.
const PLAYERS: int = 3
const WINDOW: int = 8
## The silence of a departed peer is noticed after this long without an answer.
const DISCONNECT_TIMEOUT_US: int = 800000
## The barrier must finish inside this window, and it never exceeds the disconnect timeout.
const BARRIER_TIMEOUT_US: int = 700000
## One service round. The barrier retries on the same interval.
const ROUND_US: int = 50000
## Rounds of silence that outlast the disconnect timeout, plus the rounds of the barrier.
const SILENCE_ROUNDS: int = 30


func cases() -> PackedStringArray:
	return PackedStringArray(["agreed_frame", "one_history", "second_departure"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"agreed_frame":
			_agreed_frame(context)
		"one_history":
			_one_history(context)
		"second_departure":
			_second_departure(context)
	context.finish()


func _id(value: int, width: int = 8) -> PackedByteArray:
	var result: PackedByteArray = PackedByteArray()
	result.resize(width)
	result[0] = value + 1
	return result


## A varying sample, so a prediction can disagree with the input that arrives later.
func _sample(player: int, frame: int) -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray([0, 0, 0, 0])
	bytes.encode_s32(0, (frame % 7 + 1) * (player + 1))
	return bytes


## Three peers with the lifecycle enabled, so a silent peer is detected by the timeout.
func _build(context: RefCounted, behavior: int) -> Dictionary:
	var peers: Array[Peer] = []
	var games: Array[RefCounted] = []
	for player: int in range(PLAYERS):
		var config: Config = Config.new()
		config.player_count = PLAYERS
		config.local_players = PackedInt32Array([player])
		config.input_width = 4
		config.neutral_input = PackedByteArray([0, 0, 0, 0])
		config.input_delay = 0
		config.max_prediction_frames = WINDOW
		config.history_slots = WINDOW + 1
		config.check_distance = 0
		config.sync_test = false
		config.max_snapshot_bytes = 4 * (PLAYERS + 1) + 8
		config.storage_budget_bytes = 1048576
		config.replay_max_frames = 64
		var local: T.Message = T.Message.new()
		local.kind = T.Kind.SYNC_REQUEST
		local.sender_id = _id(player)
		local.connection_id = _id(player + 20)
		local.session_id = _id(90, 16)
		local.config.player_count = PLAYERS
		local.config.input_width = 4
		local.config.input_delay = 0
		local.config.max_prediction = WINDOW
		local.config.desync_interval = 60
		local.config.neutral_input = config.neutral_input.duplicate()
		local.config.roster = [_id(0), _id(1), _id(2)]
		var handshake: H.Options = H.Options.new()
		handshake.roundtrips = 1
		var input: I.Options = I.Options.new()
		var controls: L.Options = L.Options.new()
		controls.enabled = true
		controls.disconnect_notify_us = 100000
		controls.disconnect_timeout_us = DISCONNECT_TIMEOUT_US
		controls.drop_barrier_timeout_us = BARRIER_TIMEOUT_US
		controls.keepalive_interval_us = 1000
		controls.quality_report_interval_us = 1000
		controls.disconnect_behavior = behavior
		var game: RefCounted = Game.new(PLAYERS)
		var peer: Peer = Peer.new()
		context.equal(peer.configure(config, local, game, handshake, input, controls), I.Code.OK, "configure mesh")
		peers.append(peer)
		games.append(game)
	var tokens: Array = []
	for peer: Peer in peers:
		var peer_tokens: Array[PackedByteArray] = []
		for remote: PackedByteArray in peer.peer_ids():
			peer_tokens.append(_id(remote[0] + 1, 16))
		tokens.append(peer_tokens)
	for index: int in range(peers.size()):
		context.equal(peers[index].begin(0, tokens[index]), I.Code.OK, "begin mesh")
	var mesh: Dictionary = {"peers": peers, "games": games, "now": 0, "departed": -1}
	for _round: int in range(12):
		_deliver(context, mesh, _drain(mesh))
	return mesh


func _inputs(mesh: Dictionary, peer: int) -> Array[Driver.LocalInput]:
	var result: Array[Driver.LocalInput] = []
	var frame: int = mesh.peers[peer].status().current_frame
	result.append(Driver.LocalInput.new(peer, frame, _sample(peer, frame)))
	return result


func _drain(mesh: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for source: int in range(mesh.peers.size()):
		for packet: Peer.Packet in mesh.peers[source].drain_outbox():
			result.append({"from": source, "to": packet.to[0] - 1, "bytes": packet.bytes})
	return result


## A departed peer stops answering, so its packets never reach the survivors.
func _deliver(context: RefCounted, mesh: Dictionary, packets: Array[Dictionary]) -> void:
	for packet: Dictionary in packets:
		if int(packet["from"]) == int(mesh["departed"]):
			continue
		context.equal(mesh.peers[packet.to].receive(packet.bytes, _id(packet.from), mesh.now), I.Code.OK, "deliver encoded packet")


## Every peer plays one frame. A stalled frame is allowed while the survivors agree.
func _play(context: RefCounted, mesh: Dictionary, frames: int, active: PackedInt32Array) -> void:
	for _frame: int in range(frames):
		mesh.now += ROUND_US
		for index: int in active:
			var stepped: Driver.StepResult = mesh.peers[index].step(mesh.now, _inputs(mesh, index))
			context.equal(stepped.code in [Types.Code.OK, Types.Code.PREDICTION_STALL], true, "advance peer %d" % index)
		_deliver(context, mesh, _drain(mesh))
		_deliver(context, mesh, _drain(mesh))


## Every peer services its transport. The barrier runs on the same clock.
func _service(context: RefCounted, mesh: Dictionary, rounds: int, active: PackedInt32Array) -> void:
	for _round: int in range(rounds):
		mesh.now += ROUND_US
		for index: int in active:
			context.equal(mesh.peers[index].poll(mesh.now), I.Code.OK, "poll peer %d" % index)
		_deliver(context, mesh, _drain(mesh))


## The peers that stay in the match.
func _others(departed: int) -> PackedInt32Array:
	var result: PackedInt32Array = PackedInt32Array()
	for index: int in range(PLAYERS):
		if index != departed:
			result.append(index)
	return result


## One peer stops answering. The survivors notice the silence and agree the frozen frame.
func _depart(context: RefCounted, mesh: Dictionary, departed: int) -> PackedInt32Array:
	mesh["departed"] = departed
	var survivors: PackedInt32Array = _others(departed)
	# The silence lasts longer than the disconnect timeout, and the survivors keep their own link alive.
	_service(context, mesh, SILENCE_ROUNDS, survivors)
	return survivors


## The frame every survivor froze, keyed by the peer that published it.
## A survivor that starts the coordinated drop publishes the pending frame first.
func _drops(mesh: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for index: int in range(PLAYERS):
		for event: Dictionary in mesh.peers[index].drain_events():
			if event.kind == "peer_dropped":
				var entry: Dictionary = result.get(index, {})
				entry["frame"] = int(event.frame)
				result[index] = entry
			elif event.kind == "peer_drop_pending":
				var entry: Dictionary = result.get(index, {})
				entry["pending"] = int(event.frame)
				result[index] = entry
	return result


## The input rows the game actually simulated, keyed by frame.
func _rows(game: RefCounted) -> Dictionary:
	var result: Dictionary = {}
	for request: Dictionary in game.requests:
		if request.kind != "advance":
			continue
		var row: Array = []
		for input: Dictionary in request.inputs:
			row.append({"bytes": input.bytes, "status": input.status})
		result[request.frame] = row
	return result


## The two survivors agree one frame and one frozen value.
func _agreed_frame(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE)
	_play(context, mesh, 6, PackedInt32Array([0, 1, 2]))
	_depart(context, mesh, 2)
	var dropped: Dictionary = _drops(mesh)
	context.equal(dropped.has(0), true, "the first survivor publishes the drop")
	context.equal(dropped.has(1), true, "the second survivor publishes the drop")
	if not dropped.has(0) or not dropped.has(1):
		return
	# The survivors coordinated the drop instead of freezing their own frontiers.
	context.equal(dropped[0].has("pending"), true, "the first survivor starts the coordinated drop")
	context.equal(dropped[1].has("pending"), true, "the second survivor starts the coordinated drop")
	context.equal(int(dropped[0]["frame"]), int(dropped[1]["frame"]), "the survivors agree the frozen frame")
	context.equal(int(dropped[0]["frame"]) >= 0, true, "the agreed frame is a real frame")
	for index: int in [0, 1]:
		context.equal(mesh.peers[index].status().lifecycle, Types.Lifecycle.RUNNING, "survivor %d keeps running" % index)


## The survivors keep one confirmed history after the drop.
func _one_history(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE)
	_play(context, mesh, 6, PackedInt32Array([0, 1, 2]))
	var survivors: PackedInt32Array = _depart(context, mesh, 2)
	var dropped: Dictionary = _drops(mesh)
	context.equal(dropped.size(), 2, "both survivors publish the drop")
	var before: Array[int] = []
	var confirmed_before: Array[int] = []
	for index: int in survivors:
		before.append(mesh.peers[index].status().current_frame)
		confirmed_before.append(mesh.peers[index].status().confirmed_frame)
	_play(context, mesh, 12, survivors)
	for index: int in survivors:
		context.equal(mesh.peers[index].status().lifecycle, Types.Lifecycle.RUNNING, "survivor %d keeps running" % index)
		context.equal(mesh.peers[index].status().current_frame > before[index], true, "survivor %d keeps advancing" % index)
		context.equal(mesh.peers[index].status().confirmed_frame > confirmed_before[index], true, "survivor %d confirms more frames" % index)
		context.equal(mesh.peers[index].status().reason, Types.Code.OK, "survivor %d has no terminal cause" % index)
	var rows: Array[Dictionary] = []
	for index: int in survivors:
		rows.append(_rows(mesh.games[index]))
	var shared: int = mini(mesh.peers[survivors[0]].status().confirmed_frame, mesh.peers[survivors[1]].status().confirmed_frame)
	context.equal(shared > 0, true, "the survivors confirmed a shared history")
	# The simulated row of the confirmed frontier may still hold a predicted input, because the
	# correction that confirms it arrives with the next step. The confirmed history itself is the
	# replayed row, and it is compared for every confirmed frame below.
	var compared: int = 0
	for frame: int in range(shared):
		if not rows[0].has(frame) or not rows[1].has(frame):
			continue
		for slot: int in range(PLAYERS):
			context.equal(rows[1][frame][slot]["bytes"], rows[0][frame][slot]["bytes"], "the survivors agree the row at frame %d slot %d" % [frame, slot])
			compared += 1
	context.equal(compared > 0, true, "the survivors compared their simulated rows")
	# The confirmed history is the row the session itself confirmed, not the simulated one.
	var replays: Array[RefCounted] = []
	for index: int in survivors:
		replays.append(mesh.peers[index].replay())
	var confirmed: int = 0
	for frame: int in range(shared + 1):
		var first: Variant = replays[0].inputs(frame)
		var second: Variant = replays[1].inputs(frame)
		if first == null or second == null:
			continue
		for slot: int in range(PLAYERS):
			context.equal(second.read(slot).bytes, first.read(slot).bytes, "the survivors confirm the same input at frame %d slot %d" % [frame, slot])
			confirmed += 1
	context.equal(confirmed > 0, true, "the survivors compared their confirmed rows")


## A second departure leaves one survivor, which freezes the slot on its own frontier.
func _second_departure(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE)
	_play(context, mesh, 6, PackedInt32Array([0, 1, 2]))
	_depart(context, mesh, 2)
	var dropped: Dictionary = _drops(mesh)
	context.equal(dropped.size(), 2, "both survivors publish the first drop")
	_service(context, mesh, 2, PackedInt32Array([0, 1]))
	_depart(context, mesh, 1)
	_service(context, mesh, 4, PackedInt32Array([0]))
	var second: Dictionary = _drops(mesh)
	context.equal(second.has(0), true, "the last survivor publishes the second drop")
	if second.has(0):
		# The last survivor has nobody to agree with, so it freezes on its own frontier.
		context.equal(int(second[0]["frame"]), mesh.peers[0].status().confirmed_frame,
			"the last survivor freezes on its own frontier")
	context.equal(mesh.peers[0].status().lifecycle, Types.Lifecycle.RUNNING, "the last survivor keeps running")
