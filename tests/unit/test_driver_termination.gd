extends RefCounted

# Value: protects=driver-only cancellation and active view expiry; fails_when=stopping needs the expert session; why_new=termination fixtures retain session; seam=none
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const SnapshotStatus = preload("res://addons/fortress_rollback/core/snapshot_status.gd")
const Fixture = preload("res://tests/unit/test_driver.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")


class StoppingGame:
	extends Fixture.Game
	var owner_ref: WeakRef
	var stop_kind: int = -1
	var retained_view: RefCounted
	var codes: PackedInt32Array = PackedInt32Array()

	func _stop(kind: int, view: RefCounted) -> bool:
		if kind != stop_kind:
			return false
		retained_view = view
		var target: RefCounted = owner_ref.get_ref()
		target.terminate(Types.Code.DESYNC)
		target.terminate(Types.Code.CALLBACK_FAILED)
		var empty: Array[Driver.LocalInput] = []
		codes.append(target.step(9, empty).code)
		codes.append(target.configure(null, null))
		codes.append(target.set_input_delay(0, 1).code)
		return true

	func save_state(frame: int, writer: RefCounted) -> Driver.SaveResult:
		if _stop(Types.Kind.SAVE, writer):
			trace.append("stop_save:%d" % frame)
			return Driver.SaveResult.new(true, _checksum_bytes())
		return super.save_state(frame, writer)

	func load_state(frame: int, reader: RefCounted) -> bool:
		if _stop(Types.Kind.LOAD, reader):
			trace.append("stop_load:%d" % frame)
			return true
		return super.load_state(frame, reader)

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		if _stop(Types.Kind.ADVANCE, inputs):
			trace.append("stop_advance:%d" % frame)
			return true
		return super.simulate_frame(frame, inputs)


func cases() -> PackedStringArray:
	return PackedStringArray(["client_stop", "callbacks", "completion_handler", "manual_configuration"])


func run_case(name: String, context: RefCounted) -> void:
	context.equal(Driver.new().has_method("terminate"), true, "driver-only clients can stop their session")
	if Driver.new().has_method("terminate"):
		call("_" + name, context)
	context.finish()


func _client_stop(context: RefCounted) -> void:
	var empty: RefCounted = Driver.new()
	empty.terminate()
	context.equal(empty.status().reason, Types.Code.OK, "unconfigured cancellation is harmless")
	var game: RefCounted = Fixture.Game.new()
	var driver: RefCounted = Driver.new(Fixture.new()._session(), game)
	context.equal(driver.step(0, Fixture.new()._samples(0)).code, Types.Code.OK, "running control")
	var trace: PackedStringArray = game.trace.duplicate()
	driver.terminate(Types.Code.DESYNC)
	driver.terminate()
	context.equal(driver.status().lifecycle, Types.Lifecycle.TERMINATED, "client stops through its facade")
	context.equal(driver.status().reason, Types.Code.DESYNC, "repeated stop preserves the first reason")
	var stopped: RefCounted = driver.step(1, Fixture.new()._samples(1))
	context.equal(stopped.code, Types.Code.TERMINATED, "stopped session cannot advance")
	context.equal(stopped.reason, Types.Code.DESYNC, "step reports original cancellation cause")
	context.equal(stopped.frame_after, 1, "stop preserves the completed frontier")
	context.equal(game.trace, trace, "stop invokes no further game callbacks")
	context.equal(driver.recover(2).code, Types.Code.TERMINATED, "stop cannot recover the old session")
	context.equal(driver.configure(Fixture.new()._session(), Fixture.Game.new()), Types.Code.OK, "explicit fresh session restarts")
	context.equal(driver.step(0, Fixture.new()._samples(0)).code, Types.Code.OK, "fresh session plays")
	driver.terminate(Types.Code.OK)
	context.equal(driver.status().reason, Types.Code.TERMINATED, "OK cannot leave cancellation running")


