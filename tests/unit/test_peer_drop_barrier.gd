extends RefCounted

# Value: the survivors agree the frozen frame of a departed peer; fails_when=the survivors freeze at different frames or the match ends; why_new=coordinated drop; seam=none
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const H = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const L = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
const Game = preload("res://tests/oracle/p2p_game.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(
		["agreed_frame", "lagging_survivor", "held_match", "unconfirmed_fallback", "second_departure", "codec_round_trip", "conflicting_certificate", "stale_messages"]
	)


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"agreed_frame":
			_agreed_frame(context)
		"lagging_survivor":
			_lagging_survivor(context)
		"held_match":
			_held_match(context)
		"unconfirmed_fallback":
			_unconfirmed_fallback(context)
		"second_departure":
			_second_departure(context)
		"codec_round_trip":
			_codec_round_trip(context)
		"conflicting_certificate":
			_conflicting_certificate(context)
		"stale_messages":
			_stale_messages(context)
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


## Peers with the lifecycle enabled, so a silent peer is detected by the timeout.
func _build(context: RefCounted, behavior: int, window: int = 8, count: int = 3) -> Dictionary:
	var peers: Array[Peer] = []
	var games: Array[RefCounted] = []
	for player: int in range(count):
		var config: Config = Config.new()
		config.player_count = count
		config.local_players = PackedInt32Array([player])
		config.input_width = 4
		config.neutral_input = PackedByteArray([0, 0, 0, 0])
		config.input_delay = 0
		config.max_prediction_frames = window
		config.history_slots = 9
		config.check_distance = 0
		config.sync_test = false
		config.max_snapshot_bytes = 4 * 8
		config.storage_budget_bytes = 1048576
		config.replay_max_frames = 64
		var local: T.Message = T.Message.new()
		local.kind = T.Kind.SYNC_REQUEST
		local.sender_id = _id(player)
		local.connection_id = _id(player + 20)
		local.session_id = _id(90, 16)
		local.config.player_count = count
		local.config.input_width = 4
		local.config.input_delay = 0
		local.config.max_prediction = window
		local.config.desync_interval = 60
		local.config.neutral_input = config.neutral_input.duplicate()
		var roster: Array[PackedByteArray] = []
		for slot: int in range(count):
			roster.append(_id(slot))
		local.config.roster = roster
		var handshake: H.Options = H.Options.new()
		handshake.roundtrips = 1
		var input: I.Options = I.Options.new()
		var controls: L.Options = L.Options.new()
		controls.enabled = true
		controls.disconnect_notify_us = 100000
		controls.disconnect_timeout_us = 400000
		controls.keepalive_interval_us = 1000
		controls.quality_report_interval_us = 1000
		controls.disconnect_behavior = behavior
		var game: RefCounted = Game.new(count)
		var peer: Peer = Peer.new()
		context.equal(peer.configure(config, local, game, handshake, input, controls), I.Code.OK, "configure mesh")
		peers.append(peer)
		games.append(game)
	var tokens: Array = []
	for player: int in range(peers.size()):
		var peer_tokens: Array[PackedByteArray] = []
		for remote: PackedByteArray in peers[player].peer_ids():
			peer_tokens.append(_id(remote[0] + player * 8, 16))
		tokens.append(peer_tokens)
	for index: int in range(peers.size()):
		context.equal(peers[index].begin(0, tokens[index]), I.Code.OK, "begin mesh")
	var mesh: Dictionary = {"peers": peers, "games": games, "now": 0, "cuts": {}, "unconfirmed": 0, "reasons": [], "count": count}
	for iteration: int in range(6):
		_deliver(context, mesh, _drain(mesh))
	return mesh


func _inputs(mesh: Dictionary, peer: int) -> Array[Driver.LocalInput]:
	var result: Array[Driver.LocalInput] = []
	var frame: int = mesh.peers[peer].status().current_frame
	result.append(Driver.LocalInput.new(peer, frame, _sample(peer, frame)))
	return result


