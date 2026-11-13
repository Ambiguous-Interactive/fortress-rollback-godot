extends SceneTree

# Executes the canonical global-floor schedule through the shipped session for the
# sync-floor oracle. Requests are consumed in order and never choose game callbacks;
# floor and retained-row observations read the session's public floor and each
# queue's own confirmed reads.
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const SnapshotStatus = preload("res://addons/fortress_rollback/core/snapshot_status.gd")
const PREFIX: String = "FORTRESS_SYNC_FLOOR_RESULT "
const REVISION: String = "d124c89080004d96971a629bb0427056ee1805e3"
const KIND_FIELDS: Dictionary = {
	"receive": ["player", "frame", "bytes"],
	"submit": ["player", "frame", "bytes"],
	"delay": ["player", "value"],
	"observe": [],
	"advance": [],
}


class Game:
	extends RefCounted

	# Sixteen-byte canonical state: frame, rng, pending, total as little-endian u32.
	var frame: int = 0
	var rng: int = 8173
	var pending: int = 0
	var total: int = 0

	func bytes() -> PackedByteArray:
		var state: PackedByteArray = PackedByteArray()
		state.resize(16)
		state.encode_u32(0, frame)
		state.encode_u32(4, rng)
		state.encode_u32(8, pending)
		state.encode_u32(12, total)
		return state

	func restore(state: PackedByteArray) -> String:
		if state.size() != 16:
			return "state bytes must be sixteen"
		frame = state.decode_u32(0)
		rng = state.decode_u32(4)
		pending = state.decode_u32(8)
		total = state.decode_u32(12)
		return ""

	func checksum() -> String:
		# FNV-1a over the sixteen state bytes; int64 arithmetic wraps, which is
		# exactly the mod-2**64 value, so the halves format the unsigned digest.
		var hash: int = 0xcbf29ce4 * 4294967296 + 0x84222325
		for byte: int in bytes():
			hash = (hash ^ byte) * 1099511628211
		return _u64_hex(~hash) + _u64_hex(hash)

	func _u64_hex(value: int) -> String:
		return "%08x%08x" % [(value >> 32) & 0xFFFFFFFF, value & 0xFFFFFFFF]

	func simulate(values: PackedByteArray) -> void:
		rng = (rng * 1664525 + 1013904223) & 4294967295
		total = (total + pending + (rng & 255)) & 4294967295
		pending = 0
		for player: int in range(values.size()):
			pending += (player + 1) * values[player]
		frame += 1


var _session: RefCounted
var _game: RefCounted
var _operations: Array = []
var _error: String = ""


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() != 2 or args[0] != "--artifact":
		_error = "expected --artifact PATH"
		_fail(_error)
		return
	var file: FileAccess = FileAccess.open(args[1], FileAccess.READ)
	if file == null:
		_error = "cannot read artifact"
		_fail(_error)
		return
	var parser: JSON = JSON.new()
	if parser.parse(file.get_as_text()) != OK or not parser.data is Dictionary:
		_error = "artifact is not a JSON object"
		_fail(_error)
		return
	_execute(parser.data)
	if _error.is_empty():
		print(PREFIX + JSON.stringify({"format": 1, "operations": _operations}))
		quit(0)
	else:
		_fail(_error)


func _execute(source: Dictionary) -> void:
	var problem: String = _artifact_problem(source)
	if not problem.is_empty():
		_error = problem
		return
	var operations: Array = source["operations"]
	var configuration: RefCounted = Config.new()
	configuration.player_count = 3
	configuration.local_players = PackedInt32Array([0])
	configuration.input_width = 1
	configuration.neutral_input = PackedByteArray([0])
	configuration.input_delay = 0
	configuration.check_distance = 0
	configuration.sync_test = false
	configuration.max_prediction_frames = 4
	configuration.history_slots = 5
	configuration.queue_capacity = 9
	configuration.max_snapshot_bytes = 16
	configuration.storage_budget_bytes = 65536
	_session = Session.new()
	if _session.configure(configuration) != Types.Code.OK:
		_error = "session configuration rejected"
		return
	_game = Game.new()
	for index: int in range(operations.size()):
		_operations.append(_operation(operations[index], index))
		if not _error.is_empty():
			return


