extends "res://tests/unit/test_peer_drop_backfill.gd"

# Value: protects=donor progress at minimum publication capacity; fails_when=retried plans occupy the only slot before retained chunks;
# why_new=ordinary tests poll faster than the retry period with default outboxes; seam=none


var _chunk_indices: Dictionary = {}
var _lose_plan: bool = false
var _lost_plan: bool = false


func _deliver(context: RefCounted, mesh: Dictionary, packets: Array[Dictionary], terminated: bool = false) -> void:
	var accepted: Array[Dictionary] = []
	for packet: Dictionary in packets:
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
		if decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER:
			if _lose_plan and not _lost_plan and decoded.message.phase == Drop.Phase.PREPARE and decoded.message.stage == Drop.Stage.HISTORY:
				_lost_plan = true
				continue
			if decoded.message.phase == Drop.Phase.BACKFILL and decoded.message.stage == Drop.Stage.HISTORY:
				_chunk_indices[decoded.message.chunk_index] = true
		accepted.append(packet)
	super._deliver(context, mesh, accepted, terminated)


func cases() -> PackedStringArray:
	return PackedStringArray(["fast_capacity_control", "slow_complete_control", "slow_minimum_capacity", "slow_remote_donor", "slow_lost_plan"])


func run_case(name: String, context: RefCounted) -> void:
	_mode = "capacity"
	_missing_peer = -1 if name == "slow_complete_control" else (0 if name == "slow_remote_donor" else 1)
	_lose_plan = name == "slow_lost_plan"
	_lost_plan = false
	_chunk_indices.clear()
	_seen = 0
	_donor_sources.clear()
	var mesh: Dictionary = _wide_mesh(context)
	_play(context, mesh, 6, true)
	_leave(context, mesh, 2)
	var cadence: int = 1000 if name == "fast_capacity_control" else 50000
	for elapsed: int in range(0, 4500000, cadence):
		mesh.now += cadence
		for survivor: int in [0, 1]:
			var live: T.Message = T.Message.new()
			live.kind = T.Kind.KEEP_ALIVE
			live.session_id = _id(90, 16)
			live.sender_id = _id(1 - survivor)
			live.connection_id = _id(21 - survivor)
			var encoded: T.Result = Codec.encode(live, _limits(3))
			context.equal(encoded.code, T.Code.OK, "encode independent live-link traffic with optional timers disabled")
			var received: int = mesh.peers[survivor].receive(encoded.bytes, live.sender_id, mesh.now)
			if received != I.Code.TERMINATED:
				context.equal(received, I.Code.OK, "the survivor keeps its real byte link live")
			var polled: int = mesh.peers[survivor].poll(mesh.now)
			if polled not in [I.Code.TERMINATED, I.Code.BACKPRESSURE]:
				context.equal(polled, I.Code.OK, "service the bounded outbox at the selected cadence")
		_deliver(context, mesh, _without_peer(_drain(mesh), 2), true)
	context.equal(_seen > 0, name != "slow_complete_control", "donor data gets a publication slot despite repeated plans")
	if name != "slow_complete_control":
		context.equal(_chunk_indices.has(0), true, "the first original chunk gets a publication slot")
		context.equal(_chunk_indices.has(1), true, "repeated plans cannot starve the retained second chunk")
	var running: bool = true
	for survivor: int in [0, 1]:
		running = running and mesh.peers[survivor].status().lifecycle == Types.Lifecycle.RUNNING
		context.equal(mesh.peers[survivor].status().lifecycle, Types.Lifecycle.RUNNING, "minimum-capacity service keeps complete donor recovery live")
		context.equal(mesh.peers[survivor]._core.frozen_frame(2), 8, "minimum-capacity service commits the complete recovered history")
	if not running:
		context.finish()
		return
	if name == "slow_remote_donor":
		context.equal(mesh.peers[0]._drops.barrier(_id(2).hex_encode()).history.donor, 1, "the missing coordinator receives the remote donor history")
	if _lose_plan:
		context.equal(_lost_plan, true, "the first donor plan was omitted before receipt")
	_play(context, mesh, 6, true, [0, 1], 2)
	var through: int = mini(mesh.peers[0].status().confirmed_frame, mesh.peers[1].status().confirmed_frame) - 1
	context.equal(through > 8, true, "bounded donor recovery resumes confirmed gameplay past the cut")
	var expected: PackedByteArray = _expected(through, 8)
	for survivor: int in [0, 1]:
		context.equal(mesh.games[survivor].states[through], expected, "pressure preserves canonical state from the original input history")
	context.finish()


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
		handshake.max_outbox = 1
		var controls: L.Options = L.Options.new()
		controls.enabled = true
		controls.disconnect_notify_us = 100000
		controls.disconnect_timeout_us = 2000000
		controls.drop_barrier_timeout_us = 2000000
		controls.keepalive_interval_us = 1000000000
		controls.quality_report_interval_us = 1000000000
		controls.disconnect_behavior = L.Disconnect.CONTINUE
		var game: WideGame = WideGame.new(config.player_count)
		var peer: Peer = Peer.new()
		var input: I.Options = I.Options.new()
		input.max_outbox = 1
		input.retry_interval_us = 1000000000
		context.equal(peer.configure(config, local, game, handshake, input, controls), I.Code.OK, "configure wide-input production mesh")
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
