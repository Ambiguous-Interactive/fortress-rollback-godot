extends RefCounted

# Value: protects=departed playable scenes retire retained game capabilities; fails_when=old drivers still advance;
# why_new=scene smoke tests only free nodes; seam=none
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const IntegrationGame = preload("res://examples/integration/game.gd")
const Writer = preload("res://addons/fortress_rollback/core/snapshot_writer.gd")


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
