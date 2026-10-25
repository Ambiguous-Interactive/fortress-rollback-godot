extends RefCounted

# Value: protects=final replay state verification; fails_when=the last input diverges undetected or a predicted boundary is certified;
# why_new=historical files contain only pre-input checksums; seam=none
const Game = preload("res://examples/integration/game.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Writer = preload("res://addons/fortress_rollback/core/snapshot_writer.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


class LastInputDiverges:
	extends Game
	var last: int = 0

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		var ok: bool = super.simulate_frame(frame, inputs)
		if frame == last:
			x[0] += 1
		return ok


class CaptureGame:
	extends Game
	var action: int = 0
	var session_ref: WeakRef
	var driver_ref: WeakRef
	var retained_writer: RefCounted
	var observations: PackedInt32Array = PackedInt32Array()

	func save_state(frame: int, writer: RefCounted) -> Driver.SaveResult:
		retained_writer = writer
		var result: Driver.SaveResult = super.save_state(frame, writer)
		match action:
			0:
				result.ok = false
			1:
				writer.write_bytes(PackedByteArray([0]))
			2:
				session_ref.get_ref().terminate()
			3:
				observations.append(session_ref.get_ref().call("begin_capture_replay_boundary").code)
				observations.append(driver_ref.get_ref().call("capture_replay_boundary").code)
				observations.append(driver_ref.get_ref().configure(session_ref.get_ref(), self))
		return result


func cases() -> PackedStringArray:
	return PackedStringArray(["capture_final_boundary", "terminal_validation", "expert_terminal", "capture_refusals", "terminal_golden", "capture_lifetime", "recording_cap"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"capture_final_boundary":
			_capture(context)
		"terminal_validation":
			_validation(context)
		"expert_terminal":
			_expert(context)
		"capture_refusals":
			_refusals(context)
		"terminal_golden":
			_golden(context)
		"capture_lifetime":
			_lifetime(context)
		"recording_cap":
			_cap(context)
	context.finish()


func _config() -> Config:
	var config: Config = Config.new()
	config.check_distance = 0
	config.max_snapshot_bytes = Game.SNAPSHOT_BYTES
	config.storage_budget_bytes = config.required_storage_bytes()
	config.replay_max_frames = 4
	return config


func _record(context: RefCounted, count: int, config: Config = null) -> Dictionary:
	var session: Session = Session.new()
	context.equal(session.configure(_config() if config == null else config), Types.Code.OK, "configures recorder")
	var game: Game = Game.new()
	var driver: Driver = Driver.new(session, game)
	for frame: int in count:
		if config != null and not config.sync_test:
			context.equal(session.receive_input(1, frame, PackedByteArray([0])).code, Types.Code.OK, "receives remote")
		var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, frame, PackedByteArray([Game.RIGHT]))]
		if config == null or config.sync_test:
			samples.append(Driver.LocalInput.new(1, frame, PackedByteArray([0])))
		context.equal(driver.step(frame, samples).code, Types.Code.OK, "records input")
	return {"session": session, "driver": driver, "game": game}


func _available(context: RefCounted, row: Dictionary) -> bool:
	context.equal(row.driver.has_method("capture_replay_boundary"), true, "driver exposes bounded final-state capture")
	context.equal(row.session.has_method("begin_capture_replay_boundary"), true, "expert exposes bounded final-state capture")
	return row.driver.has_method("capture_replay_boundary") and row.session.has_method("begin_capture_replay_boundary")


func _captured(context: RefCounted, row: Dictionary) -> Replay:
	if not _available(context, row):
		return null
	var result: Driver.StepResult = row.driver.call("capture_replay_boundary")
	context.equal(result.code, Types.Code.OK, "captures final state without input")
	context.equal(result.frame_before, result.frame_after, "capture does not advance")
	return row.session.replay()


func _capture(context: RefCounted) -> void:
	for count: int in [0, 1, 4]:
		var row: Dictionary = _record(context, count)
		var historical: Replay = row.session.replay()
		context.equal(historical.checksum(count).is_empty(), true, "historical export has no fabricated terminal evidence")
		var replay: Replay = _captured(context, row)
		if replay == null:
			continue
		context.equal(replay.frame_count(), count, "binds exact recorded prefix")
		context.equal(replay.checksum(count).size(), 16, "terminal checksum is present")
		var bytes: PackedByteArray = replay.to_bytes()
		context.equal(bytes.decode_u16(4), 6, "terminal evidence uses version six")
		context.equal(bytes.size(), historical.to_bytes().size() + 16, "extension has fixed bounded size")
		var decoded: Replay = Replay.new()
		context.equal(decoded.decode(bytes), Replay.DecodeCode.OK, "reads terminal format")
		context.equal(decoded.to_bytes(), bytes, "terminal bytes round trip")
		context.equal(decoded.checksum(count), replay.checksum(count), "decoded terminal checksum matches")
		var copied: Replay = replay.owned_copy()
		var checksum: PackedByteArray = copied.checksum(count)
		checksum.fill(0)
		context.equal(copied.checksum(count), replay.checksum(count), "terminal evidence is owned")
		if count > 0:
			context.equal(replay.owned_prefix(count - 1).checksum(count - 1).is_empty(), true, "shorter prefix cannot inherit a different terminal")
		for corrupt: PackedByteArray in [bytes.slice(0, -1), bytes + PackedByteArray([0])]:
			context.equal(decoded.decode(corrupt), Replay.DecodeCode.MALFORMED, "rejects missing or trailing terminal bytes")
			context.equal(decoded.to_bytes(), bytes, "rejected decode preserves recording")


func _validation(context: RefCounted) -> void:
	for count: int in [1, 4]:
		var row: Dictionary = _record(context, count)
		var historical: Replay = row.session.replay()
		var replay: Replay = _captured(context, row)
		if replay == null:
			continue
		for is_changed: bool in [false, true]:
			for terminal: bool in [false, true]:
				var game: LastInputDiverges = LastInputDiverges.new()
				game.last = count - 1 if is_changed else -1
				var player: Player = Player.new()
				context.equal(player.configure(replay if terminal else historical, game, Game.SNAPSHOT_BYTES, 1, 5), Types.Code.OK, "configures playback")
				for frame: int in count:
					context.equal(player.step(), Types.Code.OK, "preterminal playback matches")
				context.equal(player.current_frame(), count, "last input has executed")
				context.equal(player.is_complete(), not terminal, "terminal files require final SAVE before completion")
				var code: int = player.validate_current_frame()
				context.equal(code, Types.Code.DESYNC if terminal and is_changed else Types.Code.OK, "final-only divergence is detected exactly when evidence exists")
				if terminal and is_changed:
					context.equal(player.failure_frame(), count, "failure identifies final boundary")
					context.equal(player.failure_kind(), Types.Kind.SAVE, "failure identifies final SAVE")
					context.equal(player.failure_expected_checksum(), replay.checksum(count), "failure preserves expected terminal checksum")
					context.equal(player.failure_actual_checksum() != replay.checksum(count), true, "failure preserves actual final checksum")
				else:
					context.equal(player.is_complete(), true, "valid playback is complete")
					var checked: int = player.checked_checksum_count()
					context.equal(player.validate_current_frame(), Types.Code.OK, "repeated terminal inspection succeeds")
					context.equal(player.checked_checksum_count(), checked, "repeated inspection never counts twice")
					context.equal(player.restore_before(0), Types.Code.OK, "restores initial checkpoint")
					for frame: int in count:
						context.equal(player.step(), Types.Code.OK, "navigation replays original inputs")
					context.equal(player.validate_current_frame(), Types.Code.OK, "navigation validates terminal again")
					context.equal(player.checked_checksum_count(), checked, "navigation never duplicates coverage")


func _expert(context: RefCounted) -> void:
	var row: Dictionary = _record(context, 1)
	if not _available(context, row):
		return
	var capture: Types.Result = row.session.call("begin_capture_replay_boundary")
	context.equal(capture.code, Types.Code.READY, "expert capture opens one SAVE")
	var request: Types.Request = capture.batch.next_request()
	context.equal(request.kind, Types.Kind.SAVE, "capture requests actual game state")
	var saved: Driver.SaveResult = row.game.save_state(request.frame, request.writer)
	context.equal(row.session.complete_request(request.batch_id, request.request_id, saved.ok, saved.checksum).code, Types.Code.OK, "acknowledges captured state")
	context.equal(capture.batch.next_request() == null, true, "capture has no ADVANCE")
	var replay: Replay = row.session.replay()
	var game: Game = Game.new()
	var player: Player = Player.new()
	context.equal(player.configure_expert(replay, Game.SNAPSHOT_BYTES), Types.Code.OK, "configures expert terminal playback")
	for operation: int in 2:
		var batch: Types.Result = player.begin_advance()
		context.equal(batch.code, Types.Code.READY, "expert opens input or terminal batch")
		while true:
			var item: Types.Request = batch.batch.next_request()
			if item == null:
				break
			var checksum: PackedByteArray = PackedByteArray()
			var ok: bool = true
			if item.kind == Types.Kind.SAVE:
				var result: Driver.SaveResult = game.save_state(item.frame, item.writer)
				checksum = result.checksum
				ok = result.ok
			else:
				ok = game.simulate_frame(item.frame, item.inputs)
			context.equal(player.complete_request(item.batch_id, item.request_id, ok, checksum).code, Types.Code.OK, "expert validates ordered request")
	context.equal(player.is_complete(), true, "expert completion requires terminal checksum")
	context.equal(player.current_frame(), 1, "terminal batch never consumes another input")
	context.equal(player.begin_advance().code, Types.Code.FRAME_EXHAUSTED, "verified terminal is exhausted")


func _refusals(context: RefCounted) -> void:
	var config: Config = _config()
	config.sync_test = false
	config.local_players = PackedInt32Array([0])
	var row: Dictionary = _record(context, 0, config)
	if not _available(context, row):
		return
	var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, 0, PackedByteArray([Game.RIGHT]))]
	context.equal(row.driver.step(0, samples).code, Types.Code.OK, "simulates predicted input")
	context.equal(row.driver.call("capture_replay_boundary").code, Types.Code.PREDICTION_STALL, "cannot certify predicted state as finalized prefix")
	context.equal(row.session.replay().checksum(0).is_empty(), true, "refused capture leaves evidence absent")
	context.equal(row.session.receive_input(1, 0, PackedByteArray([0])).code, Types.Code.OK, "late matching input finalizes simulation")
	context.equal(row.driver.recover(1).code, Types.Code.OK, "finalizes matching history")
	context.equal(row.driver.call("capture_replay_boundary").code, Types.Code.OK, "captures finalized matching state")
	context.equal(row.session.replay().checksum(1).size(), 16, "matching late input has final evidence")
	row.session.terminate()
	context.equal(row.driver.call("capture_replay_boundary").code, Types.Code.TERMINATED, "terminated recorder cannot capture")