func _callbacks(context: RefCounted) -> void:
	for kind: int in [Types.Kind.SAVE, Types.Kind.LOAD, Types.Kind.ADVANCE]:
		var game: StoppingGame = StoppingGame.new()
		var driver: RefCounted = Driver.new(Fixture.new()._session(), game)
		game.owner_ref = weakref(driver)
		var frame: int = 3 if kind == Types.Kind.LOAD else 0
		for setup: int in range(frame):
			context.equal(driver.step(setup, Fixture.new()._samples(setup)).code, Types.Code.OK, "normal callbacks before cancellation")
		game.stop_kind = kind
		var calls_before: int = game.trace.size()
		var stopped: RefCounted = driver.step(frame, Fixture.new()._samples(frame))
		context.equal(stopped.code, Types.Code.TERMINATED, "callback cancellation aborts the batch")
		context.equal(stopped.reason, Types.Code.DESYNC, "callback cancellation retains first cause")
		context.equal(stopped.frame_after, frame, "aborted batch does not publish its frontier")
		context.equal(game.trace.size() - calls_before, 2 if kind == Types.Kind.ADVANCE else 1, "no later callback after cancellation")
		context.equal(game.codes, PackedInt32Array([Types.Code.BUSY, Types.Code.BUSY, Types.Code.BUSY]), "cancellation does not reopen reentry guards")
		if kind == Types.Kind.ADVANCE:
			context.equal(game.retained_view.size().code, Types.Code.EXPIRED_VIEW, "cancellation expires input view")
		else:
			context.equal(game.retained_view.status(), SnapshotStatus.Code.EXPIRED_VIEW, "cancellation expires snapshot view")
		context.equal(driver.configure(Fixture.new()._session(), Fixture.Game.new()), Types.Code.OK, "callback cancellation releases facade guard")
		context.equal(driver.step(0, Fixture.new()._samples(0)).code, Types.Code.OK, "replacement session plays after cancellation")


func _completion_handler(context: RefCounted) -> void:
	_shared_session_handlers(context)
	_expert_handler_mutations(context)
	_shared_driver_configuration(context)
	_notification_checksums(context)
	var driver: RefCounted = Driver.new(Fixture.new()._session(), Fixture.Game.new())
	var owner: WeakRef = weakref(driver)
	var notices: Array[int] = []
	var codes: Array[int] = []
	driver.step_completed.connect(
		func(code: int, _before: int, _after: int) -> void:
			notices.append(code)
			var target: RefCounted = owner.get_ref()
			target.terminate()
			codes.append(target.set_input_delay(0, 1).code)
	)
	var completed: RefCounted = driver.step(0, Fixture.new()._samples(0))
	context.equal(completed.code, Types.Code.OK, "cancellation after completion keeps successful step outcome")
	context.equal(completed.frame_after, 1, "completed step remains committed")
	context.equal(notices, [Types.Code.OK], "notification describes the completed operation")
	context.equal(codes, [Types.Code.BUSY], "cancellation does not allow scheduling inside handlers")
	context.equal(driver.status().lifecycle, Types.Lifecycle.TERMINATED, "handler can stop future steps")
	context.equal(completed.reason, Types.Code.TERMINATED, "returned terminal metadata reflects handler cancellation")
	context.equal(completed.failure_frame, driver.status().failure_frame, "returned terminal frame matches current status")


# Value: protects=all completion handlers see one completed frame; fails_when=another facade bypasses notification guard; why_new=same-driver reentry is already guarded; seam=none
func _shared_session_handlers(context: RefCounted) -> void:
	for attempt: String in ["second_driver", "expert_configure", "terminate_configure"]:
		var session: RefCounted = Fixture.new()._session()
		var game: RefCounted = Fixture.Game.new()
		var driver: RefCounted = Driver.new(session, game)
		var alternate: RefCounted = Driver.new(session, game)
		var alternate_ref: WeakRef = weakref(alternate)
		var codes: Array[int] = []
		var frames: Array[int] = []
		driver.step_completed.connect(
			func(_code: int, _before: int, after: int) -> void:
				if attempt == "second_driver":
					codes.append(alternate_ref.get_ref().step(1, Fixture.new()._samples(1)).code)
				else:
					if attempt == "terminate_configure":
						session.terminate(Types.Code.DESYNC)
					var config: RefCounted = Config.new()
					config.max_snapshot_bytes = 8
					config.storage_budget_bytes = config.required_storage_bytes()
					codes.append(session.configure(config))
				frames.append(after)
		)
		driver.step_completed.connect(func(_code: int, _before: int, _after: int) -> void: frames.append(session.status().current_frame))
		var completed: RefCounted = driver.step(0, Fixture.new()._samples(0))
		context.equal(codes, [Types.Code.BUSY], "shared session rejects completion-handler mutation: " + attempt)
		context.equal(frames, [1, 1], "later handler sees the same committed game frame: " + attempt)
		context.equal(completed.frame_after, 1, "outer result describes stable committed frame")
		if attempt == "terminate_configure":
			context.equal(completed.reason, Types.Code.DESYNC, "termination stays available and cannot be reconfigured away")
		else:
			context.equal(alternate.step(1, Fixture.new()._samples(1)).code, Types.Code.OK, "shared notification guard releases after handlers")


