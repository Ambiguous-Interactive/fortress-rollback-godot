extends RefCounted

# Value: protects=match actions ignore modified/repeated keys; fails_when=browser shortcuts reset games; why_new=scene tests omit modifiers; seam=none
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["ignored_shortcuts", "ordinary_shortcuts"])


func run_case(name: String, context: RefCounted) -> void:
	for example: String in ["offline", "integration", "peer"]:
		if name == "ordinary_shortcuts" and example == "offline":
			continue
		var scene: PackedScene = load("res://examples/%s/%s.tscn" % [example, example])
		var node: Node = scene.instantiate()
		node.call("_ready")
		if name == "ignored_shortcuts":
			_ignored(node, example, context)
		else:
			_ordinary(node, example, context)
			_physical_numbers(node, example, context)
		node.call("_exit_tree")
		node.free()
	context.finish()


func _state(node: Node, example: String) -> Array:
	if example == "offline":
		return [node._session, node._simulation.canonical_bytes()]
	if example == "integration":
		var demo: RefCounted = node._demo
		return [demo.loop.session, demo.loop.game.canonical_bytes(), demo.lag_ticks, demo.replay_player]
	var game: RefCounted = node._match
	return [
		game.sessions.duplicate(),
		game.games[0].canonical_bytes(),
		game.drop_every,
		game.latency_ticks,
		game.reorder,
		game.is_partitioned,
		game.games[0].is_divergent,
		game.sessions[0].input_delay(0),
		game.sessions[1].input_delay(1)
	]


func _ignored(node: Node, example: String, context: RefCounted) -> void:
	var keys: Array[Key] = [KEY_R]
	if example == "integration":
		keys += [KEY_1, KEY_2, KEY_3, KEY_P]
	elif example == "peer":
		keys += [KEY_L, KEY_T, KEY_O, KEY_SPACE, KEY_X, KEY_1, KEY_2]
	var before: Array = _state(node, example)
	for property: String in ["ctrl_pressed", "alt_pressed", "meta_pressed", "shift_pressed", "echo", "released"]:
		for key: Key in keys:
			var event: InputEventKey = InputEventKey.new()
			event.keycode = key
			event.physical_keycode = key
			event.pressed = property != "released"
			if property != "released":
				event.set(property, true)
			node.call("_unhandled_key_input", event)
			context.equal(_state(node, example), before, "%s ignores %s for key %d" % [example, property, key])


func _ordinary(node: Node, example: String, context: RefCounted) -> void:
	var previous: RefCounted = node._demo.loop.session if example == "integration" else node._match.sessions[0]._core
	var reset: InputEventKey = InputEventKey.new()
	reset.keycode = KEY_R
	reset.pressed = true
	node.call("_unhandled_key_input", reset)
	var current: RefCounted = node._demo.loop.session if example == "integration" else node._match.sessions[0]._core
	context.equal(current != previous, true, example + " plain R still replaces the match")
	context.equal(previous.status().lifecycle, Types.Lifecycle.TERMINATED, example + " plain R retires the old lifetime")
	var control: InputEventKey = InputEventKey.new()
	control.keycode = KEY_3 if example == "integration" else KEY_SPACE
	control.pressed = true
	node.call("_unhandled_key_input", control)
	context.equal(
		node._demo.lag_ticks if example == "integration" else int(node._match.is_partitioned),
		12 if example == "integration" else 1,
		example + " ordinary gameplay fault control remains available"
	)


# Value: protects=physical number-row actions remain accessible on non-US layouts;
# fails_when=logical symbol keys suppress gameplay delay controls; why_new=US logical keys cannot expose layout differences; seam=none
func _physical_numbers(node: Node, example: String, context: RefCounted) -> void:
	var key: InputEventKey = InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_AMPERSAND
	if example == "integration":
		var canonical: PackedByteArray = node._demo.loop.game.canonical_bytes()
		for index: int in range(3):
			key.physical_keycode = [KEY_1, KEY_2, KEY_3][index]
			node._unhandled_key_input(key)
			context.equal(node._demo.lag_ticks, [0, 3, 12][index], "physical effect delay ignores the logical glyph")
			context.bytes_equal(node._demo.loop.game.canonical_bytes(), canonical, 0, "physical delay action never simulates input")
		return
	node._match.is_partitioned = false
	node._match.drop_every = 0
	node._match.latency_ticks = 0
	node._match.reorder = false
	for tick: int in range(60):
		node._match.tick(PackedInt32Array([0, 0]))
	context.equal(node._can_change_delay(), true, "physical peer actions have two synchronized live sessions")
	for player: int in range(2):
		var before: PackedInt32Array = PackedInt32Array([node._match.sessions[0].input_delay(0), node._match.sessions[1].input_delay(1)])
		var bytes: PackedByteArray = node._match.games[player].canonical_bytes()
		var time: int = node._match.now_us
		key.physical_keycode = KEY_1 if player == 0 else KEY_2
		node._unhandled_key_input(key)
		context.equal(node._match.sessions[player].input_delay(player), before[player] + 1, "physical number selects its actual peer")
		context.equal(node._match.sessions[1 - player].input_delay(1 - player), before[1 - player], "physical number preserves the other peer delay")
		context.equal(node._match.now_us, time, "physical peer delay action preserves service time")
		context.bytes_equal(node._match.games[player].canonical_bytes(), bytes, node._match.games[player].frame, "physical peer delay never advances game")
