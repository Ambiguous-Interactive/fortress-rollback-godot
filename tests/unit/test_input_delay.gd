extends RefCounted

# Value: protects=runtime input-delay changes; fails_when=added frames lose or alter input, decreases rewrite frames, or peers disagree; why_new=no runtime delay API; seam=none
const Game = preload("res://examples/integration/game.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const PeerMatch = preload("res://examples/peer/match.gd")
const FRAMES: int = 90


func cases() -> PackedStringArray:
	return PackedStringArray(["validates_changes", "repeats_latest_input", "peers_agree_after_changes"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"validates_changes":
			_validates_changes(context)
		"repeats_latest_input":
			_repeats_latest_input(context)
		"peers_agree_after_changes":
			_peers_agree_after_changes(context)
	context.finish()


static func _local(player: int, frame: int) -> int:
	if player == 1:
		return Game.FIRE if frame % 5 < 2 else Game.LEFT
	return (Game.RIGHT | Game.FIRE) if frame % 11 < 8 else Game.LEFT


static func _remote(frame: int) -> int:
	return (Game.FIRE if frame % 8 < 4 else 0) | (Game.LEFT if frame % 7 < 3 else Game.RIGHT)


static func _config(sync_test: bool, delay: int, capacity: int) -> Config:
	var config: Config = Config.new()
	config.input_delay = delay
	config.queue_capacity = capacity
	config.sync_test = sync_test
	config.local_players = PackedInt32Array([0, 1] if sync_test else [0])
	config.check_distance = 4 if sync_test else 0
	config.max_snapshot_bytes = Game.SNAPSHOT_BYTES
	config.replay_max_frames = FRAMES * 2
	config.storage_budget_bytes = config.required_storage_bytes()
	return config


func _validates_changes(context: RefCounted) -> void:
	var unconfigured: Session = Session.new()
	context.equal(unconfigured.set_input_delay(0, 1).code, Types.Code.NOT_CONFIGURED, "unconfigured session refuses")
	context.equal(unconfigured.input_delay(0), -1, "unconfigured session has no delay")
	var session: Session = Session.new()
	context.equal(session.configure(_config(false, 2, 128)), Types.Code.OK, "configures")
	var driver: Driver = Driver.new(session, Game.new())
	var largest: int = 128 - 8 - 2
	# Rows run in order on one session; "step" submits the frame's sample and advances.
	var rows: Array[Dictionary] = [
		{"label": "raises before the first sample", "delay": 5, "code": Types.Code.OK, "now": 5},
		{"label": "lowers before the first sample", "delay": 1, "code": Types.Code.OK, "now": 1},
		{"label": "refuses a remote slot", "player": 1, "delay": 2, "code": Types.Code.INVALID_PLAYER, "now": 1},
		{"label": "refuses a missing slot", "player": 2, "delay": 2, "code": Types.Code.INVALID_PLAYER, "now": 1},
		{"label": "refuses a negative delay", "delay": -1, "code": Types.Code.INVALID_CONFIGURATION, "now": 1},
		{"label": "refuses a delay the queue cannot hold", "delay": largest + 1, "code": Types.Code.INVALID_CONFIGURATION, "now": 1},
		{"step": true},
		{"label": "refuses a decrease after a sample", "delay": 0, "code": Types.Code.UNSUPPORTED, "now": 1},
		{"label": "accepts the current delay", "delay": 1, "code": Types.Code.OK, "now": 1},
		{"label": "accepts the largest supported delay", "delay": largest, "code": Types.Code.OK, "now": largest},
	]
	for row: Dictionary in rows:
		if row.get("step", false):
			var frame: int = session.status().current_frame
			context.equal(driver.step(frame, [Driver.LocalInput.new(0, frame, PackedByteArray([1]))]).code, Types.Code.OK, "steps")
			continue
		context.equal(session.set_input_delay(row.get("player", 0), row.delay).code, row.code, row.label)
		context.equal(session.input_delay(0), row.now, row.label + " leaves the expected delay")
	context.equal(session.input_delay(1), -1, "remote slots have no local delay")


## Each change applies once the match reaches its frame and, if set, its condition holds.
## The model below folds samples and changes in call order, independently of the queue.
func _repeats_latest_input(context: RefCounted) -> void:
	var rows: Array[Dictionary] = [
		{"label": "raise at frame zero before input", "lag": 0, "changes": [{"frame": 0, "delay": 3}]},
		{"label": "raise mid-match", "lag": 2, "delay": 1, "changes": [{"frame": 20, "delay": 4}]},
		{"label": "raise while stalled", "lag": 12, "changes": [{"frame": 5, "delay": 3, "when": "stalled"}]},
		{"label": "raise while a correction is pending", "lag": 3, "changes": [{"frame": 25, "delay": 2, "when": "rollback"}]},
		{
			"label": "rapid raises in a small wrapping queue", "lag": 3, "capacity": 14,
			"changes": [{"frame": 10, "delay": 1}, {"frame": 11, "delay": 2}, {"frame": 12, "delay": 3}, {"frame": 40, "delay": 4}],
		},
		{"label": "raise to the largest supported delay", "lag": 3, "capacity": 24, "changes": [{"frame": 15, "delay": 14}]},
		{"label": "sync-test players change separately", "sync_test": true, "changes": [{"frame": 5, "player": 1, "delay": 2}, {"frame": 50, "delay": 3}]},
	]
	for row: Dictionary in rows:
		_check_match(context, row)


func _check_match(context: RefCounted, row: Dictionary) -> void:
	var label: String = row.label
	var sync_test: bool = row.get("sync_test", false)
	var locals: PackedInt32Array = PackedInt32Array([0, 1] if sync_test else [0])
	var session: Session = Session.new()
	context.equal(session.configure(_config(sync_test, row.get("delay", 0), row.get("capacity", 128))), Types.Code.OK, label + " configures")
	var game: Game = Game.new()
	var driver: Driver = Driver.new(session, game)
	var applied: Array[PackedInt32Array] = [PackedInt32Array(), PackedInt32Array()]
	var model_delay: PackedInt32Array = PackedInt32Array([row.get("delay", 0), 0])
	var changes: Array = row.changes.duplicate()
	var delivered: int = 0
	var stepped: int = -1
	var code: int = Types.Code.OK
	var tick: int = 0
	while session.status().current_frame < FRAMES and tick < FRAMES * 4:
		if not sync_test:
			while delivered <= tick - row.lag:
				session.receive_input(1, delivered, PackedByteArray([_remote(delivered)]))
				delivered += 1
		var frame: int = session.status().current_frame
		if not changes.is_empty() and frame >= changes[0].frame and _condition_holds(changes[0].get("when", ""), code, session):
			var change: Dictionary = changes.pop_front()
			var player: int = change.get("player", 0)
			var series: PackedInt32Array = applied[player]
			if not series.is_empty():
				for added: int in range(change.delay - model_delay[player]):
					series.append(series[-1])
			model_delay[player] = change.delay
			var result: Types.Result = session.set_input_delay(player, change.delay)
			context.equal(result.code, Types.Code.OK, label + " accepts the change")
			context.equal(result.value, series.size() - 1, label + " reports the last scheduled frame")
		var samples: Array[Driver.LocalInput] = []
		for player: int in locals:
			if stepped != frame:
				if applied[player].is_empty():
					applied[player].resize(model_delay[player])
					applied[player].fill(0)
				applied[player].append(_local(player, frame))
			samples.append(Driver.LocalInput.new(player, frame, PackedByteArray([_local(player, frame)])))
		stepped = frame
		code = driver.step(tick, samples).code
		if code != Types.Code.OK and code != Types.Code.PREDICTION_STALL:
			context.equal(code, Types.Code.OK, label + " keeps running")
			return
		tick += 1
	context.equal(changes.is_empty(), true, label + " applies every change")
	if not sync_test:
		while delivered <= session.status().current_frame:
			session.receive_input(1, delivered, PackedByteArray([_remote(delivered)]))
			delivered += 1
		var last: int = session.status().current_frame
		applied[0].append(_local(0, last))
		context.equal(driver.step(tick, [Driver.LocalInput.new(0, last, PackedByteArray([_local(0, last)]))]).code, Types.Code.OK, label + " final tick")
	for player: int in locals:
		context.equal(session.input_delay(player), model_delay[player], label + " reports the delay in effect")
	_check_replay(context, label, session, applied, sync_test, game.canonical_bytes())


func _condition_holds(when: String, last_code: int, session: Session) -> bool:
	match when:
		"stalled":
			return last_code == Types.Code.PREDICTION_STALL
		"rollback":
			return session.status().pending_rollback_frame != -1
	return true


## The recording must hold the modelled inputs and replay to the live final state with every checksum.
func _check_replay(context: RefCounted, label: String, session: Session, applied: Array[PackedInt32Array], sync_test: bool, live: PackedByteArray) -> void:
	var replay: Replay = session.replay()
	var frames: int = session.status().current_frame
	context.equal(replay.frame_count(), frames, label + " records every simulated frame")
	context.equal(replay.skipped_frames(), 0, label + " skips nothing")
	var wrong: int = 0
	for frame: int in range(frames):
		var inputs: Types.FrameInputs = replay.inputs(frame)
		var second: int = applied[1][frame] if sync_test else _remote(frame)
		if inputs.read(0).bytes != PackedByteArray([applied[0][frame]]) or inputs.read(1).bytes != PackedByteArray([second]):
			wrong += 1
	context.equal(wrong, 0, label + " schedules exactly the modelled inputs")
	var game: Game = Game.new()
	var player: Player = Player.new()
	context.equal(player.configure(replay, game, Game.SNAPSHOT_BYTES), Types.Code.OK, label + " player configures")
	var code: int = Types.Code.OK
	while code == Types.Code.OK:
		code = player.step()
	context.equal(code, Types.Code.FRAME_EXHAUSTED, label + " validates every checksum")
	context.bytes_equal(game.canonical_bytes(), live, frames, label + " replays to the live final state")


## Two real peer sessions over a lossy, reordering link raise their delay while running.
## "block" withholds packets and "hold" delivers without stepping, for the listed tick ranges.
## Each raise retries from its tick until accepted, since interruptions and backpressure refuse it for a while.
func _peers_agree_after_changes(context: RefCounted) -> void:
	var largest: int = PeerMatch.Peer.max_input_delay(Config.new())
	var rows: Array[Dictionary] = [
		{"label": "repeated raises", "raises": {40: [0, 3], 41: [0, 4], 60: [1, 5], 90: [0, 16], 91: [1, 16]}, "final": [16, 16]},
		{"label": "both peers at the largest delay", "raises": {40: [0, largest], 41: [1, largest]}, "final": [largest, largest]},
		{"label": "raise after a backpressured step", "pending": 6, "block": [40, 60], "hold": [60, 160], "raises": {61: [0, 3]}, "by": 160, "final": [3, 2]},
	]
	for row: Dictionary in rows:
		var label: String = row.label
		var peers: PeerMatch = PeerMatch.new()
		peers.replay_frames = 600
		peers.max_pending_frames = row.get("pending", 128)
		context.equal(peers.reset(), PeerMatch.I.Code.OK, label + " starts")
		context.equal(peers.sessions[0].set_input_delay(0, 3), Types.Code.NOT_SYNCHRONIZED, label + " refuses before synchronizing")
		var refused: int = 0
		var backpressured: int = 0
		var waiting: Array = []
		var last_raise: int = -1
		for tick: int in range(400):
			var block: Array = row.get("block", [-1, -1])
			var hold: Array = row.get("hold", [-1, -1])
			peers.is_partitioned = tick >= block[0] and tick < block[1]
			if row.raises.has(tick):
				waiting.append(row.raises[tick])
			if not waiting.is_empty() and peers.sessions[waiting[0][0]].set_input_delay(waiting[0][0], waiting[0][1]) == Types.Code.OK:
				waiting.pop_front()
				last_raise = tick
			if peers.sessions[0].network_status().state == "running":
				refused += int(peers.sessions[0].set_input_delay(0, 1) != Types.Code.UNSUPPORTED)
				refused += int(peers.sessions[0].set_input_delay(0, -1) != Types.Code.INVALID_CONFIGURATION)
				refused += int(peers.sessions[0].set_input_delay(0, largest + 1) != Types.Code.INVALID_CONFIGURATION)
				refused += int(peers.sessions[0].set_input_delay(1, 9) != Types.Code.INVALID_PLAYER)
			peers.tick(PackedInt32Array([tick % 13 % 16, (tick * 7) % 11 % 16]), tick < hold[0] or tick >= hold[1])
			backpressured += int(peers.last_codes[0] == Types.Code.NETWORK_BACKPRESSURE)
		context.equal(waiting.is_empty() and last_raise < row.get("by", 400), true, label + " accepts every raise in time")
		context.equal(refused, 0, label + " refuses lower, out-of-range and remote changes on every tick")
		context.equal(backpressured > 0, row.has("pending"), label + " reaches backpressure only when limited")
		context.equal(peers.failure, PeerMatch.I.Code.OK, label + " has no failure")
		for player: int in range(2):
			context.equal(peers.sessions[player].status().lifecycle, Types.Lifecycle.RUNNING, label + " peer %d keeps running" % player)
			context.equal(peers.event_counts[player].get("desync_detected", 0), 0, label + " peer %d sees no desync" % player)
			context.equal(peers.sessions[player].input_delay(player), row.final[player], label + " peer %d ends at its delay" % player)
		var first: Replay = peers.sessions[0].replay()
		var second: Replay = peers.sessions[1].replay()
		var common: int = mini(first.frame_count(), second.frame_count())
		context.equal(common > 150, true, label + " confirms frames past every change")
		var differing: int = 0
		for frame: int in range(common):
			for slot: int in range(2):
				differing += int(first.inputs(frame).read(slot).bytes != second.inputs(frame).read(slot).bytes)
		context.equal(differing, 0, label + " records the same inputs on both peers")
