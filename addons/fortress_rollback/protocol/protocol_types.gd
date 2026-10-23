class_name FortressProtocolTypes
extends RefCounted

const FEATURE_RETAINED_DROP: int = 1

enum Kind { SYNC_REQUEST = 1, SYNC_REPLY, INPUT, INPUT_ACK, QUALITY_REPORT, QUALITY_REPLY, CHECKSUM_REPORT, KEEP_ALIVE, GOODBYE, FLOOR_REQUEST, FLOOR_REPLY, DROP_BARRIER }
enum Code { OK, INVALID_TYPE, INVALID_LIMITS, INVALID_MESSAGE, INVALID_PACKET, UNSUPPORTED_VERSION, UNSUPPORTED_KIND, LIMIT_EXCEEDED, IDENTITY_MISMATCH }


class Config:
	extends RefCounted
	var player_count: int = 2
	var input_width: int = 1
	var fps: int = 60
	var max_prediction: int = 8
	var input_delay: int = 0
	var desync_interval: int = 60
	var input_format: int = 1
	var snapshot_format: int = 1
	var checksum_algorithm: int = 1
	var queue_capacity: int = 128
	var neutral_input: PackedByteArray = PackedByteArray([0])
	var roster: Array[PackedByteArray] = [PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0]), PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0])]


class Limits:
	extends RefCounted
	var max_packet_bytes: int = 65536
	var max_input_frames: int = 128
	var player_count: int = 2
	var input_width: int = 1
	var expected_session_id: PackedByteArray = PackedByteArray()
	var expected_sender_id: PackedByteArray = PackedByteArray()
	var expected_connection_id: PackedByteArray = PackedByteArray()


class Status:
	extends RefCounted
	var disconnected: bool = false
	var last_frame: int = -1
	var epoch: int = 0


class Message:
	extends RefCounted
	var kind: int = Kind.KEEP_ALIVE
	var session_id: PackedByteArray = PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
	var sender_id: PackedByteArray = PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0])
	var connection_id: PackedByteArray = PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0])
	var token: PackedByteArray = PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
	var min_compat_version: int = 1
	var features: int = 0
	var config: Config = Config.new()
	var config_digest: PackedByteArray = PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0])
	var max_packet_bytes: int = 65536
	var start_frame: int = 0
	var ack_frame: int = -1
	var frame_count: int = 1
	var players: PackedByteArray = PackedByteArray([0])
	var statuses: Array[Status] = []
	var data: PackedByteArray = PackedByteArray()
	var frame_advantage: int = 0
	var frame: int = 0
	var checksum: PackedByteArray = PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
	var reason: int = 0
	var round_seq: int = 0
	var floors: PackedInt32Array = PackedInt32Array()
	var phase: int = 0
	var operation: int = 0
	var cut: int = -1
	var bound: int = -1
	## The coordinated drop barrier carries the pinned operation identity, the
	## certificate stage and the frozen value's digest.
	var stage: int = 0
	var coordinator: int = 0
	var coordinator_generation: int = 0
	var target_set_digest: int = 0
	var cut_digest: int = 0
	var available_through: int = -1
	var chunk_index: int = 0
	var chunk_count: int = 0
	var bytes: PackedByteArray = PackedByteArray()


class Result:
	extends RefCounted
	var code: int = Code.OK
	var bytes: PackedByteArray = PackedByteArray()
	var message: Message = null
	var projection: Dictionary = {}

	func _init(value: int = Code.OK) -> void:
		code = value
