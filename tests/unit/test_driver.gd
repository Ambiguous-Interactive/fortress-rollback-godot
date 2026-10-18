extends RefCounted

# Value: protects=driver request parity and callback failure; fails_when=driver reorders or resumes failed batches; why_new=expert engine lacks driver coverage; seam=none
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


class Game:
	extends RefCounted
	var value: int = 0
	var trace: PackedStringArray = PackedStringArray()
	var snapshots: Array[PackedByteArray] = []
	var fail_kind: int = -1
	var driver: RefCounted
	var callback_session: RefCounted
	var reentry_codes: PackedInt32Array = PackedInt32Array()
	var retained_inputs: RefCounted
	var terminating_session: RefCounted
	var terminating_config: RefCounted
	var terminating_kind: int = Types.Kind.SAVE
	var termination_codes: PackedInt32Array = PackedInt32Array()

	func _reenter() -> void:
		if terminating_session != null and trace[trace.size() - 1].begins_with(["save", "load", "advance"][terminating_kind]):
			terminating_session.terminate()
			termination_codes.append(terminating_session.configure(terminating_config))
			termination_codes.append(terminating_session.poll(0).code)
			termination_codes.append(terminating_session.submit_local_input(0, 0, PackedByteArray([0])).code)
			termination_codes.append(terminating_session.receive_input(1, 0, PackedByteArray([0])).code)
			termination_codes.append(terminating_session.begin_advance().code)
			termination_codes.append(terminating_session.complete_request(0, 0, true).code)
		if callback_session != null:
			reentry_codes.append(callback_session.complete_request(1, 0, true, _checksum_bytes()).code)
		if driver != null:
			var inputs: Array[Driver.LocalInput] = []
			reentry_codes.append(driver.step(0, inputs).code)
			reentry_codes.append(driver.configure(null, null))

	func _checksum_bytes() -> PackedByteArray:
		var checksum: PackedByteArray = PackedByteArray()
		checksum.resize(16)
		return checksum

	func save_state(frame: int, writer: RefCounted) -> Driver.SaveResult:
		trace.append("save:%d" % frame)
		_reenter()
		if terminating_session != null and terminating_session.status().lifecycle == Types.Lifecycle.TERMINATED:
			return Driver.SaveResult.new(false)
		var bytes: PackedByteArray = PackedByteArray()
		bytes.resize(8)
		bytes.encode_s64(0, value)
		writer.write_bytes(bytes)
		snapshots.append(bytes.duplicate())
		var checksum: PackedByteArray = PackedByteArray()
		checksum.resize(16)
		checksum.encode_s64(0, value)
		return Driver.SaveResult.new(fail_kind != Types.Kind.SAVE, checksum)

	func load_state(frame: int, reader: RefCounted) -> bool:
		trace.append("load:%d" % frame)
		_reenter()
		if terminating_session != null and terminating_session.status().lifecycle == Types.Lifecycle.TERMINATED:
			return false
		var restored: RefCounted = reader.read_bytes(8)
		if restored.code != 0 or not reader.is_complete():
			return false
		value = restored.bytes.decode_s64(0)
		return fail_kind != Types.Kind.LOAD

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		trace.append("advance:%d" % frame)
		_reenter()
		if terminating_session != null and terminating_session.status().lifecycle == Types.Lifecycle.TERMINATED:
			return false
		retained_inputs = inputs
		for player: int in range(inputs.size().value):
			var input: Types.InputResult = inputs.read(player)
			value = value * 3 + input.bytes[0] + frame
			input.bytes[0] = 99
		return fail_kind != Types.Kind.ADVANCE