func _expert_handler_mutations(context: RefCounted) -> void:
	var session: RefCounted = Fixture.new()._session()
	var driver: RefCounted = Driver.new(session, Fixture.Game.new())
	driver.step_completed.connect(
		func(_code: int, _before: int, after: int) -> void:
			context.equal(session.status().current_frame, after, "status stays available during notification")
			context.equal(session.statistics().advanced_frames, after, "counters stay available during notification")
			context.equal(session.confirmed_inputs(after - 1) != null, true, "completed input export stays available during notification")
			for stopped: bool in [false, true]:
				if stopped:
					session.terminate(Types.Code.DESYNC)
				var codes: Array[int] = [
					session.poll(1).code,
					session.submit_local_input(0, 1, PackedByteArray([1])).code,
					session.receive_input(1, 1, PackedByteArray([1])).code,
					session.begin_advance().code,
					session.begin_recovery().code,
					session.complete_request(1, 0, true).code,
					session.set_input_delay(0, 1).code,
					session.set_confirmation_limit(0).code,
					session.freeze_player(1, 0),
					session.freeze_player_with_value(1, 0, PackedByteArray([1])),
				]
				for code: int in codes:
					context.equal(code, Types.Code.BUSY, "expert mutation remains guarded through notification and cancellation")
	)
	var completed: RefCounted = driver.step(0, Fixture.new()._samples(0))
	context.equal(completed.reason, Types.Code.DESYNC, "expert cancellation keeps first terminal cause")
	context.equal(session.poll(1).code, Types.Code.TERMINATED, "notification guard releases after cancellation")


func _shared_driver_configuration(context: RefCounted) -> void:
	for source_is_shared: bool in [false, true]:
		var session: RefCounted = Fixture.new()._session()
		var game: RefCounted = Fixture.Game.new()
		var driver: RefCounted = Driver.new(session, game)
		var independent: RefCounted = Fixture.new()._session()
		var alternate: RefCounted = Driver.new(session if source_is_shared else independent, game)
		var alternate_ref: WeakRef = weakref(alternate)
		var target: RefCounted = independent if source_is_shared else session
		var codes: Array[int] = []
		driver.step_completed.connect(
			func(_code: int, _before: int, _after: int) -> void:
				codes.append(alternate_ref.get_ref().configure(target, game))
				if not source_is_shared:
					var unattached: RefCounted = Driver.new()
					context.equal(unattached.configure(session, game), Types.Code.BUSY, "new facade cannot attach during notification")
		)
		context.equal(driver.step(0, Fixture.new()._samples(0)).code, Types.Code.OK, "configuration guard control advances")
		context.equal(codes, [Types.Code.BUSY], "source and target session notification guards protect facade configuration")
		context.equal(alternate.status().current_frame, 1 if source_is_shared else 0, "rejected configuration preserves original facade")
		context.equal(alternate.configure(target, game), Types.Code.OK, "configuration allowed after notification")


