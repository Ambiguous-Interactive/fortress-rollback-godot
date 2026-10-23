extends RefCounted

# Value: protects=external-input driver request parity; fails_when=corrections, stalled samples or callbacks differ;
# why_new=existing parity covers sync-test and recovery only; seam=none
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Game = preload("res://tests/oracle/p2p_game.gd")
const Reference = preload("res://tests/oracle/reference_game.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["immediate", "delayed_bursts"])


func run_case(name: String, context: RefCounted) -> void:
	_run(context, 0 if name == "immediate" else 2)
	context.finish()


func _config(delay: int) -> Config:
	var config: Config = Config.new()
	config.player_count = 3
	config.local_players = PackedInt32Array([0, 2])
	config.input_width = 4
	config.neutral_input = PackedByteArray([0, 0, 0, 0])
	config.sync_test = false
	config.check_distance = 0
	config.input_delay = delay
	config.max_prediction_frames = 3
	config.queue_capacity = 9
	config.history_slots = 4
	config.max_snapshot_bytes = 24
	config.replay_max_frames = 40
	config.storage_budget_bytes = config.required_storage_bytes()
	return config


func _sample(player: int, frame: int) -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray([0, 0, 0, 0])
	bytes.encode_u32(0, (frame * 7 + player * 11 + 3) % 97)
	return bytes


func _samples(frame: int) -> Array[Driver.LocalInput]:
	var samples: Array[Driver.LocalInput] = []
	for player: int in [0, 2]:
		samples.append(Driver.LocalInput.new(player, frame, _sample(player, frame)))
	return samples


func _manual(session: Session, game: RefCounted, now: int, samples: Array[Driver.LocalInput], advance: bool) -> int:
	var polled: int = session.poll(now).code
	if polled != Types.Code.OK:
		return polled
	if advance:
		for sample: Driver.LocalInput in samples:
			var submitted: int = session.submit_local_input(sample.player, sample.sample_frame, sample.bytes).code
			if submitted != Types.Code.OK:
				return submitted
	var opened: Types.Result = session.begin_advance() if advance else session.begin_recovery()
	if opened.code != Types.Code.READY:
		return opened.code
	var code: int = Types.Code.OK
	while true:
		var request: Types.Request = opened.batch.next_request()
		if request == null:
			return code
		var ok: bool = false
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
		if code != Types.Code.OK:
			return code
	return code


func _compare(context: RefCounted, manual: Session, driven: Session, manual_game: RefCounted, driven_game: RefCounted) -> void:
	context.equal(driven.status().current_frame, manual.status().current_frame, "same current boundary")
	context.equal(driven.status().confirmed_frame, manual.status().confirmed_frame, "same confirmation")
	context.equal(driven.status().pending_rollback_frame, manual.status().pending_rollback_frame, "same earliest correction")
	context.equal(driven.received_frames(), manual.received_frames(), "same receipt bank")
	context.equal(driven_game.requests, manual_game.requests, "same ordered callbacks, statuses and canonical bytes")
	context.bytes_equal(driven_game.game.bytes(), manual_game.game.bytes(), driven.status().current_frame, "same game state")
	context.bytes_equal(driven.replay().to_bytes(), manual.replay().to_bytes(), driven.status().current_frame, "same finalized recording")
	for player: int in [0, 2]:
		context.bytes_equal(driven.scheduled_local_input(player).bytes, manual.scheduled_local_input(player).bytes, player, "same retained sample")


func _run(context: RefCounted, delay: int) -> void:
	var manual: Session = Session.new()
	var driven: Session = Session.new()
	context.equal(manual.configure(_config(delay)), Types.Code.OK, "manual external-input engine")
	context.equal(driven.configure(_config(delay)), Types.Code.OK, "driven external-input engine")
	var manual_game: RefCounted = Game.new(3)
	var driven_game: RefCounted = Game.new(3)
	var driver: Driver = Driver.new(driven, driven_game)
	var next_remote: int = delay
	var stalled: int = 0
	var now: int = 0
	while driven.status().current_frame < 32 and now < 100:
		var frame: int = driven.status().current_frame
		if now % 6 == 5:
			while next_remote < frame + delay:
				for session: Session in [manual, driven]:
					context.equal(session.receive_input(1, next_remote, _sample(1, next_remote - delay)).code, Types.Code.OK, "late changing remote input")
				next_remote += 1
		var samples: Array[Driver.LocalInput] = _samples(frame)
		var expected: int = _manual(manual, manual_game, now, samples, true)
		var actual: Driver.StepResult = driver.step(now, samples)
		context.equal(actual.code, expected, "same advance or stall outcome")
		context.equal(actual.events, manual.drain_events(), "same advance or stall events")
		context.equal(actual.code in [Types.Code.OK, Types.Code.PREDICTION_STALL], true, "workload remains recoverable")
		if actual.code == Types.Code.PREDICTION_STALL:
			stalled += 1
		_compare(context, manual, driven, manual_game, driven_game)
		now += 1
	context.equal(driven.status().current_frame, 32, "workload reaches full length across queue wraps")
	context.equal(stalled > 0, true, "prediction window actually stalls")
	context.equal(driven.statistics().rollback_count > 0, true, "late changing inputs actually roll back")
	context.equal(driven.statistics().resimulated_frames, manual.statistics().resimulated_frames, "same correction work")
	while next_remote < 32:
		for session: Session in [manual, driven]:
			context.equal(session.receive_input(1, next_remote, _sample(1, next_remote - delay)).code, Types.Code.OK, "final remote tail")
		next_remote += 1
	var empty: Array[Driver.LocalInput] = []
	var expected_recovery: int = _manual(manual, manual_game, now, empty, false)
	var recovered: Driver.StepResult = driver.recover(now)
	context.equal(recovered.code, expected_recovery, "same final recovery")
	context.equal(recovered.events, manual.drain_events(), "same final recovery events")
	_compare(context, manual, driven, manual_game, driven_game)
	context.equal(driven.status().pending_rollback_frame, -1, "final correction complete")
	context.equal(driven.replay().frame_count(), 32, "final recording contains every confirmed row")
	var original: RefCounted = Reference.new(3, 2)
	for frame: int in range(32):
		var row: Array[Dictionary] = []
		for player: int in range(3):
			var bytes: PackedByteArray = PackedByteArray([0, 0, 0, 0]) if frame < delay else _sample(player, frame - delay)
			row.append({"player": player, "bytes": bytes.hex_encode(), "status": "confirmed"})
		context.equal(original.advance(row), "", "independent original-input simulation")
	context.bytes_equal(driven_game.game.bytes(), original.bytes(), 32, "corrected game equals uninterrupted original history")
