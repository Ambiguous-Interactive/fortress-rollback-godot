extends RefCounted

# Value: protects=driver-only cancellation and active view expiry; fails_when=stopping needs the expert session; why_new=termination fixtures retain session; seam=none
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const SnapshotStatus = preload("res://addons/fortress_rollback/core/snapshot_status.gd")
const Fixture = preload("res://tests/unit/test_driver.gd")


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
	return PackedStringArray(["client_stop", "callbacks", "completion_handler"])


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
	var driver: RefCounted = Driver.new(Fixture.new()._session(), Fixture.Game.new())
	var owner: WeakRef = weakref(driver)
	var notices: Array[int] = []
	var codes: Array[int] = []
	driver.step_completed.connect(func(code: int, _before: int, _after: int) -> void:
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
