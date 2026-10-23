extends "res://tests/unit/test_peer_drop_barrier.gd"

# Value: protects=real donor bytes recover complete history before commit; fails_when=missing chunks, identity or conflicting overlaps authorize a freeze;
# why_new=equal retained inventories never transfer historical rows; seam=none
const Drop = preload("res://addons/fortress_rollback/core/peer_drop_barrier.gd")

var _mode: String = ""
var _missing_peer: int = 0
var _seen: int = 0
var _dropped_chunk: bool = false
var _reordered: bool = false
var _held: Dictionary = {}
var _donor_sources: Dictionary = {}
var _width: int = 1028
var _window: int = 8
var _slots: int = 1


class WideGame:
	extends RefCounted
	const D = preload("res://addons/fortress_rollback/core/driver.gd")
	const S = preload("res://addons/fortress_rollback/core/session_types.gd")
	var frame: int = 0
	var values: PackedInt64Array = PackedInt64Array()
	var states: Dictionary = {}
	var requests: Array[Dictionary] = []

	func _init(players: int = 3) -> void:
		values.resize(players)
		values.fill(0)

	func bytes() -> PackedByteArray:
		var state: PackedByteArray = PackedByteArray()
		state.resize(8 * (values.size() + 1))
		state.encode_s64(0, frame)
		for player: int in values.size():
			state.encode_s64(8 + player * 8, values[player])
		return state

	func save_state(at: int, writer: RefCounted) -> D.SaveResult:
		var checksum: PackedByteArray = PackedByteArray()
		checksum.resize(16)
		return D.SaveResult.new(at == frame and writer.write_bytes(bytes()) == 0, checksum)

	func load_state(at: int, reader: RefCounted) -> bool:
		var loaded: RefCounted = reader.read_bytes(8 * (values.size() + 1))
		if loaded.code != 0 or not reader.is_complete() or loaded.bytes.decode_s64(0) != at:
			return false
		frame = at
		for player: int in values.size():
			values[player] = loaded.bytes.decode_s64(8 + player * 8)
		return true

	func simulate_frame(at: int, inputs: S.FrameInputs) -> bool:
		if at != frame:
			return false
		for player: int in values.size():
			for value: int in inputs.read(player).bytes:
				values[player] += value
		frame += 1
		states[at] = bytes()
		requests.append({"kind": "advance", "frame": at})
		return true


func cases() -> PackedStringArray:
	return PackedStringArray([
		"remote_donor", "loss_reorder", "conflicting_duplicate", "malformed_chunk", "wrong_donor",
		"lost_history_timeout", "resource_limit", "multiple_target_slots", "no_donor", "conflicting_overlap",
	])


