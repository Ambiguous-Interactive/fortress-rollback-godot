extends RefCounted

# Value: protects=callback result validation and lock release; fails_when=dynamic returns crash or coerce; why_new=typed fixtures only return valid types; seam=none
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const SnapshotStatus = preload("res://addons/fortress_rollback/core/snapshot_status.gd")
const Fixture = preload("res://tests/unit/test_driver.gd")
const PeerFixture = preload("res://tests/unit/test_peer_session.gd")
const PeerGame = preload("res://tests/oracle/p2p_game.gd")
const L = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")


class DynamicGame:
	extends RefCounted
	var game: RefCounted
	var fail_kind: int = -1
	# Variant deliberately models incorrectly typed application callback returns.
	var bad_result: Variant = null
	var terminate_session: RefCounted
	var callbacks: int = 0
	var retained_view: RefCounted

	func _result(kind: int, valid_result: Variant) -> Variant:
		callbacks += 1
		if kind != fail_kind:
			return valid_result
		if terminate_session != null:
			terminate_session.terminate()
		return bad_result

	func save_state(frame: int, writer: RefCounted) -> Variant:
		retained_view = writer
		return _result(Types.Kind.SAVE, game.save_state(frame, writer))

	func load_state(frame: int, reader: RefCounted) -> Variant:
		retained_view = reader
		return _result(Types.Kind.LOAD, game.load_state(frame, reader))

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> Variant:
		retained_view = inputs
		return _result(Types.Kind.ADVANCE, game.simulate_frame(frame, inputs))


