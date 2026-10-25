extends "res://tests/unit/test_peer_drop_barrier.gd"

const Drop = preload("res://addons/fortress_rollback/core/peer_drop_barrier.gd")
const Reference = preload("res://tests/oracle/reference_game.gd")
const LAYOUTS: Dictionary = {
	"interleaved_slots": [0, 1, 2, 0, 1, 2],
	"reversed_slot_ownership": [2, 1, 0, 2, 1, 0],
}


func cases() -> PackedStringArray:
	return PackedStringArray(["interleaved_slots", "reversed_slot_ownership", "last_survivor_multi_slot", "last_survivor_missing_slot"])


func run_case(name: String, context: RefCounted) -> void:
	if name.begins_with("last_survivor_"):
		_last_survivor(context, name == "last_survivor_missing_slot")
	else:
		_multi_slot(context, LAYOUTS[name])
	context.finish()


# Value: protects=the second departure preserves every endpoint-owned slot; fails_when=the final survivor truncates accepted samples;
# why_new=one-member certificates bypass multi-survivor agreement; seam=none
func _last_survivor(context: RefCounted, missing_slot: bool) -> void:
	for owners: Array in LAYOUTS.values():
		var mesh: Dictionary = _build_layout(context, owners)
		_play(context, mesh, 6, true)
		_leave(context, mesh, 2)
		_detect(context, mesh, [0, 1])
		var first_cut: int = mesh.cuts.get(0, -1)
		if missing_slot:
			var advanced: bool = false
			for slot: int in owners.size():
				if owners[slot] == 1 and not advanced:
					context.equal(mesh.peers[0]._core.receive_input(slot, 6, _sample(slot, 6)).code, Types.Code.OK, "one target slot accepts an extra actual row through the core API")
					advanced = true
			_detect(context, mesh, [0], 600000, true, [], [], true)
			for slot: int in owners.size():
				if owners[slot] == 1:
					context.equal(mesh.peers[0]._core.frozen_frame(slot), -1, "incomplete grouped history cannot partially freeze any target")
					context.equal(mesh.peers[0]._core.retained_input(slot, 5), _sample(slot, 5), "refusal preserves every original target prefix")
			context.equal(mesh.reasons, ["missing_history"], "unequal receipts without a complete cut fail with one precise reason")
			context.equal(mesh.peers[0].status().lifecycle, Types.Lifecycle.TERMINATED, "the sole survivor cannot invent a missing grouped slot row")
			continue
		_leave(context, mesh, 1)
		var expected_cut: int = -1
		for slot: int in owners.size():
			if owners[slot] == 1:
				expected_cut = maxi(expected_cut, mesh.peers[0]._core.received_frames()[slot])
		context.equal(expected_cut, 8, "both newly departed handles deliver changing actual inputs through frame eight")
		context.equal(expected_cut > mesh.peers[0].status().confirmed_frame, true, "the accepted multi-handle suffix is not yet exposed")
		_detect(context, mesh, [0])
		for slot: int in owners.size():
			if owners[slot] == 1:
				context.equal(mesh.peers[0]._core.frozen_frame(slot), expected_cut, "each handle freezes after the final original sample")
		context.equal(mesh.drop_events.get(0, []), [first_cut, expected_cut], "each departed endpoint produces exactly one notification")
		context.equal(mesh.unconfirmed, 0, "complete local multi-handle history keeps the final survivor running")
		_play(context, mesh, 12, true, [0], 1)
		var reference: RefCounted = Reference.new(owners.size(), 2)
		var states: Dictionary = {}
		for request: Dictionary in mesh.games[0].requests:
			if request.kind == "advance":
				states[request.frame] = request.state_bytes
		for frame: int in range(mesh.peers[0].status().confirmed_frame):
			var row: Array[Dictionary] = []
			for slot: int in owners.size():
				var cut: int = first_cut if owners[slot] == 2 else expected_cut
				var frozen: bool = owners[slot] != 0 and frame > cut
				row.append({"player": slot, "bytes": _sample(slot, cut if frozen else frame).hex_encode(), "status": "disconnected" if frozen else "confirmed"})
			context.equal(reference.advance(row), "", "the original six-player input history advances independently")
			context.equal(states.get(frame, ""), reference.bytes().hex_encode(), "the final survivor preserves the complete original multi-handle history")


