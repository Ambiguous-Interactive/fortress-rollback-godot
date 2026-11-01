extends RefCounted

# Value: protects=fixed-membership timeout halt; fails_when=partition advances or silently recovers; why_new=P3 covered only healed short faults; seam=none
const Match = preload("res://examples/peer/match.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
const SnapshotStatus = preload("res://addons/fortress_rollback/core/snapshot_status.gd")


class FailingGame:
	extends Match.Game
	var failed_writer: RefCounted

	func save_state(_frame: int, writer: Match.Simulation.Writer) -> Driver.SaveResult:
		failed_writer = writer
		return Driver.SaveResult.new(false)



func cases() -> PackedStringArray:
	return PackedStringArray(["terminal_partition", "interruption_recovery", "game_desync"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"terminal_partition":
			_terminal_partition(context)
		"interruption_recovery":
			_interruption_recovery(context)
		"game_desync":
			_game_desync(context)
	context.finish()


func _healthy(context: RefCounted) -> Match:
	var game: Match = Match.new()
	game.drop_every = 0
	game.reorder = false
	game.latency_ticks = 0
	context.equal(game.reset(), 0, "playable byte peers start")
	for tick: int in range(120):
		game.tick(PackedInt32Array([2, 8]))
	context.equal(game.games[0].frame > 60 and game.games[1].frame > 60, true, "healthy peers advance before partition")
	return game


func _terminal_partition(context: RefCounted) -> void:
	var game: Match = _healthy(context)
	var confirmed: PackedInt64Array = PackedInt64Array([
		game.sessions[0].status().confirmed_frame, game.sessions[1].status().confirmed_frame])
	game.is_partitioned = true
	for tick: int in range(450):
		game.tick(PackedInt32Array([2, 8]))
	context.equal(game.tick(PackedInt32Array([2, 8])), I.Code.INPUT_FAILED, "terminal partition reports a reset-required match")
	context.equal(game.failure, I.Code.INPUT_FAILED, "terminal partition latches its failure")
	var frozen: Array[PackedByteArray] = []
	for peer: int in range(2):
		context.equal(game.sessions[peer].status().lifecycle, Types.Lifecycle.TERMINATED, "unrecoverable fixed-membership partition terminates peer=%d" % peer)
		context.equal(game.sessions[peer].status().reason != Types.Code.OK, true, "termination retains explicit reason")
		context.equal(game.sessions[peer].status().confirmed_frame >= confirmed[peer], true, "termination never revokes confirmed history")
		frozen.append(game.games[peer].canonical_bytes())
	game.is_partitioned = false
	for tick: int in range(60):
		game.tick(PackedInt32Array([1, 4]))
	for peer: int in range(2):
		context.bytes_equal(game.games[peer].canonical_bytes(), frozen[peer], game.games[peer].frame, "healing cannot restart a terminated session")
	context.equal(game.reset(), 0, "explicit restart rebuilds the fixed roster")
	for tick: int in range(80):
		game.tick(PackedInt32Array([1, 4]))
	context.equal(game.games[0].frame > 40 and game.games[1].frame > 40, true, "restarted peers advance")
	for departed: int in 2:
		var closed: Match = _healthy(context)
		context.equal(closed.sessions[departed].close(closed.now_us), Types.Code.OK, "one owned peer explicitly departs")
		var reason: int = closed.sessions[departed].status().reason
		context.equal(closed.tick(PackedInt32Array([2, 8])), I.Code.INPUT_FAILED, "one terminal fixed member reports a stopped match")
		for player: int in 2:
			context.equal(closed.sessions[player].status().lifecycle, Types.Lifecycle.TERMINATED, "match cleanup retires both retained peer handles")
		context.equal(closed.sessions[departed].status().reason, reason, "cleanup preserves the departed peer first cause")
		var stopped_at: int = closed.now_us
		context.equal(closed.tick(PackedInt32Array([2, 8])), I.Code.INPUT_FAILED, "terminal result stays latched on later controls")
		context.equal(closed.now_us, stopped_at, "stopped match consumes no further service time")
	for failed: int in 2:
		var callback_failure: Match = _healthy(context)
		var failing_game: FailingGame = FailingGame.new()
		var frame: int = callback_failure.games[failed].frame
		context.equal(failing_game.load_state(frame, Match.Reader.new(callback_failure.games[failed].canonical_bytes(), true)), true, "failure fixture restores canonical state")
		context.equal(callback_failure.sessions[failed]._driver.configure(callback_failure.sessions[failed]._core, failing_game), Types.Code.OK, "attach actual failing SAVE callback")
		callback_failure.games[failed] = failing_game
		var other_before: int = callback_failure.games[1 - failed].frame
		context.equal(callback_failure.tick(PackedInt32Array([2, 8])), I.Code.INPUT_FAILED, "callback termination reports stopped match")
		context.equal(callback_failure.sessions[failed].status().reason, Types.Code.CALLBACK_FAILED, "cleanup retains callback first cause")
		context.equal(failing_game.failed_writer.status(), SnapshotStatus.Code.EXPIRED_VIEW, "terminal cleanup leaves retained writer expired")
		context.equal(callback_failure.sessions[1 - failed].status().lifecycle, Types.Lifecycle.TERMINATED, "callback failure retires retained counterpart")
		if failed == 0:
			context.equal(callback_failure.games[1].frame, other_before, "first endpoint failure prevents later counterpart simulation")

	_delivery_terminal_order(context)


# Value: protects=visible interruption and resume; fails_when=timer or healing event is lost; why_new=timeout case only checks terminal states; seam=none
func _interruption_recovery(context: RefCounted) -> void:
	var game: Match = _healthy(context)
	game.is_partitioned = true
	for tick: int in range(44):
		game.tick(PackedInt32Array([2, 8]))
	var before: PackedInt32Array = PackedInt32Array([game.games[0].frame, game.games[1].frame])
	for peer: int in range(2):
		context.equal(game.event_counts[peer].get("network_interrupted", 0), 1, "short partition visibly interrupts once")
		context.equal(game.sessions[peer].status().lifecycle, Types.Lifecycle.RUNNING, "short partition remains recoverable")
	game.is_partitioned = false
	for tick: int in range(160):
		game.tick(PackedInt32Array([2, 8]))
	for peer: int in range(2):
		context.equal(game.event_counts[peer].get("network_resumed", 0), 1, "healing visibly resumes once")
		context.equal(game.games[peer].frame > before[peer] + 100, true, "resumed peer advances beyond prediction window")
		context.equal(game.sessions[peer].status().lifecycle, Types.Lifecycle.RUNNING, "healed peer remains live")
	context.equal(game.failure, 0, "ordinary interruption is an observable lifecycle event")


# Value: protects=game checksum mismatch halt; fails_when=divergence is accepted; why_new=endpoint reports cannot prove game integration; seam=none
func _game_desync(context: RefCounted) -> void:
	for at_boundary: bool in [false, true]:
		_desync_from(context, at_boundary)


func _desync_from(context: RefCounted, at_boundary: bool) -> void:
	var game: Match = _healthy(context)
	if at_boundary:
		game.drop_every = 7
		game.reorder = true
		game.latency_ticks = 3
		for tick: int in range(450):
			game.tick(PackedInt32Array([2, 0]))
		context.equal(game.games[0].x[0], 460, "real input reaches valid right boundary before divergence")
	game.inject_desync()
	var observed: bool = false
	for tick: int in range(240):
		game.tick(PackedInt32Array([2 if tick % 2 == 0 else 0, 4 if tick % 2 == 0 else 8]))
		for peer: int in range(2):
			var event: Dictionary = game.latest_events[peer]
			if event.get("kind", "") == "desync_detected":
				observed = true
				context.equal(event.frame > 0, true, "mismatch identifies actual saved frame")
				context.equal(event.local_checksum.size() == 16 and event.remote_checksum.size() == 16, true, "mismatch preserves full checksum domain")
				context.equal(event.local_checksum != event.remote_checksum, true, "diagnostics retain the differing game checksums")
	context.equal(observed, true, "wrong game rules produce a real desync event")
	for peer: int in range(2):
		context.equal(game.sessions[peer].status().lifecycle, Types.Lifecycle.TERMINATED, "every fixed member has an explicit terminal outcome")
		var frozen: PackedByteArray = game.games[peer].canonical_bytes()
		game.tick(PackedInt32Array([1, 4]))
		context.bytes_equal(game.games[peer].canonical_bytes(), frozen, game.games[peer].frame, "terminal mismatch forbids another game step")


# Value: protects=first delivery cause and terminal fences; fails_when=later packets overwrite terminal failure; why_new=terminal checks ran after whole delivery batch; seam=none
func _delivery_terminal_order(context: RefCounted) -> void:
	for sender: int in 2:
		for terminal_first: bool in [false, true]:
			var game: Match = _healthy(context)
			var goodbye: Match.T.Message = Match.T.Message.new()
			goodbye.kind = Match.T.Kind.GOODBYE
			goodbye.session_id[0] = 17
			goodbye.sender_id = game._ids[sender].duplicate()
			goodbye.connection_id = game._ids[sender].duplicate()
			var encoded: Match.T.Result = Codec.encode(goodbye, Match.T.Limits.new())
			context.equal(encoded.code, Match.T.Code.OK, "real goodbye packet encodes for the existing incarnation")
			var terminal: Dictionary = {"sender": sender, "due": game.now_us, "bytes": encoded.bytes}
			var malformed: Dictionary = {"sender": 1 - sender, "due": game.now_us, "bytes": PackedByteArray([0])}
			game._packets = [{"sender": sender, "due": game.now_us + 100 * Match.TICK_US, "bytes": encoded.bytes}]
			game._packets.append(terminal if terminal_first else malformed)
			game._packets.append(malformed if terminal_first else terminal)
			var expected: int = I.Code.INPUT_FAILED if terminal_first else I.Code.INVALID_PACKET
			var frames: PackedInt32Array = PackedInt32Array([game.games[0].frame, game.games[1].frame])
			context.equal(game.tick(PackedInt32Array([2, 8])), expected, "packet ordering preserves the first failure domain")
			context.equal(game.failure, expected, "delivery failure remains latched")
			context.equal(game.sessions[1 - sender].status().reason, Types.Code.PROTOCOL_FAILED, "received goodbye retains its actual terminal cause")
			for player: int in 2:
				context.equal(game.sessions[player].status().lifecycle, Types.Lifecycle.TERMINATED, "terminal receive retires both fixed peers")
				context.equal(game.games[player].frame, frames[player], "terminal delivery prevents all later simulation callbacks")
			context.equal(game.queued_packets(), 0, "terminal cleanup cannot restore earlier retained future packets")
