extends RefCounted

# Value: protects=pointer and keyboard peer controls share readiness; fails_when=buttons mutate owned or stopped peers;
# why_new=match-only controls cannot prove visible actions; seam=actual scene and peer sessions
const Match = preload("res://examples/peer/match.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const SnapshotStatus = preload("res://addons/fortress_rollback/core/snapshot_status.gd")
const ACTION_KEYS: Dictionary = {
	"loss": KEY_L, "latency": KEY_T, "reorder": KEY_O, "block": KEY_SPACE,
	"desync": KEY_X, "delay_first": KEY_1, "delay_second": KEY_2, "reset": KEY_R, "pause": KEY_P, "step": KEY_N,
	"suggest_first": KEY_F, "suggest_second": KEY_G
}


func cases() -> PackedStringArray:
	return PackedStringArray(["pointer_controls", "owned_controls", "stopped_controls", "inspection", "focus_pause", "suggested_delay"])


func run_case(name: String, context: RefCounted) -> void:
	var probe: Node = _scene()
	var available: bool = probe._actions.has("pause") and probe._actions.has("step")
	probe.free()
	context.equal(available, true, "peer example exposes pause and tick controls")
	if not available:
		context.finish()
		return
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
		var unavailable: bool = action in ["delay_first", "delay_second", "desync", "step", "suggest_first", "suggest_second"]
		context.equal(scene._actions[action].disabled, unavailable, action + " reflects startup readiness")
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


# Value: protects=peer inspection freezes packet time and uses actual delayed bytes; fails_when=pause polls or step skips held input;
# why_new=match tick tests do not exercise scene pause; seam=none
func _inspection(context: RefCounted) -> void:
	var scene: Node = _scene()
	var pause: Button = scene._actions.get("pause")
	var step: Button = scene._actions.get("step")
	context.equal(pause != null and step != null, true, "peer fault demo exposes pause and single-tick controls")
	if pause == null or step == null:
		scene.free()
		return
	_healthy(scene, context)
	var game: Match = scene._match
	pause.pressed.emit()
	context.equal(scene._is_paused, true, "pointer pauses peer service")
	var before: Array = _state(game)
	for tick: int in 10:
		scene._physics_process(0.0)
	context.equal(_state(game), before, "pause freezes delivery clock, samples and transport")
	for tick: int in 30:
		var frames: PackedInt64Array = PackedInt64Array([game.games[0].frame, game.games[1].frame])
		var now: int = game.now_us
		if tick % 2 == 0:
			step.pressed.emit()
		else:
			_key(scene, "step")
		context.equal(game.now_us, now + Match.TICK_US, "step services exactly one injected packet tick")
		for player: int in 2:
			context.equal(game.games[player].frame, frames[player] + 1, "healthy step advances each byte session once")
		context.equal(scene._is_paused, true, "single tick stays paused")
	game.is_partitioned = true
	for tick: int in 20:
		step.pressed.emit()
	context.equal(game.stalls[0] > 0 and game.stalls[1] > 0, true, "stepped partition reaches real prediction bound")
	var held: PackedInt32Array = game._held.duplicate()
	step.pressed.emit()
	context.equal(game._held, held, "stalled inspection retains original samples")
	game.is_partitioned = false
	for tick: int in 30:
		step.pressed.emit()
	context.equal(game.failure, Match.I.Code.OK, "stepped packet healing resumes gameplay")
	context.equal(game.games[0].frame > 80, true, "healed peers advance after prediction stall")
	_key(scene, "pause")
	context.equal(scene._is_paused, false, "keyboard resumes continuous service")
	context.equal(step.disabled, true, "continuous service disables extra tick")
	_key(scene, "pause")
	scene._actions.reset.pressed.emit()
	context.equal(scene._is_paused, false, "accepted reset resumes a fresh match")
	pause.pressed.emit()
	game.sessions[1].close(game.now_us)
	scene._physics_process(0.0)
	context.equal(game.sessions[0].status().lifecycle, Types.Lifecycle.TERMINATED, "paused refresh retires counterpart after peer ends")
	context.equal(pause.disabled, true, "paused stopped match disables resume")
	context.equal(step.disabled, true, "paused stopped match disables step")
	context.equal(scene._actions.reset.disabled, false, "stopped match retains reset")
	scene.free()


# Value: protects=focus loss holds local packet time; fails_when=background ticks time out or focus gain resumes; why_new=manual controls miss lifecycle; seam=none
func _focus_pause(context: RefCounted) -> void:
	var scene: Node = _scene()
	_healthy(scene, context)
	var game: Match = scene._match
	var before: Array = _state(game)
	var bytes: PackedByteArray = game.games[0].canonical_bytes()
	scene.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	for tick: int in 150:
		scene._physics_process(0.0)
	context.equal(scene._is_paused, true, "application focus loss pauses local packet demo")
	context.equal(_state(game), before, "background service preserves clock, held samples and packets")
	context.bytes_equal(game.games[0].canonical_bytes(), bytes, game.games[0].frame, "focus pause preserves game state")
	scene.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	scene._physics_process(0.0)
	context.equal(_state(game), before, "focus return keeps both peers paused")
	_key(scene, "pause")
	scene._physics_process(0.0)
	context.equal(scene._is_paused, false, "explicit resume restores packet service")
	context.equal(game.now_us, before[2] + Match.TICK_US, "resume services one ordinary tick")
	var scene_ref: WeakRef = weakref(scene)
	game.sessions[0].step_completed.connect(func(_code: int, _before: int, _after: int) -> void:
		scene_ref.get_ref().notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT), CONNECT_ONE_SHOT)
	scene._physics_process(0.0)
	context.equal(game.failure, Match.I.Code.OK, "focus loss during completion preserves accepted composed work")
	before = _state(game)
	scene._physics_process(0.0)
	context.equal(_state(game), before, "next tick honors focus pause after callback unwinds")
	scene.free()


