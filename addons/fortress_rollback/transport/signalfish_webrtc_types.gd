class_name FortressSignalFishWebRTCTypes
extends RefCounted

# gdlint: disable=constant-name

const RelayTypes = preload("res://addons/fortress_rollback/transport/signalfish_relay_types.gd")
const Code = RelayTypes.Code
const Result = RelayTypes.Result


class Options:
	extends RefCounted
	var max_packet_bytes: int = 1200
	var max_pending_packets: int = 128
	var max_pending_bytes: int = 1048576
	var max_sends_per_poll: int = 8
	var max_receives_per_poll: int = 8
	var max_socket_buffered_bytes: int = 262144


static func valid_options(options: Options) -> bool:
	return options != null and options.max_packet_bytes >= 44 and options.max_packet_bytes <= 1200 \
		and options.max_pending_packets >= 1 and options.max_pending_packets <= 4096 \
		and options.max_pending_bytes >= options.max_packet_bytes and options.max_pending_bytes <= 16777216 \
		and options.max_sends_per_poll >= 1 and options.max_sends_per_poll <= options.max_pending_packets \
		and options.max_receives_per_poll >= 1 and options.max_receives_per_poll <= 4096 \
		and options.max_socket_buffered_bytes >= options.max_packet_bytes and options.max_socket_buffered_bytes <= 16777216


static func copy_options(options: Options) -> Options:
	var owned: Options = Options.new()
	for field: String in ["max_packet_bytes", "max_pending_packets", "max_pending_bytes", "max_sends_per_poll", "max_receives_per_poll", "max_socket_buffered_bytes"]:
		owned.set(field, options.get(field))
	return owned
