extends RefCounted

# Value: protects=pointer and keyboard peer controls share readiness; fails_when=buttons mutate owned or stopped peers;
# why_new=match-only controls cannot prove visible actions; seam=actual scene and peer sessions
const Match = preload("res://examples/peer/match.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const SnapshotStatus = preload("res://addons/fortress_rollback/core/snapshot_status.gd")
const ACTION_KEYS: Dictionary = {
	"loss": KEY_L, "latency": KEY_T, "reorder": KEY_O, "block": KEY_SPACE,
	"desync": KEY_X, "delay_first": KEY_1, "delay_second": KEY_2, "reset": KEY_R
}


func cases() -> PackedStringArray:
	return PackedStringArray(["pointer_controls", "owned_controls", "stopped_controls"])


func run_case(name: String, context: RefCounted) -> void:
	call("_" + name, context)
	context.finish()


func _scene() -> Node:
	var packed: PackedScene = load("res://examples/peer/peer.tscn")
	var scene: Node = packed.instantiate()
	scene.call("_ready")
	return scene


func _healthy(scene: Node, context: RefCounted) -> void:
	var game: Match = scene._match
	game.drop_every = 0
	game.latency_ticks = 0
	game.reorder = false
	for tick: int in 50:
		context.equal(game.tick(PackedInt32Array([2, 8])), Match.I.Code.OK, "real byte sessions start and advance")
	scene.call("_update_label")


func _key(scene: Node, action: String) -> void:
	var event: InputEventKey = InputEventKey.new()
	event.pressed = true
	event.keycode = ACTION_KEYS[action]
	scene.call("_unhandled_key_input", event)


func _state(game: Match) -> Array:
	return [game.sessions[0], game.sessions[1], game.now_us, game.queued_packets(), game.sent, game.delivered, game.dropped,
		game.drop_every, game.latency_ticks, game.reorder, game.is_partitioned, game.games[0].is_divergent,
		game.sessions[0].input_delay(0), game.sessions[1].input_delay(1), game._held.duplicate()]


func _pointer_controls(context: RefCounted) -> void:
	var scene: Node = _scene()
	var controls: Node = scene.find_child("PeerControls", true, false)
	context.equal(controls != null, true, "packet faults and match actions have visible pointer controls")
	if controls == null:
		scene.free()
		return
	var game: Match = scene._match
	for action: String in ACTION_KEYS:
		context.equal(scene._actions[action].focus_mode, Control.FOCUS_NONE, action + " leaves movement and Space shortcuts available")
		context.equal(scene._actions[action].disabled, action in ["delay_first", "delay_second", "desync"], action + " reflects startup readiness")
	for action: String in ["loss", "latency", "reorder", "block"]:
		var before: Array = _state(game)
		scene._actions[action].pressed.emit()
		context.equal(_state(game) != before, true, "pointer changes " + action)
		_key(scene, action)
		context.equal(_state(game), before, "keyboard uses same " + action + " action")
	_healthy(scene, context)
	for player: int in 2:
		var action: String = "delay_first" if player == 0 else "delay_second"
		var before: int = game.sessions[player].input_delay(player)
		context.equal(scene._actions[action].disabled, false, "live peer delay action enabled")
		scene._actions[action].pressed.emit()
		context.equal(game.sessions[player].input_delay(player), before + 1, "pointer raises selected peer delay")
		_key(scene, action)
		context.equal(game.sessions[player].input_delay(player), before + 2, "keyboard raises same selected peer delay")
	context.equal(scene._actions.desync.disabled, false, "running byte sessions expose deliberate desync")
	scene._actions.desync.pressed.emit()
	context.equal(game.games[0].is_divergent, true, "pointer injects actual wrong game rules")
	var old_sessions: Array = game.sessions.duplicate()
	scene._actions.reset.pressed.emit()
	context.equal(game.games[0].frame, 0, "pointer reset replaces simulated game")
	context.equal(game.games[0].is_divergent, false, "pointer reset removes injected game divergence")
	for old: RefCounted in old_sessions:
		context.equal(old.status().lifecycle, Types.Lifecycle.TERMINATED, "pointer reset retires old byte peers")
	scene.free()


func _owned_controls(context: RefCounted) -> void:
	for active: int in 2:
		for phase: String in ["expert", "notification"]:
			var scene: Node = _scene()
			_healthy(scene, context)
			var game: Match = scene._match
			var core: RefCounted = game.sessions[active]._core
			var frame: int = core.status().current_frame
			var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(active, frame, PackedByteArray([2 if active == 0 else 8]))]
			var observations: Array[int] = []
			if phase == "notification":
				game.sessions[active].step_completed.connect(func(_code: int, _before: int, _after: int) -> void:
					observations.append(1)
					_reject_actions(scene, context), CONNECT_ONE_SHOT)
				context.equal(game.sessions[active].step(game.now_us, samples).code, Types.Code.OK, "outer driver completes after rejected scene controls")
				context.equal(observations, [1], "actual shared completion guard exercised")
			else:
				context.equal(core.submit_local_input(active, frame, samples[0].bytes).code, Types.Code.OK, "expert stages current controls")
				var opened: RefCounted = core.begin_advance()
				context.equal(opened.code, Types.Code.READY, "expert owns shared match work")
				var request: RefCounted = opened.batch.next_request()
				context.equal(request.kind, Types.Kind.SAVE, "expert retains real bounded writer")
				_reject_actions(scene, context)
				context.equal(request.writer.status(), SnapshotStatus.Code.OK, "rejected scene controls preserve expert writer")
				var result: Driver.SaveResult = game.games[active].save_state(request.frame, request.writer)
				context.equal(core.complete_request(request.batch_id, request.request_id, result.ok, result.checksum).code, Types.Code.OK, "expert can complete unchanged SAVE")
				request = opened.batch.next_request()
				context.equal(request.kind, Types.Kind.ADVANCE, "original ADVANCE remains available")
				context.equal(core.complete_request(request.batch_id, request.request_id, game.games[active].simulate_frame(request.frame, request.inputs)).code,
					Types.Code.OK, "expert completes unchanged game work")
				context.equal(opened.batch.next_request() == null, true, "expert releases operation")
			scene.call("_update_label")
			context.equal(scene._actions.reset.disabled, false, "reset is available again after ownership releases")
			scene._actions.reset.pressed.emit()
			context.equal(game.games[0].frame, 0, "pointer retry resets after shared ownership releases")
			scene.free()