func _golden(context: RefCounted) -> void:
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/replay/golden.json"))
	var hex: String = ""
	for chunk: String in fixture.v6:
		hex += chunk
	var bytes: PackedByteArray = hex.hex_decode()
	var replay: Replay = Replay.new()
	context.equal(replay.decode(bytes), Replay.DecodeCode.OK, "reads independent Python terminal golden")
	context.equal(replay.to_bytes(), bytes, "reencodes exact independent terminal golden")
	context.equal(replay.checksum(4).hex_encode(), fixture.terminal_checksum, "independent terminal boundary matches")
	context.equal(replay.skipped_frames(), 0, "terminal recordings forbid substituted input")
	for frame: int in 4:
		context.equal(replay.computed_input_digest(frame), replay.input_digest(frame), "independent row digests match")
	bytes.encode_u32(15, 1)
	context.equal(replay.decode(bytes), Replay.DecodeCode.MALFORMED, "terminal checksum cannot certify substituted history")


func _lifetime(context: RefCounted) -> void:
	for action: int in 4:
		var session: Session = Session.new()
		context.equal(session.configure(_config()), Types.Code.OK, "configures capture lifetime")
		var game: CaptureGame = CaptureGame.new()
		game.action = action
		game.session_ref = weakref(session)
		var driver: Driver = Driver.new(session, game)
		game.driver_ref = weakref(driver)
		context.equal(session.submit_local_input(0, 0, PackedByteArray([Game.RIGHT])).code, Types.Code.OK, "stages next sample")
		var result: Driver.StepResult = driver.call("capture_replay_boundary")
		var expected: int = [Types.Code.CALLBACK_FAILED, Types.Code.SNAPSHOT_FAILED, Types.Code.TERMINATED, Types.Code.OK][action]
		context.equal(result.code, expected, "capture preserves callback failure or success")
		context.equal(result.failure_kind, Types.Kind.SAVE if action < 2 else -1, "capture failure identifies actual SAVE")
		context.equal(session.status().current_frame, 0, "failed capture never advances")
		context.equal(session.replay().checksum(0).size(), 16 if action == 3 else 0, "only completed SAVE publishes terminal evidence")
		context.equal(game.retained_writer.write_bytes(PackedByteArray([1])), Writer.Code.EXPIRED_VIEW, "capture writer expires after every outcome")
		if action == 3:
			context.equal(game.observations, PackedInt32Array([Types.Code.BUSY, Types.Code.BUSY, Types.Code.BUSY]), "capture holds shared callback guards")
			context.equal(driver.scheduled_local_input(0).bytes, PackedByteArray([Game.RIGHT]), "capture preserves staged next input")
		else:
			context.equal(driver.call("capture_replay_boundary").reason, expected, "later attempts preserve first cause")


func _cap(context: RefCounted) -> void:
	var row: Dictionary = _record(context, 4)
	var replay: Replay = _captured(context, row)
	if replay == null:
		return
	var terminal: PackedByteArray = replay.checksum(4)
	var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, 4, PackedByteArray([Game.LEFT])), Driver.LocalInput.new(1, 4, PackedByteArray([0]))]
	context.equal(row.driver.step(4, samples).code, Types.Code.OK, "live game continues after recording cap")
	context.equal(row.session.replay().checksum(4), terminal, "captured capped prefix keeps original final evidence")
	context.equal(row.driver.call("capture_replay_boundary").code, Types.Code.HISTORY_UNAVAILABLE, "later live state cannot replace capped terminal")
	context.equal(row.session.replay().checksum(4), terminal, "refusal preserves authentic capped evidence")
	var disabled: Config = _config()
	disabled.checksums_enabled = false
	var unverified: Dictionary = _record(context, 1, disabled)
	context.equal(unverified.driver.call("capture_replay_boundary").code, Types.Code.UNSUPPORTED, "disabled checksums never invent evidence")
	context.equal(unverified.session.replay().checksum(1).size(), 0, "disabled terminal remains absent")
