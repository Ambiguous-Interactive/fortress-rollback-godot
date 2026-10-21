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
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["continue", "halt", "frozen_value", "exported_row", "confirmed_row", "lockstep", "delay"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"continue":
			_continue(context)
		"halt":
			_halt(context)
		"frozen_value":
			_frozen_value(context)
		"exported_row":
			_exported_row(context)
		"confirmed_row":
			_confirmed_row(context)
		"lockstep":
			_lockstep(context)
		"delay":
			_delay(context)
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


## Two peers with the lifecycle enabled, so a silent peer is detected by the timeout.
func _build(context: RefCounted, behavior: int, window: int = 8) -> Dictionary:
	var peers: Array[Peer] = []
	var games: Array[RefCounted] = []
	for player: int in range(2):
		var config: Config = Config.new()
		config.player_count = 2
		config.local_players = PackedInt32Array([player])
		config.input_width = 4
		config.neutral_input = PackedByteArray([0, 0, 0, 0])
		config.input_delay = 0
		config.max_prediction_frames = window
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
		local.config.max_prediction = window
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


## The departed peer plays ahead while the survivor waits, so the survivor holds inputs that
## its own confirmed frontier has not reached yet.
func _leave(context: RefCounted, mesh: Dictionary, departed: int, survivor: int) -> void:
	for frame: int in range(3):
		mesh.now += 1000
		mesh.peers[departed].step(mesh.now, _inputs(mesh, departed))
		_deliver(context, mesh, _drain(mesh))
	context.equal(mesh.peers[survivor].status().current_frame < mesh.peers[departed].status().current_frame, true, "the survivor lags the departed peer")


## The survivor notices the silent peer and freezes its slot.
func _detect(context: RefCounted, mesh: Dictionary, survivor: int) -> int:
	mesh.now += 500000
	context.equal(mesh.peers[survivor].poll(mesh.now), I.Code.OK, "poll detects the silent peer")
	var cut: int = -1
	for event: Dictionary in mesh.peers[survivor].drain_events():
		if event.kind == "peer_dropped":
			cut = event.frame
	return cut


## The survivor keeps playing after the other one goes silent.
func _continue(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE)
	_play(context, mesh, 6)
	# The survivor is the second peer, so the departed player owns the first slot.
	var survivor: Peer = mesh.peers[1]
	var confirmed_before: int = survivor.status().confirmed_frame
	var frame_before: int = survivor.status().current_frame
	_leave(context, mesh, 0, 1)
	var cut: int = _detect(context, mesh, 1)
	context.equal(cut >= 0, true, "the survivor publishes the drop")
	context.equal(survivor.status().lifecycle, Types.Lifecycle.RUNNING, "the match survives the departure")
	# More frames than the prediction window, so a frontier that stops moving stalls the match.
	_play(context, mesh, 16, true)
	context.equal(survivor.status().current_frame, frame_before + 16, "the survivor keeps advancing")
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
	var survivor: Peer = mesh.peers[1]
	var game: RefCounted = mesh.games[1]
	var rows_before: Dictionary = _rows(game)
	_leave(context, mesh, 0, 1)
	var cut: int = _detect(context, mesh, 1)
	context.equal(cut >= 0, true, "the survivor records the agreed frame")
	var frame_at_drop: int = survivor.status().current_frame
	_play(context, mesh, 4, true)
	var rows_after: Dictionary = _rows(game)
	# A confirmed input is immutable, so the confirmed history before the drop never changes.
	for frame: int in range(mini(rows_before.size(), cut + 1)):
		for slot: int in range(2):
			if rows_before[frame][slot].status != "confirmed":
				continue
			context.equal(rows_after[frame][slot].bytes, rows_before[frame][slot].bytes, "confirmed history before the drop is unchanged")
	# Every frame after the agreed frame repeats the value confirmed at that frame.
	var departed: String = rows_after[cut][0].bytes
	for frame: int in range(cut + 1, rows_after.size()):
		context.equal(rows_after[frame][0].bytes, departed, "the departed slot repeats one frozen value")
	# Frames simulated after the drop report the disconnected status.
	for frame: int in range(frame_at_drop + 1, rows_after.size()):
		context.equal(rows_after[frame][0].status, "disconnected", "the departed slot reports a disconnected status")


## The exported confirmed rows are the rows the simulation consumed.
func _exported_row(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE)
	_play(context, mesh, 6, true)
	var survivor: Peer = mesh.peers[1]
	var game: RefCounted = mesh.games[1]
	_leave(context, mesh, 0, 1)
	var cut: int = _detect(context, mesh, 1)
	_play(context, mesh, 4, true)
	var rows: Dictionary = _rows(game)
	var replay: RefCounted = survivor.replay()
	context.equal(replay != null, true, "the survivor records the confirmed rows")
	var exported: int = 0
	for frame: int in range(replay.frame_count()):
		var inputs: Types.FrameInputs = replay.inputs(frame)
		if inputs == null or not rows.has(frame):
			continue
		exported += 1
		context.equal(inputs.read(0).bytes.hex_encode(), rows[frame][0].bytes, "the exported row is the row the simulation used")
	context.equal(exported > cut, true, "the exported rows reach past the agreed frame")
	context.equal(replay.is_skipped_frame(cut), false, "the frozen row is not skipped")


## A lockstep session keeps advancing after the drop.
func _lockstep(context: RefCounted) -> void:
	var settings: Config = Config.new()
	settings.sync_test = false
	settings.local_players = PackedInt32Array([0])
	settings.check_distance = 0
	settings.input_width = 1
	settings.neutral_input = PackedByteArray([0])
	settings.max_prediction_frames = 0
	settings.max_snapshot_bytes = 16
	settings.storage_budget_bytes = 65536
	var session: RefCounted = Session.new()
	context.equal(session.configure(settings), Session.Code.OK, "configure the lockstep session")
	_advance(context, session, 0, PackedByteArray([1]))
	_advance(context, session, 1, PackedByteArray([2]))
	context.equal(session.freeze_player(1, 1), Session.Code.OK, "freeze the remote slot")
	context.equal(session.submit_local_input(0, 2, PackedByteArray([7])).code, Session.Code.OK, "local sample")
	# A frozen slot repeats its agreed value, so it never blocks a lockstep advance.
	context.equal(session.begin_advance().code, Session.Code.READY, "the lockstep advance is ready")


## A delay change after the drop does not end the match.
func _delay(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE)
	_play(context, mesh, 6)
	var survivor: Peer = mesh.peers[1]
	_leave(context, mesh, 0, 1)
	_detect(context, mesh, 1)
	context.equal(survivor.set_input_delay(1, 1), Types.Code.OK, "the delay change is accepted")
	context.equal(survivor.status().reason, Types.Code.OK, "the match survives the delay change")
	context.equal(survivor.status().lifecycle, Types.Lifecycle.RUNNING, "the match is still running")


## The confirmed input row of a dropped slot is the row the simulation used.
func _confirmed_row(context: RefCounted) -> void:
	var settings: Config = Config.new()
	settings.sync_test = false
	settings.local_players = PackedInt32Array([0])
	settings.check_distance = 0
	settings.input_width = 1
	settings.neutral_input = PackedByteArray([0])
	settings.max_snapshot_bytes = 16
	settings.storage_budget_bytes = 65536
	var session: RefCounted = Session.new()
	context.equal(session.configure(settings), Session.Code.OK, "configure the core session")
	_advance(context, session, 0, PackedByteArray([1]))
	_advance(context, session, 1, PackedByteArray([2]))
	# The departed peer sent one more input before it left, and that input is stale.
	context.equal(session.receive_input(1, 2, PackedByteArray([3])).code, Session.Code.OK, "late remote input")
	context.equal(session.freeze_player(1, 1), Session.Code.OK, "freeze the remote slot")
	_advance(context, session, 2, PackedByteArray([9]))
	var row: Types.FrameInputs = session.confirmed_inputs(2)
	context.equal(row != null, true, "the confirmed row is available")
	context.equal(row.read(1).bytes, PackedByteArray([2]), "the confirmed row is the frozen value")
	context.equal(row.read(1).status, Queue.Status.DISCONNECTED, "the confirmed row reports the disconnected status")
	context.equal(row.read(0).bytes, PackedByteArray([7]), "the local row is unchanged")


## Advance one frame of the core session with a remote input for that frame.
func _advance(context: RefCounted, session: RefCounted, frame: int, remote: PackedByteArray) -> void:
	context.equal(session.receive_input(1, frame, remote).code, Session.Code.OK, "remote input")
	context.equal(session.submit_local_input(0, frame, PackedByteArray([7])).code, Session.Code.OK, "local sample")
	var result: RefCounted = session.begin_advance()
	context.equal(result.code, Session.Code.READY, "ready")
	var request: RefCounted = result.batch.next_request()
	while request != null:
		if request.kind == Session.Kind.SAVE:
			request.writer.write_bytes(PackedByteArray([0]))
		var checksum: PackedByteArray = PackedByteArray()
		checksum.resize(16)
		context.equal(session.complete_request(request.batch_id, request.request_id, true, checksum).code, Session.Code.OK, "complete request")
		request = result.batch.next_request()


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
