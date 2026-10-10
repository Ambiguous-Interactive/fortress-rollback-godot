extends SceneTree

# Executes submitted operations through the shipped session. Oracle requests are
# used only by the external comparator, never to choose game callbacks here.
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const SnapshotStatus = preload("res://addons/fortress_rollback/core/snapshot_status.gd")
const ReferenceGame = preload("res://tests/oracle/reference_game.gd")
const TraceSchema = preload("res://tests/oracle/trace_schema.gd")
const PREFIX: String = "FORTRESS_ORACLE_SESSION_RESULT "

var _session: RefCounted
var _game: RefCounted
var _trace: Dictionary = {}
var _error: String = ""


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() != 2 or args[0] != "--trace":
		_finish("expected --trace PATH")
		return
	var file: FileAccess = FileAccess.open(args[1], FileAccess.READ)
	if file == null:
		_finish("cannot read trace")
		return
	var parser: JSON = JSON.new()
	if parser.parse(file.get_as_text()) != OK or not parser.data is Dictionary:
		_finish("trace is not a JSON object")
		return
	var source: Dictionary = parser.data
	var schema_error: String = TraceSchema.validate(source)
	if not schema_error.is_empty():
		_finish(schema_error)
		return
	var scenario: Dictionary = _canonical_scenario(source["scenario"])
	var configuration: RefCounted = Config.new()
	configuration.player_count = int(scenario["players"])
	configuration.local_players = PackedInt32Array()
	for player: int in range(configuration.player_count):
		configuration.local_players.append(player)
	configuration.input_width = 4
	configuration.neutral_input = PackedByteArray([0, 0, 0, 0])
	configuration.input_delay = int(scenario["input_delay"])
	configuration.check_distance = int(scenario["check_distance"])
	configuration.max_snapshot_bytes = 4 * (configuration.player_count + (3 if scenario["format"] == 2 else 1))
	configuration.storage_budget_bytes = 1048576
	_session = Session.new()
	if _session.configure(configuration) != Types.Code.OK:
		_finish("session configuration rejected")
		return
	_game = ReferenceGame.new(configuration.player_count, int(scenario["format"]))
	var operations: Array[Dictionary] = []
	var sources: Array = scenario["operations"]
	for index: int in range(sources.size()):
		operations.append(_operation(sources[index], index))
		if not _error.is_empty():
			_finish(_error)
			return
	_trace = {
		"format": int(scenario["format"]),
		"upstream_revision": source["upstream_revision"],
		"scenario": scenario,
		"operations": operations,
		"final_state": {"frame": _game.frame, "bytes": _game.bytes().hex_encode(), "checksum": _game.checksum()},
	}
	_finish("")


# Both engines parse JSON numbers as floats, but stringify their integral values
# differently. Rebuild validated scenario fields in the format's integer domain.
func _canonical_scenario(source: Dictionary) -> Dictionary:
	var scenario: Dictionary = {
		"upstream_revision": source["upstream_revision"],
		"operations": [],
	}
	for field: String in ["format", "players", "input_width", "check_distance", "input_delay"]:
		scenario[field] = int(source[field])
	var operations: Array[Dictionary] = []
	for source_operation: Dictionary in source["operations"]:
		var operation: Dictionary = {"kind": source_operation["kind"]}
		if source_operation["kind"] == "input":
			operation["player"] = int(source_operation["player"])
			operation["bytes"] = source_operation["bytes"]
		operations.append(operation)
	scenario["operations"] = operations
	return scenario


func _operation(source: Dictionary, index: int) -> Dictionary:
	var before: int = _session.status().current_frame
	var code: int = Types.Code.OK
	var requests: Array[Dictionary] = []
	var events: Array = []
	match source["kind"]:
		"input":
			code = _session.submit_local_input(int(source["player"]), before, String(source["bytes"]).hex_decode()).code
		"events":
			events = _session.drain_events()
		"advance":
			var result: RefCounted = _session.begin_advance()
			code = result.code
			if code == Types.Code.READY:
				code = _consume(result.batch, requests)
	if _session.status().current_frame != _game.frame:
		_error = "operation %d: session/game frame mismatch" % index
	# Variant represents JSON null at this serialization boundary only.
	var diagnostic: Variant = null if code == Types.Code.OK else Types.Code.find_key(code)
	return {
		"index": index,
		"kind": source["kind"],
		"result": "ok" if code == Types.Code.OK else "error",
		"error": diagnostic,
		"frame_before": before,
		"frame_after": _session.status().current_frame,
		"confirmed_frame": null,
		"requests": requests,
		"events": events,
	}


func _consume(batch: RefCounted, requests: Array[Dictionary]) -> int:
	var request: RefCounted = batch.next_request()
	while request != null:
		if requests.size() >= 260:
			_error = "unbounded request batch"
			return Types.Code.CALLBACK_FAILED
		var frame: int = request.frame
		var kind: String = ""
		var inputs: Array[Dictionary] = []
		var checksum: PackedByteArray = PackedByteArray()
		var error: String = ""
		match request.kind:
			Types.Kind.SAVE:
				kind = "save"
				if frame != _game.frame or request.writer.write_bytes(_game.bytes()) != SnapshotStatus.Code.OK:
					error = "invalid save boundary"
				checksum = _game.checksum().hex_decode()
				checksum.reverse()
			Types.Kind.LOAD:
				kind = "load"
				var result: RefCounted = request.reader.read_bytes(_game.bytes().size())
				if result.code != SnapshotStatus.Code.OK:
					error = "invalid load read"
				else:
					error = _game.restore(result.bytes)
				if _game.frame != frame:
					error = "invalid load boundary"
			Types.Kind.ADVANCE:
				kind = "advance"
				var count: RefCounted = request.inputs.size()
				if count.code != Types.Code.OK or count.value != _game.accumulators.size() or frame != _game.frame:
					error = "invalid advance boundary"
				else:
					for player: int in range(count.value):
						var input: RefCounted = request.inputs.read(player)
						if input.code != Types.Code.OK or input.status not in [Queue.Status.CONFIRMED, Queue.Status.PREDICTED]:
							error = "invalid input view or status"
							break
						inputs.append({"player": player, "bytes": input.bytes.hex_encode(), "status": "confirmed" if input.status == Queue.Status.CONFIRMED else "predicted"})
					if error.is_empty():
						error = _game.advance(inputs)
			_:
				error = "unknown request kind"
		var completion: RefCounted = _session.complete_request(request.batch_id, request.request_id, error.is_empty(), checksum)
		if not error.is_empty() or completion.code != Types.Code.OK:
			_error = "request %d: %s (completion %s)" % [requests.size(), error, Types.Code.find_key(completion.code)]
			return completion.code
		requests.append({"kind": kind, "frame": frame, "state_bytes": _game.bytes().hex_encode(), "checksum": _game.checksum(), "inputs": inputs})
		request = batch.next_request()
	return Types.Code.OK


func _finish(error: String) -> void:
	var errors: Array[String] = []
	if not error.is_empty():
		errors.append(error)
	var result: Dictionary = {
		"format": 1,
		"complete": true,
		"passed": errors.is_empty(),
		"engine_version": Engine.get_version_info()["string"],
		"errors": errors,
		"trace": _trace,
	}
	print(PREFIX + JSON.stringify(result))
	quit(0 if errors.is_empty() else 1)