func cases() -> PackedStringArray:
	return PackedStringArray(["parity", "reentry", "failure", "validation", "stall", "terminate_reconfigure", "notifications", "input_validation"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"parity":
			_parity(context)
		"reentry":
			_reentry(context)
		"failure":
			_failure(context)
		"validation":
			_validation(context)
		"stall":
			_stall(context)
		"terminate_reconfigure":
			_terminate_reconfigure(context)
		"notifications":
			_notifications(context)
		"input_validation":
			_input_validation(context)
	context.finish()


func _session() -> RefCounted:
	var config: RefCounted = Config.new()
	config.max_snapshot_bytes = 8
	config.storage_budget_bytes = 65536
	config.max_prediction_frames = 2
	config.history_slots = 3
	var session: RefCounted = Session.new()
	session.configure(config)
	return session


func _samples(frame: int) -> Array[Driver.LocalInput]:
	var result: Array[Driver.LocalInput] = []
	for player: int in range(2):
		result.append(Driver.LocalInput.new(player, frame, PackedByteArray([(frame + player) % 5])))
	return result


func _expert_step(session: RefCounted, game: Game, frame: int) -> int:
	session.poll(frame)
	for sample: Driver.LocalInput in _samples(frame):
		session.submit_local_input(sample.player, sample.sample_frame, sample.bytes)
	var advance: Types.Result = session.begin_advance()
	var code: int = advance.code
	while advance.batch != null:
		var request: Types.Request = advance.batch.next_request()
		if request == null:
			break
		var ok: bool = true
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
		code = session.complete_request(request.batch_id, request.request_id, ok, checksum).code
	return code


func _parity(context: RefCounted) -> void:
	var driver_session: RefCounted = _session()
	var expert_session: RefCounted = _session()
	var driver_game: Game = Game.new()
	var expert_game: Game = Game.new()
	var driver: RefCounted = Driver.new(driver_session, driver_game)
	for frame: int in range(14):
		var result: RefCounted = driver.step(frame, _samples(frame))
		context.equal(result.code, _expert_step(expert_session, expert_game, frame), "expert outcome")
		context.equal(result.frame_before, frame, "before")
		context.equal(result.frame_after, frame + 1, "one new frame")
		context.equal(driver_game.trace, expert_game.trace, "ordered callbacks")
		context.equal(driver_game.value, expert_game.value, "canonical state")
		context.equal(driver_game.snapshots.size(), expert_game.snapshots.size(), "save count")
		for index: int in range(driver_game.snapshots.size()):
			context.bytes_equal(driver_game.snapshots[index], expert_game.snapshots[index], frame, "canonical snapshots")
		context.equal(driver_game.retained_inputs.read(0).code, Types.Code.EXPIRED_VIEW, "view expires")
	context.equal("load:1" in driver_game.trace, true, "rewind exercised")


func _reentry(context: RefCounted) -> void:
	var game: Game = Game.new()
	var driver: RefCounted = Driver.new(_session(), game)
	game.driver = driver
	game.callback_session = driver._session
	for frame: int in range(5):
		context.equal(driver.step(frame, _samples(frame)).code, Types.Code.OK, "outer step")
	for code: int in game.reentry_codes:
		context.equal(code, Types.Code.BUSY, "recursive call refused")
	game.driver = null


func _failure(context: RefCounted) -> void:
	for kind: int in [Types.Kind.SAVE, Types.Kind.LOAD, Types.Kind.ADVANCE]:
		var session: RefCounted = _session()
		var game: Game = Game.new()
		var driver: RefCounted = Driver.new(session, game)
		var frame: int = 0
		if kind == Types.Kind.LOAD:
			for setup_frame: int in range(3):
				driver.step(setup_frame, _samples(setup_frame))
			frame = 3
		game.fail_kind = kind
		var count_before: int = game.trace.size()
		context.equal(driver.step(frame, _samples(frame)).code, Types.Code.CALLBACK_FAILED, "callback failure")
		context.equal(session.status().failure_kind, kind, "failure kind")
		context.equal(session.status().current_frame, frame, "failed frame not published")
		var count_failed: int = game.trace.size()
		context.equal(count_failed - count_before, 2 if kind == Types.Kind.ADVANCE else 1, "later callbacks skipped")
		context.equal(driver.step(frame, _samples(frame)).code, Types.Code.TERMINATED, "final termination")
		context.equal(game.trace.size(), count_failed, "no retry callbacks")


func _validation(context: RefCounted) -> void:
	var driver: RefCounted = Driver.new()
	context.equal(driver.step(0, _samples(0)).code, Types.Code.NOT_CONFIGURED, "unconfigured")
	context.equal(driver.configure(_session(), RefCounted.new()), Types.Code.INVALID_CONFIGURATION, "game contract")
	var session: RefCounted = _session()
	context.equal(driver.configure(session, Game.new()), Types.Code.OK, "configure")
	var missing: Array[Driver.LocalInput] = []
	context.equal(driver.step(0, missing).code, Types.Code.MISSING_LOCAL_INPUT, "missing local input")
	context.equal(driver.step(-1, _samples(0)).code, Types.Code.INVALID_TIME, "invalid time")
	var source: PackedByteArray = PackedByteArray([3])
	var owned: Driver.LocalInput = Driver.LocalInput.new(0, 0, source)
	source[0] = 99
	context.equal(owned.bytes[0], 3, "owned local sample")
	var samples: Array[Driver.LocalInput] = [owned, Driver.LocalInput.new(1, 0, PackedByteArray([1]))]
	context.equal(driver.step(0, samples).code, Types.Code.OK, "retry after missing sample")


# Value: protects=driver recovery-only batches preserve frame and local sample; fails_when=stall is treated as success; why_new=sync-test parity never stalls; seam=none
func _stall(context: RefCounted) -> void:
	var config: RefCounted = Config.new()
	config.sync_test = false
	config.local_players = PackedInt32Array([0])
	config.check_distance = 0
	config.max_prediction_frames = 2
	config.history_slots = 3
	config.max_snapshot_bytes = 8
	config.storage_budget_bytes = 65536
	var session: RefCounted = Session.new()
	context.equal(session.configure(config), Types.Code.OK, "external-input session")
	var game: Game = Game.new()
	var driver: RefCounted = Driver.new(session, game)
	var notices: Array[PackedInt32Array] = []
	driver.step_completed.connect(func(code: int, before: int, after: int) -> void: notices.append(PackedInt32Array([code, before, after])))
	for frame: int in range(2):
		var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, frame, PackedByteArray([1]))]
		context.equal(driver.step(frame, samples).code, Types.Code.OK, "predict")
	var stalled_sample: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, 2, PackedByteArray([2]))]
	var count: int = game.trace.size()
	var stalled: RefCounted = driver.step(2, stalled_sample)
	context.equal(stalled.code, Types.Code.PREDICTION_STALL, "prediction boundary")
	context.equal(stalled.frame_after, 2, "stall keeps frame")
	context.equal(game.trace.size(), count, "immediate stall no callback")
	context.equal(notices[-1], PackedInt32Array([Types.Code.PREDICTION_STALL, 2, 2]), "immediate stall notification")
	context.equal(session.receive_input(1, 0, PackedByteArray([7])).code, Types.Code.OK, "mismatch")
	var recovered: RefCounted = driver.step(3, stalled_sample)
	context.equal(recovered.code, Types.Code.PREDICTION_STALL, "recovery-only outcome")
	context.equal(recovered.frame_after, 2, "recovery keeps frame")
	context.equal(game.trace[count], "load:0", "recovery starts with load")
	context.equal(game.trace[game.trace.size() - 1], "advance:1", "recovery stops before stalled new frame")
	context.equal(notices[-1], PackedInt32Array([Types.Code.PREDICTION_STALL, 2, 2]), "repair-only completion notification")
	context.equal(notices.size(), 4, "one signal for whole recovery batch")
	context.equal(session.receive_input(1, 1, PackedByteArray([7])).code, Types.Code.OK, "confirmation permits retry")
	var resumed: RefCounted = driver.step(4, stalled_sample)
	context.equal(resumed.code, Types.Code.OK, "stalled sample survives")
	context.equal(resumed.frame_before, 2, "retry frame before")
	context.equal(resumed.frame_after, 3, "retry one new frame")


