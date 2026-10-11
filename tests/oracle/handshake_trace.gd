extends SceneTree
# Value: protects=actual endpoint matches independent pinned upstream; fails_when=token/timing/mismatch events drift; why_new=unit expected values aren't independent; seam=none
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const H = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const Endpoint = preload("res://addons/fortress_rollback/protocol/handshake.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
var _limits: T.Limits = T.Limits.new()
var _local: T.Message


func _initialize() -> void:
	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	if arguments.size() != 2 or arguments[0] != "--scenario":
		quit(2)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(arguments[1]))
	if not _valid_fixture(parsed):
		quit(2)
		return
	var fixture: Dictionary = parsed
	_limits.input_width = 4
	_local = _message(fixture.local)
	var endpoint: Endpoint = Endpoint.new()
	var options: H.Options = H.Options.new()
	options.roundtrips = 2
	options.retry_interval_us = 200000
	options.timeout_us = 1000000
	if endpoint.configure(_local, "0200000000000000".hex_decode(), options) != H.Code.OK:
		quit(3)
		return
	var records: Array[Dictionary] = []
	for index: int in range(fixture.operations.size()):
		var operation: Dictionary = fixture.operations[index]
		var token: Variant = null
		if not operation.next_token.is_empty():
			token = String(operation.next_token).hex_decode()
		var code: int
		match operation.kind:
			"begin": code = endpoint.begin(int(operation.now_us), token)
			"poll": code = endpoint.poll(int(operation.now_us), token)
			"receive":
				var encoded: T.Result = Codec.encode(_message(operation.message), _limits)
				if encoded.code != T.Code.OK:
					quit(4)
					return
				code = endpoint.receive(encoded.bytes, String(operation.source).hex_decode(), int(operation.now_us), token)
			_: quit(5); return
		var packets: Array[Dictionary] = []
		for packet: PackedByteArray in endpoint.drain_outbox():
			var decoded: T.Result = Codec.decode(packet, _limits)
			if decoded.code != T.Code.OK:
				quit(6)
				return
			packets.append(_project_message(decoded.message))
		records.append({"code": code, "transitions": endpoint.drain_transitions(), "events": endpoint.drain_events(), "packets": packets})
	print("FORTRESS_HANDSHAKE_RESULT " + JSON.stringify({"format": 1, "complete": true, "records": records}))
	quit(0)


func _message(value: Dictionary) -> T.Message:
	var message: T.Message = T.Message.new()
	message.kind = T.Kind.SYNC_REQUEST if value.kind == "request" else T.Kind.SYNC_REPLY
	message.session_id = "01000000000000000000000000000000".hex_decode()
	message.sender_id = String(value.sender).hex_decode()
	message.connection_id = String(value.connection).hex_decode()
	message.token = String(value.token).hex_decode()
	message.min_compat_version = int(value.min_compat_version)
	message.features = int(value.features)
	message.config_digest = String(value.config_digest).hex_decode()
	message.config.player_count = int(value.player_count)
	message.config.input_width = int(value.input_width)
	message.config.fps = int(value.fps)
	message.config.max_prediction = int(value.max_prediction)
	message.config.desync_interval = int(value.desync_interval)
	message.config.neutral_input.resize(message.config.input_width)
	message.config.roster.clear()
	for index: int in range(message.config.player_count):
		message.config.roster.append(PackedByteArray([index + 1, 0, 0, 0, 0, 0, 0, 0]))
	return message


func _project_message(message: T.Message) -> Dictionary:
	return {"kind": "request" if message.kind == T.Kind.SYNC_REQUEST else "reply", "token": message.token.hex_encode(),
		"sender": message.sender_id.hex_encode(), "connection": message.connection_id.hex_encode(), "min_compat_version": message.min_compat_version,
		"features": message.features, "config_digest": message.config_digest.hex_encode(), "player_count": message.config.player_count,
		"input_width": message.config.input_width, "fps": message.config.fps, "max_prediction": message.config.max_prediction,
		"desync_interval": message.config.desync_interval}


# gdlint: disable=max-returns
func _valid_fixture(value: Variant) -> bool:
	if not value is Dictionary or not _keys(value, ["format", "local", "operations"]) or not _integer(value.format, 1, 1):
		return false
	if not _valid_message(value.local) or not value.operations is Array or value.operations.is_empty() or value.operations.size() > 129:
		return false
	if not value.operations[0] is Dictionary or value.operations[0].get("kind") != "begin":
		return false
	for operation: Variant in value.operations:
		if not operation is Dictionary or not operation.get("kind") in ["begin", "poll", "receive"]:
			return false
		var names: Array[String] = ["kind", "now_us", "next_token"]
		if operation.kind == "receive":
			names.append_array(["message", "source"])
			if not _valid_message(operation.get("message")) or not _hex(operation.get("source"), 8):
				return false
		if not _keys(operation, names) or not _integer(operation.now_us, 0, 10000000):
			return false
		if operation.next_token != "" and not _hex(operation.next_token, 16):
			return false
	return true


func _valid_message(value: Variant) -> bool:
	var names: Array[String] = ["kind", "token", "sender", "connection", "min_compat_version", "features", "config_digest",
		"player_count", "input_width", "fps", "max_prediction", "desync_interval"]
	if not value is Dictionary or not _keys(value, names) or not value.kind in ["request", "reply"]:
		return false
	for field: String in ["token", "sender", "connection", "config_digest"]:
		if not _hex(value[field], 16 if field == "token" else 8):
			return false
	for field: String in ["min_compat_version", "features", "player_count", "input_width", "fps", "max_prediction", "desync_interval"]:
		if not _integer(value[field], 0, 4294967295):
			return false
	return value.player_count >= 1 and value.player_count <= 8 and value.input_width >= 1 and value.input_width <= 65536


func _keys(value: Dictionary, names: Array[String]) -> bool:
	if value.size() != names.size():
		return false
	for name: String in names:
		if not value.has(name):
			return false
	return true


func _integer(value: Variant, minimum: int, maximum: int) -> bool:
	return (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and is_finite(float(value)) and value >= minimum and value <= maximum and value == floor(value)


func _hex(value: Variant, width: int) -> bool:
	if not value is String or value.length() != width * 2:
		return false
	for character: String in value:
		if not character in "0123456789abcdef":
			return false
	return true
