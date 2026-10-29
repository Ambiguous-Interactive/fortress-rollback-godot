extends RefCounted

# Value: protects=external-input driver request parity; fails_when=corrections, stalled samples or callbacks differ;
# why_new=existing parity covers sync-test and recovery only; seam=none
const Collector = preload("res://tests/runner/test_context.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Game = preload("res://tests/oracle/p2p_game.gd")
const Reference = preload("res://tests/oracle/reference_game.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["immediate", "delayed_bursts", "independent_delays", "independent_delay_control"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "independent_delay_control":
		var control: RefCounted = Collector.new(context.seed)
		_independent_delays(control, true)
		context.equal(control.failures.is_empty(), false, "omitted delay bridge is detected independently of paired parity")
		if not control.failures.is_empty():
			context.equal(control.failures[0].label, "independent per-slot corrected boundary", "bridge omission fails at canonical history")
			context.equal(control.failures[0].frame, 5, "first omitted bridge is localized after frame four")
	elif name == "independent_delays":
		_independent_delays(context)
	else:
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


# Value: protects=independent local delay changes during stalled repair; fails_when=bridges or staged omissions diverge;
# why_new=fixed-delay parity never mixes local delays or raises with retained samples; seam=none
func _independent_delays(context: RefCounted, omit_bridge: bool = false) -> void:
	var manual: Session = Session.new()
	var driven: Session = Session.new()
	context.equal(manual.configure(_config(0)), Types.Code.OK, "manual independent-delay configuration")
	context.equal(driven.configure(_config(0)), Types.Code.OK, "driven independent-delay configuration")
	var manual_game: RefCounted = Game.new(3)
	var driven_game: RefCounted = Game.new(3)
	var driver: Driver = Driver.new(driven, driven_game)
	var next_remote: int = 0
	var now: int = 0
	var raised: bool = false
	var omitted_samples: int = 0
	var stalls: int = 0
	while driven.status().current_frame < 32 and now < 100:
		var frame: int = driven.status().current_frame
		if now % 6 == 5:
			while next_remote < frame:
				for session: Session in [manual, driven]:
					context.equal(session.receive_input(1, next_remote, _sample(1, next_remote)).code, Types.Code.OK, "deliver independent-delay remote burst")
				next_remote += 1
		var samples: Array[Driver.LocalInput] = _samples(frame)
		if frame % 2 == 0:
			for session: Session in [manual, driven]:
				context.equal(session.submit_local_input(0, frame, _sample(0, frame)).code, Types.Code.OK, "expert stages omitted local slot")
			samples.remove_at(0)
			omitted_samples += 1
		var expected: int = _manual(manual, manual_game, now, samples, true)
		var actual: Driver.StepResult = driver.step(now, samples)
		context.equal(actual.code, expected, "independent delays preserve advance outcome")
		context.equal(actual.code in [Types.Code.OK, Types.Code.PREDICTION_STALL], true, "independent-delay workload stays recoverable")
		_compare(context, manual, driven, manual_game, driven_game)
		if actual.code == Types.Code.PREDICTION_STALL:
			stalls += 1
			if not raised:
				context.equal(frame, 3, "raise at the first prediction boundary with staged samples")
				for player: int in [0, 2]:
					var prior: Types.InputResult = driven.scheduled_local_input(player)
					var delay: int = 1 if player == 0 else 2
					context.equal(prior.code, Types.Code.OK, "stall retained each local sample before raising")
					context.equal(manual.set_input_delay(player, delay).code, Types.Code.OK, "expert raises one local slot")
					context.equal(driver.set_input_delay(player, delay).code, Types.Code.OK, "driver raises one local slot")
					context.equal(driver.input_delay(player), delay, "each local slot keeps its distinct delay")
					context.equal(driver.scheduled_local_input(player).frame, prior.frame + delay, "retained sample exposes its raised scheduled boundary")
					context.equal(driver.scheduled_local_input(player).bytes, prior.bytes, "raise preserves already staged buttons")
					context.equal(driver.set_input_delay(player, 0).code, Types.Code.UNSUPPORTED, "delay decrease cannot rewrite scheduled history")
					context.equal(driver.scheduled_local_input(player).bytes, prior.bytes, "refused decrease preserves staged buttons")
				raised = true
		now += 1
	context.equal(raised, true, "independent raises actually executed")
	context.equal(omitted_samples > 8, true, "omitted expert samples span queue reuse")
	context.equal(stalls > 1, true, "remote bursts cause repeated prediction refusal")
	context.equal(driven.status().current_frame, 32, "independent-delay workload reaches its exact target")
	while next_remote < 32:
		for session: Session in [manual, driven]:
			context.equal(session.receive_input(1, next_remote, _sample(1, next_remote)).code, Types.Code.OK, "deliver final independent-delay tail")
		next_remote += 1
	var empty: Array[Driver.LocalInput] = []
	context.equal(driver.recover(now).code, _manual(manual, manual_game, now, empty, false), "same final independent-delay recovery")
	_compare(context, manual, driven, manual_game, driven_game)
	context.equal(driven.statistics().rollback_count > 0, true, "changing remote inputs actually repaired predictions")
	context.equal(driven.replay().frame_count(), 32, "independent delays finalize every original row")
	var original: RefCounted = Reference.new(3, 2)
	var canonical: Array[PackedByteArray] = [original.bytes()]
	for frame: int in range(32):
		var row: Array[Dictionary] = []
		for player: int in range(3):
			var sample_frame: int = frame
			if player != 1 and frame > 3:
				var delay: int = 1 if player == 0 else 2
				sample_frame = maxi(3, frame - delay)
			if omit_bridge and player == 2 and frame == 4:
				sample_frame = 4
			var bytes: PackedByteArray = _sample(player, sample_frame)
			row.append({"player": player, "bytes": bytes.hex_encode(), "status": "confirmed"})
			if not omit_bridge:
				context.bytes_equal(driven.replay().inputs(frame).read(player).bytes, bytes, frame, "independent per-slot recorded row")
		context.equal(original.advance(row), "", "independent per-slot original history")
		canonical.append(original.bytes())
	var latest: Dictionary = {}
	for request: Dictionary in driven_game.requests:
		var boundary: int = request.frame + (1 if request.kind == "advance" else 0)
		latest[boundary] = request.state_bytes.hex_decode()
	for boundary: int in range(33):
		context.equal(latest.has(boundary), true, "each independent-delay canonical boundary was observed")
		if latest.has(boundary):
			context.bytes_equal(latest[boundary], canonical[boundary], boundary, "independent per-slot corrected boundary")