# Value: protects=callback lock survives terminate; fails_when=terminate opens reconfigure inside callback; why_new=batch guard alone disappears; seam=none
func _terminate_reconfigure(context: RefCounted) -> void:
	for kind: int in [Types.Kind.SAVE, Types.Kind.LOAD, Types.Kind.ADVANCE]:
		var session: RefCounted = _session()
		var game: Game = Game.new()
		var config: RefCounted = Config.new()
		config.max_snapshot_bytes = 8
		config.storage_budget_bytes = 65536
		var driver: RefCounted = Driver.new(session, game)
		var frame: int = 0
		if kind == Types.Kind.LOAD:
			for setup_frame: int in range(3):
				driver.step(setup_frame, _samples(setup_frame))
			frame = 3
		game.terminating_session = session
		game.terminating_config = config
		game.terminating_kind = kind
		var count: int = game.trace.size()
		context.equal(driver.step(frame, _samples(frame)).code, Types.Code.TERMINATED, "callback termination remains final")
		for code: int in game.termination_codes:
			context.equal(code, Types.Code.BUSY, "session busy throughout callback after termination")
		context.equal(session.status().lifecycle, Types.Lifecycle.TERMINATED, "configuration was not replaced")
		context.equal(session.status().current_frame, frame, "no replacement-frame exposure")
		context.equal(game.trace.size() - count, 2 if kind == Types.Kind.ADVANCE else 1, "later callbacks skipped")
		context.equal(session.configure(config), Types.Code.OK, "callback lock released after return")


