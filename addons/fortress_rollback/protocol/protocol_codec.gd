class_name FortressProtocolCodec
extends RefCounted

const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const V = preload("res://addons/fortress_rollback/protocol/protocol_validation.gd")
const Projector = preload("res://addons/fortress_rollback/protocol/protocol_projection.gd")
const Reader = preload("res://addons/fortress_rollback/protocol/protocol_reader.gd")
const VERSION: int = 1
const HEADER_BYTES: int = 44
const MAGIC: Array[int] = [70, 82, 71, 80]


## Variant accepts untrusted callers without engine argument-conversion errors.
static func encode(message: Variant, limits: Variant) -> T.Result:
	if not message is T.Message or not limits is T.Limits:
		return T.Result.new(T.Code.INVALID_TYPE)
	if not V.limits(limits):
		return T.Result.new(T.Code.INVALID_LIMITS)
	if message.kind < T.Kind.SYNC_REQUEST or message.kind > T.Kind.FLOOR_REPLY:
		return T.Result.new(T.Code.UNSUPPORTED_KIND)
	var size: int = V.body_size(message, limits)
	if size < 0:
		return T.Result.new(T.Code.INVALID_MESSAGE)
	if size > limits.max_packet_bytes - HEADER_BYTES:
		return T.Result.new(T.Code.LIMIT_EXCEEDED)
	if not V.identity(message, limits):
		return T.Result.new(T.Code.IDENTITY_MISMATCH)
	var writer: StreamPeerBuffer = _writer()
	writer.put_data(PackedByteArray(MAGIC))
	writer.put_u16(VERSION)
	writer.put_u8(message.kind)
	writer.put_u8(0)
	writer.put_data(message.session_id)
	writer.put_data(message.sender_id)
	writer.put_data(message.connection_id)
	writer.put_u32(size)
	_write_body(writer, message)
	var result: T.Result = T.Result.new()
	result.bytes = writer.data_array.duplicate()
	return result


## Packet size is checked before copying or constructing a reader.
static func decode(packet: Variant, limits: Variant) -> T.Result:
	if not packet is PackedByteArray or not limits is T.Limits:
		return T.Result.new(T.Code.INVALID_TYPE)
	if not V.limits(limits):
		return T.Result.new(T.Code.INVALID_LIMITS)
	if packet.size() > limits.max_packet_bytes:
		return T.Result.new(T.Code.LIMIT_EXCEEDED)
	if packet.size() < HEADER_BYTES:
		return T.Result.new(T.Code.INVALID_PACKET)
	var reader: Reader = Reader.new(packet)
	if reader.take(4) != PackedByteArray(MAGIC):
		return T.Result.new(T.Code.INVALID_PACKET)
	if reader.number(2) != VERSION:
		return T.Result.new(T.Code.UNSUPPORTED_VERSION)
	var message: T.Message = T.Message.new()
	message.kind = reader.number(1)
	if message.kind < T.Kind.SYNC_REQUEST or message.kind > T.Kind.FLOOR_REPLY:
		return T.Result.new(T.Code.UNSUPPORTED_KIND)
	if reader.number(1) != 0:
		return T.Result.new(T.Code.INVALID_PACKET)
	message.session_id = reader.take(16)
	message.sender_id = reader.take(8)
	message.connection_id = reader.take(8)
	if reader.number(4) != reader.stream.get_available_bytes():
		return T.Result.new(T.Code.INVALID_PACKET)
	if not V.identity(message, limits):
		return T.Result.new(T.Code.IDENTITY_MISMATCH)
	_read_body(reader, message, limits)
	if not reader.valid or reader.stream.get_available_bytes() != 0 or V.body_size(message, limits) < 0:
		return T.Result.new(T.Code.INVALID_PACKET)
	var result: T.Result = T.Result.new()
	result.message = message
	return result


static func encode_config(config: Variant, limits: Variant) -> T.Result:
	if not config is T.Config or not limits is T.Limits:
		return T.Result.new(T.Code.INVALID_TYPE)
	if not V.limits(limits):
		return T.Result.new(T.Code.INVALID_LIMITS)
	if not V.config(config):
		return T.Result.new(T.Code.INVALID_MESSAGE)
	if 29 + config.input_width + config.player_count * 8 > limits.max_packet_bytes:
		return T.Result.new(T.Code.LIMIT_EXCEEDED)
	var writer: StreamPeerBuffer = _writer()
	_write_config(writer, config)
	var result: T.Result = T.Result.new()
	result.bytes = writer.data_array.duplicate()
	return result


static func configuration_matches(first: Variant, second: Variant, limits: Variant) -> bool:
	var a: T.Result = encode_config(first, limits)
	var b: T.Result = encode_config(second, limits)
	return a.code == T.Code.OK and b.code == T.Code.OK and a.bytes == b.bytes


## Layout-independent owned fields for differential oracles; irrelevant fields are omitted.
static func semantic_projection(message: Variant, limits: Variant) -> T.Result:
	var result: T.Result = encode(message, limits)
	if result.code == T.Code.OK:
		result.bytes = PackedByteArray()
		result.projection = Projector.project(message)
	return result


static func _writer() -> StreamPeerBuffer:
	var writer: StreamPeerBuffer = StreamPeerBuffer.new()
	writer.big_endian = false
	return writer


