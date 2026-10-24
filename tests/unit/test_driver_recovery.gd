extends RefCounted

# Value: protects=final confirmed history without an extra sample; fails_when=recovery advances or loses staged inputs; why_new=step requires local input; seam=none
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Fixture = preload("res://tests/unit/test_driver.gd")
const SpectatorFixture = preload("res://tests/unit/test_spectator_session.gd")
const Publisher = preload("res://addons/fortress_rollback/core/spectator_publisher.gd")
const Stream = preload("res://addons/fortress_rollback/core/spectator_stream.gd")


class ReentrantGame:
	extends Fixture.Game
	var owner_ref: WeakRef
	var session_ref: WeakRef
	var codes: PackedInt32Array = PackedInt32Array()

	func _reenter() -> void:
		if owner_ref != null:
			codes.append(owner_ref.get_ref().recover(3).code)
			codes.append(session_ref.get_ref().begin_recovery().code)


class HistoryGame:
	extends Fixture.Game
	var owner_ref: WeakRef
	var callback_rows: Array[RefCounted] = []
	var callback_replay_frames: PackedInt64Array = PackedInt64Array()

	func _reenter() -> void:
		if owner_ref != null:
			callback_rows.append(owner_ref.get_ref().confirmed_inputs(0))
			callback_replay_frames.append(owner_ref.get_ref().replay().frame_count())




func _key() -> PackedByteArray:
	var key: PackedByteArray = PackedByteArray()
	key.resize(32)
	for value: int in range(32):
		key[value] = value + 1
	return key


func _digest(config: Variant = null) -> PackedByteArray:
	var agreed: Variant = config if config != null else SpectatorFixture.new()._config()
	return Stream.configuration_digest(agreed, "seed-1", "rules-1")

func cases() -> PackedStringArray:
	return PackedStringArray(["final_history", "staged_sample", "failures", "guards", "expert_parity", "matching_tail", "boundary_checksum", "client_history"])


func run_case(name: String, context: RefCounted) -> void:
	var available: bool = Driver.new().has_method("recover") and Session.new().has_method("begin_recovery")
	context.equal(available, true, "shared recovery API exists")
	if available:
		call("_" + name, context)
	context.finish()


func _session(context: RefCounted) -> RefCounted:
	var config: RefCounted = Config.new()
	config.sync_test = false
	config.local_players = PackedInt32Array([0])
	config.check_distance = 0
	config.max_prediction_frames = 4
	config.history_slots = 5
	config.queue_capacity = 9
	config.max_snapshot_bytes = 8
	config.replay_max_frames = 20
	config.storage_budget_bytes = config.required_storage_bytes()
	var session: RefCounted = Session.new()
	context.equal(session.configure(config), Types.Code.OK, "recording host configured")
	return session


func _predict(context: RefCounted, session: RefCounted, game: RefCounted) -> RefCounted:
	var driver: RefCounted = Driver.new(session, game)
	for frame: int in range(3):
		var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, frame, PackedByteArray([frame + 2]))]
		context.equal(driver.step(frame, samples).code, Types.Code.OK, "predict final host frames")
	for frame: int in range(3):
		context.equal(session.receive_input(1, frame, PackedByteArray([frame + 5])).code, Types.Code.OK, "final actual inputs arrive")
	context.equal(session.status().pending_rollback_frame, 0, "final history requires correction")
	return driver