func run_case(name: String, context: RefCounted) -> void:
	_mode = name
	_window = 128 if name == "resource_limit" else 8
	_slots = 2 if name == "multiple_target_slots" else 1
	_missing_peer = 0 if name in ["remote_donor", "no_donor"] else 1
	_seen = 0
	_dropped_chunk = false
	_reordered = false
	_held.clear()
	_donor_sources.clear()
	var mesh: Dictionary = _wide_mesh(context)
	_play(context, mesh, 6, true)
	for departure: int in range(22 if name == "resource_limit" else 1):
		_leave(context, mesh, 2)
	context.equal(mesh.peers[_missing_peer]._core.received_frames()[2 * _slots], 7, "the recipient genuinely lacks target frame eight")
	context.equal(mesh.peers[1 - _missing_peer]._core.received_frames()[2 * _slots], 71 if name == "resource_limit" else 8, "the other survivor retains the missing original row")
	_detect(context, mesh, [0, 1], 800000, true, [], [], true)
	context.equal(_seen > 0, name not in ["resource_limit", "no_donor"], "only a bounded journal may publish historical bytes")
	if name in ["remote_donor", "loss_reorder", "multiple_target_slots"]:
		for survivor: int in [0, 1]:
			context.equal(mesh.peers[survivor].status().lifecycle, Types.Lifecycle.RUNNING, "complete transferred history keeps the match running")
			for slot: int in range(2 * _slots, 3 * _slots):
				context.equal(mesh.peers[survivor]._core.frozen_frame(slot), 8, "each survivor commits every target slot at the receipt-raised cut")
				context.equal(mesh.peers[survivor]._core.retained_input(slot, 8), _sample(slot, 8), "every byte of each missing target row is installed before freeze")
		context.equal(_donor_sources.keys(), [1 - _missing_peer], "only the selected survivor supplies donor bytes")
		if name == "remote_donor":
			context.equal(mesh.peers[0]._drops.barrier(_id(2).hex_encode()).history.donor, 1, "the coordinator selects a different donor")
		elif name == "loss_reorder":
			context.equal(_dropped_chunk, true, "one original chunk was physically omitted")
			context.equal(_reordered, true, "the later retry arrived after its successor")
		_play(context, mesh, 6, true, [0, 1], 2)
		var through: int = mini(mesh.peers[0].status().confirmed_frame, mesh.peers[1].status().confirmed_frame) - 1
		context.equal(through > 8, true, "the repaired game continues beyond the cut")
		var expected: PackedByteArray = _expected(through, 8)
		for survivor: int in [0, 1]:
			context.equal(mesh.games[survivor].states[through], expected, "canonical game bytes equal independently reconstructed original inputs")
	else:
		context.equal(mesh.cuts.is_empty(), true, "invalid or incomplete history never authorizes a commit")
		for survivor: int in [0, 1]:
			context.equal(mesh.peers[survivor]._core.frozen_frame(2 * _slots), -1, "failed recovery leaves the target unfrozen")
			context.equal(mesh.peers[survivor].status().lifecycle, Types.Lifecycle.TERMINATED, "failed historical recovery terminates explicitly")
		var expected_reason: String = {
			"conflicting_duplicate": "conflicting_history", "malformed_chunk": "conflicting_history", "wrong_donor": "conflicting_history",
			"conflicting_overlap": "conflicting_history", "lost_history_timeout": "timeout", "no_donor": "missing_history", "resource_limit": "resource_limit",
		}[name]
		context.equal(mesh.reasons.is_empty(), false, "historical recovery publishes its refusal cause")
		for reason: String in mesh.reasons:
			context.equal(reason, expected_reason, "each survivor reports the intended historical recovery fault")
		if name == "conflicting_overlap":
			context.equal(mesh.reasons.has("conflicting_history"), true, "a conflicting retained actual row has a specific refusal")
			context.equal(mesh.peers[1]._core.received_frames()[2], 7, "conflicting overlap cannot install the later missing row")
			context.equal(mesh.peers[1]._core.retained_input(2, 7), _sample(2, 7), "conflicting overlap preserves original actual bytes")
		if name == "no_donor":
			context.equal(mesh.reasons.has("missing_history"), true, "no complete declared donor interval fails closed")
		if name == "resource_limit":
			context.equal(mesh.reasons.has("resource_limit"), true, "an oversized full-history journal has a specific refusal")
	context.finish()


func _expected(through: int, cut: int) -> PackedByteArray:
	var game: WideGame = WideGame.new(3 * _slots)
	for frame: int in range(through + 1):
		for player: int in range(3 * _slots):
			for value: int in _sample(player, mini(frame, cut) if player >= 2 * _slots else frame):
				game.values[player] += value
	game.frame = through + 1
	return game.bytes()


func _sample(player: int, frame: int) -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(_width)
	for index: int in _width:
		bytes[index] = (frame * 11 + player * 7 + index) % 251
	return bytes


func _inputs(mesh: Dictionary, peer: int) -> Array[Driver.LocalInput]:
	var result: Array[Driver.LocalInput] = []
	var frame: int = mesh.peers[peer].status().current_frame
	for slot: int in range(peer * _slots, (peer + 1) * _slots):
		result.append(Driver.LocalInput.new(slot, frame, _sample(slot, frame)))
	return result


func _limits(count: int = 3) -> T.Limits:
	var limits: T.Limits = super._limits(count)
	limits.input_width = _width
	return limits