## Collect the outgoing packets and the bounded event and transition inventories.
func _drain(mesh: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for source: int in range(mesh.peers.size()):
		for packet: Peer.Packet in mesh.peers[source].drain_outbox():
			var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
			result.append({"from": source, "to": packet.to[0] - 1, "bytes": packet.bytes})
		mesh.peers[source].drain_transitions()
		for event: Dictionary in mesh.peers[source].drain_events():
			if event.kind == "peer_dropped":
				mesh.cuts[source] = event.frame
			elif event.kind == "peer_drop_unconfirmed":
				mesh.unconfirmed += 1
				mesh.reasons.append(event.reason)
	return result


func _deliver(context: RefCounted, mesh: Dictionary, packets: Array[Dictionary], terminated: bool = false) -> void:
	for packet: Dictionary in packets:
		var code: int = mesh.peers[packet.to].receive(packet.bytes, _id(packet.from), mesh.now)
		if terminated and code == I.Code.TERMINATED:
			# A closed match refuses further packets.
			continue
		context.equal(code, I.Code.OK, "deliver encoded packet")


## Every peer advances and exchanges packets for the given frames.
func _play(context: RefCounted, mesh: Dictionary, frames: int, keep: bool = false, players: Array[int] = [], dropped: int = -1) -> void:
	var active: Array = []
	if players.is_empty():
		for index: int in range(mesh.peers.size()):
			active.append(index)
	else:
		active = players
	for frame: int in range(frames):
		mesh.now += 1000
		for index: int in active:
			context.equal(mesh.peers[index].step(mesh.now, _inputs(mesh, index)).code, Types.Code.OK, "advance peer")
		if not keep:
			for game: RefCounted in mesh.games:
				game.requests.clear()
		_deliver(context, mesh, _without_peer(_drain(mesh), dropped))
		_deliver(context, mesh, _without_peer(_drain(mesh), dropped))


## The packets of a departed peer never reach the survivors again.
func _without_peer(packets: Array[Dictionary], dropped: int) -> Array[Dictionary]:
	if dropped < 0:
		return packets
	var result: Array[Dictionary] = []
	for packet: Dictionary in packets:
		if packet.from == dropped or packet.to == dropped:
			continue
		result.append(packet)
	return result


## The departed peer goes silent while the survivors keep their own links alive.
func _leave(context: RefCounted, mesh: Dictionary, departed: int) -> void:
	for frame: int in range(3):
		mesh.now += 1000
		mesh.peers[departed].step(mesh.now, _inputs(mesh, departed))
		_deliver(context, mesh, _drain(mesh))


## The survivors keep their links alive until the silent peer reaches its timeout.
## The silent peer receives nothing more, so it stops answering and its links expire.
func _detect(
	context: RefCounted,
	mesh: Dictionary,
	survivors: Array[int],
	elapsed: int = 600000,
	deliver_acks: bool = true,
	alterations: Array[Dictionary] = [],
	injections: Array[Dictionary] = [],
	terminated: bool = false
) -> void:
	var waited: int = 0
	var pending: Array[Dictionary] = injections.duplicate()
	while waited < elapsed:
		mesh.now += 1000
		waited += 1000
		for survivor: int in survivors:
			var polled: int = mesh.peers[survivor].poll(mesh.now)
			if terminated and polled == I.Code.TERMINATED:
				continue
			context.equal(polled, I.Code.OK, "poll the survivor")
		var packets: Array[Dictionary] = []
		for packet: Dictionary in _drain(mesh):
			if not survivors.has(packet.to) or not survivors.has(packet.from):
				# The departed peer receives nothing more and stops answering.
				continue
			packets.append(packet)
		if not deliver_acks:
			packets = _without_acks(packets, mesh.count)
		packets = _alter(context, mesh, packets, alterations)
		if not pending.is_empty() and _barrier_started(mesh, survivors):
			for injection: Dictionary in pending:
				_inject(context, mesh, injection)
			pending.clear()
		_deliver(context, mesh, packets, terminated)


## True once the survivors hold a coordinated drop barrier for the departed peer.
func _barrier_started(mesh: Dictionary, survivors: Array[int]) -> bool:
	for survivor: int in survivors:
		if mesh.peers[survivor]._drops.has_barrier(_id(2).hex_encode()):
			return true
	return false


## Deliver one altered copy of every barrier message that matches an alteration.
## A replaced message never reaches its recipient; an extra message is delivered beside it.
func _alter(context: RefCounted, mesh: Dictionary, packets: Array[Dictionary], alterations: Array[Dictionary]) -> Array[Dictionary]:
	if alterations.is_empty():
		return packets
	var result: Array[Dictionary] = []
	for packet: Dictionary in packets:
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
		var matched: Dictionary = {}
		if decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER:
			for alteration: Dictionary in alterations:
				if int(alteration["phase"]) == decoded.message.phase and int(alteration["stage"]) == decoded.message.stage:
					matched = alteration
					break
		if matched.is_empty():
			result.append(packet)
			continue
		for field: String in matched["fields"]:
			decoded.message.set(field, matched["fields"][field])
		var encoded: T.Result = Codec.encode(decoded.message, _limits(mesh.count))
		context.equal(encoded.code, T.Code.OK, "encode the altered barrier")
		var altered: Dictionary = {"from": packet.from, "to": packet.to, "bytes": encoded.bytes}
		if bool(matched.get("replace", false)):
			result.append(altered)
		else:
			result.append(packet)
			result.append(altered)
	return result


## Deliver one synthetic barrier message to a survivor.
func _inject(context: RefCounted, mesh: Dictionary, injection: Dictionary) -> void:
	var fields: Variant = injection["fields"]
	if fields is Callable:
		fields = fields.call()
	var message: T.Message = T.Message.new()
	message.kind = T.Kind.DROP_BARRIER
	message.session_id = _id(90, 16)
	message.sender_id = _id(int(injection["from"]))
	message.connection_id = _id(int(injection["from"]) + 20)
	message.data = PackedByteArray([2, 3, 0])
	for field: String in fields:
		message.set(field, fields[field])
	var encoded: T.Result = Codec.encode(message, _limits(mesh.count))
	context.equal(encoded.code, T.Code.OK, "encode the injected barrier")
	context.equal(mesh.peers[int(injection["to"])].receive(encoded.bytes, _id(int(injection["from"])), mesh.now), I.Code.OK, "deliver the injected barrier")


## The answer of a survivor carries the answer phase of the coordinated drop.
func _without_acks(packets: Array[Dictionary], count: int) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for packet: Dictionary in packets:
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(count))
		if decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER and decoded.message.phase == 2:
			continue
		result.append(packet)
	return result


