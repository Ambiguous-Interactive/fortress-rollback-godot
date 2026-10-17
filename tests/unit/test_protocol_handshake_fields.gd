extends RefCounted

# Value: protects=peer mismatch diagnosis survives parsing; fails_when=codec enforces local agreement; why_new=handshake policy now owns compatibility; seam=none
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
const Types = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["compatibility", "geometry", "bounds"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"compatibility": _compatibility(context)
		"geometry": _geometry(context)
		"bounds": _bounds(context)
	context.finish()


func _golden() -> PackedByteArray:
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/protocol/golden.json"))
	return "".join(fixture.packets["1"]).hex_decode()


func _compatibility(context: RefCounted) -> void:
	for version: int in [0, 1, 2, 255]:
		for features: int in [0, 1, 2147483648, 4294967295]:
			var packet: PackedByteArray = _golden()
			packet[60] = version
			packet.encode_u32(61, features)
			var result: RefCounted = Codec.decode(packet, Types.Limits.new())
			context.equal(result.code, 0, "preserve compatibility for endpoint diagnosis")
			if result.code != 0:
				continue
			context.equal(result.message.min_compat_version, version, "semantic version preserved")
			context.equal(result.message.features, features, "unsigned feature bits preserved")
			context.bytes_equal(Codec.encode(result.message, Types.Limits.new()).bytes, packet, version, "canonical compatibility bytes")
			packet[4] = Codec.VERSION + 1
			context.equal(Codec.decode(packet, Types.Limits.new()).code, Types.Code.UNSUPPORTED_VERSION, "layout version remains strict")


func _geometry(context: RefCounted) -> void:
	for players: int in [2, 3, 8]:
		for width: int in [1, 2, 65536]:
			var packet: PackedByteArray = _golden().slice(0, 98)
			packet[65] = players
			packet.encode_u32(66, width)
			var neutral: PackedByteArray = PackedByteArray()
			neutral.resize(width)
			neutral.fill(255)
			packet.append_array(neutral)
			for slot: int in range(players):
				packet.append_array(PackedByteArray([slot, 0, 0, 0, 0, 0, 0, 0]))
			packet.append_array("3031323334353637".hex_decode())
			packet.append_array(PackedByteArray([0, 0, 1, 0]))
			packet.encode_u32(40, packet.size() - 44)
			var limits: RefCounted = Types.Limits.new()
			limits.max_packet_bytes = 1048576
			var result: RefCounted = Codec.decode(packet, limits)
			context.equal(result.code, 0, "independently bounded handshake dimensions")
			if result.code != 0:
				continue
			context.equal(result.message.config.player_count, players, "remote cardinality preserved")
			context.equal(result.message.config.input_width, width, "remote sample width preserved")
			context.bytes_equal(result.message.config.neutral_input, neutral, width, "remote neutral bytes preserved")
			context.bytes_equal(Codec.encode(result.message, limits).bytes, packet, width, "independent geometry bytes")
			context.equal(Codec.configuration_matches(Types.Config.new(), result.message.config, limits), false, "endpoint must diagnose differing config")
			limits.max_packet_bytes = packet.size() - 1
			context.equal(Codec.decode(packet, limits).code, Types.Code.LIMIT_EXCEEDED, "remote geometry cannot bypass packet cap")


func _bounds(context: RefCounted) -> void:
	for players: int in [0, 1, 9, 255]:
		var packet: PackedByteArray = _golden()
		packet[65] = players
		context.equal(Codec.decode(packet, Types.Limits.new()).code, Types.Code.INVALID_PACKET, "reject invalid remote cardinality")
	for width: int in [0, 65537, 4294967295]:
		var packet: PackedByteArray = _golden()
		packet.encode_u32(66, width)
		context.equal(Codec.decode(packet, Types.Limits.new()).code, Types.Code.INVALID_PACKET, "reject invalid remote width")
	for capacity: int in [0, 1, 65537, 4294967295]:
		var packet: PackedByteArray = _golden()
		packet.encode_u32(94, capacity)
		context.equal(Codec.decode(packet, Types.Limits.new()).code, Types.Code.INVALID_PACKET, "reject invalid remote queue capacity")
	for limit: int in [0, 43, 1048577, 4294967295]:
		var packet: PackedByteArray = _golden()
		packet.encode_u32(packet.size() - 4, limit)
		context.equal(Codec.decode(packet, Types.Limits.new()).code, Types.Code.INVALID_PACKET, "reject invalid advertised packet limit")
	for field: String in ["min_compat_version", "features"]:
		for value: int in [-1, 256 if field == "min_compat_version" else 4294967296]:
			var message: RefCounted = Types.Message.new()
			message.kind = Types.Kind.SYNC_REQUEST
			message.set(field, value)
			context.equal(Codec.encode(message, Types.Limits.new()).code, Types.Code.INVALID_MESSAGE, "reject semantic scalar overflow")
