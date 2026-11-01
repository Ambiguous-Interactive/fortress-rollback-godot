extends RefCounted

# Value: protects=departed playable scenes retire retained game capabilities; fails_when=old drivers still advance;
# why_new=scene smoke tests only free nodes; seam=none
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const IntegrationGame = preload("res://examples/integration/game.gd")
const Writer = preload("res://addons/fortress_rollback/core/snapshot_writer.gd")
const Reader = preload("res://addons/fortress_rollback/core/snapshot_reader.gd")


class ClosingGame:
	extends IntegrationGame
	var closing: Callable

	func save_state(frame: int, writer: Writer) -> Driver.SaveResult:
		if closing.is_valid():
			closing.call()
		return super.save_state(frame, writer)


func cases() -> PackedStringArray:
	return PackedStringArray(["retained_handles", "active_batches", "active_callbacks"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "active_callbacks":
		_callbacks(context)
	else:
		for example: String in ["offline", "integration", "peer"]:
			for failed: bool in [false, true]:
				_retained(context, example, failed, name == "active_batches")
		if name == "active_batches":
			for example: String in ["offline", "integration"]:
				_busy_retry(context, example)
	if name == "active_batches":
		_expert_gap_recovery(context)
	context.finish()


func _fixture(example: String) -> Dictionary:
	var scene: PackedScene = load("res://examples/%s/%s.tscn" % [example, example])
	var node: Node = scene.instantiate()
	node.call("_ready")
	var sessions: Array[RefCounted] = []
	var drivers: Array[Driver] = []
	var games: Array[RefCounted] = []
	var replay: RefCounted
	if example == "offline":
		sessions.append(node.get("_session"))
		drivers.append(node.get("_driver"))
		games.append(node.get("_simulation"))
	elif example == "integration":
		var demo: RefCounted = node.get("_demo")
		demo.set_lag(0)
		demo.tick(IntegrationGame.RIGHT)
		demo.start_replay()
		replay = demo.replay_player
		sessions.append(demo.loop.session)
		drivers.append(demo.loop.driver)
		games.append(demo.loop.game)
	else:
		var match_game: RefCounted = node.get("_match")
		for tick: int in range(80):
			match_game.tick(PackedInt32Array([0, 0]), false)
		for peer: RefCounted in match_game.sessions:
			sessions.append(peer._core)
			drivers.append(peer._driver)
		games.assign(match_game.games)
	return {"node": node, "sessions": sessions, "drivers": drivers, "games": games, "replay": replay}


func _retained(context: RefCounted, example: String, failed: bool, manual: bool) -> void:
	var fixture: Dictionary = _fixture(example)
	var node: Node = fixture.node
	var requests: Array[Types.Request] = []
	for session: RefCounted in fixture.sessions:
		var frame: int = session.status().current_frame
		if failed:
			session.terminate(Types.Code.DESYNC, frame)
		elif manual:
			for player: int in range(2):
				if session.input_delay(player) >= 0:
					context.equal(session.submit_local_input(player, frame, PackedByteArray([0])).code, Types.Code.OK, example + " stages manual sample")
			var opened: Types.Result = session.begin_advance()
			context.equal(opened.code, Types.Code.READY, example + " opens manual request before exit")
			if opened.batch != null:
				requests.append(opened.batch.next_request())
	var states: Array[PackedByteArray] = []
	for game: RefCounted in fixture.games:
		states.append(game.canonical_bytes())
	context.equal(node.has_method("_exit_tree"), true, example + " owns scene-exit retirement")
	if node.has_method("_exit_tree"):
		node.call("_exit_tree")
		node.call("_exit_tree")
	node.free()

	for index: int in range(fixture.sessions.size()):
		var session: RefCounted = fixture.sessions[index]
		context.equal(session.status().lifecycle, Types.Lifecycle.TERMINATED, example + " exit retires the game lifetime")
		context.equal(session.status().reason, Types.Code.DESYNC if failed else Types.Code.TERMINATED, example + " exit preserves the first cause")
		var samples: Array[Driver.LocalInput] = []
		for player: int in range(2):
			if session.input_delay(player) >= 0:
				samples.append(Driver.LocalInput.new(player, session.status().current_frame, PackedByteArray([0])))
		context.equal(fixture.drivers[index].step(2000000, samples).code, Types.Code.TERMINATED, example + " retained driver cannot invoke game callbacks")
		context.bytes_equal(fixture.games[index].canonical_bytes(), states[index], session.status().current_frame, example + " departed canonical state remains fixed")
	for request: Types.Request in requests:
		context.equal(request.writer.write_bytes(PackedByteArray([0])), Writer.Code.EXPIRED_VIEW, example + " departure expires manual writer")
	if fixture.replay != null:
		context.equal(fixture.replay.step(), Types.Code.TERMINATED, "integration exit also retires its active replay")


# Value: protects=scene physics resumes after expert ownership; fails_when=BUSY latches as permanent failure;
# why_new=retirement tests never release a running batch; seam=none
func _busy_retry(context: RefCounted, example: String) -> void:
	var fixture: Dictionary = _fixture(example)
	var node: Node = fixture.node
	var session: RefCounted = fixture.sessions[0]
	var game: RefCounted = fixture.games[0]
	var demo: RefCounted = node.get("_demo") if example == "integration" else null
	if demo != null:
		demo.stop_replay()
	var frame: int = session.status().current_frame
	var bytes: PackedByteArray = game.canonical_bytes()
	var reference: RefCounted = game.get_script().new()
	context.equal(reference.load_state(frame, Reader.new(bytes, true)), true, example + " independent current-state control loads")
	var manual_inputs: Array[PackedByteArray] = [PackedByteArray([2]), PackedByteArray([0])]
	if demo != null:
		manual_inputs[1] = PackedByteArray([demo.remote_buttons(frame)])
	for player: int in range(2):
		if session.input_delay(player) >= 0:
			context.equal(session.submit_local_input(player, frame, manual_inputs[player]).code, Types.Code.OK, example + " retains manual buttons")
	var opened: Types.Result = session.begin_advance()
	context.equal(opened.code, Types.Code.READY, example + " expert owns a real request batch")
	for attempt: int in range(2):
		node.call("_physics_process", 1.0 / 60.0)
		context.equal(node.get("_code"), Types.Code.BUSY, example + " scene observes temporary ownership")
		context.bytes_equal(game.canonical_bytes(), bytes, frame, example + " busy physics preserves canonical state")
		context.equal(session.scheduled_local_input(0).bytes, manual_inputs[0], example + " busy physics preserves manual buttons")
	while true:
		var request: Types.Request = opened.batch.next_request()
		if request == null:
			break
		var ok: bool = false
		var checksum: PackedByteArray = PackedByteArray()
		match request.kind:
			Types.Kind.SAVE:
				var saved: Driver.SaveResult = game.save_state(request.frame, request.writer)
				ok = saved.ok
				checksum = saved.checksum
			Types.Kind.LOAD:
				ok = game.load_state(request.frame, request.reader)
			Types.Kind.ADVANCE:
				ok = game.simulate_frame(request.frame, request.inputs)
		context.equal(session.complete_request(request.batch_id, request.request_id, ok, checksum).code, Types.Code.OK, example + " completes manual work")
	context.equal(reference.simulate_frame(frame, Types.FrameInputs.new(manual_inputs, PackedInt32Array([0, 0]))), true, "reference applies original manual buttons")
	context.bytes_equal(game.canonical_bytes(), reference.canonical_bytes(), frame + 1, example + " expert batch retains exact original history")
	node.call("_physics_process", 1.0 / 60.0)
	context.equal(node.get("_code"), Types.Code.OK, example + " physics retries after ownership releases")
	context.equal(session.status().current_frame, frame + 2, example + " resumes without user reset")
	var next_inputs: Array[PackedByteArray] = [PackedByteArray([0]), PackedByteArray([demo.remote_buttons(frame + 1) if demo != null else 0])]
	context.equal(reference.simulate_frame(frame + 1, Types.FrameInputs.new(next_inputs, PackedInt32Array([0, 0]))), true, "reference advances scene input after release")
	context.bytes_equal(game.canonical_bytes(), reference.canonical_bytes(), frame + 2, example + " resumed scene preserves canonical history")
	session.terminate(Types.Code.DESYNC)
	node.call("_physics_process", 1.0 / 60.0)
	bytes = game.canonical_bytes()
	node.call("_physics_process", 1.0 / 60.0)
	context.bytes_equal(game.canonical_bytes(), bytes, frame + 2, example + " true terminal failure still stops scene physics")
	context.equal(session.status().reason, Types.Code.DESYNC, example + " retry keeps the first terminal cause")
	node.call("_exit_tree")
	node.free()


func _callbacks(context: RefCounted) -> void:
	var fixture: Dictionary = _fixture("integration")
	var node: Node = fixture.node
	var demo: RefCounted = node.get("_demo")
	demo.stop_replay()
	context.equal(demo.reset(), Types.Code.OK, "callback fixture has a fresh live match")
	var game: ClosingGame = ClosingGame.new()
	demo.loop.game = game
	context.equal(demo.loop.driver.configure(demo.loop.session, game), Types.Code.OK, "callback game configures")
	game.closing = func() -> void:
		context.equal(node.has_method("_exit_tree"), true, "callback departure has a scene-exit handler")
		if node.has_method("_exit_tree"):
			node.call("_exit_tree")
	context.equal(demo.tick(IntegrationGame.LEFT), Types.Code.TERMINATED, "scene exit inside SAVE cancels outstanding work")
	game.closing = Callable()
	context.equal(demo.loop.session.status().reason, Types.Code.TERMINATED, "expired save cannot replace departure's first cause")
	context.equal(game.frame, 0, "callback cancellation never reaches ADVANCE")
	node.free()


# Value: protects=controller repairs remote rows skipped by external advancement; fails_when=current frame leaves a gap;
# why_new=ordinary scheduling never advances outside the controller; seam=none
func _expert_gap_recovery(context: RefCounted) -> void:
	for lag: int in [0, 3, 12]:
		for row: PackedInt32Array in [
			PackedInt32Array([0, 0, 0]), PackedInt32Array([1, 0, 0]), PackedInt32Array([8, 0, 0]),
			PackedInt32Array([8, 4, 0]), PackedInt32Array([128, 128, 0]),
			PackedInt32Array([1, 0, 1]), PackedInt32Array([8, 0, 1]), PackedInt32Array([8, 4, 1]), PackedInt32Array([128, 128, 1]),
		]:
			var scene: PackedScene = load("res://examples/integration/integration.tscn")
			var node: Node = scene.instantiate()
			node.call("_ready")
			var demo: RefCounted = node.get("_demo")
			context.equal(demo.start(lag), Types.Code.OK, "gap fixture starts")
			var reference: IntegrationGame = IntegrationGame.new()
			for frame: int in range(row[0]):
				var actual: int = 2 if frame < row[1] else ((4 if frame % 8 < 4 else 0) | (1 if frame % 7 < 3 else 2))
				if row[1] == 4 and frame < 4 and lag > 0:
					context.equal(demo.tick(IntegrationGame.RIGHT), Types.Code.OK, "queues original remote rows before external receipt")
					context.equal(demo.loop.session.receive_input(1, frame, PackedByteArray([actual])).code, Types.Code.OK, "external first receipt owns pending remote row")
				else:
					if frame < row[1]:
						context.equal(demo.loop.session.receive_input(1, frame, PackedByteArray([actual])).code, Types.Code.OK, "expert supplies a contiguous actual prefix")
					var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, frame, PackedByteArray([IntegrationGame.RIGHT]))]
					context.equal(demo.loop.driver.step(maxi(0, demo.loop.session._time), samples).code, Types.Code.OK, "external advancement creates a skipped controller frame")
				var original: Types.FrameInputs = Types.FrameInputs.new([PackedByteArray([2]), PackedByteArray([actual])], PackedInt32Array([0, 0]))
				context.equal(reference.simulate_frame(frame, original), true, "reference retains original external history")
			var comparisons: int = 0
			for tick: int in range(0 if row[2] == 1 else 48):
				if tick == 32:
					context.equal(demo.set_lag(0), Types.Code.OK, "drains delayed rows without changing their due times")
				var frame: int = demo.loop.session.status().current_frame
				var code: int = demo.tick(IntegrationGame.LEFT)
				context.equal(code in [Types.Code.OK, Types.Code.PREDICTION_STALL], true, "controller recovers after external advancement")
				if code == Types.Code.OK:
					var actual: int = (4 if frame % 8 < 4 else 0) | (1 if frame % 7 < 3 else 2)
					var original: Types.FrameInputs = Types.FrameInputs.new([PackedByteArray([1]), PackedByteArray([actual])], PackedInt32Array([0, 0]))
					context.equal(reference.simulate_frame(frame, original), true, "reference advances controller input")
				context.equal(demo.pending_input_count() <= demo.MAX_PENDING_INPUTS, true, "remote catch-up work stays bounded")
				var previous: int = -1
				for sample: RefCounted in demo._pending:
					context.equal(sample.frame > previous, true, "repeated ticks retain each pending row once in order")
					previous = sample.frame
				var status: Types.Status = demo.loop.session.status()
				if status.confirmed_frame >= status.current_frame - 1 and status.pending_rollback_frame == -1:
					context.bytes_equal(demo.loop.game.canonical_bytes(), reference.canonical_bytes(), reference.frame, "corrected prefix matches independent original inputs")
					comparisons += 1
			for tick: int in range(24):
				var code: int = demo.finish_tick()
				context.equal(code in [Types.Code.OK, Types.Code.PREDICTION_STALL], true, "final catch-up does not sample another local frame")
				if code == Types.Code.OK:
					break
			context.equal(demo.loop.session.status().confirmed_frame >= reference.frame - 1, true, "all skipped remote rows eventually finalize")
			context.bytes_equal(demo.loop.game.canonical_bytes(), reference.canonical_bytes(), reference.frame, "final corrected state preserves external actual authority")
			if row[2] == 0:
				context.equal(comparisons > 0, true, "compares corrected prefixes after the declared delivery drain")
			node.call("_exit_tree")
			node.free()