func _limits(count: int = 3) -> T.Limits:
	var limits: T.Limits = T.Limits.new()
	limits.player_count = count
	limits.input_width = 4
	limits.max_packet_bytes = 65536
	limits.max_input_frames = 128
	return limits


## The frame every survivor froze the departed slot at.
func _cuts(mesh: Dictionary, survivors: Array[int]) -> Array[int]:
	var result: Array[int] = []
	for survivor: int in survivors:
		result.append(mesh.cuts.get(survivor, -1))
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


## The survivors agree one frame for the departed slot and keep the same frozen value.
func _agreed_frame(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE)
	_play(context, mesh, 6, true)
	_leave(context, mesh, 2)
	_detect(context, mesh, [0, 1])
	var cuts: Array[int] = _cuts(mesh, [0, 1])
	context.equal(cuts[0] >= 0, true, "the first survivor publishes the drop")
	context.equal(cuts[1], cuts[0], "both survivors freeze the same frame")
	for survivor: int in [0, 1]:
		context.equal(mesh.peers[survivor].status().lifecycle, Types.Lifecycle.RUNNING, "the match survives the departure")
		context.equal(mesh.peers[survivor].status().reason, Types.Code.OK, "no terminal cause")
	# The survivors resimulate the frames after the agreed frame with the frozen value.
	_play(context, mesh, 4, true, [0, 1], 2)
	var rows_first: Dictionary = _rows(mesh.games[0])
	var rows_second: Dictionary = _rows(mesh.games[1])
	var cut: int = cuts[0]
	context.equal(rows_first.has(cut + 1), true, "the first survivor resimulates past the agreed frame")
	for frame: int in range(cut + 1, mini(rows_first.size(), rows_second.size())):
		context.equal(rows_first[frame][2].bytes, rows_second[frame][2].bytes, "the survivors simulate the same frozen value")
		context.equal(rows_first[frame][2].status, "disconnected", "the departed slot reports a disconnected status")
		context.equal(rows_second[frame][2].status, "disconnected", "the other survivor reports a disconnected status")


