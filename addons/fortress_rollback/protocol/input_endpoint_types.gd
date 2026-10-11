class_name FortressInputEndpointTypes
extends RefCounted

enum Code { OK, INVALID_ARGUMENT, WRONG_STATE, INVALID_PACKET, WRONG_SOURCE, WRONG_CONNECTION, UNSUPPORTED_KIND, BACKPRESSURE, TOKEN_REUSED,
	BUSY, CONFLICT, INVALID_FRAME, INPUT_FAILED, TERMINATED }


class Options:
	extends RefCounted
	var retry_interval_us: int = 200000
	var max_pending_frames: int = 128
	var max_received_frames: int = 128
	var max_input_frames: int = 128
	var max_outbox: int = 128
	var max_events: int = 128
	var max_transitions: int = 1024
	var max_buffer_bytes: int = 16777216


static func valid_options(value: Options) -> bool:
	if value.retry_interval_us < 0 or value.max_input_frames < 1 or value.max_input_frames > 128:
		return false
	if value.max_buffer_bytes < 1 or value.max_buffer_bytes > 16777216:
		return false
	for bound: int in [value.max_pending_frames, value.max_received_frames, value.max_outbox, value.max_events, value.max_transitions]:
		if bound < 1 or bound > 4096:
			return false
	return true
