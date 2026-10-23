extends RefCounted

# Value: protects=atomic retained-overlap backfill and prediction repair; fails_when=conflicts alter history or missing rows bypass rollback;
# why_new=ordinary single-input insertion cannot install a validated recovery chunk; seam=none
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Spectator = preload("res://addons/fortress_rollback/core/spectator_session.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["overlap_suffix", "atomic_refusal", "wrap_floor", "prediction", "session_fences", "session_repair"])


func run_case(name: String, context: RefCounted) -> void:
	var queue: RefCounted = Queue.new()
	queue.configure(5, PackedByteArray([0]))
	if not queue.has_method("install_missing_backfill"):
		context.equal(false, true, "the queue can install a complete immutable recovery chunk")
		context.finish()
		return
	match name:
		"overlap_suffix":
			_overlap(context, queue)
		"atomic_refusal":
			_refusals(context, queue)
		"wrap_floor":
			_wrap(context, queue)
		"prediction":
			_prediction(context, queue)
		"session_fences":
			_fences(context)
		"session_repair":
			_repair(context)
	context.finish()


func _rows(first: int, count: int) -> Array[PackedByteArray]:
	var rows: Array[PackedByteArray] = []
	for frame: int in range(first, first + count):
		rows.append(PackedByteArray([frame + 1]))
	return rows


func _overlap(context: RefCounted, queue: RefCounted) -> void:
	context.equal(queue.install_missing_backfill(0, _rows(0, 3), 0), Queue.Code.OK, "install the first actual prefix")
	var incoming: Array[PackedByteArray] = _rows(1, 4)
	context.equal(queue.validate_missing_backfill(1, incoming, 0), Queue.Code.OK, "validate overlap and suffix without mutation")
	context.equal(queue.retained_frame_range(), PackedInt64Array([0, 2]), "validation cannot advance receipts")
	context.equal(queue.install_missing_backfill(1, incoming, 0), Queue.Code.OK, "identical retained overlap permits the missing suffix")
	incoming[3][0] = 99
	for frame: int in range(5):
		context.equal(queue.retained_confirmed_input(frame).bytes, PackedByteArray([frame + 1]), "backfill retains owned actual bytes")
	context.equal(queue.install_missing_backfill(0, _rows(0, 5), 0), Queue.Code.OK, "an identical complete retransmission is idempotent")
	queue.configure(5, PackedByteArray([0]))
	queue.set_frame_delay(2)
	context.equal(queue.install_missing_backfill(0, _rows(0, 3), 0), Queue.Code.OK, "donor frames are already scheduled")
	context.equal(queue.retained_frame_range(), PackedInt64Array([0, 2]), "backfill does not apply local sample delay twice")
	context.equal(queue.retained_confirmed_input(0).bytes, PackedByteArray([1]), "scheduled frame zero preserves donor bytes")


func _refusals(context: RefCounted, queue: RefCounted) -> void:
	queue.add_input(0, PackedByteArray([1]))
	queue.add_input(1, PackedByteArray([2]))
	var bad_width: Array[PackedByteArray] = [PackedByteArray([3]), PackedByteArray()]
	var conflict: Array[PackedByteArray] = [PackedByteArray([1]), PackedByteArray([99]), PackedByteArray([3])]
	var failures: Array[Array] = [
		[0, conflict, Queue.Code.CONFLICTING_INPUT],
		[2, bad_width, Queue.Code.INPUT_WIDTH],
		[3, _rows(3, 2), Queue.Code.OUT_OF_ORDER],
		[2, _rows(2, 5), Queue.Code.CAPACITY],
		[0, _rows(0, 6), Queue.Code.CAPACITY],
		[Queue.FRAME_MAX, _rows(0, 2), Queue.Code.FRAME_RANGE],
		[-1, _rows(0, 1), Queue.Code.FRAME_RANGE],
	]
	for failure: Array in failures:
		context.equal(queue.install_missing_backfill(failure[0], failure[1], 0), failure[2], "invalid chunk is refused before mutation")
		context.equal(queue.retained_frame_range(), PackedInt64Array([0, 1]), "refusal preserves actual interval")
		for frame: int in range(2):
			context.equal(queue.retained_confirmed_input(frame).bytes, PackedByteArray([frame + 1]), "refusal preserves overlap bytes")
	context.equal(queue.install_missing_backfill(2, _rows(2, 3), 0), Queue.Code.OK, "a valid chunk still fills the original next frame")
	queue.freeze_at(4)
	context.equal(queue.install_missing_backfill(5, _rows(5, 1), 0), Queue.Code.OUT_OF_ORDER, "frozen queues reject later recovery")


func _wrap(context: RefCounted, queue: RefCounted) -> void:
	queue.install_missing_backfill(0, _rows(0, 5), 0)
	context.equal(queue.install_missing_backfill(4, _rows(4, 3), 0), Queue.Code.CAPACITY, "a fast sender cannot reclaim above the global floor")
	context.equal(queue.retained_frame_range(), PackedInt64Array([0, 4]), "capacity refusal preserves full ring")
	context.equal(queue.install_missing_backfill(4, _rows(4, 3), 1), Queue.Code.OK, "a validated floor permits non-power-of-two ring wrap")
	context.equal(queue.retained_frame_range(), PackedInt64Array([1, 6]), "the side slot preserves the exact retained floor")
	context.equal(queue.retained_confirmed_input(1).bytes, PackedByteArray([2]), "the reclaimed floor keeps its original bytes")
	context.equal(queue.install_missing_backfill(0, _rows(0, 1), 1), Queue.Code.BEFORE_RETAINED, "stale physical overlap is unavailable")
	context.equal(queue.install_missing_backfill(1, _rows(1, 5), 1), Queue.Code.OK, "tagged side-slot overlap is accepted")
	queue.input(5)
	queue.discard_confirmed_frames(5)
	context.equal(queue.install_missing_backfill(1, _rows(1, 1), 5), Queue.Code.BEFORE_RETAINED, "discard invalidates the earlier side-slot tag")


func _prediction(context: RefCounted, queue: RefCounted) -> void:
	queue.add_input(0, PackedByteArray([1]))
	context.equal(queue.input(3).bytes, PackedByteArray([1]), "simulate a repeat-latest prediction")
	var incoming: Array[PackedByteArray] = [PackedByteArray([1]), PackedByteArray([4]), PackedByteArray([5])]
	context.equal(queue.install_missing_backfill(1, incoming, 0), Queue.Code.OK, "backfill uses ordinary prediction bookkeeping")
	context.equal(queue.first_incorrect_frame(), 2, "the first changed predicted input requires repair")
	context.equal(queue.install_missing_backfill(1, incoming, 0), Queue.Code.OK, "retransmission preserves pending repair")
	context.equal(queue.first_incorrect_frame(), 2, "identical overlap cannot clear mismatch")
	queue.reset_prediction()
	context.equal(queue.input(3).bytes, PackedByteArray([5]), "after repair the real history replaces prediction")


func _settings() -> RefCounted:
	var settings: RefCounted = Config.new()
	settings.sync_test = false
	settings.local_players = PackedInt32Array([0])
	settings.check_distance = 0
	settings.max_prediction_frames = 3
	settings.max_snapshot_bytes = 16
	settings.storage_budget_bytes = 65536
	return settings


func _fences(context: RefCounted) -> void:
	var session: RefCounted = Session.new()
	context.equal(session.install_missing_backfill(1, 0, _rows(0, 1)), Types.Code.NOT_CONFIGURED, "unconfigured backfill refuses")
	session.configure(_settings())
	context.equal(session.install_missing_backfill(0, 0, _rows(0, 1)), Types.Code.INVALID_PLAYER, "a donor cannot replace local input")
	context.equal(session.install_missing_backfill(2, 0, _rows(0, 1)), Types.Code.INVALID_PLAYER, "slot bound is checked")
	context.equal(session.install_missing_backfill(1, 1, _rows(1, 1)), Types.Code.INVALID_FRAME, "initial gap is refused")
	context.equal(session.received_frames(), PackedInt64Array([-1, -1]), "invalid batch preserves every receipt")
	context.equal(session.install_missing_backfill(1, 0, _rows(0, 2)), Types.Code.OK, "valid batch installs the remote prefix")
	context.equal(session.received_frames(), PackedInt64Array([-1, 1]), "receipt advances through the installed suffix")
	session.submit_local_input(0, 0, PackedByteArray([0]))
	var batch: RefCounted = session.begin_advance().batch
	context.equal(batch != null, true, "open a real expert batch")
	context.equal(session.validate_missing_backfill(1, 1, _rows(1, 2)), Types.Code.BUSY, "validation respects active batch")
	context.equal(session.install_missing_backfill(1, 1, _rows(1, 2)), Types.Code.BUSY, "backfill cannot enter an active batch")
	session.terminate()
	context.equal(session.install_missing_backfill(1, 1, _rows(1, 2)), Types.Code.TERMINATED, "terminal history cannot be changed")
	var spectator: RefCounted = Spectator.new()
	context.equal(spectator.install_missing_backfill(0, 0, _rows(0, 1)), Types.Code.UNSUPPORTED, "spectators accept only host rows")
	context.equal(spectator.validate_missing_backfill(0, 0, _rows(0, 1)), Types.Code.UNSUPPORTED, "spectator validation cannot admit player recovery")


func _repair(context: RefCounted) -> void:
	var session: RefCounted = Session.new()
	session.configure(_settings())
	var game: Dictionary = {"value": 0, "loads": 0}
	for frame: int in range(3):
		session.submit_local_input(0, frame, PackedByteArray([frame + 1]))
		_consume(context, session, game)
	context.equal(session.install_missing_backfill(1, 0, _rows(0, 3)), Types.Code.OK, "install the missing actual history after prediction")
	context.equal(session.status().pending_rollback_frame, 0, "backfill exposes the original prediction mismatch")
	var recovery: RefCounted = session.begin_recovery()
	context.equal(recovery.code, Types.Code.READY, "recovery opens the original shared-engine repair")
	_consume_open(context, session, game, recovery.batch)
	context.equal(game.loads, 1, "backfill correction restores the original state")
	context.equal(game.value, 12, "repaired canonical state equals uninterrupted actual inputs")
	context.equal(session.status().pending_rollback_frame, -1, "completed recovery clears the mismatch")
	context.equal(session.received_frames(), PackedInt64Array([2, 2]), "repair preserves installed receipt frontiers")


func _consume(context: RefCounted, session: RefCounted, game: Dictionary) -> void:
	var result: RefCounted = session.begin_advance()
	context.equal(result.code, Types.Code.READY, "advance provides an expert batch")
	_consume_open(context, session, game, result.batch)


func _consume_open(context: RefCounted, session: RefCounted, game: Dictionary, batch: RefCounted) -> void:
	if batch == null:
		return
	var request: RefCounted = batch.next_request()
	while request != null:
		match request.kind:
			Types.Kind.SAVE:
				var state: PackedByteArray = PackedByteArray()
				state.resize(8)
				state.encode_s64(0, game.value)
				request.writer.write_bytes(state)
			Types.Kind.LOAD:
				game.value = request.reader.read_bytes(8).bytes.decode_s64(0)
				game.loads += 1
			Types.Kind.ADVANCE:
				for player: int in range(2):
					game.value += request.inputs.read(player).bytes[0]
		var checksum: PackedByteArray = PackedByteArray()
		checksum.resize(16)
		context.equal(session.complete_request(request.batch_id, request.request_id, true, checksum).code, Types.Code.OK, "complete every recovery request in order")
		request = batch.next_request()