# Value: protects=notification sees completed state and cannot recurse; fails_when=emit is early or unguarded; why_new=callback tests run inside requests; seam=none
func _notifications(context: RefCounted) -> void:
	var game: Game = Game.new()
	var session: RefCounted = _session()
	var driver: RefCounted = Driver.new(session, game)
	context.equal(driver.has_signal("step_completed"), true, "typed completion notification exists")
	if not driver.has_signal("step_completed"):
		return
	var notices: Array[PackedInt32Array] = []
	var driver_ref: WeakRef = weakref(driver)
	driver.connect(
		"step_completed",
		func(code: int, before: int, after: int) -> void:
			var current_driver: RefCounted = driver_ref.get_ref()
			notices.append(PackedInt32Array([code, before, after]))
			context.equal(session.status().current_frame, after, "published final frame")
			context.equal(session.drain_events().size(), 0, "events already drained")
			if game.retained_inputs != null:
				context.equal(game.retained_inputs.read(0).code, Types.Code.EXPIRED_VIEW, "request views expired before notification")
			var empty: Array[Driver.LocalInput] = []
			context.equal(current_driver.step(0, empty).code, Types.Code.BUSY, "notification cannot advance recursively")
			context.equal(current_driver.configure(session, game), Types.Code.BUSY, "notification cannot replace callbacks")
	)
	for frame: int in range(5):
		var result: Driver.StepResult = driver.step(frame, _samples(frame))
		context.equal(notices.size(), frame + 1, "one notice per outer step including rewinds")
		context.equal(notices[-1], PackedInt32Array([result.code, frame, frame + 1]), "notice matches returned result")
	context.equal("load:1" in game.trace, true, "notification follows actual rollback")
	game.fail_kind = Types.Kind.ADVANCE
	context.equal(driver.step(5, _samples(5)).code, Types.Code.CALLBACK_FAILED, "explicit callback failure")
	context.equal(notices[-1], PackedInt32Array([Types.Code.CALLBACK_FAILED, 5, 5]), "failed batch has final notification")
	context.equal(notices.size(), 6, "failure only once")
	context.equal(driver.configure(_session(), Game.new()), Types.Code.OK, "guard released after notification")
	var busy_session: RefCounted = _session()
	var busy_driver: RefCounted = Driver.new(busy_session, Game.new())
	var busy_notices: Array[int] = []
	busy_driver.step_completed.connect(func(code: int, _before: int, _after: int) -> void: busy_notices.append(code))
	for sample: Driver.LocalInput in _samples(0):
		busy_session.submit_local_input(sample.player, sample.sample_frame, sample.bytes)
	context.equal(busy_session.begin_advance().code, Types.Code.READY, "expert owns open batch")
	context.equal(busy_driver.step(0, _samples(0)).code, Types.Code.BUSY, "external batch rejects driver")
	context.equal(busy_notices.size(), 0, "no completion for someone else's batch")
	busy_session.terminate()


