extends RefCounted

# Value: protects=untrusted packet bounds and canonical fields; fails_when=wire drift or malformed bytes accepted; why_new=first protocol codec; seam=none
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
const Types = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["golden", "truncation", "malformed", "limits", "types", "ownership", "semantics", "hostile_bytes"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"golden": _golden(context)
		"truncation": _truncation(context)
		"malformed": _malformed(context)
		"limits": _limits(context)
		"types": _types(context)
		"ownership": _ownership(context)
		"semantics": _semantics(context)
		"hostile_bytes": _hostile_bytes(context)
	context.finish()


func _fixtures() -> Dictionary:
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/protocol/golden.json"))
	for kind: String in fixture.packets:
		fixture.packets[kind] = "".join(fixture.packets[kind])
	return fixture


func _message(kind: int) -> RefCounted:
	var message: RefCounted = Types.Message.new()
	message.kind = kind
	message.session_id = "000102030405060708090a0b0c0d0e0f".hex_decode()
	message.sender_id = "1011121314151617".hex_decode()
	message.connection_id = "18191a1b1c1d1e1f".hex_decode()
	message.token = "202122232425262728292a2b2c2d2e2f".hex_decode()
	message.config_digest = "3031323334353637".hex_decode()
	message.start_frame = 3
	message.ack_frame = -1
	message.frame_count = 2
	message.players = PackedByteArray([0, 1])
	var first: RefCounted = Types.Status.new()
	first.last_frame = -1
	var second: RefCounted = Types.Status.new()
	second.disconnected = true
	second.last_frame = 2147483647
	second.epoch = 65535
	message.statuses.append(first)
	message.statuses.append(second)
	message.data = PackedByteArray([0, 255, 128, 1])
	message.frame_advantage = -32768
	message.frame = 2147483647
	message.checksum = message.token.duplicate()
	message.reason = 255
	message.round_seq = 4294967295
	message.floors = PackedInt32Array([-1, 2147483647])
	return message


func _golden(context: RefCounted) -> void:
	var fixture: Dictionary = _fixtures()
	var limits: RefCounted = Types.Limits.new()
	for kind: int in range(1, 12):
		var expected: PackedByteArray = fixture.packets[str(kind)].hex_decode()
		var encoded: RefCounted = Codec.encode(_message(kind), limits)
		context.equal(encoded.code, 0, "golden encode %d" % kind)
		context.bytes_equal(encoded.bytes, expected, kind, "independent golden")
		var decoded: RefCounted = Codec.decode(expected, limits)
		context.equal(decoded.code, 0, "golden decode %d" % kind)
		if decoded.code == 0:
			context.equal(decoded.message.kind, kind, "kind preserved")
			var projected: RefCounted = Codec.semantic_projection(decoded.message, limits)
			context.equal(projected.code, 0, "projection validated")
			context.equal(JSON.stringify(projected.projection, "", true), JSON.stringify(_integers(fixture.projections[str(kind)]), "", true), "independent semantic projection")
			context.bytes_equal(Codec.encode(decoded.message, limits).bytes, expected, kind, "canonical round trip")
		context.state(kind, encoded.bytes)
	context.bytes_equal(Codec.encode_config(Types.Config.new(), limits).bytes, fixture.config.hex_decode(), 0, "config golden")


func _truncation(context: RefCounted) -> void:
	var limits: RefCounted = Types.Limits.new()
	for text: String in _fixtures().packets.values():
		var packet: PackedByteArray = text.hex_decode()
		for size: int in range(packet.size()):
			context.equal(Codec.decode(packet.slice(0, size), limits).code != 0, true, "every truncation %d/%d" % [size, packet.size()])
		packet.append(0)
		context.equal(Codec.decode(packet, limits).code != 0, true, "trailing garbage")


func _mutated(context: RefCounted, kind: int, offset: int, replacement: PackedByteArray, label: String) -> void:
	var packet: PackedByteArray = _fixtures().packets[str(kind)].hex_decode()
	for index: int in range(replacement.size()):
		packet[offset + index] = replacement[index]
	context.equal(Codec.decode(packet, Types.Limits.new()).code != 0, true, label)


func _malformed(context: RefCounted) -> void:
	_mutated(context, 8, 0, PackedByteArray([0]), "bad magic")
	_mutated(context, 8, 4, PackedByteArray([2, 0]), "unsupported version")
	_mutated(context, 8, 6, PackedByteArray([0]), "zero kind")
	_mutated(context, 8, 6, PackedByteArray([255]), "unknown kind")
	_mutated(context, 8, 7, PackedByteArray([1]), "reserved flags")
	_mutated(context, 8, 40, PackedByteArray([255, 255, 255, 255]), "hostile payload size")
	_mutated(context, 3, 44, PackedByteArray([255, 255, 255, 255]), "null input start")
	_mutated(context, 3, 48, PackedByteArray([254, 255, 255, 255]), "invalid ack negative")
	_mutated(context, 3, 52, PackedByteArray([0, 0]), "zero frames")
	_mutated(context, 3, 52, PackedByteArray([255, 255]), "hostile frames")
	_mutated(context, 3, 54, PackedByteArray([255]), "hostile player count")
	_mutated(context, 3, 55, PackedByteArray([1, 0]), "unsorted players")
	_mutated(context, 3, 55, PackedByteArray([0, 0]), "duplicate players")
	_mutated(context, 3, 56, PackedByteArray([2]), "outside roster player")
	_mutated(context, 3, 57, PackedByteArray([255]), "hostile status count")
	_mutated(context, 3, 58, PackedByteArray([2]), "invalid bool")
	_mutated(context, 3, 59, PackedByteArray([254, 255, 255, 255]), "invalid status negative")
	_mutated(context, 3, 72, PackedByteArray([255, 255, 255, 255]), "hostile data count")
	_mutated(context, 7, 44, PackedByteArray([255, 255, 255, 255]), "null checksum frame")
	_mutated(context, 1, 65, PackedByteArray([0]), "zero config players")
	_mutated(context, 1, 66, PackedByteArray([255, 255, 255, 255]), "hostile config width")
	_mutated(context, 11, 48, PackedByteArray([255]), "hostile floor count")
	_mutated(context, 11, 49, PackedByteArray([254, 255, 255, 255]), "invalid floor negative")


func _limits(context: RefCounted) -> void:
	var limits: RefCounted = Types.Limits.new()
	var packet: PackedByteArray = _fixtures().packets["3"].hex_decode()
	limits.max_packet_bytes = packet.size()
	context.equal(Codec.decode(packet, limits).code, 0, "exact packet cap")
	limits.max_packet_bytes = packet.size() - 1
	context.equal(Codec.decode(packet, limits).code != 0, true, "one above packet cap")
	limits = Types.Limits.new()
	limits.max_input_frames = 1
	context.equal(Codec.decode(packet, limits).code != 0, true, "negotiated frame cap")
	limits = Types.Limits.new()
	limits.input_width = 2
	context.equal(Codec.decode(packet, limits).code != 0, true, "negotiated width mismatch")
	for field: String in ["expected_session_id", "expected_sender_id", "expected_connection_id"]:
		limits = Types.Limits.new()
		limits.set(field, PackedByteArray([255]))
		context.equal(Codec.decode(packet, limits).code != 0, true, "invalid identity width " + field)
		limits.set(field, _message(3).get(field.trim_prefix("expected_")).duplicate())
		context.equal(Codec.decode(packet, limits).code, 0, "matching identity " + field)
		limits.get(field)[0] = 255
		context.equal(Codec.decode(packet, limits).code != 0, true, "mismatched identity " + field)
	var message: RefCounted = _message(3)
	limits = Types.Limits.new()
	message.frame_count = limits.max_input_frames
	message.data.resize(message.frame_count * 2)
	context.equal(Codec.encode(message, limits).code, 0, "maximum frame count")
	message.start_frame = 2147483647
	context.equal(Codec.encode(message, limits).code != 0, true, "frame range overflow")


	limits = Types.Limits.new()
	limits.player_count = 8
	limits.input_width = 65536
	limits.max_packet_bytes = 1048576
	var config: RefCounted = Types.Config.new()
	config.player_count = 8
	config.input_width = 65536
	config.neutral_input.resize(65536)
	config.roster.clear()
	for slot: int in range(8):
		config.roster.append(PackedByteArray([slot, 0, 0, 0, 0, 0, 0, 0]))
	config.fps = 4294967295
	config.max_prediction = 128
	config.input_delay = 65535
	config.desync_interval = 4294967295
	config.input_format = 4294967295
	config.snapshot_format = 4294967295
	config.checksum_algorithm = 4294967295
	message = _message(1)
	message.config = config
	var encoded: RefCounted = Codec.encode(message, limits)
	context.equal(encoded.code, 0, "maximum configuration bounds")
	if encoded.code == 0:
		var decoded: RefCounted = Codec.decode(encoded.bytes, limits)
		context.equal(decoded.code, 0, "maximum config decode")
		if decoded.code == 0:
			context.equal(Codec.configuration_matches(config, decoded.message.config, limits), true, "maximum config semantic projection")
	config.input_delay = 65536
	context.equal(Codec.encode(message, limits).code != 0, true, "config u16 overflow")


func _types(context: RefCounted) -> void:
	# Variant is intentional: exercise callers at the public untrusted boundary.
	for wrong: Variant in [null, 1, true, 1.0, "bytes", [], {}, PackedInt32Array([1]), RefCounted.new()]:
		context.equal(Codec.decode(wrong, Types.Limits.new()).code != 0, true, "wrong packet type")
		context.equal(Codec.encode(wrong, Types.Limits.new()).code != 0, true, "wrong message type")
		context.equal(Codec.decode(PackedByteArray(), wrong).code != 0, true, "wrong limits type")
		context.equal(Codec.encode_config(wrong, Types.Limits.new()).code != 0, true, "wrong config type")
	var limits: RefCounted = Types.Limits.new()
	limits.player_count = 0
	context.equal(Codec.encode(_message(8), limits).code != 0, true, "zero roster limits")
	var message: RefCounted = _message(3)
	message.statuses[0] = null
	context.equal(Codec.encode(message, Types.Limits.new()).code != 0, true, "null nested status object")
	for field: String in ["session_id", "sender_id", "connection_id", "token", "checksum", "config_digest"]:
		message = _message(7 if field == "checksum" else 1)
		message.set(field, PackedByteArray([1]))
		context.equal(Codec.encode(message, Types.Limits.new()).code != 0, true, "wrong field byte width " + field)
	for field: String in ["ack_frame", "frame", "reason", "round_seq"]:
		message = _message({"ack_frame": 4, "frame": 7, "reason": 9, "round_seq": 10}[field])
		message.set(field, -2)
		context.equal(Codec.encode(message, Types.Limits.new()).code != 0, true, "negative scalar " + field)



func _ownership(context: RefCounted) -> void:
	var message: RefCounted = _message(3)
	var limits: RefCounted = Types.Limits.new()
	var encoded: RefCounted = Codec.encode(message, limits)
	var original: PackedByteArray = encoded.bytes.duplicate()
	message.data.fill(7)
	message.session_id.fill(7)
	message.statuses[0].epoch = 1
	context.bytes_equal(encoded.bytes, original, 0, "encode owns bytes")
	var decoded: RefCounted = Codec.decode(encoded.bytes, limits)
	encoded.bytes.fill(7)
	context.bytes_equal(Codec.encode(decoded.message, limits).bytes, original, 0, "decode owns packet fields")
	var projected: RefCounted = Codec.semantic_projection(decoded.message, limits)
	projected.projection.statuses[0].epoch = 99
	projected.projection.players[0] = 1
	context.bytes_equal(Codec.encode(decoded.message, limits).bytes, original, 0, "projection owns nested records")
	var second: RefCounted = Codec.decode(original, limits)
	decoded.message.data.fill(9)
	decoded.message.statuses[0].epoch = 2
	context.bytes_equal(Codec.encode(second.message, limits).bytes, original, 0, "decodes share no mutable fields")


func _semantics(context: RefCounted) -> void:
	var limits: RefCounted = Types.Limits.new()
	var decoded: RefCounted = Codec.decode(_fixtures().packets["3"].hex_decode(), limits).message
	context.equal(decoded.start_frame, 3, "input start")
	context.equal(decoded.ack_frame, -1, "ack null sentinel")
	context.equal(decoded.frame_count, 2, "frame count")
	context.equal(decoded.players, PackedByteArray([0, 1]), "selected slots")
	context.equal(decoded.statuses[0].disconnected, false, "connected bool")
	context.equal(decoded.statuses[0].last_frame, -1, "status null sentinel")
	context.equal(decoded.statuses[1].disconnected, true, "disconnected bool")
	context.equal(decoded.statuses[1].epoch, 65535, "status epoch")
	context.equal(decoded.statuses[1].last_frame, 2147483647, "full frame domain")
	context.equal(decoded.data, PackedByteArray([0, 255, 128, 1]), "frame-major input bytes")
	context.equal(Codec.decode(_fixtures().packets["5"].hex_decode(), limits).message.frame_advantage, -32768, "signed i16 lower")
	var message: RefCounted = _message(5)
	message.frame_advantage = 32767
	context.equal(Codec.decode(Codec.encode(message, limits).bytes, limits).message.frame_advantage, 32767, "signed i16 upper")
	message.frame_advantage = 32768
	context.equal(Codec.encode(message, limits).code != 0, true, "reject i16 overflow")
	var first: RefCounted = Types.Config.new()
	var second: RefCounted = Types.Config.new()
	context.equal(Codec.configuration_matches(first, second, limits), true, "equal configuration")
	for field: String in ["fps", "max_prediction", "input_delay", "desync_interval", "input_format", "snapshot_format", "checksum_algorithm"]:
		second = Types.Config.new()
		second.set(field, second.get(field) + 1)
		context.equal(Codec.configuration_matches(first, second, limits), false, "config mismatch " + field)
	second = Types.Config.new()
	second.neutral_input[0] = 1
	context.equal(Codec.configuration_matches(first, second, limits), false, "neutral mismatch")
	second = Types.Config.new()
	second.roster[0][0] = 1
	context.equal(Codec.configuration_matches(first, second, limits), false, "roster mismatch")


func _hostile_bytes(context: RefCounted) -> void:
	var state: int = 1701
	var packets: Dictionary = _fixtures().packets
	for iteration: int in range(512):
		state = (state * 1664525 + 1013904223) & 4294967295
		var packet: PackedByteArray = packets[str(1 + state % 11)].hex_decode()
		if iteration % 4 == 0:
			packet.resize(state % 256)
		for mutation: int in range(1 + iteration % 4):
			state = (state * 1664525 + 1013904223) & 4294967295
			if packet.is_empty():
				break
			var offset: int = state % packet.size()
			state = (state * 1664525 + 1013904223) & 4294967295
			packet[offset] = (state >> 16) & 255
		var decoded: RefCounted = Codec.decode(packet, Types.Limits.new())
		context.equal(decoded.code >= 0 and decoded.code <= Types.Code.IDENTITY_MISMATCH, true, "hostile parser typed result")
		if decoded.code == 0:
			context.bytes_equal(Codec.encode(decoded.message, Types.Limits.new()).bytes, packet, iteration, "accepted hostile bytes canonical")


# Variant traverses JSON fixture trees; only known integral fixture numbers convert.
func _integers(value: Variant) -> Variant:
	if value is float:
		return int(value)
	if value is Array:
		for index: int in range(value.size()):
			value[index] = _integers(value[index])
	if value is Dictionary:
		for key: Variant in value:
			value[key] = _integers(value[key])
	return value
