extends RefCounted

# Value: protects=delayed input publication and mesh confirmation bounds; fails_when=scheduled frames or global receipt minima drift;
# why_new=external transport must reuse the existing rollback core; seam=none
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["delay_startup", "scheduled_sample", "confirmation_limit", "mesh_stall_save"])


func run_case(name: String, context: RefCounted) -> void:
	var settings: RefCounted = Config.new()
	settings.max_snapshot_bytes = 16
	settings.storage_budget_bytes = 65536
	settings.sync_test = false
	settings.local_players = PackedInt32Array([0])
	settings.check_distance = 0
	settings.input_delay = 2
	settings.max_prediction_frames = 2
	var session: RefCounted = Session.new()
	context.equal(session.configure(settings), Session.Code.OK, "configure external delayed core")
	match name:
		"delay_startup":
			var submitted: RefCounted = session.submit_local_input(0, 0, PackedByteArray([7]))
			context.equal(submitted.code, Session.Code.OK, "local delayed sample")
			context.equal(submitted.value, 2, "publish actual scheduled frame")
			context.equal(session.submit_local_input(0, 0, PackedByteArray([7])).value, 2, "retry preserves scheduled frame")
			context.equal(session.receive_input(1, 1, PackedByteArray([8])).code, Session.Code.INVALID_FRAME, "only zero or negotiated delay starts stream")
			context.equal(session.receive_input(1, 3, PackedByteArray([8])).code, Session.Code.INVALID_FRAME, "startup gap beyond delay rejected")
			context.equal(session.receive_input(1, 2, PackedByteArray([8])).code, Session.Code.OK, "scheduled remote startup")
			context.equal(session.receive_input(1, 0, PackedByteArray([0])).code, Session.Code.OK, "neutral prefix immutable")
			context.equal(session.receive_input(1, 1, PackedByteArray([9])).code, Session.Code.INPUT_ALREADY_SUBMITTED, "cannot replace neutral prefix")
			context.equal(session.receive_input(1, 4, PackedByteArray([8])).code, Session.Code.INVALID_FRAME, "later gap rejected")
			context.equal(session.receive_input(1, Queue.FRAME_MAX, PackedByteArray([8])).code, Session.Code.INVALID_FRAME, "extreme gap rejects before insertion")
			context.equal(session.receive_input(1, 3, PackedByteArray([8])).code, Session.Code.OK, "startup preserves next frame")
			for frame: int in range(3):
				if frame > 0:
					context.equal(session.submit_local_input(0, frame, PackedByteArray([7])).code, Session.Code.OK, "next local sample")
				_consume(session, context, frame, PackedByteArray([0, 0]) if frame < 2 else PackedByteArray([7, 8]))
			context.equal(session.configure(settings), Session.Code.OK, "fresh explicit-prefix core")
			for frame: int in range(3):
				context.equal(session.receive_input(1, frame, PackedByteArray([frame])).code, Session.Code.OK, "explicit remote prefix remains supported")
		"scheduled_sample":
			context.equal(session.scheduled_local_input(0).code, Session.Code.MISSING_LOCAL_INPUT, "sample absent")
			context.equal(session.scheduled_local_input(1).code, Session.Code.INVALID_PLAYER, "remote is not a local sample")
			context.equal(session.scheduled_local_input(-1).code, Session.Code.INVALID_PLAYER, "negative slot")
			var bytes: PackedByteArray = PackedByteArray([7])
			session.submit_local_input(0, 0, bytes)
			bytes[0] = 99
			var sample: RefCounted = session.scheduled_local_input(0)
			context.equal(sample.frame, 2, "owned scheduled frame")
			context.equal(sample.bytes, PackedByteArray([7]), "submitted bytes owned")
			sample.bytes[0] = 88
			sample.frame = 99
			context.equal(session.scheduled_local_input(0).bytes, PackedByteArray([7]), "published bytes owned")
			var received: PackedInt64Array = session.received_frames()
			context.equal(received, PackedInt64Array([2, -1]), "actual receipt vector")
			received[0] = 99
			context.equal(session.received_frames(), PackedInt64Array([2, -1]), "receipt vector owned")
			session.receive_input(1, 2, PackedByteArray([8]))
			_consume(session, context, 0, PackedByteArray([0, 0]))
			context.equal(session.scheduled_local_input(0).code, Session.Code.MISSING_LOCAL_INPUT, "successful advance clears publication")
			context.equal(sample.bytes, PackedByteArray([88]), "owned publication survives completion")
			context.equal(session.configure(settings), Session.Code.OK, "fresh stalled publication")
			for frame: int in range(2):
				session.submit_local_input(0, frame, PackedByteArray([7]))
				_consume(session, context, frame, PackedByteArray([0, 0]), Queue.Status.PREDICTED)
			context.equal(session.submit_local_input(0, 2, PackedByteArray([7])).value, 4, "later delayed publication")
			context.equal(session.begin_advance().code, Session.Code.PREDICTION_STALL, "missing remote stalls")
			context.equal(session.scheduled_local_input(0).frame, 4, "stall retains scheduled publication")
			context.equal(session.scheduled_local_input(0).bytes, PackedByteArray([7]), "stall retains submitted bytes")
			context.equal(session.submit_local_input(0, 2, PackedByteArray([7])).value, 4, "stalled retry publishes same frame")
			context.equal(session.submit_local_input(0, 2, PackedByteArray([8])).code, Session.Code.INPUT_ALREADY_SUBMITTED, "stalled sample immutable")
		"mesh_stall_save":
			context.equal(session.set_confirmation_limit(-1).code, Session.Code.OK, "enable source P2P request policy")
			for frame: int in range(2):
				session.submit_local_input(0, frame, PackedByteArray([7]))
				_consume(session, context, frame, PackedByteArray([0, 0]), Queue.Status.PREDICTED)
			session.submit_local_input(0, 2, PackedByteArray([7]))
			for retry: int in range(24):
				var stalled: RefCounted = session.begin_advance()
				context.equal(stalled.code, Session.Code.READY, "stalled P2P exposes current-state save")
				if stalled.batch == null:
					break
				var request: RefCounted = stalled.batch.next_request()
				context.equal(request.kind, Session.Kind.SAVE, "stall saves without advancing")
				context.equal(request.frame, 2, "save current boundary")
				request.writer.write_bytes(PackedByteArray([2]))
				var checksum: PackedByteArray = PackedByteArray()
				checksum.resize(16)
				context.equal(session.complete_request(request.batch_id, request.request_id, true, checksum).code, Session.Code.PREDICTION_STALL, "save completion reports stall")
				context.equal(stalled.batch.next_request(), null, "stall has no simulation callback")
				context.equal(session.status().current_frame, 2, "stall preserves current frame")
				context.equal(session.scheduled_local_input(0).frame, 4, "stall preserves local publication")
			context.equal(session.receive_input(1, 2, PackedByteArray([8])).code, Session.Code.OK, "actual arrives at saved boundary")
			context.equal(session.set_confirmation_limit(1).code, Session.Code.OK, "gossip permits next advance")
			_consume(session, context, 2, PackedByteArray([7, 8]))
			context.equal(session.status().current_frame, 3, "matching boundary resumes without false rollback")
		"confirmation_limit":
			_activation_before_advance(context)
			context.equal(session.set_confirmation_limit(-1).code, Session.Code.OK, "activate mesh bound before simulation")
			session.submit_local_input(0, 0, PackedByteArray([7]))
			session.receive_input(1, 2, PackedByteArray([8]))
			context.equal(session.status().confirmed_frame, -1, "local receipt cannot confirm unobserved mesh")
			context.equal(session.set_confirmation_limit(3).code, Session.Code.INVALID_FRAME, "mesh bound cannot exceed local receipts")
			context.equal(session.set_confirmation_limit(-2).code, Session.Code.INVALID_FRAME, "sentinel lower bound")
			context.equal(session.set_confirmation_limit(0).code, Session.Code.OK, "mesh progress")
			context.equal(session.status().confirmed_frame, 0, "published mesh minimum")
			context.equal(session.set_confirmation_limit(-1).code, Session.Code.INVALID_FRAME, "confirmation never regresses in fixed membership")
			context.equal(session.set_confirmation_limit(Queue.FRAME_MAX + 1).code, Session.Code.INVALID_FRAME, "frame exhaustion bound")
			_consume(session, context, 0, PackedByteArray([0, 0]))
			context.equal(session.set_confirmation_limit(2).code, Session.Code.OK, "monotonic confirmation resumes")
			context.equal(session.status().confirmed_frame, 2, "confirmed unsimulated delayed actual")
			context.equal(session.configure(settings), Session.Code.OK, "configuration resets mesh mode")
			session.submit_local_input(0, 0, PackedByteArray([7]))
			session.receive_input(1, 2, PackedByteArray([8]))
			context.equal(session.status().confirmed_frame, 2, "standalone receipt semantics preserved")
			_consume(session, context, 0, PackedByteArray([0, 0]))
			context.equal(session.set_confirmation_limit(-1).code, Session.Code.INVALID_FRAME, "late activation cannot revoke published history")
			context.equal(session.configure(settings), Session.Code.OK, "fresh guarded bound")
			context.equal(session.set_confirmation_limit(-1).code, Session.Code.OK, "bound enabled")
			session.submit_local_input(0, 0, PackedByteArray([7]))
			session.receive_input(1, 2, PackedByteArray([8]))
			var batch: RefCounted = session.begin_advance().batch
			context.equal(batch != null, true, "active expert batch")
			context.equal(session.set_confirmation_limit(0).code, Session.Code.BUSY, "batch prevents changing prediction bound")
			context.equal(session.status().confirmed_frame, -1, "busy bound preserves confirmation")
			session.terminate()
			context.equal(session.set_confirmation_limit(0).code, Session.Code.TERMINATED, "termination rejects mesh updates")
			settings.sync_test = true
			settings.local_players = PackedInt32Array([0, 1])
			context.equal(session.configure(settings), Session.Code.OK, "sync-test reconfiguration")
			context.equal(session.set_confirmation_limit(-1).code, Session.Code.INVALID_CONFIGURATION, "mesh bounds belong to external mode")
	context.finish()


