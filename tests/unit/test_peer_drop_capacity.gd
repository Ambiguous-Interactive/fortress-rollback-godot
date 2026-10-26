extends "res://tests/unit/test_peer_drop_backfill.gd"

# Value: protects=donor progress at minimum publication capacity; fails_when=retried plans occupy the only slot before retained chunks;
# why_new=ordinary tests poll faster than the retry period with default outboxes; seam=none


var _chunk_indices: Dictionary = {}
var _lose_plan: bool = false
var _lost_plan: bool = false
var _pressure_actor: int = -1
var _pressure_input: Dictionary = {}
var _hold_ready: bool = false
var _ready: Dictionary = {}


func _deliver(context: RefCounted, mesh: Dictionary, packets: Array[Dictionary], terminated: bool = false) -> void:
	var accepted: Array[Dictionary] = []
	for packet: Dictionary in packets:
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
		if _pressure_actor >= 0 and packet.to == _pressure_actor and packet.from == 1 - _pressure_actor \
			and decoded.code == T.Code.OK and decoded.message.kind == T.Kind.INPUT:
			_pressure_input = packet.duplicate(true)
		if decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER:
			if _hold_ready and packet.to == 0 and decoded.message.phase == Drop.Phase.REPORT and decoded.message.stage == Drop.Stage.READY:
				_ready = packet.duplicate(true)
				continue
			if _lose_plan and not _lost_plan and decoded.message.phase == Drop.Phase.PREPARE and decoded.message.stage == Drop.Stage.HISTORY:
				_lost_plan = true
				continue
			if decoded.message.phase == Drop.Phase.BACKFILL and decoded.message.stage == Drop.Stage.HISTORY:
				_chunk_indices[decoded.message.chunk_index] = true
		accepted.append(packet)
	super._deliver(context, mesh, accepted, terminated)


func cases() -> PackedStringArray:
	return PackedStringArray([
		"fast_capacity_control", "slow_complete_control", "slow_minimum_capacity", "slow_remote_donor", "slow_lost_plan",
		"refused_prepare_retries_after_drain", "refused_inventory_retries_after_drain",
		"refused_commit_retries_after_drain", "partial_prepare_retries_only_refused_link", "staggered_prepare_retry",
	])


func run_case(name: String, context: RefCounted) -> void:
	_pressure_actor = -1
	_hold_ready = false
	if name == "refused_commit_retries_after_drain":
		_commit_pressure(context)
		context.finish()
		return
	if name in ["partial_prepare_retries_only_refused_link", "staggered_prepare_retry"]:
		_partial_pressure(context, name == "staggered_prepare_retry")
		context.finish()
		return
	if name.begins_with("refused_"):
		_retry_pressure(context, name.begins_with("refused_inventory"))
		context.finish()
		return
	_mode = "capacity"
	_width = 1028
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
			_keep_alive(context, mesh, 1 - survivor, survivor)
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


