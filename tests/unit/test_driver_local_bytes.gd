extends RefCounted

# Value: protects=byte-only clients share driver semantics; fails_when=implicit metadata bypasses staging or guards; why_new=step uses explicit wrappers; seam=none
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Fixture = preload("res://tests/unit/test_driver.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


class MembershipGame:
	extends Fixture.Game
	var owner: WeakRef
	var observed: PackedInt32Array = PackedInt32Array()

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		observed = owner.get_ref().local_players()
		return super.simulate_frame(frame, inputs)


class NeutralGame:
	extends Fixture.Game
	var owner: WeakRef
	var observed: Array[PackedByteArray] = []
	var replacement_codes: PackedInt32Array = PackedInt32Array()

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		var driver: Driver = owner.get_ref()
		observed.append(driver.neutral_input())
		replacement_codes.append(driver.configure(Session.new(), Fixture.Game.new()))
		var copied: PackedByteArray = driver.neutral_input()
		copied.fill(99)
		var ok: bool = super.simulate_frame(frame, inputs)
		for player: int in range(inputs.size().value):
			var bytes: PackedByteArray = inputs.read(player).bytes
			for index: int in range(1, bytes.size()):
				value += bytes[index]
		return ok


func cases() -> PackedStringArray:
	return PackedStringArray(["parity", "validation", "retained", "reentry", "local_players", "neutral_input"])


func run_case(name: String, context: RefCounted) -> void:
	context.equal(Driver.new().has_method("step_local"), true, "byte-only client entry point exists")
	if Driver.new().has_method("step_local"):
		call("_" + name, context)
	context.finish()


func _bytes(frame: int) -> Array[PackedByteArray]:
	return [PackedByteArray([frame % 5]), PackedByteArray([(frame + 1) % 5])]


func _parity(context: RefCounted) -> void:
	var fixture: RefCounted = Fixture.new()
	var left_game: RefCounted = Fixture.Game.new()
	var right_game: RefCounted = Fixture.Game.new()
	var left: RefCounted = Driver.new(fixture._session(), left_game)
	var right: RefCounted = Driver.new(fixture._session(), right_game)
	for frame: int in range(20):
		var bytes: Array[PackedByteArray] = _bytes(frame)
		var actual: RefCounted = left.step_local(frame, bytes)
		var expected: RefCounted = right.step(frame, fixture._samples(frame))
		context.equal(actual.code, expected.code, "same result through queue reuse and rollback")
		context.equal(actual.frame_after, expected.frame_after, "same exposed boundary")
		context.equal(actual.events, expected.events, "same completed events")
		context.equal(left_game.trace, right_game.trace, "same ordered callbacks")
		context.equal(left_game.value, right_game.value, "same canonical game state")
		bytes[0][0] = 99
		context.equal(left.confirmed_inputs(frame).read(0).bytes, PackedByteArray([frame % 5]), "caller mutation cannot change confirmed input")
	context.equal("load:1" in left_game.trace, true, "actual rollback exercised")


func _validation(context: RefCounted) -> void:
	var empty: Array[PackedByteArray] = []
	context.equal(Driver.new().step_local(0, empty).code, Types.Code.NOT_CONFIGURED, "unconfigured call")
	for invalid_rows: Array in [empty, [PackedByteArray([1])], [PackedByteArray([1]), PackedByteArray([2, 3])], [PackedByteArray(), PackedByteArray([2])]]:
		var invalid: Array[PackedByteArray] = []
		invalid.assign(invalid_rows)
		var fixture: RefCounted = Fixture.new()
		var session: RefCounted = fixture._session()
		var driver: RefCounted = Driver.new(session, Fixture.Game.new())
		context.equal(driver.step_local(0, _bytes(0)).code, Types.Code.OK, "accepted clock control")
		context.equal(
			driver.step_local(100, invalid).code in [Types.Code.INVALID_CONFIGURATION, Types.Code.INPUT_WIDTH, Types.Code.MISSING_LOCAL_INPUT], true, "bad byte rows rejected"
		)
		context.equal(session.scheduled_local_input(0).code, Types.Code.MISSING_LOCAL_INPUT, "rejection stages no valid prefix")
		context.equal(driver.step_local(0, _bytes(1)).code, Types.Code.OK, "corrected retry preserves accepted clock")
		context.equal(driver.step_local(-1, _bytes(2)).code, Types.Code.INVALID_TIME, "successful service retains monotonic clock")


func _retained(context: RefCounted) -> void:
	var config: RefCounted = Config.new()
	config.sync_test = false
	config.local_players = PackedInt32Array([1])
	config.check_distance = 0
	config.max_prediction_frames = 2
	config.history_slots = 3
	config.max_snapshot_bytes = 8
	config.storage_budget_bytes = config.required_storage_bytes()
	var session: RefCounted = Session.new()
	context.equal(session.configure(config), Types.Code.OK, "nonzero local player configured")
	var game: RefCounted = Fixture.Game.new()
	var driver: RefCounted = Driver.new(session, game)
	for frame: int in range(2):
		var bytes: Array[PackedByteArray] = [PackedByteArray([frame + 2])]
		context.equal(driver.step_local(frame, bytes).code, Types.Code.OK, "implicit nonzero slot advances")
	var stalled: Array[PackedByteArray] = [PackedByteArray([9])]
	context.equal(driver.step_local(2, stalled).code, Types.Code.PREDICTION_STALL, "stalled bytes retained")
	stalled[0][0] = 99
	context.equal(driver.scheduled_local_input(1).bytes, PackedByteArray([9]), "caller does not own retained bytes")
	for frame: int in range(2):
		context.equal(session.receive_input(0, frame, PackedByteArray([4])).code, Types.Code.OK, "actual remote rows permit retry")
	var omitted: Array[PackedByteArray] = [PackedByteArray()]
	context.equal(driver.step_local(3, omitted).code, Types.Code.OK, "empty row uses retained stalled buttons")
	context.equal(driver.status().current_frame, 3, "retry advances exactly once")
	context.equal(driver.scheduled_local_input(1).code, Types.Code.MISSING_LOCAL_INPUT, "retry consumes retained sample")


func _reentry(context: RefCounted) -> void:
	var fixture: RefCounted = Fixture.new()
	var session: RefCounted = fixture._session()
	var driver: RefCounted = Driver.new(session, Fixture.Game.new())
	var alternate: RefCounted = Driver.new(session, Fixture.Game.new())
	var owner: WeakRef = weakref(driver)
	var other: WeakRef = weakref(alternate)
	var attempts: PackedInt32Array = PackedInt32Array()
	driver.step_completed.connect(
		func(_code: int, _before: int, _after: int) -> void:
			attempts.append(owner.get_ref().step_local(100, _bytes(1)).code)
			attempts.append(other.get_ref().step_local(100, _bytes(1)).code)
	)
	context.equal(driver.step_local(0, _bytes(0)).code, Types.Code.OK, "outer byte-only call completes")
	context.equal(attempts, PackedInt32Array([Types.Code.BUSY, Types.Code.BUSY]), "shared completion ownership prevents buffer mutation")
	context.equal(driver.step_local(0, _bytes(1)).code, Types.Code.OK, "reentry leaves next bytes and clock usable")


# Value: protects=driver-only row mapping; fails_when=membership order differs from byte submission; why_new=existing cases know the configured slot; seam=none
func _local_players(context: RefCounted) -> void:
	var driver: RefCounted = Driver.new()
	context.equal(driver.has_method("local_players"), true, "driver reveals byte-row player order")
	if not driver.has_method("local_players"):
		return
	context.equal(driver.local_players(), PackedInt32Array(), "unconfigured driver has no local slots")
	for roster: PackedInt32Array in [PackedInt32Array([1]), PackedInt32Array([6, 1, 4]), PackedInt32Array([7, 6, 5, 4, 3, 2, 1, 0])]:
		var config: Config = Config.new()
		config.sync_test = false
		config.player_count = 8
		config.check_distance = 0
		config.local_players = roster
		config.max_snapshot_bytes = 8
		config.storage_budget_bytes = config.required_storage_bytes()
		var session: Session = Session.new()
		context.equal(session.configure(config), Types.Code.OK, "arbitrary local membership configured")
		var game: MembershipGame = MembershipGame.new()
		game.owner = weakref(driver)
		context.equal(driver.configure(session, game), Types.Code.OK, "driver switches membership")
		var expected_slots: PackedInt32Array = roster.duplicate()
		expected_slots.sort()
		context.equal(driver.local_players(), expected_slots, "row order is ascending, independent of configuration order")
		var owned: PackedInt32Array = driver.local_players()
		owned.fill(0)
		context.equal(driver.local_players(), expected_slots, "returned slots cannot change driver membership")
		var rows: Array[PackedByteArray] = []
		for player: int in driver.local_players():
			rows.append(PackedByteArray([player + 1]))
		var canonical: int = 0
		for player: int in range(8):
			if player not in expected_slots:
				context.equal(session.receive_input(player, 0, PackedByteArray([0])).code, Types.Code.OK, "remote original row delivered")
			canonical = canonical * 3 + (player + 1 if player in expected_slots else 0)
		context.equal(driver.step_local(0, rows).code, Types.Code.OK, "client submits discovered row order")
		context.equal(game.observed, expected_slots, "callback may observe local membership")
		context.equal(game.value, canonical, "actual callback uses the intended local player bytes")
		for player: int in expected_slots:
			context.bytes_equal(driver.confirmed_inputs(0).read(player).bytes, PackedByteArray([player + 1]), 0, "confirmed row preserves discovered mapping")
		driver.terminate()
		context.equal(driver.local_players(), expected_slots, "terminal session retains its configured local membership")


# Value: protects=driver-only wide neutral sampling; fails_when=shape or bytes require retained config; why_new=byte tests assume one-byte zero neutral; seam=none
func _neutral_input(context: RefCounted) -> void:
	var driver: RefCounted = Driver.new()
	context.equal(driver.has_method("neutral_input"), true, "driver supplies configured neutral bytes")
	if not driver.has_method("neutral_input"):
		return
	context.equal(driver.neutral_input(), PackedByteArray(), "unconfigured driver has no neutral sample")
	context.equal(driver.configure(Session.new(), Fixture.Game.new()), Types.Code.OK, "unconfigured session can be attached")
	context.equal(driver.neutral_input(), PackedByteArray(), "unconfigured session has no sample shape")
	var config: Config = Config.new()
	config.input_width = 3
	config.neutral_input = PackedByteArray([12, 0, 255])
	config.max_snapshot_bytes = 8
	config.storage_budget_bytes = config.required_storage_bytes()
	var session: Session = Session.new()
	context.equal(session.configure(config), Types.Code.OK, "wide nonzero neutral session configured")
	var game: NeutralGame = NeutralGame.new()
	game.owner = weakref(driver)
	context.equal(driver.configure(session, game), Types.Code.OK, "driver-only wide client attached")
	config.neutral_input.fill(1)
	context.equal(driver.neutral_input(), PackedByteArray([12, 0, 255]), "caller configuration does not own installed neutral bytes")
	var owned: PackedByteArray = driver.neutral_input()
	owned.fill(7)
	context.equal(driver.neutral_input(), PackedByteArray([12, 0, 255]), "neutral sample read is owned")
	var expected: int = 0
	for frame: int in range(5):
		var rows: Array[PackedByteArray] = []
		for player: int in driver.local_players():
			var sample: PackedByteArray = driver.neutral_input()
			sample[1] = frame + player
			rows.append(sample)
			# The game consumes every byte; sync-test restores must preserve the full result.
			expected = expected * 3 + 12 + frame
		for player: int in driver.local_players():
			expected += frame + player + 255
		context.equal(driver.step_local(frame, rows).code, Types.Code.OK, "client builds wide rows using only the driver")
		context.equal(game.value, expected, "wide samples reach actual callbacks and survive rewind")
		for player: int in driver.local_players():
			context.bytes_equal(driver.confirmed_inputs(frame).read(player).bytes, rows[player], frame, "confirmed wide row keeps every supplied byte")
	context.equal("load:1" in game.trace, true, "wide rows exercise real sync-test rollback")
	for sample: PackedByteArray in game.observed:
		context.equal(sample, PackedByteArray([12, 0, 255]), "read remains safe during simulation callbacks")
	for code: int in game.replacement_codes:
		context.equal(code, Types.Code.BUSY, "callback read does not release replacement ownership")
	context.equal(driver.configure(null, null), Types.Code.INVALID_CONFIGURATION, "invalid replacement rejected")
	context.equal(driver.neutral_input(), PackedByteArray([12, 0, 255]), "invalid replacement preserves sample shape")
	driver.terminate()
	context.equal(driver.neutral_input(), PackedByteArray([12, 0, 255]), "terminal session preserves recorded sample shape")
	context.equal(driver.configure(Fixture.new()._session(), Fixture.Game.new()), Types.Code.OK, "driver accepts a fresh one-byte session")
	context.equal(driver.neutral_input(), PackedByteArray([0]), "replacement reads its own neutral sample")
