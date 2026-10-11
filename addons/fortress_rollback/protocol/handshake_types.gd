class_name FortressHandshakeTypes
extends RefCounted

enum Code { OK, INVALID_ARGUMENT, WRONG_STATE, INVALID_PACKET, WRONG_SOURCE, WRONG_CONNECTION, UNSUPPORTED_KIND, BACKPRESSURE, TOKEN_REUSED }


class Options:
	extends RefCounted
	var roundtrips: int = 5
	var retry_interval_us: int = 200000
	var timeout_us: int = -1
	var max_packet_bytes: int = 65536
	var max_pending_tokens: int = 128
	var max_consumed_tokens: int = 4096
	var max_outbox: int = 128
	var max_events: int = 128
	var max_transitions: int = 1024


static func valid_options(value: Options) -> bool:
	if value.roundtrips < 1 or value.roundtrips > 128:
		return false
	if value.max_transitions < 2 or value.max_consumed_tokens < value.roundtrips:
		return false
	if value.retry_interval_us < 0 or value.timeout_us < -1:
		return false
	if value.max_packet_bytes < 44 or value.max_packet_bytes > 1048576:
		return false
	for bound: int in [value.max_pending_tokens, value.max_consumed_tokens, value.max_outbox, value.max_events, value.max_transitions]:
		if bound < 1 or bound > 4096:
			return false
	return true