func _artifact_problem(source: Dictionary) -> String:
	for field: String in ["upstream_revision", "players", "max_prediction", "queue_capacity", "input_width", "input_delay", "operations"]:
		if not source.has(field):
			return "artifact missing " + field
	if source["upstream_revision"] != REVISION:
		return "stale upstream revision"
	if (
		not _whole(source["players"])
		or not _whole(source["max_prediction"])
		or not _whole(source["queue_capacity"])
		or not _whole(source["input_width"])
		or not _whole(source["input_delay"])
		or int(source["players"]) != 3
		or int(source["max_prediction"]) != 4
		or int(source["queue_capacity"]) != 9
		or int(source["input_width"]) != 1
		or int(source["input_delay"]) != 0
	):
		return "artifact outside the canonical floor configuration"
	var operations: Array = source["operations"]
	if operations.is_empty():
		return "artifact has no operations"
	for index: int in range(operations.size()):
		if not _scheduled(operations[index]):
			return "operation %d violates the artifact schema" % index
	return ""


func _scheduled(source: Dictionary) -> bool:
	if not KIND_FIELDS.has(source.get("kind")):
		return false
	var expected: Array = ["kind"]
	expected.append_array(KIND_FIELDS[source["kind"]])
	var keys_ok: bool = source.keys().all(func(key: Variant) -> bool: return key in expected)
	var fields_ok: bool = KIND_FIELDS[source["kind"]].all(func(field: Variant) -> bool: return source.has(field) and (field == "bytes" or _whole(source[field])))
	var ranges_ok: bool = ["player", "frame", "value"].all(func(field: Variant) -> bool: return not source.has(field) or source[field] >= 0)
	var player_ok: bool = not source.has("player") or (source["player"] >= 0 and source["player"] <= 2)
	var bytes_ok: bool = not source.has("bytes") or (source["bytes"] is String and _hex_bytes(source["bytes"]))
	return keys_ok and fields_ok and ranges_ok and player_ok and bytes_ok


func _whole(value: Variant) -> bool:
	# JSON numbers arrive as floats; both engines rebuild validated fields in the integer domain.
	return value is int or (value is float and value == floor(value) and value >= 0 and value <= 2147483647)


func _hex_bytes(value: String) -> bool:
	if value.length() != 2:
		return false
	for character: String in value:
		if character not in "0123456789abcdef":
			return false
	return true


func _operation(source: Dictionary, index: int) -> Dictionary:
	var record: Dictionary = {"index": index, "kind": source["kind"]}
	match source["kind"]:
		"receive":
			var code: int = _session.receive_input(int(source["player"]), int(source["frame"]), source["bytes"].hex_decode()).code
			record["player"] = int(source["player"])
			record["frame"] = int(source["frame"])
			record["bytes"] = source["bytes"]
			record["accepted"] = code == Types.Code.OK
		"submit":
			var result: RefCounted = _session.submit_local_input(int(source["player"]), int(source["frame"]), source["bytes"].hex_decode())
			record["player"] = int(source["player"])
			record["frame"] = int(source["frame"])
			record["bytes"] = source["bytes"]
			record["accepted"] = result.code == Types.Code.OK
			record["scheduled"] = result.value
		"delay":
			var result: RefCounted = _session.set_input_delay(int(source["player"]), int(source["value"]))
			record["player"] = int(source["player"])
			record["value"] = int(source["value"])
			record["ok"] = result.code == Types.Code.OK
			record["frame_delay"] = _session._queues[0].frame_delay() if record["ok"] else null
			record["last_added"] = _session._queues[0]._last_added if record["ok"] else null
		"observe":
			record.merge(_observe())
		"advance":
			var executed: RefCounted = _session.begin_advance()
			var requests: Array = []
			if executed.code == Types.Code.READY:
				var failure: String = _consume(executed.batch, requests)
				if not failure.is_empty():
					_error = "operation %d: %s" % [index, failure]
			record["advanced"] = executed.code == Types.Code.READY and _error.is_empty()
			record["confirmed_frame"] = _session.status().confirmed_frame
			record["requests"] = requests
		_:
			_error = "operation %d: unknown kind" % index
	return record