func _final_history(context: RefCounted) -> void:
	var session: RefCounted = _session(context)
	var game: RefCounted = Fixture.Game.new()
	var driver: RefCounted = _predict(context, session, game)
	context.equal(session.replay().frame_count(), 0, "unrepaired tail is not recorded")
	game.trace.clear()
	var recovered: RefCounted = driver.recover(3)
	context.equal(recovered.code, Types.Code.OK, "recover without a new local sample")
	context.equal(recovered.frame_before, 3, "before frame retained")
	context.equal(recovered.frame_after, 3, "recovery simulates no new frame")
	context.equal(game.trace, PackedStringArray(["load:0", "advance:0", "save:1", "advance:1", "save:2", "advance:2", "save:3"]), "ordinary ordered rollback callbacks")
	context.equal(session.status().pending_rollback_frame, -1, "tail corrected")
	context.equal(session.scheduled_local_input(0).code, Types.Code.MISSING_LOCAL_INPUT, "no fabricated sample")
	context.equal(session.replay().frame_count(), 3, "exact final replay length")
	var playback: RefCounted = Fixture.Game.new()
	var player: RefCounted = Player.new()
	context.equal(player.configure(session.replay(), playback, 8), Types.Code.OK, "recorded final tail playable")
	for frame: int in range(3):
		context.equal(player.step(), Types.Code.OK, "replay checksum and original input")
	context.equal(playback.value, game.value, "replay matches corrected host state")
	var expected: int = 0
	for frame: int in range(3):
		expected = (expected * 3 + frame + 2 + frame) * 3 + frame + 5 + frame
	context.equal(game.value, expected, "independent original-input history")
	var trace: PackedStringArray = game.trace.duplicate()
	context.equal(driver.recover(4).code, Types.Code.OK, "repeated recovery is idle")
	context.equal(game.trace, trace, "idle recovery invokes no callbacks")
	context.equal(driver.recover(2).code, Types.Code.INVALID_TIME, "recovery keeps monotonic clock")
	var identity: PackedByteArray = PackedByteArray()
	identity.resize(32)
	var publisher: RefCounted = Publisher.new()
	context.equal(publisher.configure(session, identity, _key(), _digest(), 128), Types.Code.OK, "final history can publish")
	context.equal(publisher.finish_host(), Types.Code.OK, "clean end needs no extra host frame")
	var stream: RefCounted = Stream.new()
	context.equal(stream.configure(SpectatorFixture.new()._config(), identity, _key(), _digest(), 0, 100, 128), Types.Code.OK, "viewer configured")
	var offer: PackedByteArray = publisher.encode_offer()
	context.equal(stream.receive_packet(offer, 0), Types.Code.OK, "viewer accepts the startup offer")
	context.equal(publisher.receive_accept(stream.encode_accept()), Types.Code.OK, "host accepts the startup answer")
	for frame: int in range(4):
		var packet: RefCounted = publisher.prepare_packet()
		context.equal(packet.code, Types.Code.OK, "final packet ready")
		context.equal(stream.receive_packet(packet.bytes, frame), Types.Code.OK, "confirmed tail delivered")
		context.equal(publisher.acknowledge_packet(packet.bytes), Types.Code.OK, "tail accepted")
	var viewing: RefCounted = Fixture.Game.new()
	var viewer_driver: RefCounted = Driver.new(stream.playback_session(), viewing)
	var empty: Array[Driver.LocalInput] = []
	for frame: int in range(3):
		context.equal(viewer_driver.step(frame, empty).code, Types.Code.OK, "viewer plays final history")
	context.equal(viewer_driver.step(3, empty).code, Types.Code.TERMINATED, "viewer ends at exact host frame")
	context.equal(viewing.value, expected, "viewer matches independent corrected history")


func _staged_sample(context: RefCounted) -> void:
	var session: RefCounted = _session(context)
	var game: RefCounted = Fixture.Game.new()
	var driver: RefCounted = _predict(context, session, game)
	context.equal(session.submit_local_input(0, 3, PackedByteArray([9])).code, Types.Code.OK, "expert stages next sample")
	context.equal(driver.recover(3).code, Types.Code.OK, "repair with a staged sample")
	context.equal(session.scheduled_local_input(0).bytes, PackedByteArray([9]), "repair preserves staged buttons")
	context.equal(session.receive_input(1, 3, PackedByteArray([8])).code, Types.Code.OK, "next remote input")
	var empty: Array[Driver.LocalInput] = []
	context.equal(driver.step(4, empty).code, Types.Code.OK, "ordinary advance consumes retained sample")
	context.equal(session.status().current_frame, 4, "only ordinary step advances")
	context.equal(session.scheduled_local_input(0).code, Types.Code.MISSING_LOCAL_INPUT, "ordinary advance clears sample")


func _failures(context: RefCounted) -> void:
	for kind: int in [Types.Kind.LOAD, Types.Kind.SAVE, Types.Kind.ADVANCE]:
		var session: RefCounted = _session(context)
		var game: RefCounted = Fixture.Game.new()
		var driver: RefCounted = _predict(context, session, game)
		game.fail_kind = kind
		var failed: RefCounted = driver.recover(3)
		context.equal(failed.code, Types.Code.CALLBACK_FAILED, "recovery callback failure stops")
		context.equal(failed.get("failure_kind"), kind, "recovery identifies the failed ordered callback")
		context.equal(session.status().lifecycle, Types.Lifecycle.TERMINATED, "failed recovery is terminal")
		context.equal(driver.recover(4).code, Types.Code.TERMINATED, "failed recovery cannot resume")
		context.equal(session.replay().frame_count(), 0, "failed repair publishes no recording")
	context.equal(Driver.new().recover(0).code, Types.Code.NOT_CONFIGURED, "unconfigured recovery")