## A survivor that lags still agrees the frame the other survivor can freeze.
func _lagging_survivor(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE)
	_play(context, mesh, 6, true)
	_leave(context, mesh, 2)
	# The second survivor stops stepping, so its confirmed frontier trails the first one.
	mesh.now += 1000
	mesh.peers[0].step(mesh.now, _inputs(mesh, 0))
	_detect(context, mesh, [0, 1])
	var cuts: Array[int] = _cuts(mesh, [0, 1])
	context.equal(cuts[0] >= 0, true, "the first survivor publishes the drop")
	context.equal(cuts[1], cuts[0], "the lagging survivor agrees the frame")


## The match holds while the survivors agree the frozen frame.
func _held_match(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE)
	_play(context, mesh, 6, true)
	_leave(context, mesh, 2)
	var held_frame: int = -1
	var held: int = 0
	var waited: int = 0
	while waited < 600000:
		mesh.now += 1000
		waited += 1000
		for survivor: int in [0, 1]:
			mesh.peers[survivor].poll(mesh.now)
		if held_frame < 0 and mesh.peers[0]._drops.has_barrier(_id(2).hex_encode()):
			held_frame = mesh.peers[0].status().current_frame
		for survivor: int in [0, 1]:
			var code: int = mesh.peers[survivor].step(mesh.now, _inputs(mesh, survivor)).code
			if held_frame >= 0 and code == Types.Code.PREDICTION_STALL:
				held += 1
				context.equal(mesh.peers[survivor].status().current_frame, held_frame, "the held match does not advance")
		var packets: Array[Dictionary] = []
		for packet: Dictionary in _drain(mesh):
			if packet.to == 2 or packet.from == 2:
				continue
			packets.append(packet)
		_deliver(context, mesh, packets)
	context.equal(held_frame >= 0, true, "the coordinated drop starts")
	context.equal(held > 0, true, "the match holds while the survivors agree")


## A barrier that never completes leaves the survivors on their own frontier and says so.
func _unconfirmed_fallback(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE)
	_play(context, mesh, 6, true)
	_leave(context, mesh, 2)
	# The answers never arrive, so the barrier reaches its timeout.
	_detect(context, mesh, [0, 1], 800000, false)
	context.equal(mesh.cuts.size() > 0, true, "the survivors still keep the match running")
	context.equal(mesh.unconfirmed > 0, true, "the survivors report the missing agreement")


## A departure after the owner of the lowest slot left still agrees one frame.
func _second_departure(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE, 8, 4)
	_play(context, mesh, 6, true)
	# The owner of the lowest slot leaves first, so the next departure has no owner of
	# the lowest surviving slot among the peers that are still in the match.
	_leave(context, mesh, 0)
	_detect(context, mesh, [1, 2, 3])
	_leave(context, mesh, 1)
	_detect(context, mesh, [2, 3], 800000)
	var cuts: Array[int] = _cuts(mesh, [2, 3])
	context.equal(cuts[0] >= 0, true, "the second survivor publishes the drop")
	context.equal(cuts[1], cuts[0], "the remaining survivors freeze the same frame")
	context.equal(mesh.unconfirmed, 0, "both departures agree without a fallback")
	for survivor: int in [2, 3]:
		context.equal(mesh.peers[survivor].status().lifecycle, Types.Lifecycle.RUNNING, "the match survives both departures")

