extends RefCounted

# Value: protects=expert clients inspect paused replay boundaries before consuming input; fails_when=validation advances or bypasses integrity and request lifetime gates;
# why_new=paused validation was callback-only; seam=none
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Writer = preload("res://addons/fortress_rollback/core/snapshot_writer.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Fixture = preload("res://tests/unit/test_replay_viewer.gd")


class CallbackGame:
	extends Simulation
	var owner: WeakRef
	var reentry_codes: Array[int] = []

	func save_state(frame: int, writer: Writer) -> Driver.SaveResult:
		reentry_codes.append(owner.get_ref().begin_validate_current_frame().code)
		return super.save_state(frame, writer)


func cases() -> PackedStringArray:
	return PackedStringArray(["paused_parity", "paused_integrity", "paused_lifetime"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"paused_parity":
			_paused_parity(context)
		"paused_integrity":
			_paused_integrity(context)
		"paused_lifetime":
			_paused_lifetime(context)
	context.finish()


func _paused_parity(context: RefCounted) -> void:
	var empty: Player = Player.new()
	context.equal(empty.begin_validate_current_frame().code, Types.Code.NOT_CONFIGURED, "unconfigured validation refuses")
	context.equal(empty.configure_expert(Fixture.recording(0)), Types.Code.OK, "empty recording configures")
	context.equal(empty.begin_validate_current_frame().code, Types.Code.OK, "empty complete boundary needs no request")
	context.equal(empty.is_complete(), true, "empty validation does not fabricate an input")
	for coverage: String in ["full", "sparse", "none", "input only", "cached"]:
		var replay: Replay = Fixture.recording(4)
		for frame: int in 4:
			if coverage in ["none", "cached"] or (coverage == "sparse" and frame % 2 == 1):
				replay._flags[frame] = 0
		var limit: int = 0 if coverage == "input only" else Simulation.SNAPSHOT_BYTES
		var expert: Player = Player.new()
		var callback: Player = Player.new()
		var game: Simulation = Simulation.new()
		var control: Simulation = Simulation.new()
		var cached: bool = coverage == "cached"
		var code: int = expert.configure(replay, game, limit, 2, 3) if cached else expert.configure_expert(replay, limit)
		context.equal(code, Types.Code.OK, "manual request playback configures")
		context.equal(callback.configure(replay, control, limit, 2 if cached else 0, 3 if cached else 0), Types.Code.OK, "callback control configures")
		for frame: int in 5:
			var before: PackedByteArray = game.canonical_bytes()
			var validation: Types.Result = expert.begin_validate_current_frame()
			var saves: bool = limit > 0 and (not replay.checksum(frame).is_empty() or (cached and frame < 4 and frame % 2 == 0))
			context.equal(validation.code, Types.Code.READY if saves else Types.Code.OK, "only recorded checksums need an expert SAVE")
			if saves:
				var request: Types.Request = validation.batch.next_request()
				context.equal(request.kind, Types.Kind.SAVE, "paused validation requests only a save")
				context.equal(request.frame, frame, "validation identifies the selected state boundary")
				var checksum: PackedByteArray = game.save_state(frame, request.writer).checksum
				context.equal(expert.complete_request(request.batch_id, request.request_id, true, checksum).code, Types.Code.OK, "validation save completes")
				context.equal(validation.batch.next_request(), null, "validation never emits an ADVANCE")
			else:
				context.equal(validation.batch, null, "input-only validation has no callback batch")
			context.equal(callback.validate_current_frame(), Types.Code.OK, "callback validates the same boundary")
			context.equal(expert.current_frame(), frame, "expert validation preserves position")
			context.bytes_equal(game.canonical_bytes(), before, frame, "validation does not simulate selected input")
			context.equal(expert.checked_checksum_count(), callback.checked_checksum_count(), "paused APIs publish the same distinct checksum coverage")
			if frame < 4:
				_advance(context, expert, game)
				context.equal(callback.step(), Types.Code.OK, "callback advances the same input")
				context.bytes_equal(game.canonical_bytes(), control.canonical_bytes(), frame + 1, "validation preserves canonical playback")
		context.equal(expert.is_complete(), true, "final boundary remains complete")
		context.state(game.frame, game.canonical_bytes())


func _advance(context: RefCounted, player: Player, game: Simulation) -> void:
	var result: Types.Result = player.begin_advance()
	context.equal(result.code, Types.Code.READY, "expert frame opens")
	while true:
		var request: Types.Request = result.batch.next_request()
		if request == null:
			return
		var checksum: PackedByteArray = PackedByteArray()
		var ok: bool = true
		if request.kind == Types.Kind.SAVE:
			checksum = game.save_state(request.frame, request.writer).checksum
		else:
			ok = game.simulate_frame(request.frame, request.inputs)
		context.equal(player.complete_request(request.batch_id, request.request_id, ok, checksum).code, Types.Code.OK, "expert frame request completes")


func _paused_integrity(context: RefCounted) -> void:
	for fault: String in ["input", "digest", "checksum", "short checksum", "overflow", "expired", "callback"]:
		var replay: Replay = Fixture.recording(4)
		var snapshots: bool = fault not in ["input", "digest"]
		var player: Player = Player.new()
		var game: Simulation = Simulation.new()
		if fault == "input":
			replay._inputs[0] ^= 1
		elif fault == "digest":
			replay._digests[0] ^= 1
		elif fault == "checksum":
			replay._checksums[0] ^= 1
		context.equal(player.configure_expert(replay, Simulation.SNAPSHOT_BYTES if snapshots else 0), Types.Code.OK, "integrity fixture configures")
		var result: Types.Result = player.begin_validate_current_frame()
		var code: int = result.code
		var writer: Writer
		if snapshots:
			context.equal(code, Types.Code.READY, "snapshot validation requests application state")
			var request: Types.Request = result.batch.next_request()
			writer = request.writer
			var checksum: PackedByteArray = game.save_state(0, writer).checksum
			if fault == "short checksum":
				checksum.resize(15)
			elif fault == "overflow":
				writer.write_bytes(PackedByteArray([0]))
			elif fault == "expired":
				writer._expire()
			code = player.complete_request(request.batch_id, request.request_id, fault != "callback", checksum).code
			context.equal(writer.status(), Writer.Code.EXPIRED_VIEW, "failed validation releases its bounded writer")
		var expected: int = Types.Code.DESYNC
		if fault in ["overflow", "expired"]:
			expected = Types.Code.SNAPSHOT_FAILED
		elif fault == "callback":
			expected = Types.Code.CALLBACK_FAILED
		context.equal(code, expected, fault + " cannot validate the paused boundary")
		context.equal(player.current_frame(), 0, "failed validation does not consume input")
		context.equal(player.failure_frame(), 0, "failure identifies the selected boundary")
		context.equal(player.checked_checksum_count(), 0, "failed validation cannot claim checksum coverage")
		context.equal(player.begin_validate_current_frame().code, expected, "validation failure remains latched")
		context.equal(player.begin_advance().code, expected, "validation failure blocks forward playback")
		context.equal(player.failure_expected_checksum().is_empty(), fault not in ["input", "digest", "checksum"], "comparison failures retain bounded evidence")
		context.state(game.frame, game.canonical_bytes())


func _paused_lifetime(context: RefCounted) -> void:
	var player: Player = Player.new()
	var replay: Replay = Fixture.recording(4)
	context.equal(player.configure_expert(replay, Simulation.SNAPSHOT_BYTES), Types.Code.OK, "paused expert configures")
	var result: Types.Result = player.begin_validate_current_frame()
	var request: Types.Request = result.batch.next_request()
	var writer: Writer = request.writer
	var batch_id: int = request.batch_id
	var request_id: int = request.request_id
	context.equal(player.begin_validate_current_frame().code, Types.Code.BUSY, "validation retains its open batch")
	context.equal(player.begin_advance().code, Types.Code.BUSY, "validation blocks advancement")
	context.equal(player.configure_expert(replay), Types.Code.BUSY, "validation blocks replacement")
	context.equal(player.complete_request(batch_id, request_id + 1, true).code, Types.Code.STALE_REQUEST, "wrong acknowledgement preserves the active validation")
	context.equal(writer.status(), Writer.Code.OK, "wrong identity preserves the live writer")
	var game: Simulation = Simulation.new()
	var checksum: PackedByteArray = game.save_state(0, writer).checksum
	request.kind = Types.Kind.ADVANCE
	request.frame = 100
	context.equal(player.complete_request(batch_id, request_id, true, checksum).code, Types.Code.OK, "public metadata cannot turn validation into input consumption")
	context.equal(player.current_frame(), 0, "validation does not commit a frame")
	context.equal(writer.status(), Writer.Code.EXPIRED_VIEW, "successful validation expires its writer")
	context.equal(result.batch.next_request(), null, "completed validation cannot supply more requests")
	context.equal(player.complete_request(batch_id, request_id, true, checksum).code, Types.Code.STALE_REQUEST, "duplicate validation acknowledgement refuses")
	_advance(context, player, game)
	context.equal(player.checked_checksum_count(), 1, "revalidating through advancement does not count a checksum twice")
	var abandoned: Types.Result = player.begin_validate_current_frame()
	var retained: Writer = abandoned.batch.next_request().writer
	player.terminate()
	context.equal(retained.status(), Writer.Code.EXPIRED_VIEW, "termination expires paused validation views")
	context.equal(abandoned.batch.next_request(), null, "terminated validation cannot publish requests")
	context.equal(player.begin_validate_current_frame().code, Types.Code.TERMINATED, "termination remains latched")
	context.equal(player.configure_expert(replay, Simulation.SNAPSHOT_BYTES), Types.Code.OK, "terminated validation can restart explicitly")
	var newer: Types.Result = player.begin_validate_current_frame()
	var next: Types.Request = newer.batch.next_request()
	context.equal(next.batch_id > batch_id, true, "validation batch identities survive reconfiguration")
	context.equal(result.batch.next_request(), null, "old validation cannot borrow a new request")
	context.equal(player.complete_request(next.batch_id, next.request_id, false).code, Types.Code.CALLBACK_FAILED, "new lifetime owns its failure")
	var callback_game: CallbackGame = CallbackGame.new()
	callback_game.owner = weakref(player)
	context.equal(player.configure(replay, callback_game, Simulation.SNAPSHOT_BYTES), Types.Code.OK, "callback validation configures")
	context.equal(player.validate_current_frame(), Types.Code.OK, "callback validation still succeeds")
	context.equal(callback_game.reentry_codes, [Types.Code.BUSY], "callback guard also blocks opening manual validation")
	context.state(game.frame, game.canonical_bytes())