# Value: protects=drained publication pressure immediately retries refused drop phases; fails_when=refusal consumes the retry clock;
# why_new=slow-capacity cases wait an entire retry interval after every drain; seam=none
func _retry_pressure(context: RefCounted, follower: bool) -> void:
	_mode = "retry_pressure"
	_missing_peer = -1
	_width = 4
	_pressure_actor = 1 if follower else 0
	_pressure_input.clear()
	var mesh: Dictionary = _wide_mesh(context)
	_play(context, mesh, 6, true)
	_leave(context, mesh, 2)
	context.equal(_pressure_input.is_empty(), false, "capture actual survivor input bytes before departure")
	mesh.now += 2000001
	var actor: Peer = mesh.peers[_pressure_actor]
	context.equal(actor.receive(_pressure_input.bytes, _id(1 - _pressure_actor), mesh.now), I.Code.OK, "a real duplicate input queues its required ACK")
	if follower:
		_keep_alive(context, mesh, 1, 0)
		context.equal(mesh.peers[0].poll(mesh.now), I.Code.OK, "the coordinator opens a real drop operation")
		for packet: Peer.Packet in mesh.peers[0].drain_outbox():
			if packet.to == _id(1):
				context.equal(actor.receive(packet.bytes, _id(0), mesh.now), I.Code.OK, "deliver the original PREPARE before follower detection")
	context.equal(actor.poll(mesh.now), I.Code.OK, "departure detection attempts the phase behind the queued ACK")
	var barrier: Drop.Barrier = actor._drops.barrier(_id(2).hex_encode())
	context.equal(barrier != null, true, "the real timeout opens the bounded agreement")
	var before: Array[Peer.Packet] = actor.drain_outbox()
	var acknowledgements: int = 0
	for packet: Peer.Packet in before:
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(3))
		if packet.to == _id(1 - _pressure_actor) and decoded.code == T.Code.OK:
			context.equal(decoded.message.kind, T.Kind.INPUT_ACK, "the required ACK occupied the survivor's only publication slot")
			acknowledgements += 1
	context.equal(acknowledgements, 1, "drain the one real packet that refused the drop phase")
	context.equal(actor.poll(mesh.now), I.Code.OK, "repoll after drain without advancing protocol time")
	var emitted: int = 0
	for packet: Peer.Packet in actor.drain_outbox():
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(3))
		if packet.to == _id(1 - _pressure_actor) and decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER:
			emitted += 1
			context.equal(decoded.message.phase, Drop.Phase.REPORT if follower else Drop.Phase.PREPARE, "the refused phase retries after its slot becomes available")
			context.equal(decoded.message.stage, Drop.Stage.INVENTORY if follower else Drop.Stage.NONE, "the retry preserves the original phase stage")
	context.equal(emitted, 1, "a refused phase does not wait another retry period after drain")


func _keep_alive(context: RefCounted, mesh: Dictionary, sender: int, recipient: int) -> void:
	var live: T.Message = T.Message.new()
	live.kind = T.Kind.KEEP_ALIVE
	live.session_id = _id(90, 16)
	live.sender_id = _id(sender)
	live.connection_id = _id(sender + 20)
	var encoded: T.Result = Codec.encode(live, _limits(mesh.count))
	context.equal(encoded.code, T.Code.OK, "encode original survivor identity")
	context.equal(mesh.peers[recipient].receive(encoded.bytes, _id(sender), mesh.now), I.Code.OK, "keep the survivor's actual link live")


# Value: protects=partial publication retries the refused peer without flooding accepted peers; fails_when=all-peer clocks lose link ownership;
# why_new=two-survivor cases have only one publication destination; seam=none
func _partial_pressure(context: RefCounted, staggered: bool = false) -> void:
	_mode = "retry_pressure"
	_missing_peer = -1
	_width = 4
	_pressure_actor = 0
	_pressure_input.clear()
	var mesh: Dictionary = _wide_mesh(context, 4)
	_play(context, mesh, 6, true)
	_leave(context, mesh, 3)
	mesh.now += 2000001
	context.equal(mesh.peers[0].receive(_pressure_input.bytes, _id(1), mesh.now), I.Code.OK, "queue a real ACK on the first survivor link")
	_keep_alive(context, mesh, 2, 0)
	context.equal(mesh.peers[0].poll(mesh.now), I.Code.OK, "open the operation across one pressured and one healthy link")
	var first: PackedInt32Array = PackedInt32Array()
	for packet: Peer.Packet in mesh.peers[0].drain_outbox():
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
		if decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER:
			first.append(packet.to[0] - 1)
	context.equal(first, PackedInt32Array([2]), "the healthy survivor accepted the first PREPARE")
	var accepted_at: int = mesh.now
	if staggered:
		mesh.now += Drop.RETRY_US / 2
	context.equal(mesh.peers[0].poll(mesh.now), I.Code.OK, "retry only after draining the refused link")
	var second: PackedInt32Array = PackedInt32Array()
	for packet: Peer.Packet in mesh.peers[0].drain_outbox():
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
		if decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER:
			second.append(packet.to[0] - 1)
	context.equal(second, PackedInt32Array([1]), "only the refused survivor receives an immediate retry")
	context.equal(mesh.peers[0].poll(accepted_at + Drop.RETRY_US - 1), I.Code.OK, "accepted links retain their normal retry interval")
	context.equal(mesh.peers[0].drain_outbox().is_empty(), true, "neither accepted publication repeats before its own deadline")
	if staggered:
		context.equal(mesh.peers[0].poll(accepted_at + Drop.RETRY_US), I.Code.OK, "the early accepted link reaches its own retry equality")
		var due: PackedInt32Array = PackedInt32Array()
		for packet: Peer.Packet in mesh.peers[0].drain_outbox():
			var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
			if decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER:
				due.append(packet.to[0] - 1)
		context.equal(due, PackedInt32Array([2]), "a later refused-link acceptance cannot postpone the healthy PREPARE")


