extends RefCounted

# Value: protects=driver-only retry and delay controls; fails_when=stalls hide owned samples or handlers change scheduling; why_new=expert tests bypass the driver; seam=none
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Fixture = preload("res://tests/unit/test_driver.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["stalled_retry", "delay_policy", "unconfigured"])


func run_case(name: String, context: RefCounted) -> void:
	var driver: RefCounted = Driver.new()
	for method: String in ["scheduled_local_input", "input_delay", "set_input_delay"]:
		context.equal(driver.has_method(method), true, "driver exposes " + method)
		if not driver.has_method(method):
			context.finish()
			return
	call("_" + name, context)
	context.finish()


func _stalled_retry(context: RefCounted) -> void:
	var config: Config = Config.new()
	config.sync_test = false
	config.local_players = PackedInt32Array([0])
	config.check_distance = 0
	config.max_prediction_frames = 2
	config.history_slots = 3
	config.max_snapshot_bytes = 8
	config.storage_budget_bytes = 65536
	var session: Session = Session.new()
	context.equal(session.configure(config), Types.Code.OK, "remote-input session configured")
	var driver: RefCounted = Driver.new(session, Fixture.Game.new())
	for frame: int in 2:
		var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, frame, PackedByteArray([1]))]
		context.equal(driver.step(frame, samples).code, Types.Code.OK, "prediction advances")
	var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, 2, PackedByteArray([9]))]
	context.equal(driver.step(2, samples).code, Types.Code.PREDICTION_STALL, "prediction boundary retains sample")
	var retained: Types.InputResult = driver.scheduled_local_input(0)
	context.equal(retained.code, Types.Code.OK, "driver reveals retained sample")
	context.equal(retained.frame, 2, "retained scheduled frame")
	context.bytes_equal(retained.bytes, PackedByteArray([9]), 2, "retained original input")
	retained.bytes[0] = 99
	context.bytes_equal(driver.scheduled_local_input(0).bytes, PackedByteArray([9]), 2, "returned bytes cannot change retry")
	context.equal(driver.scheduled_local_input(1).code, Types.Code.INVALID_PLAYER, "remote slot has no local sample")
	for frame: int in 2:
		context.equal(session.receive_input(1, frame, PackedByteArray([3])).code, Types.Code.OK, "transport supplies remote input")
	var empty: Array[Driver.LocalInput] = []
	context.equal(driver.step(3, empty).code, Types.Code.OK, "retry consumes retained sample without resampling")
	context.equal(driver.status().current_frame, 3, "retry advances exactly once")
	context.equal(driver.scheduled_local_input(0).code, Types.Code.MISSING_LOCAL_INPUT, "successful retry releases sample")
	context.bytes_equal(retained.bytes, PackedByteArray([99]), 2, "retained result survives later steps")


func _delay_policy(context: RefCounted) -> void:
	var driver: RefCounted = Driver.new(Fixture.new()._session(), Fixture.Game.new())
	context.equal(driver.input_delay(0), 0, "initial local delay")
	context.equal(driver.input_delay(8), -1, "invalid slot sentinel")
	context.equal(driver.set_input_delay(0, 1).code, Types.Code.OK, "delay applies before first sample")
	context.equal(driver.input_delay(0), 1, "new delay visible")
	var handler_codes: PackedInt32Array = PackedInt32Array()
	var owner: WeakRef = weakref(driver)
	driver.step_completed.connect(func(_code: int, _before: int, _after: int) -> void:
		var target: RefCounted = owner.get_ref()
		handler_codes.append(target.set_input_delay(0, 2).code)
	)
	context.equal(driver.step(0, Fixture.new()._samples(0)).code, Types.Code.OK, "delayed driver step")
	context.equal(handler_codes, PackedInt32Array([Types.Code.BUSY]), "completion handler cannot change scheduling")
	context.equal(driver.input_delay(0), 1, "handler leaves delay unchanged")
	context.equal(driver.set_input_delay(0, 0).code, Types.Code.UNSUPPORTED, "decrease after submission refused")
	context.equal(driver.set_input_delay(0, 2).code, Types.Code.OK, "between-step increase accepted")
	context.equal(driver.input_delay(0), 2, "accepted increase observable")
	context.equal(driver.set_input_delay(0, -1).code, Types.Code.INVALID_CONFIGURATION, "invalid delay refused")
	context.equal(driver.input_delay(0), 2, "invalid update is atomic")


func _unconfigured(context: RefCounted) -> void:
	var driver: RefCounted = Driver.new()
	context.equal(driver.input_delay(0), -1, "unconfigured delay sentinel")
	context.equal(driver.set_input_delay(0, 1).code, Types.Code.NOT_CONFIGURED, "unconfigured setter is explicit")
	context.equal(driver.scheduled_local_input(0).code, Types.Code.NOT_CONFIGURED, "unconfigured sample read is explicit")
