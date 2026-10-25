extends RefCounted

# Value: protects=manual replay navigation validates bounded cached states before committing a frame; fails_when=restore skips ordered LOAD/SAVE or trusts malformed state;
# why_new=existing cache tests use synchronous callbacks only; seam=none
const Checkpoints = preload("res://tests/unit/test_replay_checkpoints.gd")
const Fixture = preload("res://tests/unit/test_replay_viewer.gd")
const Validation = preload("res://tests/unit/test_replay_validation.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Reader = preload("res://addons/fortress_rollback/core/snapshot_reader.gd")
const Writer = preload("res://addons/fortress_rollback/core/snapshot_writer.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Simulation = preload("res://examples/offline/simulation.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["navigation_parity", "restore_integrity", "restore_lifetime", "checkpoint_revalidation"])


func run_case(name: String, context: RefCounted) -> void:
	var probe: RefCounted = Player.new()
	context.equal(probe.has_method("begin_restore_before"), true, "expert playback exposes checkpoint navigation")
	if probe.has_method("begin_restore_before"):
		call("_" + name, context)
	context.finish()


func _prepare(context: RefCounted, player: RefCounted, game: Simulation, replay: Replay, capacity: int = 3) -> void:
	context.equal(player.configure_expert(replay, Simulation.SNAPSHOT_BYTES, null, 3, capacity), Types.Code.OK, "expert bounded cache configures")
	context.equal(player.begin_restore_before(0).code, Types.Code.HISTORY_UNAVAILABLE, "no checkpoint before first successful save")
	for frame: int in replay.frame_count():
		Validation.new()._advance(context, player, game)
	context.equal(player.current_frame(), replay.frame_count(), "preparation executes full workload")


func _restore(context: RefCounted, player: RefCounted, game: Simulation, target: int, expected_frame: int) -> void:
	var before: int = player.current_frame()
	var result: Types.Result = player.begin_restore_before(target)
	context.equal(result.code, Types.Code.READY, "retained checkpoint opens restore batch")
	var request: Types.Request = result.batch.next_request()
	context.equal(request.kind, Types.Kind.LOAD, "restore first requests the cached snapshot")
	context.equal(request.frame, expected_frame, "restore chooses nearest retained checkpoint")
	var reader: Reader = request.reader
	context.equal(game.load_state(request.frame, reader), true, "application loads original cached state")
	context.equal(player.complete_request(request.batch_id, request.request_id, true).code, Types.Code.OK, "load acknowledgement succeeds")
	context.equal(reader.status(), Reader.Code.EXPIRED_VIEW, "load acknowledgement expires reader")
	context.equal(player.current_frame(), before, "load does not prematurely commit exposed frame")
	request = result.batch.next_request()
	context.equal(request.kind, Types.Kind.SAVE, "restored state must be independently saved")
	context.equal(request.frame, expected_frame, "validation saves selected boundary")
	var saved: Driver.SaveResult = game.save_state(request.frame, request.writer)
	var writer: Writer = request.writer
	context.equal(player.complete_request(request.batch_id, request.request_id, saved.ok, saved.checksum).code, Types.Code.OK, "exact snapshot round-trip completes")
	context.equal(writer.status(), Writer.Code.EXPIRED_VIEW, "restore validation expires writer")
	context.equal(player.current_frame(), expected_frame, "frame commits after exact verification")
	context.equal(result.batch.next_request(), null, "navigation never simulates an input")


func _navigation_parity(context: RefCounted) -> void:
	for checksums: bool in [true, false]:
		var replay: Replay = Fixture.recording(12)
		if not checksums:
			replay._flags.fill(0)
		var expert: RefCounted = Player.new()
		var callback: RefCounted = Player.new()
		var game: Simulation = Simulation.new()
		var control: Simulation = Simulation.new()
		_prepare(context, expert, game, replay)
		context.equal(callback.configure(replay, control, Simulation.SNAPSHOT_BYTES, 3, 3), Types.Code.OK, "callback cache configures")
		for frame: int in 12:
			context.equal(callback.step(), Types.Code.OK, "callback canonical control")
		context.equal(expert.checkpoint_frames(), PackedInt64Array([0, 6, 9]), "expert inventory lists actual retained validated checkpoints")
		var inventory: PackedInt64Array = expert.checkpoint_frames()
		inventory.clear()
		context.equal(expert.checkpoint_frames(), callback.checkpoint_frames(), "callback and manual modes expose identical owned inventories")
		var checked: int = expert.checked_checksum_count()
		for pair: Array in [[8, 6], [11, 9], [0, 0], [5, 0]]:
			if pair[0] == 5:
				context.equal(expert.begin_restore_before(5).code, Types.Code.OK, "forward target does not rewind an already closer current state")
				continue
			_restore(context, expert, game, pair[0], pair[1])
			context.equal(callback.restore_before(pair[0]), Types.Code.OK, "callback selects the same checkpoint")
			context.bytes_equal(game.canonical_bytes(), control.canonical_bytes(), pair[1], "manual and callback restore canonical equality")
			context.equal(expert.checked_checksum_count(), checked, "navigation does not double-count checksum coverage")
			Validation.new()._advance(context, expert, game)
			context.equal(callback.step(), Types.Code.OK, "callback continuation")
			context.bytes_equal(game.canonical_bytes(), control.canonical_bytes(), pair[1] + 1, "manual continuation matches callback history")
		context.state(game.frame, game.canonical_bytes())
	var bounded: RefCounted = Player.new()
	var bounded_game: Simulation = Simulation.new()
	_prepare(context, bounded, bounded_game, Fixture.recording(12), 2)
	_restore(context, bounded, bounded_game, 8, 0)
	_restore(context, bounded, bounded_game, 11, 9)


func _restore_integrity(context: RefCounted) -> void:
	for fault: String in ["load callback", "unread", "underflow", "expired reader", "save callback", "overflow", "expired writer", "short checksum", "checksum", "bytes"]:
		var player: RefCounted = Player.new()
		var game: Simulation = Simulation.new()
		_prepare(context, player, game, Fixture.recording(12))
		var result: Types.Result = player.begin_restore_before(8)
		var request: Types.Request = result.batch.next_request()
		var reader: Reader = request.reader
		if fault != "unread":
			game.load_state(request.frame, reader)
		if fault == "underflow":
			reader.read_bytes(1)
		elif fault == "expired reader":
			reader._expire()
		var code: int = player.complete_request(request.batch_id, request.request_id, fault != "load callback").code
		var expected: int = Types.Code.CALLBACK_FAILED if fault.ends_with("callback") else Types.Code.SNAPSHOT_FAILED
		if fault in ["short checksum", "checksum", "bytes"]:
			expected = Types.Code.DESYNC
		if fault not in ["load callback", "unread", "underflow", "expired reader"]:
			context.equal(code, Types.Code.OK, "healthy load before save fault")
			request = result.batch.next_request()
			var original_checksum: PackedByteArray = game.save_state(request.frame, Writer.new(Simulation.SNAPSHOT_BYTES)).checksum
			if fault == "bytes":
				game.rng_state ^= 1
			var saved: Driver.SaveResult = game.save_state(request.frame, request.writer)
			if fault == "overflow":
				request.writer.write_bytes(PackedByteArray([0]))
			elif fault == "expired writer":
				request.writer._expire()
			elif fault == "short checksum":
				saved.checksum.resize(15)
			elif fault == "checksum":
				saved.checksum[0] ^= 1
			elif fault == "bytes":
				saved.checksum = original_checksum
			var writer: Writer = request.writer
			code = player.complete_request(request.batch_id, request.request_id, fault != "save callback", saved.checksum).code
			context.equal(writer.status(), Writer.Code.EXPIRED_VIEW, "failed restore releases writer")
		context.equal(code, expected, fault + " blocks restored boundary")
		context.equal(reader.status(), Reader.Code.EXPIRED_VIEW, "failed restore releases reader")
		context.equal(player.current_frame(), 12, "failed restore cannot commit selected frame")
		context.equal(player.failure_frame(), 6, "failure identifies attempted cached boundary")
		context.equal(player.begin_advance().code, expected, "restore failure stops playback")
		context.equal(player.begin_restore_before(0).code, expected, "navigation cannot erase failure")
		context.equal(player.failure_expected_checksum().is_empty(), fault != "checksum", "only real checksum comparison supplies paired evidence")
		context.state(game.frame, game.canonical_bytes())


func _restore_lifetime(context: RefCounted) -> void:
	var player: RefCounted = Player.new()
	context.equal(player.begin_restore_before(0).code, Types.Code.NOT_CONFIGURED, "unconfigured restore refuses")
	var replay: Replay = Fixture.recording(12)
	for dimensions: Array in [[0, 2], [1, 0], [-1, 2], [1, 1], [1, 1025], [1, 1024]]:
		var limit: int = 16777216 if dimensions == [1, 1024] else Simulation.SNAPSHOT_BYTES
		context.equal(player.configure_expert(replay, limit, null, dimensions[0], dimensions[1]), Types.Code.INVALID_CONFIGURATION, "invalid expert cache budget refuses")
	var game: Simulation = Simulation.new()
	_prepare(context, player, game, replay)
	for target: int in [-1, 13, 9223372036854775807]:
		context.equal(player.begin_restore_before(target).code, Types.Code.INVALID_FRAME, "invalid navigation target refuses")
	var result: Types.Result = player.begin_restore_before(8)
	var request: Types.Request = result.batch.next_request()
	var batch_id: int = request.batch_id
	var request_id: int = request.request_id
	var reader: Reader = request.reader
	context.equal(player.begin_restore_before(0).code, Types.Code.BUSY, "restore cannot abandon open request")
	context.equal(player.begin_advance().code, Types.Code.BUSY, "restore blocks advancement")
	context.equal(player.begin_validate_current_frame().code, Types.Code.BUSY, "restore blocks paused validation")
	context.equal(player.configure_expert(replay), Types.Code.BUSY, "restore blocks replacement")
	context.equal(player.complete_request(batch_id, request_id + 1, true).code, Types.Code.STALE_REQUEST, "wrong acknowledgement preserves restore")
	context.equal(reader.status(), Reader.Code.OK, "wrong identity keeps reader usable")
	game.load_state(6, reader)
	request.kind = Types.Kind.ADVANCE
	request.frame = 100
	context.equal(player.complete_request(batch_id, request_id, true).code, Types.Code.OK, "public metadata cannot turn load into advance")
	request = result.batch.next_request()
	context.equal(request.frame, 6, "save uses authoritative selected frame")
	var writer: Writer = request.writer
	var saved: Driver.SaveResult = game.save_state(6, writer)
	context.equal(player.complete_request(batch_id, request_id, true).code, Types.Code.STALE_REQUEST, "duplicate load cannot acknowledge save")
	player.terminate()
	context.equal(writer.status(), Writer.Code.EXPIRED_VIEW, "termination expires navigation writer")
	context.equal(result.batch.next_request(), null, "terminated restore has no requests")
	context.equal(player.complete_request(request.batch_id, request.request_id, saved.ok, saved.checksum).code, Types.Code.TERMINATED, "termination remains first cause")
	context.equal(player.failure_frame(), 12, "termination retains the exposed playback boundary")
	context.equal(player.configure_expert(replay, Simulation.SNAPSHOT_BYTES, null, 3, 3), Types.Code.OK, "explicit restart clears cache")
	context.equal(player.begin_restore_before(0).code, Types.Code.HISTORY_UNAVAILABLE, "old lifetime cannot lend cached state")
	context.equal(result.batch.next_request(), null, "old batch cannot borrow restarted requests")
	context.state(game.frame, game.canonical_bytes())


# Value: protects=cached replay boundaries detect changed game state during repeated playback;
# fails_when=duplicate cached frames skip canonical comparison; why_new=restore tests validate LOAD only; seam=none
func _checkpoint_revalidation(context: RefCounted) -> void:
	for expert: bool in [false, true]:
		for operation: String in ["advance", "validate"]:
			for target: int in [0, 3]:
				for fault: String in ["none", "checksum", "bytes"]:
					var replay: Replay = Fixture.recording(8)
					replay._flags.fill(0)
					var player: Player = Player.new()
					var wrapper: Checkpoints.FaultGame = Checkpoints.FaultGame.new()
					var game: Simulation = wrapper.game
					if expert:
						context.equal(player.configure_expert(replay, Simulation.SNAPSHOT_BYTES, null, 3, 4), Types.Code.OK, "manual cache configures")
					else:
						context.equal(player.configure(replay, wrapper, Simulation.SNAPSHOT_BYTES, 3, 4), Types.Code.OK, "callback cache configures")
					for frame: int in 8:
						context.equal(_dispatch_boundary(player, game, expert, false), Types.Code.OK, "original prefix establishes checkpoints")
					if expert:
						_restore(context, player, game, target, target)
					else:
						context.equal(player.restore_before(target), Types.Code.OK, "restore original validated state")
					var expected_checksum: PackedByteArray = Simulation.checksum(game.canonical_bytes())
					if fault != "none":
						game.rng_state ^= 1
					if not expert and fault == "bytes":
						wrapper.fault = "checksum collision"
						wrapper.cached_checksum = expected_checksum
					var code: int = _dispatch_boundary(player, game, expert, operation == "validate", expected_checksum if fault == "bytes" else PackedByteArray())
					context.equal(code, Types.Code.OK if fault == "none" else Types.Code.DESYNC, fault + " revalidated cached boundary")
					context.equal(player.checked_checksum_count(), 0, "cached evidence is separate from recorded-checksum coverage")
					if fault != "none":
						context.equal(player.current_frame(), target, "changed cached boundary cannot consume input")
						context.equal(player.failure_frame(), target, "diagnostic identifies changed cached frame")
						context.equal(player.failure_kind(), Types.Kind.SAVE, "failed checkpoint comparison names SAVE")
						context.equal(player.failure_comparison(), "checkpoint_" + fault, "diagnostic distinguishes checksum and canonical bytes")
						context.equal(player.begin_advance().code, Types.Code.DESYNC, "divergence remains latched")
					context.state(game.frame, game.canonical_bytes())


func _dispatch_boundary(player: Player, game: Simulation, expert: bool, validation: bool, checksum: PackedByteArray = PackedByteArray()) -> int:
	if not expert:
		return player.validate_current_frame() if validation else player.step()
	var result: Types.Result = player.begin_validate_current_frame() if validation else player.begin_advance()
	if result.code != Types.Code.READY:
		return result.code
	while true:
		var request: Types.Request = result.batch.next_request()
		if request == null:
			return Types.Code.OK
		var digest: PackedByteArray = PackedByteArray()
		var ok: bool
		if request.kind == Types.Kind.SAVE:
			var saved: Driver.SaveResult = game.save_state(request.frame, request.writer)
			ok = saved.ok
			digest = saved.checksum if checksum.is_empty() else checksum
		else:
			ok = game.simulate_frame(request.frame, request.inputs)
		var code: int = player.complete_request(request.batch_id, request.request_id, ok, digest).code
		if code != Types.Code.OK:
			return code
	return Types.Code.OK
