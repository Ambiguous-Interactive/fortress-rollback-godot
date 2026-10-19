class_name FortressDriver
extends RefCounted

## Completed step or recovery, after ordered callbacks and event collection. Reentrant driver calls remain BUSY.
signal step_completed(code: int, frame_before: int, frame_after: int)

# gdlint: disable=max-returns
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Writer = preload("res://addons/fortress_rollback/core/snapshot_writer.gd")
const Reader = preload("res://addons/fortress_rollback/core/snapshot_reader.gd")


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
# Config validates at most eight player slots; indices borrow only this step's input list.
var _sample_indices: PackedInt64Array = PackedInt64Array([-1, -1, -1, -1, -1, -1, -1, -1])


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
		if not accepts_callback_arguments(game, method):
			return Types.Code.INVALID_CONFIGURATION
	_session = session
	_game = game
	return Types.Code.OK


## Whether a game method accepts the frame and view arguments supplied by the driver.
## Rejects incompatible reflected types. Erased script annotations and implementation remain the game's responsibility.
static func accepts_callback_arguments(game: RefCounted, name: String) -> bool:
	if game == null:
		return false
	for method: Dictionary in game.get_method_list():
		if method.name != name:
			continue
		var argument_count: int = method.args.size()
		var required_count: int = argument_count - method.default_args.size()
		var is_vararg: bool = (method.flags & METHOD_FLAG_VARARG) != 0
		if required_count > 2 or (argument_count < 2 and not is_vararg):
			return false
		if argument_count > 0 and method.args[0].type not in [TYPE_NIL, TYPE_INT, TYPE_FLOAT]:
			return false
		if argument_count > 1:
			var view_argument: Dictionary = method.args[1]
			if view_argument.type not in [TYPE_NIL, TYPE_OBJECT]:
				return false
			if view_argument.type == TYPE_OBJECT and not _accepts_view_class(view_argument.class_name, name):
				return false
		return true
	return false


static func _accepts_view_class(view_class: StringName, method: String) -> bool:
	if view_class == &"":
		return true
	if ClassDB.class_exists(view_class):
		return ClassDB.is_parent_class("RefCounted", view_class)
	var script: Script = Writer if method == "save_state" else (Reader if method == "load_state" else Types.FrameInputs)
	while script != null:
		if script.get_global_name() == view_class:
			return true
		script = script.get_base_script()
	return false


## Consume the session's ordered requests; simulation and recovery policy stay in session.
func step(now_us: int, local_inputs: Array[LocalInput]) -> StepResult:
	return _step(now_us, local_inputs, true)


## Apply pending corrections and finalize confirmed recording history without advancing a new frame.
## Preserves staged samples and emits step_completed after ordered recovery callbacks.
func recover(now_us: int) -> StepResult:
	var empty: Array[LocalInput] = []
	return _step(now_us, empty, false)


func _step(now_us: int, local_inputs: Array[LocalInput], allow_advance: bool) -> StepResult:
	var before: int = _session.status().current_frame if _session != null else 0
	if _is_stepping:
		return StepResult.new(Types.Code.BUSY, before, before)
	if _session == null or _game == null:
		return StepResult.new(Types.Code.NOT_CONFIGURED, before, before)
	_is_stepping = true
	var code: int = _session.poll(now_us).code
	if code != Types.Code.OK:
		return _finish(code, before)
	if allow_advance:
		# Reject malformed lists before any valid prefix becomes a retained stalled sample.
		_sample_indices.fill(-1)
		for index: int in range(local_inputs.size()):
			var sample: LocalInput = local_inputs[index]
			if sample == null:
				return _finish(Types.Code.INVALID_CONFIGURATION, before)
			code = _session.validate_local_input(sample.player, sample.sample_frame, sample.bytes)
			if code != Types.Code.OK:
				return _finish(code, before)
			var prior_index: int = _sample_indices[sample.player]
			if prior_index != -1 and local_inputs[prior_index].bytes != sample.bytes:
				return _finish(Types.Code.INPUT_ALREADY_SUBMITTED, before)
			_sample_indices[sample.player] = index
		for player: int in range(_sample_indices.size()):
			if _sample_indices[player] != -1 or _session.input_delay(player) < 0:
				continue
			if _session.scheduled_local_input(player).code == Types.Code.MISSING_LOCAL_INPUT:
				# No batch can open without this sample. Let the engine prioritize terminal exhaustion.
				return _finish(_session.begin_advance().code, before)
		for index: int in _sample_indices:
			if index == -1:
				continue
			var sample: LocalInput = local_inputs[index]
			code = _session.submit_local_input(sample.player, sample.sample_frame, sample.bytes).code
			if code != Types.Code.OK:
				return _finish(code, before)
	var advance: Types.Result = _session.begin_advance() if allow_advance else _session.begin_recovery()
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
				# Callback results cross the dynamic application boundary before validation.
				var saved: Variant = _game.save_state(request.frame, request.writer)
				if saved is SaveResult:
					ok = saved.ok
					checksum = saved.checksum
			Types.Kind.LOAD:
				var loaded: Variant = _game.load_state(request.frame, request.reader)
				ok = loaded is bool and loaded
			Types.Kind.ADVANCE:
				var simulated: Variant = _game.simulate_frame(request.frame, request.inputs)
				ok = simulated is bool and simulated
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
