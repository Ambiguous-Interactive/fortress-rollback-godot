class_name FortressInputEndpointTypes
extends RefCounted

enum Code { OK, INVALID_ARGUMENT, WRONG_STATE, INVALID_PACKET, WRONG_SOURCE, WRONG_CONNECTION, UNSUPPORTED_KIND, BACKPRESSURE, TOKEN_REUSED,
	BUSY, CONFLICT, INVALID_FRAME, INPUT_FAILED, TERMINATED }

## Largest input batch any peer may send. Received batches are checked against this, not the local send cap.
const MAX_INPUT_FRAMES: int = 128


## Plain-language name for a protocol endpoint result code. This enum is a separate
## numeric space from the session reasons, so it keeps its own text; unknown codes
## keep their number so diagnostics stay identifiable.
static func reason_text(code: int) -> String:
	match code:
		Code.OK:
			return "no failure"
		Code.INVALID_ARGUMENT:
			return "invalid call"
		Code.WRONG_STATE:
			return "unexpected transport state"
		Code.INVALID_PACKET:
			return "malformed packet"
		Code.WRONG_SOURCE:
			return "packet from the wrong source"
		Code.WRONG_CONNECTION:
			return "packet on the wrong connection"
		Code.UNSUPPORTED_KIND:
			return "unsupported packet kind"
		Code.BACKPRESSURE:
			return "blocked packets"
		Code.TOKEN_REUSED:
			return "transport token reused"
		Code.BUSY:
			return "waiting for packet service"
		Code.CONFLICT:
			return "conflicting packet delivery"
		Code.INVALID_FRAME:
			return "invalid frame"
		Code.INPUT_FAILED:
			return "confirmed input failed"
		Code.TERMINATED:
			return "session terminated"
		_:
			return "failure code %d" % code


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
	if value.retry_interval_us < 0 or value.max_input_frames < 1 or value.max_input_frames > MAX_INPUT_FRAMES:
		return false
	if value.max_buffer_bytes < 1 or value.max_buffer_bytes > 16777216:
		return false
	for bound: int in [value.max_pending_frames, value.max_received_frames, value.max_outbox, value.max_events, value.max_transitions]:
		if bound < 1 or bound > 4096:
			return false
	return true
