class_name FortressSignalFishRelayTypes
extends RefCounted

enum Code { OK, INVALID_ARGUMENT, WRONG_STATE, INCOMPATIBLE_MODE, INVALID_ENVELOPE, WRONG_SOURCE, WRONG_SESSION, NOT_RECIPIENT, TOO_LARGE,
	BACKPRESSURE, RECEIVE_OVERFLOW, SDK_FAILURE, PEER_FAILURE }


class Options:
	extends RefCounted
	var max_packet_bytes: int = 65479
	var max_pending_packets: int = 128
	var max_pending_bytes: int = 1048576
	var max_received_packets: int = 128
	var max_received_bytes: int = 1048576
	var max_sends_per_poll: int = 8
	var max_receives_per_poll: int = 8
	var max_socket_buffered_bytes: int = 262144


class Result:
	extends RefCounted
	var code: int = Code.OK
	var sent: int = 0
	var received: int = 0
	## Transport items taken off the wire during this poll, refused ones included.
	## A refused item is still traffic: valid work can sit behind it.
	var activity: int = 0
	var peer_code: int = 0

	func _init(value: int = Code.OK) -> void:
		code = value


static func valid_options(options: Options) -> bool:
	return options != null and options.max_packet_bytes >= 44 and options.max_packet_bytes <= 65479 \
		and options.max_pending_packets >= 1 and options.max_pending_packets <= 4096 \
		and options.max_received_packets >= 1 and options.max_received_packets <= 4096 \
		and options.max_pending_bytes >= options.max_packet_bytes + 57 and options.max_pending_bytes <= 16777216 \
		and options.max_received_bytes >= options.max_packet_bytes + 57 and options.max_received_bytes <= 16777216 \
		and options.max_sends_per_poll >= 1 and options.max_sends_per_poll <= options.max_pending_packets \
		and options.max_receives_per_poll >= 1 and options.max_receives_per_poll <= options.max_received_packets \
		and options.max_socket_buffered_bytes >= options.max_packet_bytes + 57 and options.max_socket_buffered_bytes <= 16777216


static func copy_options(options: Options) -> Options:
	var owned: Options = Options.new()
	for field: String in ["max_packet_bytes", "max_pending_packets", "max_pending_bytes", "max_received_packets", "max_received_bytes",
		"max_sends_per_poll", "max_receives_per_poll", "max_socket_buffered_bytes"]:
		owned.set(field, options.get(field))
	return owned