func _observe() -> Dictionary:
	var floor_value: int = _session.rollback_floor()
	var players: Array = []
	for player: int in range(_session._queues.size()):
		var queue: RefCounted = _session._queues[player]
		var span: PackedInt64Array = queue.retained_frame_range()
		var confirmed: RefCounted = queue.confirmed_input(floor_value)
		var retained: RefCounted = queue.retained_confirmed_input(floor_value)
		(
			players
			. append(
				{
					"range": null if span.is_empty() else [span[0], span[1]],
					"confirmed_floor": confirmed.bytes.hex_encode() if confirmed.code == Queue.Code.OK else null,
					"retained_floor": retained.bytes.hex_encode() if retained.code == Queue.Code.OK else null,
				}
			)
		)
	return {"floor": floor_value, "players": players}


func _consume(batch: RefCounted, requests: Array) -> String:
	var request: RefCounted = batch.next_request()
	while request != null:
		if requests.size() >= 4000:
			return "unbounded request batch"
		var failure: String = _request(request, requests)
		if not failure.is_empty():
			return failure
		request = batch.next_request()
	return ""


func _request(request: RefCounted, requests: Array) -> String:
	var kind: String = ""
	var inputs: Array = []
	var checksum: PackedByteArray = PackedByteArray()
	var failure: String = ""
	match request.kind:
		Types.Kind.SAVE:
			kind = "save"
			if request.frame != _game.frame or request.writer.write_bytes(_game.bytes()) != SnapshotStatus.Code.OK:
				failure = "invalid save boundary"
			checksum = _checksum_bytes()
		Types.Kind.LOAD:
			kind = "load"
			var restored: RefCounted = request.reader.read_bytes(16)
			if restored.code != SnapshotStatus.Code.OK or not request.reader.is_complete():
				failure = "invalid load read"
			else:
				failure = _game.restore(restored.bytes)
		Types.Kind.ADVANCE:
			kind = "advance"
			var count: RefCounted = request.inputs.size()
			if count.code != Types.Code.OK or count.value != 3 or request.frame != _game.frame:
				failure = "invalid advance boundary"
			else:
				var values: PackedByteArray = PackedByteArray()
				for player: int in range(count.value):
					var input: RefCounted = request.inputs.read(player)
					if input.code != Types.Code.OK or input.bytes.size() != 1:
						return "invalid input view"
					values.append(input.bytes[0])
					inputs.append(
						{
							"player": player,
							"bytes": input.bytes.hex_encode(),
							"status": "confirmed" if input.status == Queue.Status.CONFIRMED else "predicted" if input.status == Queue.Status.PREDICTED else "disconnected"
						}
					)
				if failure.is_empty():
					_game.simulate(values)
			checksum = _checksum_bytes()
		_:
			failure = "unknown request kind"
	var completion: RefCounted = _session.complete_request(request.batch_id, request.request_id, failure.is_empty(), checksum)
	if not failure.is_empty() or completion.code != Types.Code.OK:
		return "%s (completion %s)" % [failure, Types.Code.find_key(completion.code)]
	requests.append({"kind": kind, "frame": request.frame, "state_bytes": _game.bytes().hex_encode(), "checksum": _game.checksum(), "inputs": inputs})
	return ""


func _checksum_bytes() -> PackedByteArray:
	return _game.checksum().hex_decode()


func _fail(reason: String) -> void:
	_error = reason
	printerr("sync floor oracle: " + reason)
	quit(2)
