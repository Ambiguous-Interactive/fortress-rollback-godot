class_name FortressProtocolProjection
extends RefCounted

const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")


## JSON-safe semantic records retain wide values as exact lowercase hex strings.
static func project(message: T.Message) -> Dictionary:
	var record: Dictionary = {
		"kind": message.kind,
		"session_id": message.session_id.hex_encode(),
		"sender_id": message.sender_id.hex_encode(),
		"connection_id": message.connection_id.hex_encode(),
	}
	match message.kind:
		T.Kind.SYNC_REQUEST, T.Kind.SYNC_REPLY:
			record["token"] = message.token.hex_encode()
			record["min_compat_version"] = message.min_compat_version
			record["features"] = message.features
			record["config_digest"] = message.config_digest.hex_encode()
			record["max_packet_bytes"] = message.max_packet_bytes
			var roster: Array[String] = []
			for peer: PackedByteArray in message.config.roster:
				roster.append(peer.hex_encode())
			record["config"] = {
				"player_count": message.config.player_count,
				"input_width": message.config.input_width,
				"fps": message.config.fps,
				"max_prediction": message.config.max_prediction,
				"input_delay": message.config.input_delay,
				"desync_interval": message.config.desync_interval,
				"input_format": message.config.input_format,
				"snapshot_format": message.config.snapshot_format,
				"checksum_algorithm": message.config.checksum_algorithm,
				"queue_capacity": message.config.queue_capacity,
				"neutral_input": message.config.neutral_input.hex_encode(),
				"roster": roster,
			}
		T.Kind.INPUT:
			record["start_frame"] = message.start_frame
			record["ack_frame"] = message.ack_frame
			record["frame_count"] = message.frame_count
			var players: Array[int] = []
			for player: int in message.players:
				players.append(player)
			record["players"] = players
			var statuses: Array[Dictionary] = []
			for status: T.Status in message.statuses:
				statuses.append({"disconnected": status.disconnected, "last_frame": status.last_frame, "epoch": status.epoch})
			record["statuses"] = statuses
			record["data"] = message.data.hex_encode()
		T.Kind.INPUT_ACK:
			record["ack_frame"] = message.ack_frame
		T.Kind.QUALITY_REPORT:
			record["frame_advantage"] = message.frame_advantage
			record["token"] = message.token.hex_encode()
		T.Kind.QUALITY_REPLY:
			record["token"] = message.token.hex_encode()
		T.Kind.CHECKSUM_REPORT:
			record["frame"] = message.frame
			record["checksum"] = message.checksum.hex_encode()
		T.Kind.GOODBYE:
			record["reason"] = message.reason
		T.Kind.FLOOR_REQUEST, T.Kind.FLOOR_REPLY:
			record["round_seq"] = message.round_seq
			if message.kind == T.Kind.FLOOR_REPLY:
				var floors: Array[int] = []
				for floor_frame: int in message.floors:
					floors.append(floor_frame)
				record["floors"] = floors
		T.Kind.DROP_BARRIER:
			record["phase"] = message.phase
			record["operation"] = message.operation
			record["cut"] = message.cut
			record["bound"] = message.bound
			record["stage"] = message.stage
			record["coordinator"] = message.coordinator
			record["coordinator_generation"] = message.coordinator_generation
			record["target_set_digest"] = message.target_set_digest
			record["cut_digest"] = message.cut_digest
			record["available_through"] = message.available_through
			record["chunk_index"] = message.chunk_index
			record["chunk_count"] = message.chunk_count
			var slots: Array[int] = []
			var index: int = 0
			while index < message.data.size():
				slots.append(message.data[index])
				index += 3
			record["slots"] = slots
			record["bytes"] = message.bytes.hex_encode()
	return record