# Value: protects=confirmation before first advance; fails_when=initial activation revokes receipts; why_new=late activation only tested after advance; seam=none
func _activation_before_advance(context: RefCounted) -> void:
	for delay: int in [0, 2]:
		var settings: Config = Config.new()
		settings.sync_test = false
		settings.local_players = PackedInt32Array([0])
		settings.check_distance = 0
		settings.input_delay = delay
		settings.max_snapshot_bytes = 16
		settings.storage_budget_bytes = 65536
		var session: Session = Session.new()
		context.equal(session.configure(settings), Session.Code.OK, "fresh pre-advance activation boundary")
		context.equal(session.submit_local_input(0, 0, PackedByteArray([7])).code, Session.Code.OK, "retain local actual before activation")
		context.equal(session.receive_input(1, delay, PackedByteArray([8])).code, Session.Code.OK, "retain remote actual before activation")
		context.equal(session.status().current_frame, 0, "no simulation advance at activation boundary")
		context.equal(session.status().confirmed_frame, delay, "actual receipt minimum already published")
		for lower: int in range(-1, delay):
			context.equal(session.set_confirmation_limit(lower).code, Session.Code.INVALID_FRAME,
				"initial activation cannot revoke published confirmation delay=%d limit=%d" % [delay, lower])
			context.equal(session.status().confirmed_frame, delay, "rejected initial activation preserves published confirmation")
			context.equal(session.received_frames(), PackedInt64Array([delay, delay]), "rejected initial activation preserves retained actuals")
			context.equal(session.scheduled_local_input(0).bytes, PackedByteArray([7]), "rejected initial activation preserves scheduled sample")
		context.equal(session.set_confirmation_limit(delay).code, Session.Code.OK, "equal initial activation remains valid before advance")
		context.equal(session.set_confirmation_limit(delay).code, Session.Code.OK, "equal explicit confirmation remains idempotent")
		context.equal(session.set_confirmation_limit(delay + 1).code, Session.Code.INVALID_FRAME, "activation cannot invent higher receipt")
		context.equal(session.status().confirmed_frame, delay, "equal activation preserves public history")
		_consume(session, context, 0, PackedByteArray([7, 8]) if delay == 0 else PackedByteArray([0, 0]))


func _consume(session: RefCounted, context: RefCounted, frame: int, expected: PackedByteArray, remote_status: int = Queue.Status.CONFIRMED) -> void:
	var result: RefCounted = session.begin_advance()
	context.equal(result.code, Session.Code.READY, "available batch")
	if result.batch == null:
		return
	var request: RefCounted = result.batch.next_request()
	while request != null:
		if request.kind == Session.Kind.SAVE:
			request.writer.write_bytes(PackedByteArray([frame]))
		elif request.kind == Session.Kind.ADVANCE:
			context.equal(request.inputs.read(0).bytes, PackedByteArray([expected[0]]), "local canonical input")
			context.equal(request.inputs.read(1).bytes, PackedByteArray([expected[1]]), "remote canonical input")
			context.equal(request.inputs.read(1).status, remote_status, "expected remote input certainty")
		var checksum: PackedByteArray = PackedByteArray()
		checksum.resize(16)
		context.equal(session.complete_request(request.batch_id, request.request_id, true, checksum).code, Session.Code.OK, "consume core request")
		request = result.batch.next_request()
