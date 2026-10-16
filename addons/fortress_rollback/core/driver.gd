class_name FortressDriver
extends RefCounted

## Completed outer step, after ordered callbacks and event collection. Reentrant driver calls remain BUSY.
signal step_completed(code: int, frame_before: int, frame_after: int)

# gdlint: disable=max-returns
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


class LocalInput:
	extends RefCounted
	var player: int
	var sample_frame: int
	var bytes: PackedByteArray

	func _init(slot: int, frame: int, sample: PackedByteArray) -> void:
		player = slot
		sample_frame = frame
		bytes = sample.duplicate()


class SaveResult:
	extends RefCounted
	var ok: bool
	var checksum: PackedByteArray

	func _init(callback_ok: bool = true, saved_checksum: PackedByteArray = PackedByteArray()) -> void:
		ok = callback_ok
		checksum = saved_checksum.duplicate()


class StepResult:
	extends RefCounted
	var code: int
	var frame_before: int
	var frame_after: int
	var events: Array[RefCounted] = []

	func _init(result_code: int, before: int, after: int) -> void:
		code = result_code
		frame_before = before
		frame_after = after


var _session: Session
var _game: RefCounted
var _is_stepping: bool = false


func _init(session: Session = null, game: RefCounted = null) -> void:
	if session != null or game != null:
		configure(session, game)


## Game supplies save_state -> SaveResult and load_state/simulate_frame -> bool.
func configure(session: Session, game: RefCounted) -> int:
	if _is_stepping:
		return Types.Code.BUSY
	if session == null or game == null:
		return Types.Code.INVALID_CONFIGURATION
	for method: String in ["save_state", "load_state", "simulate_frame"]:
		if not game.has_method(method):
			return Types.Code.INVALID_CONFIGURATION
	_session = session
	_game = game
	return Types.Code.OK


## Consume the session's ordered requests; simulation and recovery policy stay in session.
func step(now_us: int, local_inputs: Array[LocalInput]) -> StepResult:
	var before: int = _session.status().current_frame if _session != null else 0
	if _is_stepping:
		return StepResult.new(Types.Code.BUSY, before, before)
	if _session == null or _game == null:
		return StepResult.new(Types.Code.NOT_CONFIGURED, before, before)
	_is_stepping = true
	var code: int = _session.poll(now_us).code
	if code != Types.Code.OK:
		return _finish(code, before)
	for sample: LocalInput in local_inputs:
		if sample == null:
			return _finish(Types.Code.INVALID_CONFIGURATION, before)
		code = _session.submit_local_input(sample.player, sample.sample_frame, sample.bytes).code
		if code != Types.Code.OK:
			return _finish(code, before)
	var advance: Types.Result = _session.begin_advance()
	if advance.code != Types.Code.READY:
		return _finish(advance.code, before)
	while true:
		var request: Types.Request = advance.batch.next_request()
		if request == null:
			var status: Types.Status = _session.status()
			if status.lifecycle == Types.Lifecycle.TERMINATED:
				code = status.reason
			return _finish(code, before)
		# Capture identities before application callbacks can edit request metadata.
		var batch_id: int = request.batch_id
		var request_id: int = request.request_id
		var ok: bool = false
		var checksum: PackedByteArray = PackedByteArray()
		code = _session._begin_driver_callback()
		if code != Types.Code.OK:
			return _finish(code, before)
		match request.kind:
			Types.Kind.SAVE:
				var saved: SaveResult = _game.save_state(request.frame, request.writer)
				if saved != null:
					ok = saved.ok
					checksum = saved.checksum
			Types.Kind.LOAD:
				ok = _game.load_state(request.frame, request.reader)
			Types.Kind.ADVANCE:
				ok = _game.simulate_frame(request.frame, request.inputs)
		_session._end_driver_callback()
		code = _session.complete_request(batch_id, request_id, ok, checksum).code
		if code != Types.Code.OK:
			return _finish(code, before)
	return _finish(code, before)


func _finish(code: int, before: int) -> StepResult:
	var result: StepResult = StepResult.new(code, before, _session.status().current_frame)
	# An externally opened expert batch owns its events until completion.
	if code != Types.Code.BUSY:
		result.events = _session.drain_events()
		step_completed.emit(result.code, result.frame_before, result.frame_after)
	_is_stepping = false
	return result