static func _write_config(writer: StreamPeerBuffer, config: T.Config) -> void:
	writer.put_u8(config.player_count)
	writer.put_u32(config.input_width)
	writer.put_u32(config.fps)
	writer.put_u16(config.max_prediction)
	writer.put_u16(config.input_delay)
	writer.put_u32(config.desync_interval)
	writer.put_u32(config.input_format)
	writer.put_u32(config.snapshot_format)
	writer.put_u32(config.checksum_algorithm)
	writer.put_data(config.neutral_input)
	for identity: PackedByteArray in config.roster:
		writer.put_data(identity)


static func _write_body(writer: StreamPeerBuffer, message: T.Message) -> void:
	match message.kind:
		T.Kind.SYNC_REQUEST, T.Kind.SYNC_REPLY:
			writer.put_data(message.token)
			writer.put_u8(message.min_compat_version)
			writer.put_u32(message.features)
			_write_config(writer, message.config)
			writer.put_data(message.config_digest)
		T.Kind.INPUT:
			writer.put_32(message.start_frame)
			writer.put_32(message.ack_frame)
			writer.put_u16(message.frame_count)
			writer.put_u8(message.players.size())
			writer.put_data(message.players)
			writer.put_u8(message.statuses.size())
			for status: T.Status in message.statuses:
				writer.put_u8(1 if status.disconnected else 0)
				writer.put_32(status.last_frame)
				writer.put_u16(status.epoch)
			writer.put_u32(message.data.size())
			writer.put_data(message.data)
		T.Kind.INPUT_ACK:
			writer.put_32(message.ack_frame)
		T.Kind.QUALITY_REPORT:
			writer.put_16(message.frame_advantage)
			writer.put_data(message.token)
		T.Kind.QUALITY_REPLY:
			writer.put_data(message.token)
		T.Kind.CHECKSUM_REPORT:
			writer.put_32(message.frame)
			writer.put_data(message.checksum)
		T.Kind.GOODBYE:
			writer.put_u8(message.reason)
		T.Kind.FLOOR_REQUEST, T.Kind.FLOOR_REPLY:
			writer.put_u32(message.round_seq)
			if message.kind == T.Kind.FLOOR_REPLY:
				writer.put_u8(message.floors.size())
				for frame: int in message.floors:
					writer.put_32(frame)


static func _read_config(reader: Reader) -> T.Config:
	var config: T.Config = T.Config.new()
	config.player_count = reader.number(1)
	config.input_width = reader.number(4)
	config.fps = reader.number(4)
	config.max_prediction = reader.number(2)
	config.input_delay = reader.number(2)
	config.desync_interval = reader.number(4)
	config.input_format = reader.number(4)
	config.snapshot_format = reader.number(4)
	config.checksum_algorithm = reader.number(4)
	if config.player_count < 2 or config.player_count > 8 or config.input_width < 1 or config.input_width > 65536:
		reader.valid = false
		return config
	config.neutral_input = reader.take(config.input_width)
	config.roster.clear()
	for index: int in range(config.player_count):
		config.roster.append(reader.take(8))
	return config


static func _read_body(reader: Reader, message: T.Message, limits: T.Limits) -> void:
	match message.kind:
		T.Kind.SYNC_REQUEST, T.Kind.SYNC_REPLY:
			message.token = reader.take(16)
			message.min_compat_version = reader.number(1)
			message.features = reader.number(4)
			message.config = _read_config(reader)
			message.config_digest = reader.take(8)
		T.Kind.INPUT:
			_read_input(reader, message, limits)
		T.Kind.INPUT_ACK:
			message.ack_frame = reader.number(4, true)
		T.Kind.QUALITY_REPORT:
			message.frame_advantage = reader.number(2, true)
			message.token = reader.take(16)
		T.Kind.QUALITY_REPLY:
			message.token = reader.take(16)
		T.Kind.CHECKSUM_REPORT:
			message.frame = reader.number(4, true)
			message.checksum = reader.take(16)
		T.Kind.GOODBYE:
			message.reason = reader.number(1)
		T.Kind.FLOOR_REQUEST, T.Kind.FLOOR_REPLY:
			message.round_seq = reader.number(4)
			if message.kind == T.Kind.FLOOR_REPLY:
				var count: int = reader.number(1)
				if count != limits.player_count:
					reader.valid = false
					return
				for index: int in range(count):
					message.floors.append(reader.number(4, true))


static func _read_input(reader: Reader, message: T.Message, limits: T.Limits) -> void:
	message.start_frame = reader.number(4, true)
	message.ack_frame = reader.number(4, true)
	message.frame_count = reader.number(2)
	var count: int = reader.number(1)
	if count < 1 or count > limits.player_count or message.frame_count < 1 or message.frame_count > limits.max_input_frames:
		reader.valid = false
		return
	message.players = reader.take(count)
	if reader.number(1) != limits.player_count:
		reader.valid = false
		return
	for index: int in range(limits.player_count):
		var status: T.Status = T.Status.new()
		var flag: int = reader.number(1)
		if flag > 1:
			reader.valid = false
			return
		status.disconnected = flag == 1
		status.last_frame = reader.number(4, true)
		status.epoch = reader.number(2)
		message.statuses.append(status)
	var byte_count: int = reader.number(4)
	if byte_count != message.frame_count * count * limits.input_width:
		reader.valid = false
		return
	message.data = reader.take(byte_count)