# Value: protects=actual measured peer suggestions can be accepted safely; fails_when=scene ignores suggestions or applies stale/owned work;
# why_new=advisor tests bypass scene controls; seam=actual encoded peer traffic
func _suggested_delay(context: RefCounted) -> void:
	var scene: Node = _scene()
	var available: bool = scene._actions.has("suggest_first") and scene._actions.has("suggest_second")
	context.equal(available, true, "peer example exposes measured delay acceptance")
	if not available:
		scene.free()
		return
	var game: Match = scene._match
	game.latency_ticks = 12
	for tick: int in 600:
		game.tick(PackedInt32Array([tick % 16, (tick * 3) % 16]))
		if not game.recommendations[0].is_empty() and not game.recommendations[1].is_empty():
			break
	context.equal(game.failure, Match.I.Code.OK, "high-latency peers remain healthy")
	for player: int in 2:
		context.equal(game.recommendations[player].size(), 1, "actual measured suggestion retained once")
		if game.recommendations[player].is_empty():
			scene.free()
			return
		var action: String = "suggest_first" if player == 0 else "suggest_second"
		var suggested: int = game.recommendations[player][0].suggested_delay
		context.equal(game.sessions[player].input_delay(player), 2, "measured suggestion never applies automatically")
		context.equal(suggested > game.sessions[player].input_delay(player), true, "actual event suggests a higher delay")
		scene._update_label()
		context.equal(scene._actions[action].disabled, false, "measured suggestion enables selected control")
		context.equal(scene._actions[action].text.contains(str(suggested)), true, "selected control names actual delay")
		game.sessions[1 - player]._core._begin_driver_notification()
		scene._update_label()
		context.equal(scene._actions[action].disabled, true, "other peer ownership blocks suggestion")
		scene._actions[action].pressed.emit()
		context.equal(game.sessions[player].input_delay(player) < suggested, true, "owned suggestion leaves delay unchanged")
		game.sessions[1 - player]._core._end_driver_notification()
		if player == 0:
			scene._actions[action].pressed.emit()
		else:
			var event: InputEventKey = InputEventKey.new()
			event.pressed = true
			event.keycode = KEY_G
			scene._unhandled_key_input(event)
		context.equal(game.sessions[player].input_delay(player), suggested, "pointer or key applies measured delay")
		context.equal(scene._actions[action].disabled, true, "accepted suggestion no longer offered")
	for tick: int in 160:
		game.tick(PackedInt32Array([tick % 16, (tick * 3) % 16]))
	var common: int = mini(game.sessions[0].status().confirmed_frame, game.sessions[1].status().confirmed_frame)
	var first: Types.FrameInputs = game.sessions[0].confirmed_inputs(common)
	var second: Types.FrameInputs = game.sessions[1].confirmed_inputs(common)
	context.equal(common > 100 and first != null and second != null, true, "both peers retain continued confirmed gameplay")
	if first != null and second != null:
		for player: int in 2:
			context.bytes_equal(first.read(player).bytes, second.read(player).bytes, common, "confirmed input agrees after accepting suggestions")
			context.equal(first.input_status(player), second.input_status(player), "confirmed statuses agree after accepting suggestions")
	context.equal(game.failure, Match.I.Code.OK, "real byte peers continue after both suggestions")
	for player: int in 2:
		context.equal(game.event_counts[player].get("desync_detected", 0), 0, "delay acceptance preserves agreement")
	scene._actions.reset.pressed.emit()
	game.latency_ticks = 12
	for tick: int in 600:
		game.tick(PackedInt32Array([0, 0]))
		if not game.recommendations[0].is_empty() and not game.recommendations[1].is_empty():
			break
	context.equal(game.suggested_input_delay(0) > 2 and game.suggested_input_delay(1) > 2, true, "fresh match obtains fresh measured offers")
	game.latency_ticks = 0
	game.drop_every = 0
	game.reorder = false
	for tick: int in 750:
		game.tick(PackedInt32Array([0, 0]))
	for player: int in 2:
		context.equal(game.recommendations[player].size(), 1, "unused recommendation history remains bounded")
		context.equal(game.suggested_input_delay(player), -1, "old recommendation expires during continued play")
		context.equal(game.apply_suggested_delay(player), Types.Code.INVALID_CONFIGURATION, "expired recommendation cannot raise delay")
		context.equal(game.sessions[player].input_delay(player), 2, "expired offer preserves selected delay")
	scene._update_label()
	context.equal(scene._actions.suggest_first.disabled and scene._actions.suggest_second.disabled, true, "expired suggestions disable both actions")
	scene._actions.reset.pressed.emit()
	context.equal(scene._actions.suggest_first.disabled and scene._actions.suggest_second.disabled, true, "reset clears old measured offers")
	scene.free()