func _wide_mesh(context: RefCounted) -> Dictionary:
	var peers: Array[Peer] = []
	var games: Array[RefCounted] = []
	for player: int in range(3):
		var config: Config = Config.new()
		config.player_count = 3 * _slots
		config.local_players = PackedInt32Array()
		for slot: int in range(player * _slots, (player + 1) * _slots):
			config.local_players.append(slot)
		config.input_width = _width
		config.neutral_input.resize(_width)
		config.neutral_input.fill(0)
		config.max_prediction_frames = _window
		config.queue_capacity = maxi(128, _window * 2 + 2)
		config.history_slots = _window + 1
		config.check_distance = 0
		config.sync_test = false
		config.max_snapshot_bytes = 8 * (config.player_count + 1)
		config.storage_budget_bytes = 4194304
		var local: T.Message = T.Message.new()
		local.kind = T.Kind.SYNC_REQUEST
		local.sender_id = _id(player)
		local.connection_id = _id(player + 20)
		local.session_id = _id(90, 16)
		local.config.player_count = config.player_count
		local.config.input_width = _width
		local.config.input_delay = 0
		local.config.max_prediction = _window
		local.config.queue_capacity = config.queue_capacity
		local.config.desync_interval = 60
		local.config.neutral_input = config.neutral_input.duplicate()
		local.config.roster = []
		for slot: int in config.player_count:
			local.config.roster.append(_id(slot / _slots))
		var handshake: H.Options = H.Options.new()
		handshake.roundtrips = 1
		var controls: L.Options = L.Options.new()
		controls.enabled = true
		controls.disconnect_notify_us = 100000
		controls.disconnect_timeout_us = 400000
		controls.keepalive_interval_us = 1000
		controls.quality_report_interval_us = 1000
		controls.disconnect_behavior = L.Disconnect.CONTINUE
		var game: WideGame = WideGame.new(config.player_count)
		var peer: Peer = Peer.new()
		context.equal(peer.configure(config, local, game, handshake, I.Options.new(), controls), I.Code.OK, "configure wide-input production mesh")
		peers.append(peer)
		games.append(game)
	for player: int in range(3):
		var tokens: Array[PackedByteArray] = []
		for remote: PackedByteArray in peers[player].peer_ids():
			tokens.append(_id(remote[0] + player * 8, 16))
		context.equal(peers[player].begin(0, tokens), I.Code.OK, "begin wide-input handshake")
	var mesh: Dictionary = {"peers": peers, "games": games, "now": 0, "cuts": {}, "unconfirmed": 0, "reasons": [], "count": 3 * _slots}
	for iteration: int in range(6):
		_deliver(context, mesh, _drain(mesh))
	return mesh


func _deliver(context: RefCounted, mesh: Dictionary, packets: Array[Dictionary], terminated: bool = false) -> void:
	var accepted: Array[Dictionary] = []
	for packet: Dictionary in packets:
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
		if decoded.code == T.Code.OK and decoded.message.kind == T.Kind.INPUT and packet.from == 2 and packet.to == _missing_peer:
			if decoded.message.start_frame + decoded.message.frame_count - 1 > 7:
				continue
		if _mode in ["no_donor", "conflicting_overlap"] and decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER:
			if decoded.message.phase == Drop.Phase.REPORT and decoded.message.stage == Drop.Stage.INVENTORY:
				decoded.message.bytes = decoded.message.bytes.duplicate()
				decoded.message.bytes.encode_s32(3 if _mode == "no_donor" else 7, 8 if _mode == "no_donor" else 6)
				var encoded: T.Result = Codec.encode(decoded.message, _limits(mesh.count))
				context.equal(encoded.code, T.Code.OK, "encode a bounded retained interval for a recovery fault")
				accepted.append({"from": packet.from, "to": packet.to, "bytes": encoded.bytes})
				continue
		if decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER and decoded.message.phase == Drop.Phase.BACKFILL:
			if decoded.message.stage == Drop.Stage.HISTORY:
				_seen += 1
				_donor_sources[packet.from] = true
				if _mode == "lost_history_timeout":
					continue
				if _mode == "loss_reorder":
					if decoded.message.chunk_index == 0 and not _dropped_chunk:
						_dropped_chunk = true
						continue
					if decoded.message.chunk_index == 0 and not _reordered:
						_held = packet
						continue
					if decoded.message.chunk_index == 1 and not _held.is_empty():
						accepted.append(packet)
						accepted.append(_held)
						_held = {}
						_reordered = true
						continue
				if _mode in ["malformed_chunk", "conflicting_duplicate", "conflicting_overlap"]:
					var altered: T.Message = decoded.message
					if _mode == "malformed_chunk":
						altered.chunk_count += 1
					else:
						if _mode == "conflicting_duplicate":
							accepted.append(packet)
						altered.bytes = altered.bytes.duplicate()
						if _mode == "conflicting_duplicate" or altered.chunk_index == 0:
							altered.bytes[0] ^= 1
					var encoded: T.Result = Codec.encode(altered, _limits(mesh.count))
					context.equal(encoded.code, T.Code.OK, "encode a structurally valid conflicting history packet")
					accepted.append({"from": packet.from, "to": packet.to, "bytes": encoded.bytes})
					continue
				if _mode == "wrong_donor":
					decoded.message.sender_id = _id(1 - packet.from)
					decoded.message.connection_id = _id(21 - packet.from)
					var encoded: T.Result = Codec.encode(decoded.message, _limits(mesh.count))
					context.equal(encoded.code, T.Code.OK, "encode a real survivor attributed as the wrong donor")
					accepted.append({"from": 1 - packet.from, "to": 1 - packet.to, "bytes": encoded.bytes})
					continue
		accepted.append(packet)
	super._deliver(context, mesh, accepted, terminated)
