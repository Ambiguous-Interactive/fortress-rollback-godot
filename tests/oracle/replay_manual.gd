extends RefCounted

const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")

var calls: Array[Dictionary] = []


func step(session: Session, game: RefCounted, now_us: int, samples: Array[Driver.LocalInput]) -> int:
	var before: int = session.status().current_frame
	var code: int = session.poll(now_us).code
	if code == Types.Code.OK:
		for sample: Driver.LocalInput in samples:
			code = session.submit_local_input(sample.player, sample.sample_frame, sample.bytes).code
			if code != Types.Code.OK:
				break
	if code == Types.Code.OK:
		code = consume(session, game, session.begin_advance())
	return _finished(session, "advance", before, code)


func recover(session: Session, game: RefCounted, now_us: int) -> int:
	var before: int = session.status().current_frame
	var code: int = session.poll(now_us).code
	if code == Types.Code.OK:
		code = consume(session, game, session.begin_recovery())
	return _finished(session, "recover", before, code)


func capture(session: Session, game: RefCounted) -> int:
	var before: int = session.status().current_frame
	return _finished(session, "capture", before, consume(session, game, session.begin_capture_replay_boundary()))


func consume(session: Session, game: RefCounted, opened: Types.Result) -> int:
	if opened.code != Types.Code.READY:
		return opened.code
	while true:
		var request: Types.Request = opened.batch.next_request()
		if request == null:
			return Types.Code.OK
		var checksum: PackedByteArray = PackedByteArray()
		var ok: bool = false
		match request.kind:
			Types.Kind.SAVE:
				var saved: Driver.SaveResult = game.save_state(request.frame, request.writer)
				ok = saved.ok
				checksum = saved.checksum
			Types.Kind.LOAD:
				ok = game.load_state(request.frame, request.reader)
			Types.Kind.ADVANCE:
				ok = game.simulate_frame(request.frame, request.inputs)
			_:
				return Types.Code.UNSUPPORTED
		var code: int = session.complete_request(request.batch_id, request.request_id, ok, checksum).code
		if code != Types.Code.OK:
			return code
	return Types.Code.OK


func _finished(session: Session, operation: String, before: int, code: int) -> int:
	calls.append({"operation": operation, "before": before, "after": session.status().current_frame, "code": code})
	return code