func _reject_actions(scene: Node, context: RefCounted) -> void:
	var game: Match = scene._match
	var before: Array = _state(game)
	scene.call("_update_label")
	for action: String in ACTION_KEYS:
		context.equal(scene._actions[action].disabled, true, action + " visibly disabled during owned game work")
		scene._actions[action].pressed.emit()
		_key(scene, action)
		context.equal(_state(game), before, "pointer and keyboard " + action + " preserve active operation")


func _stopped_controls(context: RefCounted) -> void:
	for active: int in 2:
		var scene: Node = _scene()
		_healthy(scene, context)
		var game: Match = scene._match
		context.equal(game.sessions[active].close(game.now_us), Types.Code.OK, "real peer closure precedes scene refresh")
		var before: Array = _state(game)
		scene.call("_update_label")
		for action: String in ACTION_KEYS:
			context.equal(scene._actions[action].disabled, action != "reset", action + " readiness after either fixed member stops")
			if action != "reset":
				scene._actions[action].pressed.emit()
				_key(scene, action)
				context.equal(_state(game), before, "stopped scene " + action + " preserves retained observations")
		scene._actions.reset.pressed.emit()
		context.equal(game.failure, Match.I.Code.OK, "stopped pointer reset clears terminal failure")
		context.equal(game.games[0].frame, 0, "stopped pointer reset starts fresh gameplay")
		scene.free()
