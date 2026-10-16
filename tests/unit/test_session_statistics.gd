extends RefCounted

# Value: protects=owned completed-work metrics; fails_when=failed callbacks or reads count as rollback work;
# why_new=callback parity lacks public diagnostics; seam=none
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Fixture = preload("res://tests/unit/test_driver.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["completed_work", "stalls_and_repair", "failure_and_reset"])


func run_case(name: String, context: RefCounted) -> void:
	var session: Session = Session.new()
	context.equal(session.has_method("statistics"), true, "session exposes owned work statistics")
	if not session.has_method("statistics"):
		context.finish()
		return
	var config: Config = Config.new()
	config.max_snapshot_bytes = 8
	config.max_prediction_frames = 2
	config.check_distance = 2
	config.history_slots = 3
	config.storage_budget_bytes = 65536
	if name == "stalls_and_repair":
		config.sync_test = false
		config.check_distance = 0
		config.local_players = PackedInt32Array([0])
	context.equal(session.configure(config), Types.Code.OK, "configure")
	var game: RefCounted = Fixture.Game.new()
	var driver: Driver = Driver.new(session, game)
	if name == "completed_work":
		var fixture: RefCounted = Fixture.new()
		var expert: Session = Session.new()
		context.equal(expert.configure(config), Types.Code.OK, "configure expert")
		var reference: RefCounted = Fixture.Game.new()
		for frame: int in range(7):
			context.equal(driver.step(frame, fixture._samples(frame)).code, fixture._expert_step(expert, reference, frame), "driver expert parity")
			context.equal(game.value, reference.value, "diagnostic reads preserve canonical gameplay")
			context.equal(session.statistics().rollback_count, maxi(0, frame - 2), "successful restores counted once")
			context.equal(session.statistics().resimulated_frames, maxi(0, frame - 2) * 2, "only replayed frames counted")
			context.equal(session.statistics().advanced_frames, frame + 1, "new frames counted separately")
			context.equal(expert.statistics().resimulated_frames, session.statistics().resimulated_frames, "manual and driver share counters")
			var owned: RefCounted = session.statistics()
			owned.rollback_count = 900
			context.equal(session.statistics().rollback_count, maxi(0, frame - 2), "caller cannot alter counters")
		context.equal(session.statistics().last_rollback_depth, 2, "last completed load depth")
		context.equal(session.statistics().max_rollback_depth, 2, "maximum completed load depth")
	elif name == "stalls_and_repair":
		for frame: int in range(2):
			context.equal(driver.step(frame, _local(frame)).code, Types.Code.OK, "predict two frames")
		for attempt: int in range(3):
			context.equal(driver.step(2, _local(2)).code, Types.Code.PREDICTION_STALL, "stall")
		context.equal(session.statistics().prediction_stalls, 3, "each actual stalled attempt counted")
		context.equal(session.statistics().advanced_frames, 2, "stalls do not count advances")
		context.equal(session.receive_input(1, 0, PackedByteArray([1])).code, Types.Code.OK, "correction")
		context.equal(driver.step(2, _local(2)).code, Types.Code.PREDICTION_STALL, "repair without new frame")
		context.equal(session.statistics().rollback_count, 1, "repair-only load counted")
		context.equal(session.statistics().resimulated_frames, 2, "repair-only replay counted")
		context.equal(session.statistics().prediction_stalls, 4, "repair-only stall counted once")
		context.equal(session.statistics().advanced_frames, 2, "repair does not advance frontier")
		context.equal(driver.step(2, _local(2)).code, Types.Code.PREDICTION_STALL, "retry after repair")
		context.equal(session.statistics().rollback_count, 1, "matching retry never recounts restore")
	else:
		var fixture: RefCounted = Fixture.new()
		for frame: int in range(3):
			context.equal(driver.step(frame, fixture._samples(frame)).code, Types.Code.OK, "setup")
		game.fail_kind = Types.Kind.LOAD
		context.equal(driver.step(3, fixture._samples(3)).code, Types.Code.CALLBACK_FAILED, "load failure")
		context.equal(session.statistics().rollback_count, 0, "failed load is not completed work")
		context.equal(session.statistics().resimulated_frames, 0, "failed load skips replay")
		context.equal(session.statistics().advanced_frames, 3, "successful history survives failure")
		context.equal(driver.step(4, fixture._samples(3)).code, Types.Code.TERMINATED, "terminal retries")
		context.equal(session.statistics().prediction_stalls, 0, "errors are not prediction stalls")
		context.equal(session.configure(config), Types.Code.OK, "explicit fresh session")
		context.equal(session.statistics().advanced_frames, 0, "new session clears counters")
		context.equal(session.statistics().max_rollback_depth, 0, "new session clears depth")
	context.finish()


func _local(frame: int) -> Array[Driver.LocalInput]:
	return [Driver.LocalInput.new(0, frame, PackedByteArray([1]))]
