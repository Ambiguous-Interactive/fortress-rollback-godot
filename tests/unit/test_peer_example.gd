extends RefCounted

# Value: protects=byte recovery/stalled controls; fails_when=retry/reset breaks; why_new=offline scene has no packet faults; seam=none
const Match = preload("res://examples/peer/match.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")


class ObservedGame:
	extends Match.Game
	var prefixes: Dictionary = {}

	func simulate_frame(input_frame: int, inputs: Types.FrameInputs) -> bool:
		var accepted: bool = super.simulate_frame(input_frame, inputs)
		if accepted:
			prefixes[frame] = canonical_bytes()
			while prefixes.size() > 32:
				var frames: Array = prefixes.keys()
				frames.sort()
				prefixes.erase(frames[0])
		return accepted


func cases() -> PackedStringArray:
	return PackedStringArray(["recovery", "sustained_faults", "reset", "scene", "scene_delay_actions"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"scene_delay_actions":
			_scene_delay_actions(context)
		"recovery":
			_recovery(context)
		"sustained_faults":
			_sustained_faults(context)
		"reset":
			_reset(context)
		"scene":
			var scene: PackedScene = load("res://examples/peer/peer.tscn")
			var node: Node = scene.instantiate()
			context.equal(node is Node2D, true, "playable scene loads without oracle dependencies")
			node.call("_ready")
			for tick: int in range(30):
				node.call("_physics_process", 1.0 / 60.0)
			node.free()
	context.finish()


func _recovery(context: RefCounted) -> void:
	var game: Match = _observed_match(context)
	var expected: Array[PackedByteArray] = _reference(600)
	for tick: int in range(240):
		game.tick(_buttons(game))
		context.equal(game.failure, I.Code.OK, "loss/reorder advances without protocol failure tick=%d" % tick)
	context.equal(game.dropped > 0, true, "configured loss actually drops bytes")
	context.equal(game.games[0].restores + game.games[1].restores > 0, true, "late changing input actually rewinds")
	game.is_partitioned = true
	for tick: int in range(60):
		game.tick(_buttons(game))
	context.equal(game.stalls[0] > 0 and game.stalls[1] > 0, true, "partition reaches prediction bound on both peers")
	var before: int = mini(game.games[0].frame, game.games[1].frame)
	game.is_partitioned = false
	game.drop_every = 0
	game.reorder = false
	game.latency_ticks = 0
	for tick: int in range(160):
		game.tick(_buttons(game))
		context.equal(game.failure, I.Code.OK, "retained samples recover after partition tick=%d" % tick)
		for peer: int in range(2):
			var frame: int = game.games[peer].frame
			if game.sessions[peer].status().confirmed_frame >= frame - 1:
				context.bytes_equal(game.games[peer].canonical_bytes(), expected[frame], frame, "seed=1701 confirmed canonical prefix vs submitted input history")
	context.equal(mini(game.games[0].frame, game.games[1].frame) > before + 100, true, "both peers resume beyond prediction window")
	# Peers may finish different frames; compare owned confirmed snapshots at one shared frame.
	var snapshots: Array[Dictionary] = [{}, {}]
	for tick: int in range(80):
		game.tick(PackedInt32Array([0, 0]))
		for peer: int in range(2):
			var observed: ObservedGame = game.games[peer]
			var boundary: int = mini(game.sessions[peer].status().confirmed_frame + 1, observed.frame)
			if boundary > 0 and observed.prefixes.has(boundary):
				snapshots[peer][boundary] = observed.prefixes[boundary].duplicate()
	var shared: int = mini(game.sessions[0].status().confirmed_frame, game.sessions[1].status().confirmed_frame) + 1
	shared = mini(shared, mini(game.games[0].frame, game.games[1].frame))
	context.equal(snapshots[0].has(shared) and snapshots[1].has(shared), true, "both peers retain a shared confirmed boundary")
	if snapshots[0].has(shared) and snapshots[1].has(shared):
		context.bytes_equal(snapshots[0][shared], snapshots[1][shared], shared, "seed=1701 full canonical state agrees after loss and partition")
	context.equal(game.sessions[0].status().confirmed_frame > before, true, "confirmation resumes")
	context.equal(game.sessions[1].status().confirmed_frame > before, true, "other peer confirmation resumes")
	context.equal(game.queued_packets() <= Match.MAX_PACKETS, true, "transport storage remains bounded")


# Value: protects=confirmed canonical prefixes during active faults; fails_when=rollback skips correction; why_new=recovery disabled faults before byte checks; seam=none
func _sustained_faults(context: RefCounted) -> void:
	var game: Match = _observed_match(context)
	var expected: Array[PackedByteArray] = _reference(3000)
	var comparisons: PackedInt32Array = PackedInt32Array([0, 0])
	var checked_frame: PackedInt32Array = PackedInt32Array([-1, -1])
	for tick: int in range(3000):
		game.tick(_buttons(game))
		context.equal(game.failure, I.Code.OK, "sustained faults remain playable tick=%d" % tick)
		context.equal(game.queued_packets() <= Match.MAX_PACKETS, true, "transport remains bounded tick=%d" % tick)
		for peer: int in range(2):
			var network: Dictionary = game.sessions[peer].network_status()
			for endpoint: Dictionary in network.peers.values():
				context.equal(endpoint.pending.size() <= 128, true, "pending input queue bounded peer=%d tick=%d" % [peer, tick])
				context.equal(endpoint.received.size() <= 128, true, "received input queue bounded peer=%d tick=%d" % [peer, tick])
			var observed: ObservedGame = game.games[peer]
			context.equal(observed.prefixes.size() <= 32, true, "owned observation ledger bounded")
			var boundary: int = mini(game.sessions[peer].status().confirmed_frame + 1, observed.frame)
			# Receive can advance confirmation before correction. Compare only after
			# this tick's driver has consumed the real correction/advance callbacks.
			if game.last_codes[peer] in [Types.Code.OK, Types.Code.PREDICTION_STALL] and boundary > checked_frame[peer] and boundary > 0:
				context.equal(observed.prefixes.has(boundary), true, "corrected confirmed boundary remains observed")
				if observed.prefixes.has(boundary):
					context.bytes_equal(observed.prefixes[boundary], expected[boundary], boundary,
						"seed=1701 active loss/reorder/latency confirmed prefix peer=%d tick=%d" % [peer, tick])
					comparisons[peer] += 1
					checked_frame[peer] = boundary
	context.equal(game.drop_every, 7, "default loss stays active during all comparisons")
	context.equal(game.reorder, true, "default reorder stays active during all comparisons")
	context.equal(game.latency_ticks, 3, "default latency stays active during all comparisons")
	context.equal(game.is_partitioned, false, "sustained scenario uses default packet faults")
	context.equal(game.dropped > 0, true, "sustained packet loss occurred")
	context.equal(game.games[0].restores + game.games[1].restores > 0, true, "sustained late input caused rollback")
	context.equal(comparisons[0] > 0 and comparisons[1] > 0, true, "both peers compare corrected confirmed prefixes under active faults")
	context.equal(mini(game.games[0].frame, game.games[1].frame) > 1500, true, "both peers progress for thousands of service ticks")
	context.equal(mini(game.sessions[0].status().confirmed_frame, game.sessions[1].status().confirmed_frame) > 1500, true, "confirmation keeps progressing")
	context.state(0, comparisons.to_byte_array())
	context.state(1, game.games[0].canonical_bytes())
	context.state(2, game.games[1].canonical_bytes())


func _observed_match(context: RefCounted) -> Match:
	var game: Match = Match.new()
	var ids: Array[PackedByteArray] = [PackedByteArray([1, 0, 0, 0, 0, 0, 0, 0]), PackedByteArray([2, 0, 0, 0, 0, 0, 0, 0])]
	for player: int in range(2):
		var config: Config = Config.new()
		config.sync_test = false
		config.check_distance = 0
		config.local_players = PackedInt32Array([player])
		config.input_delay = 2
		config.max_snapshot_bytes = Simulation.SNAPSHOT_BYTES
		config.storage_budget_bytes = config.required_storage_bytes()
		var profile: Match.T.Message = Match.T.Message.new()
		profile.kind = Match.T.Kind.SYNC_REQUEST
		profile.sender_id = ids[player].duplicate()
		profile.connection_id = ids[player].duplicate()
		profile.session_id[0] = 17
		profile.config.input_delay = 2
		profile.config.roster = [ids[0].duplicate(), ids[1].duplicate()]
		var handshake: Match.H.Options = Match.H.Options.new()
		handshake.roundtrips = 2
		var observed: ObservedGame = ObservedGame.new()
		var session: Match.Peer = Match.Peer.new()
		context.equal(session.configure(config, profile, observed, handshake, I.Options.new()), I.Code.OK, "observed example peer starts")
		game.sessions.append(session)
		game.games.append(observed)
		game.presentations.append(Match.Presentation.new())
		var token: PackedByteArray = PackedByteArray()
		token.resize(16)
		token[0] = 255 - player
		context.equal(session.begin(0, [token]), I.Code.OK, "observed example handshake starts")
	return game


func _buttons(game: Match) -> PackedInt32Array:
	return PackedInt32Array([(game.games[0].frame * 7) % 16, (game.games[1].frame * 3) % 16])


func _reset(context: RefCounted) -> void:
	var game: Match = Match.new()
	game.reset()
	for tick: int in range(80):
		game.tick(PackedInt32Array([2, 8]))
	context.equal(game.reset(), I.Code.OK, "reset rebuilds sessions and transport")
	context.equal(game.games[0].frame, 0, "first simulation reset")
	context.equal(game.games[1].frame, 0, "second simulation reset")
	context.equal(game.delivered, 0, "old packets and delivery count removed")
	context.equal(game.games[0].restores, 0, "rollback diagnostics reset")
	context.equal(game.tick(PackedInt32Array([16, 0])), I.Code.INVALID_ARGUMENT, "unsupported controls reject before simulation")
	context.equal(game.failure, I.Code.OK, "invalid controls keep the replacement retryable")
	context.equal(game.games[0].frame, 0, "bad controls preserve state")


func _reference(count: int) -> Array[PackedByteArray]:
	var config: Config = Config.new()
	config.check_distance = 0
	config.max_snapshot_bytes = Simulation.SNAPSHOT_BYTES
	config.storage_budget_bytes = config.required_storage_bytes()
	var session: Session = Session.new()
	session.configure(config)
	var simulation: Simulation = Simulation.new()
	var driver: Driver = Driver.new(session, simulation)
	var result: Array[PackedByteArray] = [simulation.canonical_bytes()]
	for frame: int in range(count):
		var first: int = 0 if frame < 2 else ((frame - 2) * 7) % 16
		var second: int = 0 if frame < 2 else ((frame - 2) * 3) % 16
		var inputs: Array[Driver.LocalInput] = [
			Driver.LocalInput.new(0, frame, PackedByteArray([first])),
			Driver.LocalInput.new(1, frame, PackedByteArray([second])),
		]
		driver.step(frame, inputs)
		result.append(simulation.canonical_bytes())
	return result


# Value: protects=peer scene delay prompts and keys after termination; fails_when=historical sessions advertise live actions;
# why_new=match tests do not inspect scene text or handlers; seam=actual scene and peer lifetime
func _scene_delay_actions(context: RefCounted) -> void:
	var scene: PackedScene = load("res://examples/peer/peer.tscn")
	var node: Node = scene.instantiate()
	node.call("_ready")
	var game: Match = node._match
	for phase: String in ["starting", "live", "stopped", "reset", "recovered", "match_failure"]:
		if phase in ["live", "recovered"]:
			for tick: int in 50:
				game.tick(PackedInt32Array([0, 0]))
		elif phase == "stopped":
			context.equal(game.sessions[0].close(game.now_us), Types.Code.OK, "actual local peer closure")
		elif phase == "reset":
			var reset: InputEventKey = InputEventKey.new()
			reset.pressed = true
			reset.keycode = KEY_R
			node.call("_unhandled_key_input", reset)
		elif phase == "match_failure":
			game._packets.append({"sender": 0, "due": game.now_us, "bytes": PackedByteArray([0])})
			context.equal(game.tick(PackedInt32Array([0, 0])) != I.Code.OK, true, "actual encoded delivery failure")
			context.equal(game.failure != I.Code.OK, true, "actual service failure stays latched")
			var stopped_at: int = game.now_us
			context.equal(game.tick(PackedInt32Array([0, 0])), game.failure, "later controls retain actual failure")
			context.equal(game.now_us, stopped_at, "latched service failure stops further service")
			var first_cause: int = game.failure
			context.equal(game.sessions[0].close(game.now_us), Types.Code.OK, "peer stops after earlier delivery failure")
			context.equal(game.tick(PackedInt32Array([0, 0])), first_cause, "terminal cleanup preserves earlier actual service failure")
			context.equal(game.sessions[1].status().lifecycle, Types.Lifecycle.TERMINATED, "earlier service failure does not strand terminal cleanup")
			node._delay_result = " | Preserve previous feedback."
		var actionable: bool = phase in ["live", "recovered"]
		node.call("_update_label")
		context.equal(node._label.text.contains("raise peer input delay"), actionable, phase + " peer delay prompt readiness")
		var before: PackedInt32Array = PackedInt32Array([game.sessions[0].input_delay(0), game.sessions[1].input_delay(1)])
		var feedback: String = node._delay_result
		for key: Key in [KEY_1, KEY_2]:
			var event: InputEventKey = InputEventKey.new()
			event.keycode = key
			event.pressed = true
			node.call("_unhandled_key_input", event)
		var after: PackedInt32Array = PackedInt32Array([game.sessions[0].input_delay(0), game.sessions[1].input_delay(1)])
		context.equal(after, PackedInt32Array([before[0] + 1, before[1] + 1]) if actionable else before, phase + " peer delay keys readiness")
		if not actionable:
			context.equal(node._delay_result, feedback, phase + " unavailable keys preserve feedback")
	node.free()
