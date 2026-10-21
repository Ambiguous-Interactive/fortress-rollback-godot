extends RefCounted

# Value: a departed peer freezes its slot and the survivors keep playing; fails_when=the match ends or the confirmed frontier stops; why_new=graceful drop; seam=none
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const H = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const L = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")
const Game = preload("res://tests/oracle/p2p_game.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["continue", "halt", "frozen_value"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"continue":
			_continue(context)
		"halt":
			_halt(context)
		"frozen_value":
			_frozen_value(context)
	context.finish()


func _id(value: int, width: int = 8) -> PackedByteArray:
	var result: PackedByteArray = PackedByteArray()
	result.resize(width)
	result[0] = value + 1
	return result


func _sample(player: int, frame: int) -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray([0, 0, 0, 0])
	bytes.encode_s32(0, (mini(frame, 3) + 1) * (player + 1))
	return bytes


## Two peers with the lifecycle enabled, so a silent peer is detected by the timeout.
func _build(context: RefCounted, behavior: int) -> Dictionary:
	var peers: Array[Peer] = []
	var games: Array[RefCounted] = []
	for player: int in range(2):
		var config: Config = Config.new()
		config.player_count = 2
		config.local_players = PackedInt32Array([player])
		config.input_width = 4
		config.neutral_input = PackedByteArray([0, 0, 0, 0])
		config.input_delay = 0
		config.max_prediction_frames = 8
		config.history_slots = 9
		config.check_distance = 0
		config.sync_test = false
		config.max_snapshot_bytes = 4 * 5
		config.storage_budget_bytes = 1048576
		config.replay_max_frames = 64
		var local: T.Message = T.Message.new()
		local.kind = T.Kind.SYNC_REQUEST
		local.sender_id = _id(player)
		local.connection_id = _id(player + 20)
		local.session_id = _id(90, 16)
		local.config.player_count = 2
		local.config.input_width = 4
		local.config.input_delay = 0
		local.config.max_prediction = 8
		local.config.desync_interval = 60
		local.config.neutral_input = config.neutral_input.duplicate()
		local.config.roster = [_id(0), _id(1)]
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
		var game: RefCounted = Game.new(2)
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
	var mesh: Dictionary = {"peers": peers, "games": games, "now": 0}
	for iteration: int in range(6):
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


func _deliver(context: RefCounted, mesh: Dictionary, packets: Array[Dictionary]) -> void:
	for packet: Dictionary in packets:
		context.equal(mesh.peers[packet.to].receive(packet.bytes, _id(packet.from), mesh.now), I.Code.OK, "deliver encoded packet")


## Both peers advance and exchange packets for the given frames.
func _play(context: RefCounted, mesh: Dictionary, frames: int, keep: bool = false) -> void:
	for frame: int in range(frames):
		mesh.now += 1000
		for index: int in range(mesh.peers.size()):
			context.equal(mesh.peers[index].step(mesh.now, _inputs(mesh, index)).code, Types.Code.OK, "advance peer")
		if not keep:
			for game: RefCounted in mesh.games:
				game.requests.clear()
		_deliver(context, mesh, _drain(mesh))
		_deliver(context, mesh, _drain(mesh))


## The surviving peer keeps playing after the other one goes silent.
func _continue(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE)
	_play(context, mesh, 6)
	var survivor: Peer = mesh.peers[0]
	var confirmed_before: int = survivor.status().confirmed_frame
	var frame_before: int = survivor.status().current_frame
	# The remote peer leaves: it stops sending and the survivor stops hearing from it.
	mesh.now += 500000
	context.equal(survivor.poll(mesh.now), I.Code.OK, "poll detects the silent peer")
	var dropped: bool = false
	for event: Dictionary in survivor.drain_events():
		if event.kind == "peer_dropped":
			dropped = true
			context.equal(event.frame >= 0, true, "drop event names the agreed frame")
	context.equal(dropped, true, "survivor publishes the drop")
	context.equal(survivor.status().lifecycle, Types.Lifecycle.RUNNING, "the match survives the departure")
	_play(context, mesh, 4)
	context.equal(survivor.status().current_frame > frame_before, true, "the survivor keeps advancing")
	context.equal(survivor.status().confirmed_frame > confirmed_before, true, "the confirmed frontier keeps moving")
	context.equal(survivor.status().reason, Types.Code.OK, "no terminal cause")


## The default policy still ends the match when a peer goes silent.
func _halt(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, L.Disconnect.HALT)
	_play(context, mesh, 4)
	var survivor: Peer = mesh.peers[0]
	mesh.now += 500000
	survivor.poll(mesh.now)
	context.equal(survivor.status().lifecycle, Types.Lifecycle.TERMINATED, "the match ends with the default policy")
	context.equal(survivor.status().reason, Types.Code.PROTOCOL_FAILED, "the departure is the terminal cause")


## The frozen slot repeats one value and the confirmed history before it never changes.
func _frozen_value(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE)
	_play(context, mesh, 6, true)
	var survivor: Peer = mesh.peers[0]
	var game: RefCounted = mesh.games[0]
	var rows_before: Dictionary = _rows(game)
	mesh.now += 500000
	survivor.poll(mesh.now)
	var cut: int = -1
	for row: Dictionary in survivor.diagnostics().peers:
		if row.get("dropped", false):
			cut = row.freeze_frame
	context.equal(cut >= 0, true, "the survivor records the agreed frame")
	var frame_at_drop: int = survivor.status().current_frame
	_play(context, mesh, 4, true)
	var rows_after: Dictionary = _rows(game)
	# The rows before the agreed frame are the confirmed history and never change.
	for frame: int in range(mini(rows_before.size(), cut + 1)):
		context.equal(rows_after[frame], rows_before[frame], "confirmed history before the drop is unchanged")
	# Every frame after the agreed frame repeats the value confirmed at that frame.
	var departed: String = rows_after[cut][1].bytes
	for frame: int in range(cut + 1, rows_after.size()):
		context.equal(rows_after[frame][1].bytes, departed, "the departed slot repeats one frozen value")
	# Frames simulated after the drop report the disconnected status.
	for frame: int in range(frame_at_drop, rows_after.size()):
		context.equal(rows_after[frame][1].status, "disconnected", "the departed slot reports a disconnected status")


## The input rows the game actually simulated, keyed by frame; a resimulated frame wins.
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
