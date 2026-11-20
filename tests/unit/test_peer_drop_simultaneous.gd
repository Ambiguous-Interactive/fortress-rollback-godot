extends "res://tests/unit/test_peer_drop_barrier.gd"

# Value: protects=fixed barrier participants cannot silently shrink when two peers go silent together;
# fails_when=a survivor omits the second departure from the open certificate or freezes a partial cut;
# why_new=existing second-departure coverage is serial; seam=none
const Drop = preload("res://addons/fortress_rollback/core/peer_drop_barrier.gd")

const TARGETS: Array[int] = [3, 4]
const SURVIVORS: Array[int] = [0, 1, 2]


func cases() -> PackedStringArray:
	return PackedStringArray(["simultaneous_departure"])


func run_case(_name: String, context: RefCounted) -> void:
	var mesh: Dictionary = _build_five(context)
	_play(context, mesh, 6, true)
	# Both departing peers finish their last exchanged frame, then go silent together.
	_leave(context, mesh, 3)
	_leave(context, mesh, 4)
	_wait_for_departures(context, mesh, 600000)
	for survivor: int in SURVIVORS:
		context.equal(mesh.peers[survivor].status().lifecycle, Types.Lifecycle.TERMINATED, "an overlapping departure ends the match explicitly")
		context.equal(mesh.peers[survivor].status().reason, Types.Code.PROTOCOL_FAILED, "the terminal cause is a protocol failure")
		for target: int in TARGETS:
			context.equal(mesh.peers[survivor]._core.frozen_frame(target), -1, "no survivor freezes a slot on an incomplete participant set")
			var barrier: Variant = mesh.peers[survivor]._drops.barrier(_id(target).hex_encode())
			context.equal(barrier == null or barrier.state != Drop.COMMITTED, true, "no overlapping certificate commits at survivor %d" % survivor)
	context.equal(mesh.reasons.count("participant_lost"), SURVIVORS.size(), "every survivor names the missing participant instead of a timeout")
	context.equal(mesh.cuts.is_empty(), true, "no survivor publishes a partial drop")
	context.finish()


# The shared barrier fixture fixes a 32-byte snapshot ceiling for four peers; the
# five-peer mesh reserves the game's own fixed-header size for every player.
func _build_five(context: RefCounted) -> Dictionary:
	var count: int = 5
	var peers: Array[Peer] = []
	var games: Array[RefCounted] = []
	for player: int in range(count):
		var config: Config = Config.new()
		config.player_count = count
		config.local_players = PackedInt32Array([player])
		config.input_width = 4
		config.neutral_input = PackedByteArray([0, 0, 0, 0])
		config.max_prediction_frames = 8
		config.history_slots = 9
		config.check_distance = 0
		config.sync_test = false
		config.max_snapshot_bytes = 8 * (count + 1)
		config.storage_budget_bytes = 1048576
		config.replay_max_frames = 64
		var local: T.Message = T.Message.new()
		local.kind = T.Kind.SYNC_REQUEST
		local.sender_id = _id(player)
		local.connection_id = _id(player + 20)
		local.session_id = _id(90, 16)
		local.config.player_count = count
		local.config.input_width = 4
		local.config.max_prediction = 8
		local.config.desync_interval = 60
		local.config.neutral_input = config.neutral_input.duplicate()
		var roster: Array[PackedByteArray] = []
		for slot: int in range(count):
			roster.append(_id(slot))
		local.config.roster = roster
		var handshake: H.Options = H.Options.new()
		handshake.roundtrips = 1
		var controls: L.Options = L.Options.new()
		controls.enabled = true
		controls.disconnect_notify_us = 100000
		controls.disconnect_timeout_us = 400000
		controls.keepalive_interval_us = 1000
		controls.quality_report_interval_us = 1000
		controls.disconnect_behavior = L.Disconnect.CONTINUE
		controls.drop_barrier_timeout_us = 250000
		var game: RefCounted = Game.new(count)
		var peer: Peer = Peer.new()
		context.equal(peer.configure(config, local, game, handshake, I.Options.new(), controls), I.Code.OK, "configure a five-peer mesh")
		peers.append(peer)
		games.append(game)
	var tokens: Array = []
	for player: int in range(peers.size()):
		var peer_tokens: Array[PackedByteArray] = []
		for remote: PackedByteArray in peers[player].peer_ids():
			peer_tokens.append(_id(remote[0] + player * 8, 16))
		tokens.append(peer_tokens)
	for index: int in range(peers.size()):
		context.equal(peers[index].begin(0, tokens[index]), I.Code.OK, "begin the five-peer mesh")
	var mesh: Dictionary = {"peers": peers, "games": games, "now": 0, "cuts": {}, "unconfirmed": 0, "reasons": [], "count": count}
	for _iteration: int in range(6):
		_deliver(context, mesh, _drain(mesh))
	return mesh


func _wait_for_departures(context: RefCounted, mesh: Dictionary, elapsed: int) -> void:
	var waited: int = 0
	while waited < elapsed:
		mesh.now += 1000
		waited += 1000
		for survivor: int in SURVIVORS:
			var polled: int = mesh.peers[survivor].poll(mesh.now)
			if polled == I.Code.TERMINATED:
				continue
			context.equal(polled, I.Code.OK, "poll a surviving peer")
		var packets: Array[Dictionary] = []
		for packet: Dictionary in _drain(mesh):
			if SURVIVORS.has(packet.to) and SURVIVORS.has(packet.from):
				packets.append(packet)
		_deliver(context, mesh, packets, true)
