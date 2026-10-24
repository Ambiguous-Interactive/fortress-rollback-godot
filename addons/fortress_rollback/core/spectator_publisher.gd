class_name FortressSpectatorPublisher
extends RefCounted

# gdlint: disable=constant-name,max-returns
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Stream = preload("res://addons/fortress_rollback/core/spectator_stream.gd")
const Negotiation = preload("res://addons/fortress_rollback/core/spectator_negotiation.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Code = Types.Code

## One host's bounded confirmed-row cursor. Acknowledgement means transport acceptance, not delivery.
## The caller authenticates recipients, retries delivery and stops the host before finish_host().
## The host offers the envelope version and the optional kinds before its first row.
var _host: Session
var _source_config: RefCounted
var _identity: PackedByteArray
var _key: PackedByteArray
var _digest: PackedByteArray
var _players: int = 0
var _width: int = 0
var _next_frame: int = 0
var _end_frame: int = -1
var _packet: PackedByteArray
var _finished: bool = false
var _negotiation: Negotiation = Negotiation.new()
var _offered_versions: int = 0
var _offered_kinds: int = 0
var _accept: PackedByteArray = PackedByteArray()


## A fresh publisher starts from frame zero; later admission needs separate state transfer.
## The key authenticates every published packet; the digest binds the agreed match configuration.
## A fresh publisher starts without an envelope agreement; it offers one before any row.
func configure(host: Session, identity: PackedByteArray, key: PackedByteArray, digest: PackedByteArray, max_packet_bytes: int) -> int:
	if _host != null and _host._mutation_code() == Code.BUSY:
		return Code.BUSY
	if host == null or host._config == null or identity.size() != 32 or key.size() != Stream.KEY_BYTES or digest.size() != Stream.DIGEST_BYTES:
		return Code.INVALID_CONFIGURATION
	var code: int = host._mutation_code()
	if code != Code.OK:
		return code
	if max(Stream.HEADER_BYTES + host._config.player_count * (host._config.input_width + 1), Stream.NEGOTIATION_BYTES) > max_packet_bytes:
		return Code.INVALID_CONFIGURATION
	_host = host
	_source_config = host._config
	_identity = identity.duplicate()
	_key = key.duplicate()
	_digest = digest.duplicate()
	_players = host._config.player_count
	_width = host._config.input_width
	_next_frame = 0
	_end_frame = -1
	_packet = PackedByteArray()
	_finished = false
	_negotiation.reset()
	_offered_versions = Negotiation.supported_versions(Stream.VERSION)
	_offered_kinds = Negotiation.CAP_ALL
	_accept = PackedByteArray()
	return Code.OK


func next_frame() -> int:
	return _next_frame


## PENDING before the startup exchange, AGREED after it and REFUSED after it fails.
func agreement_state() -> int:
	return _negotiation.state()


## The agreed envelope version, or zero before the agreement.
func agreement_version() -> int:
	return _negotiation.version()


## The agreed optional kinds, or zero before the agreement.
func agreement_kinds() -> int:
	return _negotiation.kinds()


## The one recorded refusal reason, or OK while the agreement holds.
func agreement_reason() -> int:
	return _negotiation.reason()


## One authenticated startup offer. The viewer answers it with its own accept packet.
func encode_offer() -> PackedByteArray:
	if _host == null or _host._config != _source_config or _host._mutation_code() != Code.OK:
		return PackedByteArray()
	return Stream.encode_offer(_identity, _digest, _players, _width, _key)


## Accept the viewer's answer to the startup offer. The answer is authenticated, so a
## peer cannot choose a weaker envelope without the shared key. A refused answer
## records one reason and keeps the host from publishing any row.
func receive_accept(packet: PackedByteArray) -> int:
	if _host == null:
		return Code.NOT_CONFIGURED
	if _host._config != _source_config:
		return Code.INVALID_CONFIGURATION
	var code: int = _host._mutation_code()
	if code != Code.OK:
		return code
	if packet.size() != Stream.NEGOTIATION_BYTES:
		return Code.PROTOCOL_FAILED
	if not Stream.header_matches(packet, Negotiation.ACCEPT, _identity, _digest, _players, _width):
		return Code.PROTOCOL_FAILED
	if not Stream.tag_matches(packet, _key):
		return Code.PROTOCOL_FAILED
	if packet.decode_u32(60) != 0:
		return Code.PROTOCOL_FAILED
	if _negotiation.refused():
		# A refused agreement is terminal; the host publishes nothing after it.
		return _negotiation.reason()
	if _negotiation.agreed():
		# A retried answer repeats the same agreement; a different one is a protocol failure.
		return Code.OK if packet == _accept else Code.PROTOCOL_FAILED
	var capabilities: PackedInt64Array = Negotiation.decode_capabilities(packet, Stream.HEADER_BYTES)
	if capabilities.size() != 2:
		return Code.PROTOCOL_FAILED
	var accepted_versions: int = capabilities[0]
	var accepted_kinds: int = capabilities[1]
	var chosen: int = packet[4]
	if chosen < 1 or chosen > Negotiation.MAX_VERSION or (accepted_versions & (1 << chosen)) == 0:
		return Code.PROTOCOL_FAILED
	if (_offered_versions & (1 << chosen)) == 0:
		return _refuse(Code.UNSUPPORTED)
	if not Negotiation.kinds_within(accepted_kinds, _offered_kinds):
		return _refuse(Code.UNSUPPORTED)
	_negotiation.agree(chosen, accepted_kinds)
	_accept = packet.duplicate()
	return Code.OK


## Returns one owned packet; repeated calls preserve the exact refused FIFO head.
## No available row returns PREDICTION_STALL. Missing overwritten history is explicit.
## The envelope agreement comes first; an unagreed host publishes no row.
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
	if not _negotiation.agreed():
		result.code = Code.NOT_SYNCHRONIZED
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
		_packet = _signed(_header(Stream.END, _end_frame))
	elif _next_frame < status.current_frame and _next_frame <= status.confirmed_frame:
		var inputs: Types.FrameInputs = _host.confirmed_inputs(_next_frame)
		if inputs == null:
			result.code = Code.PREDICTION_STALL if status.pending_rollback_frame >= 0 else Code.HISTORY_UNAVAILABLE
			return result
		var packet: PackedByteArray = _header(Stream.ROW, _next_frame)
		var statuses: PackedByteArray = PackedByteArray()
		for player: int in range(_players):
			var input: Types.InputResult = inputs.read(player)
			if input.code != Code.OK or input.status not in [Session.Queue.Status.CONFIRMED, Session.Queue.Status.DISCONNECTED]:
				result.code = Code.INVALID_CONFIGURATION
				return result
			packet.append_array(input.bytes)
			statuses.append(input.status)
		packet.append_array(statuses)
		_packet = _signed(packet)
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
	if not _negotiation.agreed() or (_negotiation.kinds() & Negotiation.CAP_KEEPALIVE) == 0:
		return PackedByteArray()
	if _end_frame >= 0 and _host.status().current_frame != _end_frame:
		return PackedByteArray()
	return _signed(_header(Stream.KEEPALIVE, 0))


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


## One refusal reason ends the agreement; the host publishes no row after it.
func _refuse(reason: int) -> int:
	_negotiation.refuse(reason)
	return reason


func _header(kind: int, frame: int) -> PackedByteArray:
	return Stream.encode_header(kind, frame, _players, _width, _identity, _digest, _negotiation.version())


## Every published packet carries the keyed tag that the viewer verifies.
func _signed(packet: PackedByteArray) -> PackedByteArray:
	return Stream.authenticate(packet, _key)