## The barrier message keeps its operation identity, its stage and its frozen value on the wire.
func _codec_round_trip(context: RefCounted) -> void:
	var limits: T.Limits = _limits()
	var message: T.Message = T.Message.new()
	message.kind = T.Kind.DROP_BARRIER
	message.phase = 2
	message.stage = 2
	message.reason = 3
	message.coordinator = 1
	message.coordinator_generation = 2
	message.operation = 7
	message.target_set_digest = 11
	message.cut = 42
	message.bound = 11
	message.available_through = 40
	message.cut_digest = 13
	message.chunk_index = 1
	message.chunk_count = 2
	message.data = PackedByteArray([2, 3, 0])
	message.bytes = PackedByteArray([9, 8])
	var encoded: T.Result = Codec.encode(message, limits)
	context.equal(encoded.code, T.Code.OK, "encode the barrier")
	var decoded: T.Result = Codec.decode(encoded.bytes, limits)
	context.equal(decoded.code, T.Code.OK, "decode the barrier")
	context.equal(decoded.message.kind, T.Kind.DROP_BARRIER, "the barrier keeps its kind")
	context.equal(decoded.message.phase, 2, "the barrier keeps its phase")
	context.equal(decoded.message.stage, 2, "the barrier keeps its stage")
	context.equal(decoded.message.reason, 3, "the barrier keeps its reason")
	context.equal(decoded.message.coordinator, 1, "the barrier keeps its coordinator")
	context.equal(decoded.message.coordinator_generation, 2, "the barrier keeps the coordinator era")
	context.equal(decoded.message.operation, 7, "the barrier keeps its operation")
	context.equal(decoded.message.target_set_digest, 11, "the barrier keeps its target digest")
	context.equal(decoded.message.cut, 42, "the barrier keeps its cut")
	context.equal(decoded.message.bound, 11, "the barrier keeps its bound")
	context.equal(decoded.message.available_through, 40, "the barrier keeps its retained range")
	context.equal(decoded.message.cut_digest, 13, "the barrier keeps the frozen value's digest")
	context.equal(decoded.message.chunk_index, 1, "the barrier keeps its chunk index")
	context.equal(decoded.message.chunk_count, 2, "the barrier keeps its chunk count")
	context.equal(decoded.message.data, PackedByteArray([2, 3, 0]), "the barrier keeps its target list")
	context.equal(decoded.message.bytes, PackedByteArray([9, 8]), "the barrier keeps its frozen value")
	# An unknown phase, an unknown stage and a malformed target list are refused.
	var invalid: T.Message = T.Message.new()
	invalid.kind = T.Kind.DROP_BARRIER
	invalid.phase = 9
	invalid.operation = 1
	invalid.cut = 1
	invalid.bound = 0
	invalid.data = PackedByteArray([0, 0, 0])
	context.equal(Codec.encode(invalid, limits).code, T.Code.INVALID_MESSAGE, "an unknown phase is refused")
	var unknown_stage: T.Message = T.Message.new()
	unknown_stage.kind = T.Kind.DROP_BARRIER
	unknown_stage.phase = 1
	unknown_stage.stage = 7
	unknown_stage.operation = 1
	unknown_stage.cut = 1
	unknown_stage.bound = 0
	unknown_stage.data = PackedByteArray([0, 0, 0])
	context.equal(Codec.encode(unknown_stage, limits).code, T.Code.INVALID_MESSAGE, "an unknown stage is refused")
	var empty: T.Message = T.Message.new()
	empty.kind = T.Kind.DROP_BARRIER
	empty.phase = 1
	empty.operation = 1
	empty.cut = 1
	empty.bound = 0
	empty.data = PackedByteArray()
	context.equal(Codec.encode(empty, limits).code, T.Code.INVALID_MESSAGE, "an empty target list is refused")
	var unordered: T.Message = T.Message.new()
	unordered.kind = T.Kind.DROP_BARRIER
	unordered.phase = 1
	unordered.operation = 1
	unordered.cut = 1
	unordered.bound = 0
	unordered.data = PackedByteArray([2, 0, 0, 1, 0, 0])
	context.equal(Codec.encode(unordered, limits).code, T.Code.INVALID_MESSAGE, "an unordered target list is refused")


## A certificate that names another value ends the match instead of freezing divergent values.
func _conflicting_certificate(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE)
	_play(context, mesh, 6, true)
	_leave(context, mesh, 2)
	# The certificate of one survivor names another value.
	_detect(context, mesh, [0, 1], 600000, true, [{"phase": 2, "stage": 2, "fields": {"cut_digest": 1}, "replace": true}], [], true)
	context.equal(mesh.reasons.has("conflicting_history"), true, "the survivors report the conflicting history")
	for survivor: int in [0, 1]:
		context.equal(mesh.peers[survivor].status().lifecycle, Types.Lifecycle.TERMINATED, "the match ends instead of freezing divergent values")
		context.equal(mesh.peers[survivor].status().reason, Types.Code.PROTOCOL_FAILED, "the terminal cause is the conflicting history")


## The barrier of the departed peer, read when a message is built.
func _barrier(mesh: Dictionary) -> Variant:
	return mesh.peers[0]._drops.barrier(_id(2).hex_encode())


