extends RefCounted

# Value: protects=controller clocks and input under ownership; fails_when=BUSY arrives after staging; why_new=restart tests omit service controls; seam=none
const Demo = preload("res://examples/integration/demo.gd")
const Game = preload("res://examples/integration/game.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


class CallbackGame:
	extends Game
	var callback: Callable
	var from_save: bool = true

	func save_state(frame: int, writer: Game.Writer) -> Driver.SaveResult:
		if from_save and callback.is_valid():
			callback.call()
		return super.save_state(frame, writer)

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		if not from_save and callback.is_valid():
			callback.call()
		return super.simulate_frame(frame, inputs)


func cases() -> PackedStringArray:
	return PackedStringArray(["live_controls", "replay_controls", "stopped_controls"])


func run_case(name: String, context: RefCounted) -> void:
	call("_" + name, context)
	context.finish()


func _snapshot(demo: Demo) -> Array:
	var pending: Array = []
	for sample: RefCounted in demo._pending:
		pending.append([sample.frame, sample.due_tick, sample.buttons])
	return [demo.tick_count, demo.stall_count, demo.lag_ticks, demo._remote_sample_frame,
		demo.loop._sample_frame, demo.loop._sample.duplicate(), pending,
		demo.loop.session.received_frames(), demo.loop.game.canonical_bytes(), demo.effects.recent_ids.duplicate()]


func _attempt(demo: Demo, control: String) -> int:
	match control:
		"tick":
			return demo.tick(Game.FIRE)
		"finish":
			return demo.finish_tick()
		"lag":
			return demo.set_lag(12)
		"loop_tick":
			return demo.loop.tick(demo.tick_count * Demo.TICK_US, Game.FIRE)
	return Types.Code.INVALID_CONFIGURATION


func _live_controls(context: RefCounted) -> void:
	_input_rejections(context)
	for control: String in ["tick", "finish", "lag", "loop_tick"]:
		var demo: Demo = Demo.new()
		context.equal(demo.start(0), Types.Code.OK, "live fixture starts")
		var owner: WeakRef = weakref(demo)
		var notices: PackedInt32Array = PackedInt32Array()
		var callback: Callable = func(_code: int, _before: int, _after: int) -> void:
			var current: Demo = owner.get_ref()
			var before: Array = _snapshot(current)
			notices.append(_attempt(current, control))
			context.equal(_snapshot(current), before, control + " preserves controller during completion")
		demo.loop.driver.step_completed.connect(callback)
		context.equal(demo.tick(Game.RIGHT), Types.Code.OK, "outer operation completes")
		demo.loop.driver.step_completed.disconnect(callback)
		context.equal(notices, PackedInt32Array([Types.Code.BUSY]), control + " refuses notification reentry")
		context.equal(demo.tick_count, 1, control + " advances outer clock only once")
		context.equal(demo.tick(Game.LEFT), Types.Code.OK, control + " permits subsequent real sample")
		var reference: Demo = Demo.new()
		reference.start(0)
		reference.tick(Game.RIGHT)
		reference.tick(Game.LEFT)
		context.bytes_equal(demo.loop.game.canonical_bytes(), reference.loop.game.canonical_bytes(), 2, control + " cannot inject future buttons")
		# An expert-owned batch must also reject before any controller staging.
		var frame: int = demo.loop.session.status().current_frame
		context.equal(demo.loop.session.submit_local_input(0, frame, PackedByteArray([Game.LEFT])).code, Types.Code.OK, "stage expert sample")
		context.equal(demo.loop.session.begin_advance().code, Types.Code.READY, "expert owns live batch")
		var before: Array = _snapshot(demo)
		context.equal(_attempt(demo, control), Types.Code.BUSY, control + " respects expert batch")
		context.equal(_snapshot(demo), before, control + " preserves expert-owned state")
		demo.loop.session.terminate()


func _replay_controls(context: RefCounted) -> void:
	for control: String in ["tick", "finish", "lag"]:
		var demo: Demo = Demo.new()
		demo.start(0)
		for frame: int in 4:
			demo.tick(Game.RIGHT)
		context.equal(demo.start_replay(), Types.Code.OK, "recorded match opens")
		var before: Array = _snapshot(demo)
		if control != "lag":
			context.equal(_attempt(demo, control), Types.Code.BUSY, control + " keeps live game paused during replay")
			context.equal(_snapshot(demo), before, control + " leaves paused match unchanged")
		context.equal(demo.replay_player.begin_advance().code, Types.Code.READY, "replay expert batch opens")
		before = _snapshot(demo)
		context.equal(_attempt(demo, control), Types.Code.BUSY, control + " respects replay expert ownership")
		context.equal(_snapshot(demo), before, control + " preserves controller under replay batch")
		demo.stop_replay()
		context.equal(demo.set_lag(3), Types.Code.OK, "idle lag control resumes")
		context.equal(demo.tick(Game.LEFT), Types.Code.OK, "live service resumes after playback stops")

	_replay_callback_controls(context)


func _replay_callback_controls(context: RefCounted) -> void:
	for callback: String in ["save", "advance", "validate"]:
		for control: String in ["tick", "finish", "lag"]:
			var demo: Demo = Demo.new()
			demo.start(0)
			for frame: int in 4:
				demo.tick(Game.RIGHT)
			demo.start_replay()
			var player: RefCounted = demo.replay_player
			var game: CallbackGame = CallbackGame.new()
			game.from_save = callback != "advance"
			context.equal(player.configure(demo.loop.session.replay(), game, Game.SNAPSHOT_BYTES), Types.Code.OK, "callback replay configures")
			var owner: WeakRef = weakref(demo)
			var attempts: PackedInt32Array = PackedInt32Array()
			game.callback = func() -> void:
				var current: Demo = owner.get_ref()
				var before: Array = _snapshot(current)
				attempts.append(_attempt(current, control))
				context.equal(_snapshot(current), before, control + " preserves live match during replay callback")
				current.stop_replay()
				current.stop_replay()
				attempts.append(_attempt(current, control))
				context.equal(_snapshot(current), before, control + " preserves live match after callback cancellation")
			var code: int = player.validate_current_frame() if callback == "validate" else player.step()
			game.callback = Callable()
			context.equal(code, Types.Code.TERMINATED, "callback cancellation remains terminal")
			context.equal(attempts, PackedInt32Array([Types.Code.BUSY, Types.Code.BUSY]), control + " retains cancelled callback ownership")
			context.equal(demo.tick(Game.LEFT), Types.Code.OK, "live match resumes after cancelled callback returns")


func _stopped_controls(context: RefCounted) -> void:
	for control: String in ["tick", "finish", "lag", "loop_tick"]:
		var demo: Demo = Demo.new()
		demo.start(0)
		demo.tick(Game.RIGHT)
		demo.loop.session.terminate()
		var before: Array = _snapshot(demo)
		if control == "lag":
			context.equal(_attempt(demo, control), Types.Code.OK, "stopped match can select next lag")
		else:
			context.equal(_attempt(demo, control), Types.Code.TERMINATED, control + " reports stopped match")
			context.equal(_snapshot(demo), before, control + " cannot mutate stopped match")

	for exhausted: String in ["_current", "_batch_id"]:
		for control: String in ["tick", "finish", "loop_tick"]:
			var demo: Demo = Demo.new()
			demo.start(3)
			demo.tick(Game.RIGHT)
			demo.loop.session.set(exhausted, 2147483647 if exhausted == "_current" else 9223372036854775807)
			var before: Array = _snapshot(demo)
			context.equal(_attempt(demo, control), Types.Code.FRAME_EXHAUSTED, control + " detects exhaustion before staging")
			context.equal(_snapshot(demo), before, control + " preserves exhausted controller")
	var demo: Demo = Demo.new()
	demo.start(0)
	context.equal(demo.loop.tick(-1, Game.FIRE), Types.Code.INVALID_TIME, "invalid clock rejects before sampling")
	context.equal(demo.loop.tick(0, Game.LEFT), Types.Code.OK, "corrected clock accepts current buttons")
	var reference: Game = Game.new()
	var samples: Array[PackedByteArray] = [PackedByteArray([Game.LEFT]), PackedByteArray([0])]
	context.equal(reference.simulate_frame(0, Types.FrameInputs.new(samples, PackedInt32Array([1, 2]))), true, "reference advances current buttons")
	context.bytes_equal(demo.loop.game.canonical_bytes(), reference.canonical_bytes(), 1, "invalid time cannot retain stale buttons")


func _input_rejections(context: RefCounted) -> void:
	for facade: String in ["demo", "loop"]:
		for rejection: String in ["conflict", "player", "width"]:
			var demo: Demo = Demo.new()
			demo.start(3)
			var expected: int = Types.Code.INPUT_ALREADY_SUBMITTED
			if rejection == "conflict":
				context.equal(demo.loop.session.submit_local_input(0, 0, PackedByteArray([Game.LEFT])).code, Types.Code.OK, "expert stages original sample")
			elif rejection == "player":
				demo.loop.local_player = 1
				expected = Types.Code.INVALID_PLAYER
			else:
				var config: RefCounted = demo.loop.session._config.owned_copy()
				config.input_width = 2
				config.neutral_input = PackedByteArray([0, 0])
				config.storage_budget_bytes = config.required_storage_bytes()
				context.equal(demo.loop.session.configure(config), Types.Code.OK, "expert changes sample width")
				expected = Types.Code.INPUT_WIDTH
			var before: Array = _snapshot(demo)
			var code: int = demo.tick(Game.RIGHT) if facade == "demo" else demo.loop.tick(0, Game.RIGHT)
			context.equal(code, expected, facade + " rejects " + rejection)
			context.equal(_snapshot(demo), before, facade + " rejected input preserves controller")
			if rejection == "player":
				demo.loop.local_player = 0
			elif rejection == "width":
				context.equal(demo.loop.start(), Types.Code.OK, "restore supported sample shape")
			code = demo.tick(Game.LEFT) if facade == "demo" else demo.loop.tick(0, Game.LEFT)
			context.equal(code, Types.Code.OK, facade + " corrected sample retry advances")
			context.equal(demo.loop.game.x[0], 96, facade + " retry uses corrected LEFT buttons")

	for control: String in ["tick", "finish", "loop_tick"]:
		var demo: Demo = Demo.new()
		demo.start(3)
		demo.tick(Game.RIGHT)
		context.equal(demo.loop.session.poll(1000000).code, Types.Code.OK, "expert poll moves clock ahead")
		var before: Array = _snapshot(demo)
		context.equal(_attempt(demo, control), Types.Code.INVALID_TIME, control + " rejects stale controller time")
		context.equal(_snapshot(demo), before, control + " invalid time preserves queued deliveries")