# Value: protects=all handles of one departed endpoint freeze consistently; fails_when=one-slot ownership is assumed; why_new=drop fixtures use one handle; seam=none
func _multi_slot(context: RefCounted, owners: Array) -> void:
	var mesh: Dictionary = _build_layout(context, owners)
	_play(context, mesh, 6, true)
	_leave(context, mesh, 2)
	_detect(context, mesh, [0, 1])
	var cuts: Array[int] = _cuts(mesh, [0, 1])
	context.equal(cuts[0] >= 0, true, "the multi-handle departure commits")
	context.equal(cuts[1], cuts[0], "both survivors agree the frozen frame")
	context.equal(mesh.unconfirmed, 0, "all handles commit without fallback")
	var first: Drop.Barrier = mesh.peers[0]._drops.barrier(_id(2).hex_encode())
	var second: Drop.Barrier = mesh.peers[1]._drops.barrier(_id(2).hex_encode())
	context.equal(first != null and second != null, true, "both survivors own the committed agreement")
	if first == null or second == null:
		return
	var slots: PackedInt32Array = PackedInt32Array()
	var lowest: int = -1
	for slot: int in range(owners.size()):
		if owners[slot] == 2:
			slots.append(slot)
		elif lowest < 0:
			lowest = slot
	context.equal(first.slots, slots, "the target contains every departed local handle")
	context.equal(second.slots, slots, "both survivors identify the same full target")
	context.equal(first.coordinator, lowest, "the coordinator owns the lowest surviving slot")
	context.equal(second.coordinator, lowest, "slot order determines the coordinator on both peers")
	context.equal(first.state, Drop.COMMITTED, "the first survivor commits the certificate")
	context.equal(second.state, Drop.COMMITTED, "the second survivor commits the certificate")
	context.equal(first.value.size(), slots.size() * 4, "the certificate includes every departed sample")
	var expected_value: PackedByteArray = PackedByteArray()
	for slot: int in slots:
		expected_value.append_array(_sample(slot, cuts[0]))
	context.equal(first.value, expected_value, "the certificate concatenates original samples in slot order")
	context.equal(second.value, expected_value, "the follower certifies the same complete value")
	context.equal(first.digest, second.digest, "both survivors certify the same digest")
	var commit_count: int = 0
	for packet: Dictionary in mesh.barrier_packets:
		var message: T.Message = packet.message
		if message.phase != Drop.Phase.COMMIT:
			continue
		commit_count += 1
		context.equal(packet.from, owners[lowest], "the COMMIT comes from the lowest slot owner")
		context.equal(message.data.size(), slots.size() * 3, "the encoded COMMIT retains all target eras")
		context.equal(message.cut, cuts[0], "the encoded COMMIT names the frozen frame")
		context.equal(message.cut_digest, first.digest, "the encoded COMMIT names the complete frozen value")
	context.equal(commit_count > 0, true, "real encoded COMMIT traffic completed the agreement")
	var before: int = mesh.peers[0].status().current_frame
	_play(context, mesh, 12, true, [0, 1], 2)
	for survivor: int in [0, 1]:
		context.equal(mesh.peers[survivor].status().current_frame, before + 12, "every continuing frame advances")
		context.equal(mesh.peers[survivor].status().lifecycle, Types.Lifecycle.RUNNING, "the multi-handle match continues")
		context.equal(mesh.drop_events.get(survivor, []), [cuts[0]], "one endpoint departure publishes one drop")
	var shared: int = mini(mesh.peers[0].status().confirmed_frame, mesh.peers[1].status().confirmed_frame)
	context.equal(shared > before, true, "the canonical check includes new confirmed gameplay")
	_compare_original_history(context, mesh, owners, cuts[0], shared)