func _notification_checksums(context: RefCounted) -> void:
	var session: RefCounted = Fixture.new()._session()
	var driver: RefCounted = Driver.new(session, Fixture.Game.new())
	var published: Array[Dictionary] = []
	driver.step_completed.connect(func(_code: int, _before: int, _after: int) -> void: published.assign(session.confirmed_checksums(true)))
	context.equal(driver.step(0, Fixture.new()._samples(0)).code, Types.Code.OK, "checksum notification control advances")
	context.equal(published.size(), 1, "completed checksum remains readable during notification")
	context.equal(published, session.confirmed_checksums(true), "notification checksum export equals post-notification export")
	for sample: Driver.LocalInput in Fixture.new()._samples(1):
		context.equal(session.submit_local_input(sample.player, sample.sample_frame, sample.bytes).code, Types.Code.OK, "expert batch control stages input")
	context.equal(session.begin_advance().code, Types.Code.READY, "expert checksum protection control opens batch")
	context.equal(session.confirmed_checksums(true).size(), 0, "active expert batch still withholds checksum exports")
	session.terminate()
	context.equal(session.confirmed_checksums(true).size(), 0, "terminal checksum protection remains")


# Value: protects=expert callback ownership; fails_when=configure replaces callbacks after SAVE;
# why_new=notification tests do not retain manual batches; seam=none
func _manual_configuration(context: RefCounted) -> void:
	for attempt: String in ["same", "source", "target", "unattached"]:
		var session: RefCounted = Fixture.new()._session()
		var original: RefCounted = Fixture.Game.new()
		var independent: RefCounted = Fixture.new()._session()
		var driver: RefCounted = Driver.new()
		if attempt != "unattached":
			context.equal(driver.configure(independent if attempt == "target" else session, original), Types.Code.OK, "initial callback ownership: " + attempt)
		for sample: Driver.LocalInput in Fixture.new()._samples(0):
			context.equal(session.submit_local_input(sample.player, sample.sample_frame, sample.bytes).code, Types.Code.OK, "expert stages original input")
		var opened: RefCounted = session.begin_advance()
		context.equal(opened.code, Types.Code.READY, "expert opens ordered batch")
		var save: RefCounted = opened.batch.next_request()
		context.equal(save.kind, Types.Kind.SAVE, "partial batch begins with SAVE")
		var saved: Driver.SaveResult = original.save_state(save.frame, save.writer)
		context.equal(session.complete_request(save.batch_id, save.request_id, saved.ok, saved.checksum).code, Types.Code.OK, "expert completes original SAVE")
		var advance: RefCounted = opened.batch.next_request()
		context.equal(advance.kind, Types.Kind.ADVANCE, "expert retains pending simulation view")
		var target: RefCounted = independent if attempt == "source" else session
		context.equal(driver.configure(target, Fixture.Game.new()), Types.Code.BUSY, "open source or target batch rejects callback replacement: " + attempt)
		context.equal(advance.inputs.size().code, Types.Code.OK, "rejected replacement preserves active expert view")
		context.equal(original.simulate_frame(advance.frame, advance.inputs), true, "expert finishes original game")
		context.equal(session.complete_request(advance.batch_id, advance.request_id, true).code, Types.Code.OK, "expert finishes its own batch")
		context.equal(opened.batch.next_request(), null, "original batch drains")
		if attempt in ["same", "source"]:
			context.equal(driver.status().current_frame, 1, "rejected replacement preserves source session")
			context.equal(driver.step(1, Fixture.new()._samples(1)).code, Types.Code.OK, "original callbacks remain usable")
			var control_session: RefCounted = Fixture.new()._session()
			var control_game: RefCounted = Fixture.Game.new()
			for frame: int in range(2):
				context.equal(Fixture.new()._expert_step(control_session, control_game, frame), Types.Code.OK, "uninterrupted expert control")
			context.equal(original.value, control_game.value, "partial batch cannot silently replace canonical game state")
			context.equal(original.trace, control_game.trace, "original callbacks retain ordered ownership")
		elif attempt == "unattached":
			context.equal(driver.step(1, Fixture.new()._samples(1)).code, Types.Code.NOT_CONFIGURED, "rejected attachment remains unconfigured")
		else:
			context.equal(driver.status().current_frame, 0, "rejected target keeps independent source")
		context.equal(driver.configure(session, original), Types.Code.OK, "completed manual batch permits explicit attachment")
