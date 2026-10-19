class_name FortressSpectatorPublisher
extends RefCounted

# gdlint: disable=constant-name,max-returns
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Stream = preload("res://addons/fortress_rollback/core/spectator_stream.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Code = Types.Code

## One host's bounded confirmed-row cursor. Acknowledgement means transport acceptance, not delivery.
## The caller authenticates recipients, retries delivery and stops the host before finish_host().
var _host: Session
var _source_config: RefCounted
var _identity: PackedByteArray
var _players: int = 0
var _width: int = 0
var _next_frame: int = 0
var _end_frame: int = -1
var _packet: PackedByteArray
var _finished: bool = false


## A fresh publisher starts from frame zero; later admission needs separate state transfer.
func configure(host: Session, identity: PackedByteArray, max_packet_bytes: int) -> int:
	if _host != null and _host._mutation_code() == Code.BUSY:
		return Code.BUSY
	if host == null or host._config == null or identity.size() != 32:
		return Code.INVALID_CONFIGURATION
	var code: int = host._mutation_code()
	if code != Code.OK:
		return code
	if Stream.HEADER_BYTES + host._config.player_count * host._config.input_width > max_packet_bytes:
		return Code.INVALID_CONFIGURATION
	_host = host
	_source_config = host._config
	_identity = identity.duplicate()
	_players = host._config.player_count
	_width = host._config.input_width
	_next_frame = 0
	_end_frame = -1
	_packet = PackedByteArray()
	_finished = false
	return Code.OK


func next_frame() -> int:
	return _next_frame


## Returns one owned packet; repeated calls preserve the exact refused FIFO head.
## No available row returns PREDICTION_STALL. Missing overwritten history is explicit.
func prepare_packet() -> Types.InputResult:
	var result: Types.InputResult = Types.InputResult.new()
	result.frame = _next_frame
	if _host == null:
		result.code = Code.NOT_CONFIGURED
		return result
	if _finished:
		result.code = Code.TERMINATED
		return result
	if _host._config != _source_config:
		result.code = Code.INVALID_CONFIGURATION
		return result
	var code: int = _host._mutation_code()
	if code != Code.OK:
		result.code = code
		return result
	var status: Types.Status = _host.status()
	if _end_frame >= 0 and status.current_frame != _end_frame:
		result.code = Code.INVALID_FRAME
		return result
	if not _packet.is_empty():
		if (
			_packet[5] == Stream.ROW
			and status.pending_rollback_frame < 0
			and _next_frame + 1 < status.current_frame
			and _next_frame + 1 <= status.confirmed_frame
			and _host.confirmed_inputs(_next_frame + 1) == null
		):
			result.code = Code.HISTORY_UNAVAILABLE
			return result
		result.bytes = _packet.duplicate()
		return result
	if _end_frame == _next_frame:
		_packet = _header(Stream.END, _end_frame)
	elif _next_frame < status.current_frame and _next_frame <= status.confirmed_frame:
		var inputs: Types.FrameInputs = _host.confirmed_inputs(_next_frame)
		if inputs == null:
			result.code = Code.PREDICTION_STALL if status.pending_rollback_frame >= 0 else Code.HISTORY_UNAVAILABLE
			return result
		_packet = _header(Stream.ROW, _next_frame)
		for player: int in range(_players):
			_packet.append_array(inputs.read(player).bytes)
	else:
		result.code = Code.PREDICTION_STALL
		return result
	result.bytes = _packet.duplicate()
	return result


## Advance only after the caller's transport accepts the complete current packet.
## Refusals need no acknowledgement; returned bytes cannot mutate the retained head.
func acknowledge_packet(packet: PackedByteArray) -> int:
	if _host == null:
		return Code.NOT_CONFIGURED
	var code: int = _host._mutation_code()
	if code != Code.OK:
		return code
	if _host._config != _source_config or _packet.is_empty() or packet != _packet:
		return Code.STALE_REQUEST
	if _end_frame >= 0 and _host.status().current_frame != _end_frame:
		return Code.INVALID_FRAME
	if _packet[5] == Stream.ROW:
		_next_frame += 1
	else:
		_finished = true
	_packet = PackedByteArray()
	return Code.OK


## Independent liveness packet: a refused row must not prevent an idle host heartbeat.
func encode_keepalive() -> PackedByteArray:
	if _host == null or _host._config != _source_config or _host._mutation_code() != Code.OK or _finished:
		return PackedByteArray()
	if _end_frame >= 0 and _host.status().current_frame != _end_frame:
		return PackedByteArray()
	return _header(Stream.KEEPALIVE, 0)


## Freeze the exclusive fully confirmed end, then publish retained rows before END.
## The host must remain stopped and configured until every prepared packet is accepted.
func finish_host() -> int:
	if _host == null:
		return Code.NOT_CONFIGURED
	var code: int = _host._mutation_code()
	if code != Code.OK:
		return code
	if _host._config != _source_config:
		return Code.INVALID_CONFIGURATION
	var status: Types.Status = _host.status()
	if status.pending_rollback_frame >= 0 or status.confirmed_frame < status.current_frame - 1:
		return Code.PREDICTION_STALL
	if _end_frame >= 0 and _end_frame != status.current_frame:
		return Code.INVALID_FRAME
	_end_frame = status.current_frame
	return Code.OK


func _header(kind: int, frame: int) -> PackedByteArray:
	return Stream.encode_header(kind, frame, _players, _width, _identity)
