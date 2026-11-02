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
