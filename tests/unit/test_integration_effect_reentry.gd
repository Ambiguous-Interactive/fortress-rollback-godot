extends RefCounted

# gdlint: disable=max-returns

# Value: protects=confirmed effect callbacks preserve their active match; fails_when=effect hooks reenter service or replace owners;
# why_new=driver guards end before effects run; seam=application Effects.play override
const Demo = preload("res://examples/integration/demo.gd")
const Game = preload("res://examples/integration/game.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


class CallbackEffects:
	extends Demo.DemoEffects
	var callback: Callable

	func play(id: int) -> void:
		if callback.is_valid():
			var action: Callable = callback
			callback = Callable()
			action.call()
		super.play(id)


func cases() -> PackedStringArray:
	return PackedStringArray(["effect_reentry", "effect_cancellation"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "effect_cancellation":
		_effect_cancellation(context)
		context.finish()
		return
	for delivery: String in ["immediate", "final_tail"]:
		for control: String in ["tick", "finish", "lag", "loop_tick", "start", "reset", "replay", "loop_start", "expert", "driver"]:
			var demo: Demo = Demo.new()
			context.equal(demo.start(0 if delivery == "immediate" else 3), Types.Code.OK, "effect fixture starts")
			var effects: CallbackEffects = CallbackEffects.new()
			demo.effects = effects
			demo.loop.effects = effects
			var owner: WeakRef = weakref(demo)
			var calls: PackedInt32Array = PackedInt32Array()
			effects.callback = func() -> void:
				var current: Demo = owner.get_ref()
				var old_loop: RefCounted = current.loop
				var old_driver: RefCounted = current.loop.driver
				var before: Array = _snapshot(current)
				calls.append(_attempt(current, control))
				context.equal(current.loop == old_loop, true, control + " retains the active match")
				context.equal(current.loop.driver == old_driver, true, control + " retains the active driver")
				context.equal(_snapshot(current), before, control + " preserves all serviced state")
			context.equal(demo.tick(Game.FIRE), Types.Code.OK, "original frame advances")
			if delivery == "final_tail":
				context.equal(calls.size(), 0, "unconfirmed effect waits for actual input")
				for turn: int in 5:
					var code: int = demo.finish_tick()
					context.equal(code in [Types.Code.OK, Types.Code.PREDICTION_STALL], true, "tail recovery stays usable")
			context.equal(calls, PackedInt32Array([Types.Code.BUSY]), delivery + " refuses " + control + " from effect hook")
			context.equal(demo.loop.session.status().current_frame, 1, "effect hook cannot add simulation frames")
			context.equal(demo.loop.game.frame, 1, "game agrees with its active session")
			context.equal(demo.loop.session.status().lifecycle, Types.Lifecycle.RUNNING, "rejected reentry keeps the game running")
			context.equal(effects.total_count > 0, true, "actual confirmed effect was delivered")
			context.equal(demo.set_lag(0), Types.Code.OK, "effect guard releases for later controls")
			context.equal(demo.tick(Game.LEFT), Types.Code.OK, "later input advances without a restart")
			context.equal(demo.loop.game.frame, 2, "only the next real sample advances")
	context.finish()


func _effect_cancellation(context: RefCounted) -> void:
	for delay: int in [0, 3]:
		var demo: Demo = Demo.new()
		context.equal(demo.start(delay), Types.Code.OK, "cancellation fixture starts")
		var effects: CallbackEffects = CallbackEffects.new()
		demo.effects = effects
		demo.loop.effects = effects
		var owner: WeakRef = weakref(demo)
		var original: RefCounted = demo.loop
		var calls: PackedInt32Array = PackedInt32Array()
		effects.callback = func() -> void:
			var current: Demo = owner.get_ref()
			current.loop.session.terminate(Types.Code.DESYNC)
			var before: Array = _snapshot(current)
			for control: String in ["start", "reset", "tick", "finish", "loop_tick", "loop_start", "expert", "driver"]:
				calls.append(_attempt(current, control))
				context.equal(_snapshot(current), before, control + " cannot mutate after hook cancellation")
				context.equal(current.loop == original, true, control + " cannot replace canceled callback owner")
			current.loop.session.terminate()
			context.equal(current.loop.session.status().reason, Types.Code.DESYNC, "hook keeps its first terminal cause")
		var code: int = demo.tick(Game.FIRE)
		if delay > 0:
			context.equal(code, Types.Code.OK, "unconfirmed fire initially advances")
			for turn: int in 5:
				code = demo.finish_tick()
				if code == Types.Code.DESYNC:
					break
		context.equal(code, Types.Code.DESYNC, "outer service reports effect cancellation cause")
		context.equal(calls.size(), 8, "all cancellation reentry controls ran")
		for result: int in calls:
			context.equal(result, Types.Code.BUSY, "cancellation keeps callback ownership gates")
		context.equal(demo.loop.game.frame, 1, "cancellation adds no simulation frame")
		context.equal(effects.total_count, 2, "already-confirmed effect batch finishes before returning")
		context.equal(demo.reset(), Types.Code.OK, "outside callback explicit restart is available")
		context.equal(original.session.status().reason, Types.Code.DESYNC, "replacement preserves retained owner's cause")
		context.equal(demo.tick(Game.LEFT), Types.Code.OK, "fresh match runs after cancellation")


func _snapshot(demo: Demo) -> Array:
	var pending: Array = []
	for input: RefCounted in demo._pending:
		pending.append([input.frame, input.due_tick, input.buttons])
	return [
		demo.tick_count,
		demo.stall_count,
		demo.lag_ticks,
		demo._remote_sample_frame,
		demo.loop._sample_frame,
		demo.loop._sample.duplicate(),
		pending,
		demo.loop.session._time,
		demo.loop.session.received_frames(),
		demo.loop.game.canonical_bytes(),
		demo.effects.total_count
	]


func _attempt(demo: Demo, control: String) -> int:
	match control:
		"tick":
			return demo.tick(Game.RIGHT)
		"finish":
			return demo.finish_tick()
		"lag":
			return demo.set_lag(12)
		"loop_tick":
			return demo.loop.tick(demo.tick_count * Demo.TICK_US, Game.RIGHT)
		"start":
			return demo.start(12)
		"reset":
			return demo.reset()
		"replay":
			return demo.start_replay()
		"loop_start":
			return demo.loop.start()
		"expert":
			return demo.loop.session.begin_recovery().code
		"driver":
			return demo.loop.driver.recover(demo.tick_count * Demo.TICK_US).code
	return Types.Code.INVALID_CONFIGURATION