# Value: protects=irreversible commit publication resumes after ACK pressure; fails_when=an unsent COMMIT starts its retry clock;
# why_new=prepare/inventory retries occur before the irreversible state change; seam=none
func _commit_pressure(context: RefCounted) -> void:
	_mode = "retry_pressure"
	_missing_peer = -1
	_width = 4
	_pressure_actor = 0
	_pressure_input.clear()
	_hold_ready = true
	_ready.clear()
	var mesh: Dictionary = _wide_mesh(context)
	_play(context, mesh, 6, true)
	_leave(context, mesh, 2)
	for tick: int in range(60):
		mesh.now += 50000
		for survivor: int in [0, 1]:
			_keep_alive(context, mesh, 1 - survivor, survivor)
			context.equal(mesh.peers[survivor].poll(mesh.now), I.Code.OK, "service the real operation until the original READY is held")
		_deliver(context, mesh, _without_peer(_drain(mesh), 2))
		if not _ready.is_empty():
			break
	context.equal(_ready.is_empty(), false, "hold an actual follower certificate before coordinator commit")
	if _ready.is_empty():
		return
	context.equal(mesh.peers[0].receive(_pressure_input.bytes, _id(1), mesh.now), I.Code.OK, "a duplicate original input occupies the coordinator's only output slot")
	context.equal(mesh.peers[0].receive(_ready.bytes, _id(1), mesh.now), I.Code.OK, "the actual READY commits while publication is refused")
	context.equal(mesh.peers[0]._core.frozen_frame(2), 8, "the certified local decision remains irreversible")
	var before: Array[Peer.Packet] = mesh.peers[0].drain_outbox()
	context.equal(before.size(), 1, "only the previously queued ACK can be drained")
	if before.size() == 1:
		context.equal(Codec.decode(before[0].bytes, _limits(3)).message.kind, T.Kind.INPUT_ACK, "no COMMIT was published before pressure cleared")
	context.equal(mesh.peers[0].poll(mesh.now), I.Code.OK, "retry the refused irreversible commit at the same clock")
	var commits: int = 0
	for packet: Peer.Packet in mesh.peers[0].drain_outbox():
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(3))
		if decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER and decoded.message.phase == Drop.Phase.COMMIT:
			commits += 1
	context.equal(commits, 1, "a refused first COMMIT does not consume a retry period")


func _wide_mesh(context: RefCounted, count: int = 3) -> Dictionary:
	var peers: Array[Peer] = []
	var games: Array[RefCounted] = []
	for player: int in range(count):
		var config: Config = Config.new()
		config.player_count = count * _slots
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
	for player: int in range(count):
		var tokens: Array[PackedByteArray] = []
		for remote: PackedByteArray in peers[player].peer_ids():
			tokens.append(_id(remote[0] + player * 8, 16))
		context.equal(peers[player].begin(0, tokens), I.Code.OK, "begin wide-input handshake")
	var mesh: Dictionary = {"peers": peers, "games": games, "now": 0, "cuts": {}, "unconfirmed": 0, "reasons": [], "count": count * _slots}
	for iteration: int in range(6):
		_deliver(context, mesh, _drain(mesh))
	return mesh