func _guards(context: RefCounted) -> void:
	var session: RefCounted = _session(context)
	var game: ReentrantGame = ReentrantGame.new()
	var driver: RefCounted = _predict(context, session, game)
	game.owner_ref = weakref(driver)
	game.session_ref = weakref(session)
	context.equal(driver.recover(3).code, Types.Code.OK, "guarded recovery completes")
	context.equal(game.codes.size(), 14, "every repair callback attempted reentry")
	for code: int in game.codes:
		context.equal(code, Types.Code.BUSY, "session and driver recovery refuse callback reentry")
	context.equal(session.statistics().prediction_stalls, 0, "explicit recovery is not a prediction stall")
	context.equal(session.statistics().advanced_frames, 3, "recovery adds no ordinary advances")
	context.equal(session.statistics().resimulated_frames, 3, "recovery counts its actual corrected frames")
	for mode: String in ["sync", "spectator"]:
		var unsupported: RefCounted = Session.new()
		var config: RefCounted = Config.new() if mode == "sync" else SpectatorFixture.new()._config()
		config.max_snapshot_bytes = 8
		config.storage_budget_bytes = config.required_storage_bytes()
		context.equal(unsupported.configure(config), Types.Code.OK, "unsupported mode control configured")
		context.equal(Driver.new(unsupported, Fixture.Game.new()).recover(0).code, Types.Code.UNSUPPORTED, "recovery cannot bypass specialized session semantics")
		unsupported._current = 2147483647
		context.equal(Driver.new(unsupported, Fixture.Game.new()).recover(0).code, unsupported.begin_recovery().code, "rejected recovery keeps expert eligibility priority")
		context.equal(unsupported.status().lifecycle, Types.Lifecycle.RUNNING, "unsupported recovery does not terminate the specialized session")
	for frame_limit: bool in [true, false]:
		var exhausted: RefCounted = _session(context)
		if frame_limit:
			exhausted._current = 2147483647
		else:
			exhausted._batch_id = 9223372036854775807
		context.equal(Driver.new(exhausted, Fixture.Game.new()).recover(0).code, Types.Code.FRAME_EXHAUSTED, "recovery preserves shared terminal limits")


func _expert_parity(context: RefCounted) -> void:
	var manual: RefCounted = _session(context)
	var driven: RefCounted = _session(context)
	var manual_game: RefCounted = Fixture.Game.new()
	var driver_game: RefCounted = Fixture.Game.new()
	_predict(context, manual, manual_game)
	var driver: RefCounted = _predict(context, driven, driver_game)
	manual_game.trace.clear()
	driver_game.trace.clear()
	var advance: RefCounted = manual.begin_recovery()
	context.equal(advance.code, Types.Code.READY, "expert recovery opens shared batch")
	context.equal(driver.recover(3).code, Types.Code.OK, "driver recovery")
	context.equal(Driver.new(manual, Fixture.Game.new()).recover(3).code, Types.Code.BUSY, "external batch remains caller-owned")
	while true:
		var request: RefCounted = advance.batch.next_request()
		if request == null:
			break
		var ok: bool = true
		var checksum: PackedByteArray = PackedByteArray()
		if request.kind == Types.Kind.SAVE:
			var saved: RefCounted = manual_game.save_state(request.frame, request.writer)
			ok = saved.ok
			checksum = saved.checksum
		elif request.kind == Types.Kind.LOAD:
			ok = manual_game.load_state(request.frame, request.reader)
		else:
			ok = manual_game.simulate_frame(request.frame, request.inputs)
		context.equal(manual.complete_request(request.batch_id, request.request_id, ok, checksum).code, Types.Code.OK, "expert callback acknowledged")
	context.equal(manual_game.trace, driver_game.trace, "identical expert/driver request sequence")
	context.equal(manual_game.value, driver_game.value, "identical expert/driver final state")
	context.equal(manual.replay().to_bytes(), driven.replay().to_bytes(), "identical finalized recording")


func _matching_tail(context: RefCounted) -> void:
	var session: RefCounted = _session(context)
	var game: RefCounted = Fixture.Game.new()
	var driver: RefCounted = Driver.new(session, game)
	var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, 0, PackedByteArray([2]))]
	context.equal(driver.step(0, samples).code, Types.Code.OK, "predict neutral remote")
	context.equal(session.receive_input(1, 0, PackedByteArray([0])).code, Types.Code.OK, "matching late actual")
	context.equal(session.status().pending_rollback_frame, -1, "matching input needs no repair")
	game.trace.clear()
	context.equal(driver.recover(1).code, Types.Code.OK, "finalize matching late input")
	context.equal(game.trace.is_empty(), true, "matching tail invokes no callback")
	context.equal(session.replay().frame_count(), 1, "matching late tail is recorded without an extra step")


