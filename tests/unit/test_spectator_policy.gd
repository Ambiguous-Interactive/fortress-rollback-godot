extends RefCounted

const Spectator = preload("res://addons/fortress_rollback/core/spectator_session.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Stream = preload("res://addons/fortress_rollback/core/spectator_stream.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Fixture = preload("res://tests/unit/test_spectator_session.gd")
const GameFixture = preload("res://tests/unit/test_driver.gd")


class DrainingGame:
	extends GameFixture.Game
	var viewer_ref: WeakRef
	var drain_counts: PackedInt32Array = PackedInt32Array()

	func _reenter() -> void:
		var viewer: RefCounted = viewer_ref.get_ref()
		drain_counts.append(viewer.drain_events().size())
		viewer.terminate(Types.Code.PROTOCOL_FAILED)
		drain_counts.append(viewer.drain_events().size())


func _key() -> PackedByteArray:
	var key: PackedByteArray = PackedByteArray()
	key.resize(32)
	for value: int in range(32):
		key[value] = value + 1
	return key


func _digest(config: Variant = null) -> PackedByteArray:
	var agreed: Variant = config if config != null else Fixture.new()._config()
	return Stream.configuration_digest(agreed, "seed-1", "rules-1")


func cases() -> PackedStringArray:
	return PackedStringArray(["confirmation_policy", "playback_events", "failure_events", "empty_end_and_reentry", "completion_status"])


func run_case(name: String, context: RefCounted) -> void:
	call("_" + name, context)
	context.finish()


# Value: protects=viewer exports host-confirmed rows; fails_when=player confirmation gates freeze viewer state; why_new=viewer tests skip mesh controls; seam=none
func _confirmation_policy(context: RefCounted) -> void:
	for use_player_control: bool in [false, true]:
		var viewer: Session = Spectator.new()
		context.equal(viewer.configure(Fixture.new()._config()), Types.Code.OK, "configure confirmed-only viewer")
		if use_player_control:
			context.equal(viewer.set_confirmation_limit(-1).code, Types.Code.UNSUPPORTED, "player confirmation policy unavailable before playback")
		var game: RefCounted = GameFixture.Game.new()
		var driver: RefCounted = Driver.new(viewer, game)
		var empty: Array[Driver.LocalInput] = []
		for frame: int in range(8):
			context.equal(viewer.receive_host_frame(frame, Fixture.new()._row(frame)).code, Types.Code.OK, "host confirms complete row")
			context.equal(driver.step(frame, empty).code, Types.Code.OK, "viewer plays host row")
			context.equal(viewer.status().confirmed_frame, frame, "viewer confirmation follows played host input")
			var exported: Types.FrameInputs = viewer.confirmed_inputs(frame)
			context.equal(exported != null, true, "played host input remains exportable")
			if exported != null:
				for player: int in range(2):
					context.equal(exported.read(player).bytes, Fixture.new()._row(frame)[player], "export preserves host bytes")
			if use_player_control:
				context.equal(viewer.set_confirmation_limit(frame).code, Types.Code.UNSUPPORTED, "player confirmation policy unavailable after playback")
		context.equal(viewer.host_frontier(), 7, "refused control preserves host frontier")
		context.equal(game.trace.size(), 8, "every host row simulated once")

	var config: RefCounted = Fixture.new()._config()
	config.spectator = false
	config.local_players = PackedInt32Array([0, 1])
	var player_session: Session = Session.new()
	context.equal(player_session.configure(config), Types.Code.OK, "ordinary player control configuration")
	context.equal(player_session.set_confirmation_limit(-1).code, Types.Code.OK, "player mesh may establish confirmation policy")
	for player: int in range(2):
		context.equal(player_session.submit_local_input(player, 0, Fixture.new()._row(0)[player]).code, Types.Code.OK, "player input receipt")
	context.equal(player_session.status().confirmed_frame, -1, "player policy waits for remote evidence")
	context.equal(player_session.set_confirmation_limit(0).code, Types.Code.OK, "player mesh may advance confirmation")
	context.equal(player_session.status().confirmed_frame, 0, "ordinary player confirmation remains controllable")


# Value: protects=bounded startup and clean ending; fails_when=lifecycle events vanish or duplicate; why_new=playback checks expose status only; seam=none
func _playback_events(context: RefCounted) -> void:
	var viewer: RefCounted = Spectator.new()
	context.equal(viewer.drain_events().size(), 0, "unconfigured viewer has no lifecycle")
	context.equal(viewer.configure(Fixture.new()._config()), Types.Code.OK, "start viewer")
	var events: Array[RefCounted] = viewer.drain_events()
	context.equal(events.size(), 1, "startup is observable")
	if events.size() != 1:
		return
	context.equal(events[0].kind, Spectator.EventKind.WAITING_FOR_HOST, "startup waits for complete host history")
	context.equal(events[0].frame, 0, "startup boundary")
	context.equal(viewer.receive_host_frame(1, Fixture.new()._row(1)).code, Types.Code.OK, "future row waits behind gap")
	context.equal(viewer.drain_events().size(), 0, "future row does not claim synchronization")
	context.equal(viewer.receive_host_frame(0, Fixture.new()._row(0)).code, Types.Code.OK, "first contiguous host row")
	context.equal(viewer.receive_host_frame(0, Fixture.new()._row(0)).code, Types.Code.OK, "duplicate row")
	context.equal(viewer.set_playback(2, 1, 3), Types.Code.OK, "delay still holds received rows")
	context.equal(viewer.finish_host(), Types.Code.OK, "clean host closure")
	context.equal(viewer.finish_host(), Types.Code.OK, "repeated closure is idempotent")
	var driver: RefCounted = Driver.new(viewer, GameFixture.Game.new())
	var empty: Array[Driver.LocalInput] = []
	events = viewer.drain_events()
	context.equal(events.size(), 2, "paused tail publishes synchronization and closure without completion")
	context.equal(viewer.status().lifecycle, Types.Lifecycle.RUNNING, "paused tail remains playable")
	for frame: int in range(2):
		var step: Driver.StepResult = driver.step(frame, empty)
		context.equal(step.code, Types.Code.OK, "drain complete clean tail")
		events.append_array(step.events)
	var end: Driver.StepResult = driver.step(2, empty)
	context.equal(end.code, Types.Code.TERMINATED, "clean playback completes")
	events.append_array(end.events)
	viewer.terminate(Types.Code.PROTOCOL_FAILED)
	events.append_array(viewer.drain_events())
	context.equal(events.size(), 3, "synchronization, closure and terminal occur once each")
	if events.size() == 3:
		context.equal(events[0].kind, Spectator.EventKind.SYNCHRONIZED, "complete prefix synchronizes playback")
		context.equal(events[1].kind, Spectator.EventKind.HOST_FINISHED, "input closure precedes tail playback completion")
		context.equal(events[2].kind, Spectator.EventKind.TERMINATED, "terminal completion after last frame")
		context.equal(events[2].reason, Types.Code.TERMINATED, "clean terminal reason remains owned")
		context.equal(events[2].frame, 2, "exclusive completed boundary")
		events[2].reason = Types.Code.PROTOCOL_FAILED
	context.equal(viewer.status().reason, Types.Code.TERMINATED, "caller-owned event cannot change lifecycle")
	context.equal(viewer.drain_events().size(), 0, "drain consumes events")
	context.equal(viewer.configure(Fixture.new()._config()), Types.Code.OK, "fresh viewer lifetime")
	var invalid: RefCounted = Fixture.new()._config()
	invalid.queue_capacity = 0
	context.equal(viewer.configure(invalid), Types.Code.INVALID_CONFIGURATION, "rejected replacement preserves event")
	context.equal(viewer.drain_events().size(), 1, "fresh startup survives rejected configuration")


# Value: protects=immediate loss notification; fails_when=expiry or callbacks omit terminal cause; why_new=stream tests inspect status only; seam=none
func _failure_events(context: RefCounted) -> void:
	var stream: RefCounted = Stream.new()
	var identity: PackedByteArray = PackedByteArray()
	identity.resize(32)
	context.equal(stream.configure(Fixture.new()._config(), identity, _key(), _digest(), 0, 100, 128), Types.Code.OK, "configure expiry fixture")
	var offer: PackedByteArray = Stream.encode_offer(identity, _digest(), 2, 1, _key())
	context.equal(stream.receive_packet(offer, 0), Types.Code.OK, "agree the envelope before the first row")
	var viewer: RefCounted = stream.playback_session()
	context.equal(stream.receive_packet(stream.encode_row(0, Fixture.new()._row(0)), 0), Types.Code.OK, "accepted buffered row")
	context.equal(stream.poll(100), Types.Code.PROTOCOL_FAILED, "host loss commits termination")
	context.equal(stream.poll(101), Types.Code.TERMINATED, "repeated expiry preserves terminal")
	var events: Array[RefCounted] = viewer.drain_events()
	context.equal(events.size(), 3, "startup, receipt and loss remain available")
	if events.size() == 3:
		context.equal(events[2].kind, Spectator.EventKind.TERMINATED, "loss is terminal notification")
		context.equal(events[2].reason, Types.Code.PROTOCOL_FAILED, "loss retains exact cause")
		context.equal(events[2].frame, 0, "buffered row did not simulate after loss")
	viewer = Spectator.new()
	viewer.configure(Fixture.new()._config())
	viewer.receive_host_frame(0, Fixture.new()._row(0))
	var batch: Types.Result = viewer.begin_advance()
	context.equal(viewer.drain_events().size(), 0, "active batch cannot consume lifecycle events")
	var request: Types.Request = batch.batch.next_request()
	context.equal(viewer.complete_request(request.batch_id, request.request_id, false).code, Types.Code.CALLBACK_FAILED, "application failure commits terminal")
	events = viewer.drain_events()
	context.equal(events.size(), 3, "callback failure does not lose earlier lifecycle")
	if events.size() == 3:
		context.equal(events[2].reason, Types.Code.CALLBACK_FAILED, "callback cause published immediately")
		context.equal(events[2].frame, 0, "failed request frame")


# Value: protects=empty end and guarded drains; fails_when=END completes early or callback steals events; why_new=expert failures skip driver guards; seam=none
func _empty_end_and_reentry(context: RefCounted) -> void:
	_notification_events(context)
	var viewer: RefCounted = Spectator.new()
	viewer.configure(Fixture.new()._config())
	viewer.finish_host()
	context.equal(viewer.status().lifecycle, Types.Lifecycle.RUNNING, "input closure leaves playback completion pending")
	var events: Array[RefCounted] = viewer.drain_events()
	context.equal(events.size(), 2, "empty host publishes startup and input closure")
	if events.size() == 2:
		context.equal(events[1].kind, Spectator.EventKind.HOST_FINISHED, "empty closure does not fabricate input synchronization")
	var driver: RefCounted = Driver.new(viewer, GameFixture.Game.new())
	var empty: Array[Driver.LocalInput] = []
	var end: Driver.StepResult = driver.step(0, empty)
	context.equal(end.code, Types.Code.TERMINATED, "empty viewer finishes through ordinary service")
	context.equal(end.events.size(), 1, "driver owns terminal notification")
	context.equal(viewer.drain_events().size(), 0, "event is not delivered twice")
	viewer = Spectator.new()
	viewer.configure(Fixture.new()._config())
	viewer.receive_host_frame(0, Fixture.new()._row(0))
	var game: DrainingGame = DrainingGame.new()
	game.viewer_ref = weakref(viewer)
	driver = Driver.new(viewer, game)
	var failed: Driver.StepResult = driver.step(0, empty)
	context.equal(failed.code, Types.Code.TERMINATED, "termination during callback stops driver")
	context.equal(game.drain_counts, PackedInt32Array([0, 0]), "callback cannot steal events before or after termination")
	context.equal(failed.events.size(), 3, "driver receives startup, synchronization and callback termination once")
	if failed.events.size() == 3:
		context.equal(failed.events[2].reason, Types.Code.PROTOCOL_FAILED, "committed cause wins over callback acknowledgement")
	context.equal(viewer.drain_events().size(), 0, "callback terminal drains once")


# Value: protects=terminal event ownership through completion handlers; fails_when=notification drains steal cancellation;
# why_new=callback drains run before completion notifications; seam=none
func _notification_events(context: RefCounted) -> void:
	for cancel: bool in [false, true]:
		var viewer: RefCounted = Spectator.new()
		context.equal(viewer.configure(Fixture.new()._config()), Types.Code.OK, "notification viewer configured")
		context.equal(viewer.receive_host_frame(0, Fixture.new()._row(0)).code, Types.Code.OK, "notification row available")
		var driver: RefCounted = Driver.new(viewer, GameFixture.Game.new())
		var drain_counts: Array[int] = []
		driver.step_completed.connect(
			func(_code: int, _before: int, _after: int) -> void:
				if cancel:
					viewer.terminate(Types.Code.PROTOCOL_FAILED)
				drain_counts.append(viewer.drain_events().size())
		)
		driver.step_completed.connect(func(_code: int, _before: int, _after: int) -> void: drain_counts.append(viewer.drain_events().size()))
		var empty: Array[Driver.LocalInput] = []
		var completed: Driver.StepResult = driver.step(0, empty)
		context.equal(completed.code, Types.Code.OK, "notification follows completed host row")
		context.equal(completed.events.size(), 2, "driver owns startup and synchronization")
		context.equal(drain_counts, [0, 0], "completion handlers cannot drain newly committed terminal events")
		var events: Array[RefCounted] = viewer.drain_events()
		context.equal(events.size(), 1 if cancel else 0, "terminal notification remains available after every handler")
		if events.size() == 1:
			context.equal(events[0].kind, Spectator.EventKind.TERMINATED, "cancellation publishes terminal event")
			context.equal(events[0].reason, Types.Code.PROTOCOL_FAILED, "cancellation cause remains exact")
			context.equal(events[0].frame, 1, "terminal event identifies completed boundary")
		context.equal(viewer.drain_events().size(), 0, "terminal event drains exactly once after notification")


# Value: protects=completion means fully serviced clean host ending; fails_when=generic cancellation claims completion;
# why_new=terminal reason alone cannot distinguish an unconsumed tail or canceled final boundary; seam=none
func _completion_status(context: RefCounted) -> void:
	for frames: int in [0, 3]:
		for mode: String in ["clean", "cancel", "tail", "boundary", "failure"]:
			var viewer: RefCounted = Spectator.new()
			context.equal(viewer.is_complete(), false, "unconfigured viewer is incomplete")
			context.equal(viewer.configure(Fixture.new()._config()), Types.Code.OK, "configure completion viewer")
			context.equal(viewer.is_complete(), false, "fresh viewer is incomplete")
			for frame: int in frames:
				context.equal(viewer.receive_host_frame(frame, Fixture.new()._row(frame)).code, Types.Code.OK, "retain complete host input")
			var driver: RefCounted = Driver.new(viewer, GameFixture.Game.new())
			var empty: Array[Driver.LocalInput] = []
			if mode != "cancel":
				context.equal(viewer.finish_host(), Types.Code.OK, "close host input")
			context.equal(viewer.is_complete(), false, "input closure alone never completes playback")
			if mode in ["clean", "boundary"]:
				for frame: int in frames:
					context.equal(driver.step(frame, empty).code, Types.Code.OK, "consume one clean tail row")
				context.equal(viewer.is_complete(), false, "last consumed row still awaits terminal call")
			if mode == "clean":
				context.equal(driver.step(frames, empty).code, Types.Code.TERMINATED, "ordinary service completes clean ending")
			else:
				viewer.terminate(Types.Code.PROTOCOL_FAILED if mode == "failure" else Types.Code.TERMINATED)
			context.equal(viewer.is_complete(), mode == "clean", "cancellation and failure never claim completion")
			context.equal(driver.step(frames + 1, empty).code, Types.Code.TERMINATED, "terminal service cannot revive viewer")
			context.equal(viewer.is_complete(), mode == "clean", "terminal retry preserves completion status")
			var invalid: RefCounted = Fixture.new()._config()
			invalid.queue_capacity = 0
			context.equal(viewer.configure(invalid), Types.Code.INVALID_CONFIGURATION, "reject invalid replacement")
			context.equal(viewer.is_complete(), mode == "clean", "rejected replacement preserves completion")
			context.equal(viewer.configure(Fixture.new()._config()), Types.Code.OK, "fresh playback replaces old lifetime")
			context.equal(viewer.is_complete(), false, "successful replacement clears completion")