# Value: protects=rejected driver sample lists permit corrected retries; fails_when=valid prefix commits before invalid tail; why_new=validation covers one sample only; seam=none
func _input_validation(context: RefCounted) -> void:
	var malformed: Array[Driver.LocalInput] = [
		null,
		Driver.LocalInput.new(2, 0, PackedByteArray([1])),
		Driver.LocalInput.new(1, 1, PackedByteArray([1])),
		Driver.LocalInput.new(1, 0, PackedByteArray([1, 2])),
		Driver.LocalInput.new(0, 0, PackedByteArray([2])),
	]
	var codes: PackedInt32Array = PackedInt32Array([
		Types.Code.INVALID_CONFIGURATION, Types.Code.INVALID_PLAYER, Types.Code.INVALID_FRAME,
		Types.Code.INPUT_WIDTH, Types.Code.INPUT_ALREADY_SUBMITTED,
	])
	for index: int in range(malformed.size()):
		var session: RefCounted = _session()
		var game: Game = Game.new()
		var driver: RefCounted = Driver.new(session, game)
		var rejected: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, 0, PackedByteArray([1])), malformed[index]]
		context.equal(driver.step(0, rejected).code, codes[index], "invalid tail rejected")
		context.equal(session.scheduled_local_input(0).code, Types.Code.MISSING_LOCAL_INPUT, "rejected prefix was not retained")
		context.equal(session.received_frames(), PackedInt64Array([-1, -1]), "rejected list leaves receipt bank unchanged")
		context.equal(game.trace.size(), 0, "invalid list never invokes game")
		var repaired: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, 0, PackedByteArray([3])), Driver.LocalInput.new(1, 0, PackedByteArray([4]))]
		context.equal(driver.step(0, repaired).code, Types.Code.OK, "corrected retry accepts fresh sample")
		context.equal(game.value, 13, "simulation uses corrected samples")
	var session: RefCounted = _session()
	var game: Game = Game.new()
	var driver: RefCounted = Driver.new(session, game)
	context.equal(session.submit_local_input(0, 0, PackedByteArray([2])).code, Types.Code.OK, "expert retained sample")
	context.equal(session.submit_local_input(0, 0, PackedByteArray([3])).value, -1, "conflicting expert retry keeps rejected scheduled-frame sentinel")
	var conflicting: Array[Driver.LocalInput] = [Driver.LocalInput.new(1, 0, PackedByteArray([1])), Driver.LocalInput.new(0, 0, PackedByteArray([3]))]
	context.equal(driver.step(0, conflicting).code, Types.Code.INPUT_ALREADY_SUBMITTED, "conflict with retained expert sample")
	context.equal(session.scheduled_local_input(1).code, Types.Code.MISSING_LOCAL_INPUT, "conflict rejects valid prefix")
	context.bytes_equal(session.scheduled_local_input(0).bytes, PackedByteArray([2]), 0, "expert sample preserved")
	var repeated: Array[Driver.LocalInput] = [
		Driver.LocalInput.new(0, 0, PackedByteArray([2])), Driver.LocalInput.new(0, 0, PackedByteArray([2])),
		Driver.LocalInput.new(1, 0, PackedByteArray([4])),
	]
	context.equal(driver.step(0, repeated).code, Types.Code.OK, "identical duplicates and expert sample remain idempotent")
	context.equal(game.value, 10, "accepted list uses retained sample")

	# Duplicate list length must not change acceptance or prevent servicing a complete input frame.
	var many: Array[Driver.LocalInput] = []
	var duplicate: Driver.LocalInput = Driver.LocalInput.new(0, 1, PackedByteArray([2]))
	for index: int in range(10000):
		many.append(duplicate)
	many.append(Driver.LocalInput.new(1, 1, PackedByteArray([4])))
	context.equal(driver.step(1, many).code, Types.Code.OK, "large identical duplicate list accepted")
	context.equal(session.status().current_frame, 2, "large list advances only one frame")
	context.equal(game.value, 104, "large list applies each player's input once")
