class_name FortressProtocolValidation
extends RefCounted

const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")


static func frame(value: int, nullable: bool = true) -> bool:
	return value >= (-1 if nullable else 0) and value <= 2147483647


static func limits(value: T.Limits) -> bool:
	return (
		value.max_packet_bytes >= 44
		and value.max_packet_bytes <= 1048576
		and value.max_input_frames >= 1
		and value.max_input_frames <= 65535
		and value.player_count >= 2
		and value.player_count <= 8
		and value.input_width >= 1
		and value.input_width <= 65536
		and value.expected_session_id.size() in [0, 16]
		and value.expected_sender_id.size() in [0, 8]
		and value.expected_connection_id.size() in [0, 8]
	)


## Bounds for the receive packet limit a peer advertises while connecting.
const MIN_PACKET_BYTES: int = 44
const MAX_PACKET_BYTES: int = 1048576
## Fixed-width configuration bytes before the neutral input and roster.
const CONFIG_FIXED_BYTES: int = 33


static func config(value: T.Config) -> bool:
	if value == null:
		return false
	if value.player_count < 2 or value.player_count > 8 or value.input_width < 1 or value.input_width > 65536:
		return false
	if value.fps < 1 or value.fps > 4294967295 or value.max_prediction < 0 or value.max_prediction > 128:
		return false
	if value.input_delay < 0 or value.input_delay > 65535 or value.desync_interval < 0 or value.desync_interval > 4294967295:
		return false
	if value.queue_capacity < 2 or value.queue_capacity > 65536:
		return false
	for identifier: int in [value.input_format, value.snapshot_format, value.checksum_algorithm]:
		if identifier < 1 or identifier > 4294967295:
			return false
	if value.neutral_input.size() != value.input_width or value.roster.size() != value.player_count:
		return false
	for identity: PackedByteArray in value.roster:
		if identity.size() != 8:
			return false
	return true


static func identity(message: T.Message, bounds: T.Limits) -> bool:
	return (
		(bounds.expected_session_id.is_empty() or bounds.expected_session_id == message.session_id)
		and (bounds.expected_sender_id.is_empty() or bounds.expected_sender_id == message.sender_id)
		and (bounds.expected_connection_id.is_empty() or bounds.expected_connection_id == message.connection_id)
	)


## Negative length means malformed. Arithmetic stays below signed-64 bounds.
static func body_size(message: T.Message, bounds: T.Limits) -> int:
	if message.session_id.size() != 16 or message.sender_id.size() != 8 or message.connection_id.size() != 8:
		return -1
	match message.kind:
		T.Kind.SYNC_REQUEST, T.Kind.SYNC_REPLY:
			if message.token.size() != 16 or message.min_compat_version < 0 or message.min_compat_version > 255:
				return -1
			if message.features < 0 or message.features > 4294967295 or message.config_digest.size() != 8 or not config(message.config):
				return -1
			if message.max_packet_bytes < MIN_PACKET_BYTES or message.max_packet_bytes > MAX_PACKET_BYTES:
				return -1
			return 33 + CONFIG_FIXED_BYTES + message.config.input_width + message.config.player_count * 8
		T.Kind.INPUT:
			if not frame(message.start_frame, false) or not frame(message.ack_frame):
				return -1
			if message.frame_count < 1 or message.frame_count > bounds.max_input_frames:
				return -1
			if message.start_frame > 2147483647 - (message.frame_count - 1):
				return -1
			if message.players.is_empty() or message.players.size() > bounds.player_count or message.statuses.size() != bounds.player_count:
				return -1
			var previous: int = -1
			for player: int in message.players:
				if player <= previous or player >= bounds.player_count:
					return -1
				previous = player
			for status: T.Status in message.statuses:
				if status == null or not frame(status.last_frame) or status.epoch < 0 or status.epoch > 65535:
					return -1
			if message.data.size() != message.frame_count * message.players.size() * bounds.input_width:
				return -1
			return 16 + message.players.size() + message.statuses.size() * 7 + message.data.size()
		T.Kind.INPUT_ACK:
			return 4 if frame(message.ack_frame) else -1
		T.Kind.QUALITY_REPORT:
			return 18 if message.token.size() == 16 and message.frame_advantage >= -32768 and message.frame_advantage <= 32767 else -1
		T.Kind.QUALITY_REPLY:
			return 16 if message.token.size() == 16 else -1
		T.Kind.CHECKSUM_REPORT:
			return 20 if frame(message.frame, false) and message.checksum.size() == 16 else -1
		T.Kind.KEEP_ALIVE:
			return 0
		T.Kind.GOODBYE:
			return 1 if message.reason >= 0 and message.reason <= 255 else -1
		T.Kind.FLOOR_REQUEST, T.Kind.FLOOR_REPLY:
			if message.round_seq < 0 or message.round_seq > 4294967295:
				return -1
			if message.kind == T.Kind.FLOOR_REQUEST:
				return 4
			if message.floors.size() != bounds.player_count:
				return -1
			for floor_frame: int in message.floors:
				if not frame(floor_frame):
					return -1
			return 5 + 4 * message.floors.size()
		T.Kind.DROP_BARRIER:
			if message.phase < 1 or message.phase > 3:
				return -1
			if message.operation < 0 or message.operation > 4294967295:
				return -1
			if not frame(message.cut) or not frame(message.bound):
				return -1
			if message.data.is_empty() or message.data.size() > bounds.player_count:
				return -1
			var previous_slot: int = -1
			for slot: int in message.data:
				if slot <= previous_slot or slot >= bounds.player_count:
					return -1
				previous_slot = slot
			return 14 + message.data.size()
	return -1