## The operation identity of the current barrier and the target list it names.
func _identity_fields(mesh: Dictionary) -> Dictionary:
	var barrier: Variant = _barrier(mesh)
	var era: int = barrier.generations[0]
	return {
		"phase": 1,
		"operation": barrier.operation,
		"target_set_digest": barrier.target_set_digest,
		"coordinator": barrier.coordinator,
		"coordinator_generation": barrier.coordinator_generation,
		"data": PackedByteArray([2, era & 255, (era >> 8) & 255]),
	}


## A prepare of an operation that already closed.
func _stale_operation_fields(mesh: Dictionary) -> Dictionary:
	var fields: Dictionary = _identity_fields(mesh)
	fields["operation"] = int(fields["operation"]) - 1
	fields["target_set_digest"] = 0
	return fields


## A prepare of another connected era.
func _other_era_fields(mesh: Dictionary) -> Dictionary:
	var fields: Dictionary = _identity_fields(mesh)
	var era: int = _barrier(mesh).generations[0]
	fields["data"] = PackedByteArray([2, (era + 1) & 255, (era >> 8) & 255])
	fields["cut"] = 2
	fields["cut_digest"] = 999
	return fields


## A prepare of another target set.
func _other_target_fields(mesh: Dictionary) -> Dictionary:
	var fields: Dictionary = _identity_fields(mesh)
	fields["target_set_digest"] = int(fields["target_set_digest"]) + 1
	fields["cut"] = 2
	fields["cut_digest"] = 999
	return fields


## A proposal from a survivor that does not own the lowest surviving slot.
func _foreign_proposal_fields(mesh: Dictionary) -> Dictionary:
	var fields: Dictionary = _identity_fields(mesh)
	fields["cut"] = 2
	fields["cut_digest"] = 999
	return fields


## A commit that names a frame the survivor never certified.
func _uncertified_commit_fields(mesh: Dictionary) -> Dictionary:
	var fields: Dictionary = _identity_fields(mesh)
	fields["phase"] = 4
	fields["cut"] = 2
	fields["cut_digest"] = 5
	return fields


## A stale operation, a stale era and a commit without a certificate change nothing.
func _stale_messages(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE)
	_play(context, mesh, 6, true)
	_leave(context, mesh, 2)
	var injections: Array[Dictionary] = [
		# A stale operation.
		{"to": 1, "from": 0, "fields": _stale_operation_fields.bind(mesh)},
		# A prepare of another connected era.
		{"to": 1, "from": 0, "fields": _other_era_fields.bind(mesh)},
		# A prepare of another target set.
		{"to": 1, "from": 0, "fields": _other_target_fields.bind(mesh)},
		# A proposal from a survivor that does not own the lowest surviving slot.
		{"to": 0, "from": 1, "fields": _foreign_proposal_fields.bind(mesh)},
		# A commit without a certificate.
		{"to": 1, "from": 0, "fields": _uncertified_commit_fields.bind(mesh)},
	]
	_detect(context, mesh, [0, 1], 600000, true, [{"phase": 2, "stage": 2, "fields": {"cut_digest": 7}, "replace": false}], injections)
	var cuts: Array[int] = _cuts(mesh, [0, 1])
	context.equal(cuts[0] >= 0, true, "the first survivor publishes the drop")
	context.equal(cuts[1], cuts[0], "both survivors freeze the same frame")
	context.equal(mesh.unconfirmed, 0, "the stale messages change no agreement")
	for survivor: int in [0, 1]:
		context.equal(mesh.peers[survivor].status().lifecycle, Types.Lifecycle.RUNNING, "the match survives the stale messages")
	# The duplicated certificate never replaces the certified value.
	var proposer: Variant = mesh.peers[0]._drops.barrier(_id(2).hex_encode())
	context.equal(proposer.certificates.size(), 1, "the certificate is counted once")
	context.equal(int(proposer.certificates.values()[0]["digest"]), int(proposer.digest), "the certificate names the certified value")
	context.equal(int(proposer.certificates.values()[0]["cut"]), int(proposer.cut), "the certificate names the certified frame")
	# The unauthorized commit never moves the certified frame of the survivor.
	var follower: Variant = mesh.peers[1]._drops.barrier(_id(2).hex_encode())
	context.equal(int(follower.cut), int(proposer.cut), "the survivor keeps the certified frame")
