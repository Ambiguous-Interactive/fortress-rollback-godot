extends RefCounted

# Value: protects=restarting the guide loop resets the whole match; fails_when=session frame resets beneath old game/input/effects;
# why_new=demo restarts create another loop instead of reusing one; seam=none
const Loop = preload("res://examples/integration/loop.gd")
const Game = preload("res://examples/integration/game.gd")
const Effects = preload("res://examples/integration/effects.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


class RecordedEffects:
	extends Effects
	var ids: PackedInt64Array = PackedInt64Array()

	func play(id: int) -> void:
		ids.append(id)


class CallbackGame:
	extends Game
	var on_save: Callable

	func save_state(frame: int, writer: Game.Writer) -> Driver.SaveResult:
		if on_save.is_valid():
			on_save.call()
		return super.save_state(frame, writer)


func cases() -> PackedStringArray:
	return PackedStringArray(["restart_lifetime", "restart_rejections", "restart_callbacks"])


func run_case(name: String, context: RefCounted) -> void:
	call("_" + name, context)
	context.finish()


func _restart_lifetime(context: RefCounted) -> void:
	var ledger: RecordedEffects = RecordedEffects.new()
	var loop: Loop = Loop.new(0, ledger)
	var custom_game: Game = Game.new()
	custom_game.x[0] = 104
	loop.game = custom_game
	context.equal(loop.start(), Types.Code.OK, "initial caller-owned callbacks configure")
	context.equal(loop.game, custom_game, "first start keeps supplied game")
	context.equal(loop.effects, ledger, "first start keeps supplied ledger")
	context.equal(loop.session.receive_input(1, 0, PackedByteArray([Game.FIRE])).code, Types.Code.OK, "confirm first remote input")
	context.equal(loop.tick(0, Game.RIGHT | Game.FIRE), Types.Code.OK, "original game moves and fires")
	context.equal(ledger.ids.size(), 2, "original match plays confirmed effects")
	var previous: RefCounted = loop.session
	var old_driver: Driver = loop.driver
	var old_bytes: PackedByteArray = custom_game.canonical_bytes()
	context.equal(loop.start(), Types.Code.OK, "same loop starts a fresh match")
	context.equal(loop.session != previous, true, "restart replaces session lifetime")
	context.equal(previous.status().lifecycle, Types.Lifecycle.TERMINATED, "old session permanently retires")
	context.equal(old_driver.recover(1).code, Types.Code.TERMINATED, "retained driver cannot call old callbacks")
	context.bytes_equal(custom_game.canonical_bytes(), old_bytes, 1, "old game remains unchanged")
	context.bytes_equal(loop.game.canonical_bytes(), Game.new().canonical_bytes(), 0, "restart restores complete original game")
	context.equal(loop.effects.last_played_id, 0, "restart clears effect deduplication")
	context.equal(loop._sample_frame, -1, "restart clears sampled frame")
	context.equal(loop._sample.is_empty(), true, "restart clears old buttons")
	context.equal(loop.session.receive_input(1, 0, PackedByteArray([0])).code, Types.Code.OK, "fresh match accepts frame-zero input")
	context.equal(loop.tick(0, Game.LEFT), Types.Code.OK, "restart accepts fresh frame-zero buttons and clock")
	var reference: Game = Game.new()
	context.equal(
		reference.simulate_frame(0, Types.FrameInputs.new([PackedByteArray([Game.LEFT]), PackedByteArray([0])], PackedInt32Array([0, 0]))), true, "independent fresh game advances"
	)
	context.bytes_equal(loop.game.canonical_bytes(), reference.canonical_bytes(), 1, "restart does not reuse old sample or game")


func _restart_rejections(context: RefCounted) -> void:
	for missing: String in ["game", "effects"]:
		var unconfigured: Loop = Loop.new(0)
		unconfigured.set(missing, null)
		var original: RefCounted = unconfigured.session
		context.equal(unconfigured.start(), Types.Code.INVALID_CONFIGURATION, "missing initial " + missing + " rejects without callbacks")
		context.equal(unconfigured.session, original, "invalid initial callback owner preserves session")
		context.equal(unconfigured.driver, null, "invalid initial callback owner creates no driver")
	var loop: Loop = Loop.new(0)
	context.equal(loop.start(), Types.Code.OK, "start rejection fixture")
	context.equal(loop.tick(0, Game.RIGHT), Types.Code.OK, "fixture retains live samples")
	var previous: RefCounted = loop.session
	var driver: Driver = loop.driver
	var bytes: PackedByteArray = loop.game.canonical_bytes()
	loop.local_player = 9
	context.equal(loop.start(), Types.Code.INVALID_CONFIGURATION, "invalid player rejects replacement")
	context.equal(loop.session, previous, "invalid start preserves current session")
	context.equal(loop.driver, driver, "invalid start preserves current driver")
	context.bytes_equal(loop.game.canonical_bytes(), bytes, 1, "invalid start preserves canonical game")
	context.equal(loop._sample_frame, 0, "invalid start preserves held sample")
	loop.local_player = 0
	var frame: int = previous.status().current_frame
	context.equal(previous.submit_local_input(0, frame, PackedByteArray([Game.LEFT])).code, Types.Code.OK, "expert stages next input")
	var opened: Types.Result = previous.begin_advance()
	context.equal(opened.code, Types.Code.READY, "expert owns an active batch")
	context.equal(loop.start(), Types.Code.BUSY, "held expert work rejects restart")
	context.equal(loop.session, previous, "busy restart preserves session identity")
	previous.terminate()
	context.equal(loop.start(), Types.Code.OK, "restart is available after cancellation")
	var outcomes: PackedInt32Array = PackedInt32Array()
	var owner: WeakRef = weakref(loop)
	loop.driver.step_completed.connect(func(_code: int, _before: int, _after: int) -> void: outcomes.append(owner.get_ref().start()), CONNECT_ONE_SHOT)
	context.equal(loop.tick(0, Game.RIGHT), Types.Code.OK, "completion invokes restart attempt")
	context.equal(outcomes, PackedInt32Array([Types.Code.BUSY]), "completion ownership rejects restart")
	context.equal(loop.start(), Types.Code.OK, "restart works after completion ownership releases")
	previous = loop.session
	var custom: Game = Game.new()
	custom.x[1] = 304
	var ledger: RecordedEffects = RecordedEffects.new()
	context.equal(loop.start(custom, ledger), Types.Code.OK, "restart accepts explicit custom game and effects")
	context.equal(loop.game, custom, "explicit game installs without losing customization")
	context.equal(loop.effects, ledger, "explicit custom effect hook installs")
	context.equal(previous.status().reason, Types.Code.TERMINATED, "explicit replacement retires previous owner")
	for invalid: String in ["game", "effects"]:
		previous = loop.session
		var invalid_game: Game = Game.new()
		var invalid_effects: Effects = Effects.new()
		if invalid == "game":
			invalid_game.frame = 1
		else:
			invalid_effects.last_played_id = 1
		context.equal(loop.start(invalid_game, invalid_effects), Types.Code.INVALID_CONFIGURATION, "used " + invalid + " cannot initialize a new match")
		context.equal(loop.session, previous, "invalid custom replacement preserves current session")
		context.equal(loop.game, custom, "invalid custom replacement preserves current game")
		context.equal(loop.effects, ledger, "invalid custom replacement preserves current ledger")


func _restart_callbacks(context: RefCounted) -> void:
	for cancel: bool in [false, true]:
		var loop: Loop = Loop.new(0)
		var custom: CallbackGame = CallbackGame.new()
		context.equal(loop.start(custom), Types.Code.OK, "configure custom callback game")
		var previous: RefCounted = loop.session
		var owner: WeakRef = weakref(loop)
		var outcomes: PackedInt32Array = PackedInt32Array()
		custom.on_save = func() -> void:
			var active: Loop = owner.get_ref()
			if cancel:
				active.session.terminate(Types.Code.DESYNC)
			outcomes.append(active.start())
			context.equal(active.session, previous, "callback retains its session throughout attempted replacement")
		var code: int = loop.tick(0, Game.RIGHT)
		custom.on_save = Callable()
		context.equal(code, Types.Code.TERMINATED if cancel else Types.Code.OK, "callback preserves ordinary or cancelled operation result")
		context.equal(previous.status().reason, Types.Code.DESYNC if cancel else Types.Code.OK, "cancelled callback preserves first terminal cause")
		context.equal(outcomes, PackedInt32Array([Types.Code.BUSY]), "callback restart remains BUSY even after cancellation")
		context.equal(loop.start(), Types.Code.OK, "restart succeeds once callback returns")