func _compare_original_history(context: RefCounted, mesh: Dictionary, owners: Array, cut: int, shared: int) -> void:
	var reference: RefCounted = Reference.new(owners.size(), 2)
	var states: Dictionary = {}
	for frame: int in range(shared):
		var row: Array[Dictionary] = []
		for slot: int in range(owners.size()):
			var frozen: bool = owners[slot] == 2 and frame > cut
			row.append({"player": slot, "bytes": _sample(slot, cut if frozen else frame).hex_encode(), "status": "disconnected" if frozen else "confirmed"})
		context.equal(reference.advance(row), "", "the independent original-input history advances")
		states[frame] = reference.bytes().hex_encode()
	for survivor: int in [0, 1]:
		var rows: Dictionary = _rows(mesh.games[survivor])
		var actual_states: Dictionary = {}
		for request: Dictionary in mesh.games[survivor].requests:
			if request.kind == "advance":
				actual_states[request.frame] = request.state_bytes
		for frame: int in range(shared):
			context.equal(actual_states.get(frame, ""), states[frame], "confirmed canonical state matches the original six-player history")
			if frame <= cut or not rows.has(frame):
				continue
			for slot: int in range(owners.size()):
				var frozen: bool = owners[slot] == 2
				context.equal(rows[frame][slot].bytes, _sample(slot, cut if frozen else frame).hex_encode(), "every handle uses its own original or frozen sample")
				if frozen:
					context.equal(rows[frame][slot].status, "disconnected", "every departed handle exposes disconnected status")


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
			var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
			if decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER:
				mesh.barrier_packets.append({"from": source, "to": packet.to[0] - 1, "message": decoded.message})
			result.append({"from": source, "to": packet.to[0] - 1, "bytes": packet.bytes})
		mesh.peers[source].drain_transitions()
		for event: Dictionary in mesh.peers[source].drain_events():
			if event.kind == "peer_dropped":
				mesh.cuts[source] = event.frame
				if not mesh.drop_events.has(source):
					mesh.drop_events[source] = []
				mesh.drop_events[source].append(event.frame)
			elif event.kind == "peer_drop_unconfirmed":
				mesh.unconfirmed += 1
				mesh.reasons.append(event.reason)
	return result


func _build_layout(context: RefCounted, owners: Array) -> Dictionary:
	var peers: Array[Peer] = []
	var games: Array[RefCounted] = []
	for endpoint: int in range(3):
		var config: Config = Config.new()
		config.player_count = owners.size()
		config.local_players = PackedInt32Array()
		for slot: int in range(owners.size()):
			if owners[slot] == endpoint:
				config.local_players.append(slot)
		config.input_width = 4
		config.neutral_input = PackedByteArray([0, 0, 0, 0])
		config.input_delay = 0
		config.max_prediction_frames = 8
		config.history_slots = 9
		config.check_distance = 0
		config.sync_test = false
		config.max_snapshot_bytes = 4 * (owners.size() + 3)
		config.storage_budget_bytes = 1048576
		config.replay_max_frames = 64
		var local: T.Message = T.Message.new()
		local.kind = T.Kind.SYNC_REQUEST
		local.sender_id = _id(endpoint)
		local.connection_id = _id(endpoint + 20)
		local.session_id = _id(90, 16)
		local.config.player_count = owners.size()
		local.config.input_width = 4
		local.config.input_delay = 0
		local.config.max_prediction = 8
		local.config.desync_interval = 60
		local.config.neutral_input = config.neutral_input.duplicate()
		var roster: Array[PackedByteArray] = []
		for owner: int in owners:
			roster.append(_id(owner))
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
		controls.disconnect_behavior = L.Disconnect.CONTINUE
		controls.drop_barrier_timeout_us = 250000
		var game: RefCounted = Game.new(owners.size())
		var peer: Peer = Peer.new()
		context.equal(peer.configure(config, local, game, handshake, input, controls), I.Code.OK, "configure the multi-handle mesh")
		peers.append(peer)
		games.append(game)
	for endpoint: int in range(peers.size()):
		var tokens: Array[PackedByteArray] = []
		for remote: PackedByteArray in peers[endpoint].peer_ids():
			tokens.append(_id(remote[0] + endpoint * 8, 16))
		context.equal(peers[endpoint].begin(0, tokens), I.Code.OK, "begin the multi-handle mesh")
	var mesh: Dictionary = {
		"peers": peers,
		"games": games,
		"now": 0,
		"cuts": {},
		"unconfirmed": 0,
		"reasons": [],
		"count": owners.size(),
		"owners": owners,
		"barrier_packets": [],
		"drop_events": {},
	}
	for iteration: int in range(6):
		_deliver(context, mesh, _drain(mesh))
	return mesh