func _boundary_checksum(context: RefCounted) -> void:
	var session: RefCounted = _session(context)
	context.equal(session.set_confirmation_limit(-1).code, Types.Code.OK, "mesh owns confirmation")
	var game: RefCounted = Fixture.Game.new()
	var driver: RefCounted = Driver.new(session, game)
	for frame: int in range(4):
		var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, frame, PackedByteArray([7]))]
		context.equal(driver.step(frame, samples).code, Types.Code.OK, "predict to window edge")
	var staged: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, 4, PackedByteArray([7]))]
	context.equal(driver.step(4, staged).code, Types.Code.PREDICTION_STALL, "mesh stall saves current boundary")
	var old_checksum: PackedByteArray = game._checksum_bytes()
	old_checksum.encode_s64(0, game.value)
	for frame: int in range(5):
		context.equal(session.receive_input(1, frame, PackedByteArray([8])).code, Types.Code.OK, "actual input includes current boundary")
	context.equal(session.set_confirmation_limit(4).code, Types.Code.OK, "remote evidence confirms boundary")
	context.equal(driver.recover(5).code, Types.Code.OK, "repair at saved mesh boundary")
	var found: bool = false
	for saved: Dictionary in session.confirmed_checksums(true):
		if saved.frame == 4:
			found = true
			context.equal(saved.checksum.decode_s64(0), game.value, "published boundary checksum reflects corrected state")
			context.equal(saved.checksum != old_checksum, true, "stale predicted boundary is replaced")
	context.equal(found, true, "corrected current boundary remains available")
	context.equal(session.status().current_frame, 4, "checksum capture adds no simulation tick")


# Value: protects=driver-only owned history; fails_when=expert access is required or provisional data leaks; why_new=existing exports call session; seam=none
func _client_history(context: RefCounted) -> void:
	var empty: RefCounted = Driver.new()
	var available: bool = empty.has_method("confirmed_inputs") and empty.has_method("replay")
	context.equal(available, true, "small client exposes confirmed history without expert session")
	if not available:
		return
	context.equal(empty.confirmed_inputs(0), null, "unconfigured driver has no confirmed row")
	context.equal(empty.replay(), null, "unconfigured driver has no recording")
	context.equal(Driver.new(Fixture.new()._session(), Fixture.Game.new()).replay(), null, "disabled recording stays disabled")
	var session: RefCounted = _session(context)
	var game: HistoryGame = HistoryGame.new()
	var driver: RefCounted = _predict(context, session, game)
	context.equal(driver.confirmed_inputs(-1), null, "negative frame is unavailable")
	context.equal(driver.confirmed_inputs(0), null, "uncorrected confirmed input is unavailable")
	context.equal(driver.replay().frame_count(), 0, "uncorrected recording stays private")
	game.owner_ref = weakref(driver)
	context.equal(driver.recover(3).code, Types.Code.OK, "driver finalizes corrected history")
	context.equal(game.callback_rows.size(), 7, "all ordered repair callbacks observed history")
	for row: RefCounted in game.callback_rows:
		context.equal(row, null, "active callback cannot expose input rows")
	for frames: int in game.callback_replay_frames:
		context.equal(frames, 0, "active repair hides provisional replay tail")
	game.owner_ref = null
	var retained: RefCounted = driver.confirmed_inputs(0)
	context.equal(retained.read(0).bytes, PackedByteArray([2]), "final local sample is visible")
	context.equal(retained.read(1).bytes, PackedByteArray([5]), "final corrected remote sample is visible")
	var bytes: PackedByteArray = retained.read(1).bytes
	bytes[0] = 99
	context.equal(driver.confirmed_inputs(0).read(1).bytes, PackedByteArray([5]), "input result mutation cannot rewrite history")
	context.equal(driver.confirmed_inputs(3), null, "unsimulated boundary is unavailable")
	var replay: RefCounted = driver.replay()
	context.equal(replay.frame_count(), 3, "driver exports exact confirmed replay")
	var original: PackedByteArray = replay.to_bytes()
	var shorter: RefCounted = replay.owned_prefix(1)
	context.equal(replay.decode(shorter.to_bytes()), 0, "caller can replace its recording copy")
	context.equal(driver.replay().to_bytes(), original, "replacing exported replay leaves recording untouched")
	context.equal(driver.recover(4).code, Types.Code.OK, "another driver call completes")
	context.equal(retained.read(1).bytes, PackedByteArray([5]), "owned row remains live after future calls")
	for frame: int in range(3, 13):
		context.equal(session.receive_input(1, frame, PackedByteArray([frame % 5 + 5])).code, Types.Code.OK, "later actual rows arrive")
		var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, frame, PackedByteArray([frame % 5 + 2]))]
		context.equal(driver.step(frame + 2, samples).code, Types.Code.OK, "later frames wrap bounded input history")
	context.equal(driver.confirmed_inputs(0), null, "released queue history is unavailable through driver")
	context.equal(retained.read(1).bytes, PackedByteArray([5]), "owned row survives physical history wrap")