func cases() -> PackedStringArray:
	return PackedStringArray(["valid", "malformed", "termination", "peer_failure"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"valid":
			_local(context, false, false)
		"malformed":
			_local(context, true, false)
		"termination":
			_local(context, true, true)
		"peer_failure":
			_peer_failure(context)
	context.finish()


func _local(context: RefCounted, malformed: bool, terminating: bool) -> void:
	var fixture: RefCounted = Fixture.new()
	# Null, coercible scalars and unrelated objects must all fail the same way.
	var invalid: Array = [null, 0, 1, true, false, "yes", [], {}, RefCounted.new()] if malformed else [null]
	for kind: int in [Types.Kind.SAVE, Types.Kind.LOAD, Types.Kind.ADVANCE]:
		for bad: Variant in invalid:
			if bad is bool and kind != Types.Kind.SAVE:
				continue
			var session: RefCounted = fixture._session()
			var game: DynamicGame = DynamicGame.new()
			game.game = Fixture.Game.new()
			var driver: Driver = Driver.new(session, game)
			var frame: int = 3 if kind == Types.Kind.LOAD else 0
			for setup: int in range(frame):
				context.equal(driver.step(setup, fixture._samples(setup)).code, Types.Code.OK, "valid callback control")
			game.bad_result = bad
			game.fail_kind = kind if malformed else -1
			game.terminate_session = session if terminating else null
			var notices: Array[int] = []
			var recursive: Array[RefCounted] = []
			var owner: WeakRef = weakref(driver)
			driver.step_completed.connect(
				func(code: int, _before: int, _after: int) -> void:
					notices.append(code)
					recursive.append(owner.get_ref().recover(frame))
			)
			var count_before: int = game.callbacks
			var result: Driver.StepResult = driver.step(frame, fixture._samples(frame))
			var expected: int = Types.Code.TERMINATED if terminating else (Types.Code.CALLBACK_FAILED if malformed else Types.Code.OK)
			context.equal(result.code, expected, "dynamic callback outcome")
			context.equal(result.get("failure_kind"), kind if malformed and not terminating else -1, "step identifies the failed callback")
			context.equal(notices, [expected], "one final notification")
			context.equal(recursive[0].code, Types.Code.BUSY, "completion handlers remain guarded")
			context.equal(recursive[0].get("failure_kind"), result.get("failure_kind"), "guarded result retains terminal callback identity")
			if malformed:
				context.equal(result.frame_after, frame, "failed frontier is unpublished")
				context.equal(game.callbacks - count_before, 2 if kind == Types.Kind.ADVANCE else 1, "later callbacks skipped")
				if kind == Types.Kind.ADVANCE:
					context.equal(game.retained_view.size().code, Types.Code.EXPIRED_VIEW, "failed input view expires")
				else:
					context.equal(game.retained_view.status(), SnapshotStatus.Code.EXPIRED_VIEW, "failed snapshot view expires")
				context.equal(session.status().lifecycle, Types.Lifecycle.TERMINATED, "session halts")
				if not terminating:
					context.equal(session.status().failure_kind, kind, "failure identifies malformed callback")
				var count: int = game.callbacks
				var retry: Driver.StepResult = driver.step(frame, fixture._samples(frame))
				context.equal(retry.code, Types.Code.TERMINATED, "failure cannot retry")
				context.equal(retry.get("failure_kind"), kind if not terminating else -1, "retry preserves the first callback failure")
				context.equal(driver.recover(frame).get("failure_kind"), kind if not terminating else -1, "recovery preserves the first callback failure")
				context.equal(game.callbacks, count, "no callbacks after failure")
				var replacement: Config = Config.new()
				replacement.max_snapshot_bytes = 8
				replacement.storage_budget_bytes = 65536
				context.equal(session.configure(replacement), Types.Code.OK, "callback guard released")
				context.equal(driver.configure(fixture._session(), Fixture.Game.new()), Types.Code.OK, "driver guard released")


# Value: protects=downloaded callback identity; fails_when=diagnostics drop failure_kind;
# why_new=step metadata is transient and does not validate saved reports; seam=encoded two-peer traffic
func _peer_failure(context: RefCounted) -> void:
	for kind: int in [Types.Kind.SAVE, Types.Kind.LOAD, Types.Kind.ADVANCE]:
		_peer_callback_failure(context, kind)


func _peer_callback_failure(context: RefCounted, kind: int) -> void:
	var fixture: RefCounted = PeerFixture.new()
	var game: DynamicGame = DynamicGame.new()
	game.game = PeerGame.new(2)
	var controls: L.Options = L.Options.new()
	var mesh: Dictionary = fixture._build(context, 2, 0, false, 128, true, false, 8, controls, 60, 0, game)
	context.equal(mesh.peers[0].diagnostics().get("failure_kind"), -1, "healthy report has no failed callback")
	if kind == Types.Kind.LOAD:
		mesh.now = 1
		for index: int in range(2):
			context.equal(mesh.peers[index].step(1, fixture._inputs(mesh, index)).code, Types.Code.OK, "initial peer frame predicts missing remote input")
		fixture._deliver(context, mesh, fixture._drain(mesh))
		fixture._deliver(context, mesh, fixture._drain(mesh))
		context.equal(mesh.peers[0].status().pending_rollback_frame, 0, "late real remote input opens correction")
	game.fail_kind = kind
	game.bad_result = 1
	var notices: Array[int] = []
	mesh.peers[0].step_completed.connect(func(code: int, _before: int, _after: int) -> void: notices.append(code))
	var before: int = mesh.peers[0].status().current_frame
	var result: Driver.StepResult = mesh.peers[0].recover(2) if kind == Types.Kind.LOAD else mesh.peers[0].step(2, fixture._inputs(mesh, 0))
	context.equal(result.code, Types.Code.CALLBACK_FAILED, "peer reports malformed callback")
	context.equal(result.get("failure_kind"), kind, "peer identifies the failed callback")
	context.equal(result.frame_after, before, "peer does not publish failed advance")
	context.equal(mesh.peers[0].network_status().state, "terminated", "peer halts")
	context.equal(notices, [Types.Code.CALLBACK_FAILED], "peer emits final failure")
	context.equal(mesh.peers[0].recover(3).get("failure_kind"), kind, "peer recovery retains callback identity")
	var report: Dictionary = mesh.peers[0].diagnostics()
	context.equal(report.get("failure_kind"), kind, "downloaded diagnostic identifies failed callback")
	context.equal(report.reason, Types.Code.CALLBACK_FAILED, "downloaded diagnostic preserves terminal cause")
	context.equal(report.failure_frame, 0, "downloaded diagnostic identifies actual failed request frame")
	report["failure_kind"] = -1
	mesh.peers[0].drain_events()
	context.equal(mesh.peers[0].diagnostics().get("failure_kind"), kind, "owned report and event drains preserve first callback failure")
	if kind == Types.Kind.ADVANCE:
		context.equal(game.retained_view.size().code, Types.Code.EXPIRED_VIEW, "callback input expires")
	else:
		context.equal(game.retained_view.status(), SnapshotStatus.Code.EXPIRED_VIEW, "callback snapshot view expires")
	for packet: Dictionary in fixture._drain(mesh):
		var delivered: int = mesh.peers[packet.to].receive(packet.bytes, fixture._id(packet.from), 2)
		context.equal(delivered in [I.Code.OK, I.Code.TERMINATED], true, "terminal exchange remains bounded")
	context.equal(mesh.peers[1].network_status().state, "terminated", "goodbye stops remote match")
	context.equal(mesh.peers[0].poll(3), I.Code.TERMINATED, "callback failure remains terminal")
