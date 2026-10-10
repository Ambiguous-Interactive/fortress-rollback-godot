extends RefCounted

# Value: protects=ordered rollback and expert lifecycle; fails_when=requests, ownership or stalls drift;
# why_new=first production session; seam=none
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["first_tick", "validation", "busy", "prediction", "remote_gap", "input_view"])


func run_case(name: String, context: RefCounted) -> void:
	var settings: RefCounted = Config.new()
	settings.max_snapshot_bytes = 16
	settings.storage_budget_bytes = 65536
	var session: RefCounted = Session.new()
	context.equal(session.configure(settings), Session.Code.OK, "configure")
	match name:
		"first_tick":
			context.equal(session.begin_advance().code, Session.Code.MISSING_LOCAL_INPUT, "missing samples")
			for player: int in range(2):
				context.equal(session.submit_local_input(player, 0, PackedByteArray([player])).code, Session.Code.OK, "sample")
			var result: RefCounted = session.begin_advance()
			context.equal(result.code, Session.Code.READY, "ready")
			var request: RefCounted = result.batch.next_request()
			context.equal(request.frame, 0, "save S(0)")
			context.equal(request.kind, Session.Kind.SAVE, "save before advance")
			request.writer.write_bytes(PackedByteArray([0]))
			context.equal(session.complete_request(request.batch_id, request.request_id, true, _checksum()).code, Session.Code.OK, "complete save")
			context.equal(request.writer.status(), request.writer.Code.EXPIRED_VIEW, "expired save")
			request = result.batch.next_request()
			context.equal(request.kind, Session.Kind.ADVANCE, "advance")
			context.equal(request.inputs.read(1).bytes, PackedByteArray([1]), "slot order")
			context.equal(session.status().current_frame, 0, "commit after callbacks")
			context.equal(session.complete_request(request.batch_id, request.request_id, true).code, Session.Code.OK, "complete advance")
			context.equal(session.status().current_frame, 1, "frame committed")
			context.equal(result.batch.next_request(), null, "batch consumed")
		"validation":
			context.equal(session.submit_local_input(2, 0, PackedByteArray([0])).code, Session.Code.INVALID_PLAYER, "slot bound")
			context.equal(session.submit_local_input(0, 1, PackedByteArray([0])).code, Session.Code.INVALID_FRAME, "current sample only")
			context.equal(session.submit_local_input(0, 0, PackedByteArray()).code, Session.Code.INPUT_WIDTH, "fixed width")
			context.equal(session.poll(-1).code, Session.Code.INVALID_TIME, "negative time")
			context.equal(session.poll(20).code, Session.Code.OK, "time")
			context.equal(session.poll(19).code, Session.Code.INVALID_TIME, "backward time")
			context.equal(session.submit_local_input(0, 0, PackedByteArray([4])).code, Session.Code.OK, "first sample")
			context.equal(session.submit_local_input(0, 0, PackedByteArray([4])).code, Session.Code.OK, "same retry")
			context.equal(session.submit_local_input(0, 0, PackedByteArray([5])).code, Session.Code.INPUT_ALREADY_SUBMITTED, "conflict")
		"busy":
			for player: int in range(2):
				session.submit_local_input(player, 0, PackedByteArray([0]))
			var batch: RefCounted = session.begin_advance().batch
			var request: RefCounted = batch.next_request()
			context.equal(session.poll(0).code, Session.Code.BUSY, "busy poll")
			context.equal(session.begin_advance().code, Session.Code.BUSY, "busy advance")
			context.equal(session.submit_local_input(0, 0, PackedByteArray([0])).code, Session.Code.BUSY, "busy sample")
			context.equal(session.complete_request(request.batch_id, request.request_id + 1, true).code, Session.Code.STALE_REQUEST, "out of order")
			context.equal(session.complete_request(request.batch_id, request.request_id, false).code, Session.Code.CALLBACK_FAILED, "failed callback")
			context.equal(session.status().lifecycle, Session.Lifecycle.TERMINATED, "terminal")
			context.equal(session.status().current_frame, 0, "no false completion")
			context.equal(request.writer.status(), request.writer.Code.EXPIRED_VIEW, "abort expires")
		"remote_gap":
			settings.sync_test = false
			settings.local_players = PackedInt32Array([0])
			settings.check_distance = 0
			context.equal(session.configure(settings), Session.Code.OK, "external core")
			context.equal(session.receive_input(1, 3, PackedByteArray([9])).code, Session.Code.INVALID_FRAME, "initial remote gap rejected")
			for frame: int in range(4):
				context.equal(session.receive_input(1, frame, PackedByteArray([7])).code, Session.Code.OK, "explicit remote prefix")
			context.equal(session.receive_input(1, 3, PackedByteArray([7])).code, Session.Code.OK, "identical repeat")
			context.equal(session.receive_input(1, 3, PackedByteArray([8])).code, Session.Code.INPUT_ALREADY_SUBMITTED, "confirmed immutable")
			context.equal(session.receive_input(1, 5, PackedByteArray([9])).code, Session.Code.INVALID_FRAME, "later gap rejected")
			context.equal(session.receive_input(1, 4, PackedByteArray([6])).code, Session.Code.OK, "gap rejection preserves next frame")
		"input_view":
			for player: int in range(2):
				session.submit_local_input(player, 0, PackedByteArray([player]))
			var batch: RefCounted = session.begin_advance().batch
			var saved: RefCounted = batch.next_request()
			session.complete_request(saved.batch_id, saved.request_id, true, _checksum())
			var request: RefCounted = batch.next_request()
			context.equal(request.inputs.has_method("append"), false, "request inputs have no roster mutation API")
			if request.inputs.has_method("append"):
				request.inputs.append(PackedByteArray([99]), 0)
			context.equal(request.inputs.size().value, 2, "roster fixed during callback")
			context.equal(request.inputs.read(2).code, Session.Code.INVALID_PLAYER, "no injected slot")
			session.complete_request(request.batch_id, request.request_id, true)
			context.equal(request.inputs.has_method("append"), false, "retained view cannot allocate roster")
			context.equal(request.inputs.size().code, Session.Code.EXPIRED_VIEW, "view expired")
			context.equal(request.inputs.has_method("expire"), false, "expiration belongs to session")
			var source: Array[PackedByteArray] = [PackedByteArray([5]), PackedByteArray([6])]
			var statuses: PackedInt32Array = PackedInt32Array([1, 2])
			var view: RefCounted = Types.FrameInputs.new(source, statuses)
			source[0][0] = 99
			source.append(PackedByteArray([7]))
			statuses[0] = 99
			context.equal(view.size().value, 2, "constructor owns roster")
			context.equal(view.read(0).status, 1, "constructor owns statuses")
			context.equal(view.read(0).bytes, PackedByteArray([5]), "constructor owns nested bytes")
		"prediction":
			settings.sync_test = false
			settings.local_players = PackedInt32Array([0])
			settings.max_prediction_frames = 2
			settings.check_distance = 0
			context.equal(session.configure(settings), Session.Code.OK, "external core")
			for frame: int in range(2):
				session.submit_local_input(0, frame, PackedByteArray([1]))
				_consume(session, session.begin_advance().batch, context)
			session.submit_local_input(0, 2, PackedByteArray([1]))
			context.equal(session.begin_advance().code, Session.Code.PREDICTION_STALL, "exact prediction edge")
			context.equal(session.status().current_frame, 2, "stall preserves frame")
			context.equal(session.receive_input(1, 0, PackedByteArray([0])).code, Session.Code.OK, "matching remote")
			context.equal(session.status().confirmed_frame, 0, "global minimum")
			context.equal(session.begin_advance().code, Session.Code.PREDICTION_STALL, "confirmed zero still stalls")
	context.finish()


func _consume(session: RefCounted, batch: RefCounted, context: RefCounted) -> void:
	context.equal(batch != null, true, "available batch")
	if batch == null:
		return
	var request: RefCounted = batch.next_request()
	while request != null:
		if request.kind == Session.Kind.SAVE:
			request.writer.write_bytes(PackedByteArray([request.frame]))
		context.equal(session.complete_request(request.batch_id, request.request_id, true, _checksum()).code, Session.Code.OK, "consume")
		request = batch.next_request()


func _checksum() -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(16)
	return bytes
