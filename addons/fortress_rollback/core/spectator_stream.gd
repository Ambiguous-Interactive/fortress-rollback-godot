class_name FortressSpectatorStream
extends RefCounted

# gdlint: disable=constant-name,max-returns
const Spectator = preload("res://addons/fortress_rollback/core/spectator_session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Negotiation = preload("res://addons/fortress_rollback/core/spectator_negotiation.gd")
const Code = Types.Code
const VERSION: int = 3
const HEADER_BYTES: int = 80
const DIGEST_BYTES: int = 16
const TAG_BYTES: int = 16
const KEY_BYTES: int = 32
const ROW: int = 1
const END: int = 2
const KEEPALIVE: int = 3
const OFFER: int = Negotiation.OFFER
const ACCEPT: int = Negotiation.ACCEPT
const NEGOTIATION_BYTES: int = HEADER_BYTES + Negotiation.CAPABILITY_BYTES

## Confirmed-row byte envelope, separate from the player protocol.
## Every packet carries a keyed tag over its header and body, so only a host
## that holds the shared key can produce a packet the viewer accepts.
## One packet owns one complete row. Caller-owned transport retries refused packets.
## The envelope version and the optional kinds are negotiated before the first row,
## so a peer that speaks another envelope fails at startup instead of mid-playback.
## Callers agree neutral input, initial game state, seed and rules before opening this stream;
## the agreed configuration digest travels in every packet and fences a mismatched match.
var _session: Spectator
var _config: Config
var _identity: PackedByteArray
var _key: PackedByteArray
var _digest: PackedByteArray
var _timeout_us: int = 0
var _last_time: int = 0
var _last_received: int = 0
var _end_frame: int = -1
var _highest_frame: int = -1
var _is_finished: bool = false
var _negotiation: Negotiation = Negotiation.new()
var _offer: PackedByteArray = PackedByteArray()


## Identity is session (16 bytes), host (8 bytes), then connection lifetime (8 bytes).
## The key authenticates the host, the digest binds the agreed match configuration.
## Reconfiguration creates a fresh viewer and a fresh envelope agreement.
## The caller's playback policy survives reconfiguration when it still fits the new ring.
func configure(
	config: Config, identity: PackedByteArray, key: PackedByteArray, digest: PackedByteArray, now_us: int, timeout_us: int, max_packet_bytes: int
) -> int:
	if config == null or identity.size() != 32 or key.size() != KEY_BYTES or digest.size() != DIGEST_BYTES or now_us < 0 or timeout_us < 1:
		return Code.INVALID_CONFIGURATION
	if config.validate() != Code.OK or not config.spectator or max(HEADER_BYTES + config.player_count * (config.input_width + 1), NEGOTIATION_BYTES) > max_packet_bytes:
		return Code.INVALID_CONFIGURATION
	if _session != null and _session._mutation_code() == Code.BUSY:
		return Code.BUSY
	var policy: PackedInt64Array = PackedInt64Array()
	if _session != null:
		policy = _session.playback_policy()
	var session: Spectator = Spectator.new()
	var code: int = session.configure(config)
	if code != Code.OK:
		return code
	_session = session
	_config = session._config
	_identity = identity.duplicate()
	_key = key.duplicate()
	_digest = digest.duplicate()
	_timeout_us = timeout_us
	_last_time = now_us
	_last_received = now_us
	_end_frame = -1
	_highest_frame = -1
	_is_finished = false
	_negotiation.reset()
	_offer = PackedByteArray()
	if policy.size() == 3:
		# A policy that no longer fits the new ring falls back to the session defaults.
		session.set_playback(policy[0], policy[1], policy[2])
	return Code.OK


func playback_session() -> Spectator:
	return _session


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


## Encode only host-confirmed complete rows. Empty bytes mean invalid dimensions or frame.
## The host obtains bytes and statuses through confirmed_inputs(), after correction completes.
## Omitted statuses retain the byte-only API's all-confirmed default.
## A row needs the agreed envelope version, so it cannot be encoded before the startup exchange.
func encode_row(frame: int, inputs: Array[PackedByteArray], statuses: PackedByteArray = PackedByteArray()) -> PackedByteArray:
	if not _negotiation.agreed() or _config == null or _session._config != _config:
		return PackedByteArray()
	if frame < 0 or frame >= Queue.FRAME_MAX or inputs.size() != _config.player_count:
		return PackedByteArray()
	for bytes: PackedByteArray in inputs:
		if bytes.size() != _config.input_width:
			return PackedByteArray()
	var finalized: PackedByteArray = Spectator.finalized_statuses(statuses, _config.player_count)
	if finalized.is_empty():
		return PackedByteArray()
	var packet: PackedByteArray = _header(ROW, frame)
	for bytes: PackedByteArray in inputs:
		packet.append_array(bytes)
	packet.append_array(finalized)
	return authenticate(packet, _key)


## Exclusive final frame; END may arrive before its rows, which remain receivable until complete.
func encode_end(final_frame: int) -> PackedByteArray:
	if not _negotiation.agreed() or _config == null or _session._config != _config:
		return PackedByteArray()
	if final_frame < 0 or final_frame > Queue.FRAME_MAX:
		return PackedByteArray()
	return authenticate(_header(END, final_frame), _key)


## Authenticated host liveness without input progress; requires a receiver supporting kind 3.
## Send before the timeout while confirmation stalls or row delivery is backpressured.
func encode_keepalive() -> PackedByteArray:
	if not _negotiation.agreed() or _config == null or _session._config != _config:
		return PackedByteArray()
	if not _kind_agreed(KEEPALIVE):
		return PackedByteArray()
	return authenticate(_header(KEEPALIVE, 0), _key)


## One authenticated startup offer for the agreed identity and dimensions.
## The host sends it before its first row; the viewer answers with encode_accept().
static func encode_offer(identity: PackedByteArray, digest: PackedByteArray, players: int, width: int, key: PackedByteArray) -> PackedByteArray:
	var packet: PackedByteArray = encode_header(OFFER, 0, players, width, identity, digest, VERSION)
	if packet.is_empty():
		return PackedByteArray()
	packet.append_array(Negotiation.encode_capabilities(Negotiation.supported_versions(VERSION), Negotiation.CAP_ALL))
	return authenticate(packet, key)


## The authenticated answer to one accepted offer. Empty bytes mean no agreement yet.
func encode_accept() -> PackedByteArray:
	if not _negotiation.agreed() or _config == null or _session._config != _config:
		return PackedByteArray()
	var packet: PackedByteArray = encode_header(ACCEPT, 0, _config.player_count, _config.input_width, _identity, _digest, _negotiation.version())
	if packet.is_empty():
		return PackedByteArray()
	packet.append_array(Negotiation.encode_capabilities(Negotiation.supported_versions(_negotiation.version()), _negotiation.kinds()))
	return authenticate(packet, _key)


## No receive queue is retained. Backpressure/BUSY leave this packet caller-owned for retry.
## Foreign identity, foreign configuration and forged packets are inert. Conflicting accepted history is terminal.
func receive_packet(packet: PackedByteArray, now_us: int) -> int:
	if _session == null:
		return Code.NOT_CONFIGURED
	if _session._config != _config:
		return Code.INVALID_CONFIGURATION
	if packet.size() < 6:
		return Code.PROTOCOL_FAILED
	var kind: int = packet[5]
	if kind == OFFER:
		return _receive_offer(packet, now_us)
	if packet.size() < HEADER_BYTES or packet.slice(12, 44) != _identity:
		return Code.PROTOCOL_FAILED
	if not _negotiation.agreed():
		# The startup exchange owns the envelope version, so no row is accepted before it.
		var state: int = _session._mutation_code()
		return state if state != Code.OK else Code.NOT_SYNCHRONIZED
	var expected_size: int = HEADER_BYTES + (_config.player_count * (_config.input_width + 1) if kind == ROW else 0)
	if (
		packet.size() != expected_size
		or packet.slice(0, 4) != "FRGS".to_ascii_buffer()
		or kind not in [ROW, END, KEEPALIVE]
		or not _kind_agreed(kind)
		or packet[6] != _config.player_count
		or packet[7] != 0
		or packet.decode_u32(8) != _config.input_width
		or packet.slice(44, 60) != _digest
	):
		return Code.PROTOCOL_FAILED
	if not tag_matches(packet, _key):
		return Code.PROTOCOL_FAILED
	# The version is read after the tag, so only an authenticated peer can refuse the envelope.
	var version: int = packet[4]
	if version < 1 or version > Negotiation.MAX_VERSION:
		return Code.PROTOCOL_FAILED
	var frame: int = packet.decode_u32(60)
	if frame > Queue.FRAME_MAX or (kind == ROW and frame == Queue.FRAME_MAX) or (kind == KEEPALIVE and frame != 0):
		return Code.INVALID_FRAME
	var statuses: PackedByteArray = packet.slice(HEADER_BYTES + _config.player_count * _config.input_width) if kind == ROW else PackedByteArray()
	if kind == ROW and Spectator.finalized_statuses(statuses, _config.player_count).is_empty():
		return Code.INVALID_CONFIGURATION
	var code: int = poll(now_us)
	if code != Code.OK:
		return code
	if _is_finished:
		return Code.TERMINATED
	if version != _negotiation.version():
		return _refuse(Code.UNSUPPORTED)
	code = _session._mutation_code()
	if code != Code.OK:
		return code
	if kind == END:
		if (_end_frame >= 0 and _end_frame != frame) or frame <= _highest_frame:
			return _fail()
		_end_frame = frame
	elif kind == ROW:
		if _end_frame >= 0 and frame >= _end_frame:
			return _fail()
		var row: Array[PackedByteArray] = []
		for player: int in range(_config.player_count):
			var start: int = HEADER_BYTES + player * _config.input_width
			row.append(packet.slice(start, start + _config.input_width))
		code = _session.receive_host_frame(frame, row, statuses).code
		if code == Code.INPUT_ALREADY_SUBMITTED:
			return _fail()
		if code != Code.OK:
			return code
		_highest_frame = maxi(_highest_frame, frame)
	_last_received = now_us
	if _end_frame >= 0 and _session.host_frontier() + 1 == _end_frame:
		code = _session.finish_host()
		if code == Code.OK:
			_is_finished = true
	return code


## Accept one startup offer. The exchange is authenticated, so a peer cannot choose
## a weaker envelope without the shared key. A refused offer records one reason and
## terminates the viewer before any row is played.
func _receive_offer(packet: PackedByteArray, now_us: int) -> int:
	if now_us < _last_time:
		return Code.INVALID_TIME
	if packet.size() != NEGOTIATION_BYTES:
		return Code.PROTOCOL_FAILED
	if not header_matches(packet, OFFER, _identity, _digest, _config.player_count, _config.input_width):
		return Code.PROTOCOL_FAILED
	if not tag_matches(packet, _key):
		return Code.PROTOCOL_FAILED
	if packet.decode_u32(60) != 0:
		return Code.PROTOCOL_FAILED
	var capabilities: PackedInt64Array = Negotiation.decode_capabilities(packet, HEADER_BYTES)
	if capabilities.size() != 2:
		return Code.PROTOCOL_FAILED
	var offered_versions: int = capabilities[0]
	var offered_kinds: int = capabilities[1]
	var preferred: int = packet[4]
	if preferred < 1 or preferred > Negotiation.MAX_VERSION or (offered_versions & (1 << preferred)) == 0:
		return Code.PROTOCOL_FAILED
	var code: int = poll(now_us)
	if code != Code.OK:
		return code
	if _is_finished:
		return Code.TERMINATED
	if _negotiation.agreed():
		# A retried offer repeats the same agreement and refreshes the host liveness.
		if packet != _offer:
			return _fail()
		_last_received = now_us
		return Code.OK
	if _negotiation.refused():
		# A refused agreement is terminal; the viewer already stopped.
		return Code.TERMINATED
	if not Negotiation.kinds_acceptable(offered_kinds):
		return _refuse(Code.UNSUPPORTED)
	var version: int = Negotiation.common_version(offered_versions, Negotiation.supported_versions(VERSION))
	if version == 0:
		return _refuse(Code.UNSUPPORTED)
	_negotiation.agree(version, offered_kinds)
	_offer = packet.duplicate()
	_last_received = now_us
	return Code.OK


## Inject monotonic microseconds. Expiry wins over a newly arrived packet at the deadline.
## Poll independently of playback, including while a host gap or transport refusal persists.
func poll(now_us: int) -> int:
	if _session == null:
		return Code.NOT_CONFIGURED
	if _session._config != _config:
		return Code.INVALID_CONFIGURATION
	if now_us < 0 or now_us < _last_time:
		return Code.INVALID_TIME
	var code: int = _session._mutation_code()
	if code != Code.OK:
		return code
	_last_time = now_us
	if not _is_finished and now_us - _last_received >= _timeout_us:
		return _fail()
	return Code.OK


func _fail() -> int:
	_session.terminate(Code.PROTOCOL_FAILED)
	return Code.PROTOCOL_FAILED


## One refusal reason ends the viewer before it plays anything.
func _refuse(reason: int) -> int:
	_negotiation.refuse(reason)
	_session.terminate(reason)
	return reason


## True when the agreed kinds carry the packet kind.
func _kind_agreed(kind: int) -> bool:
	var capability: int = 0
	match kind:
		ROW:
			capability = Negotiation.CAP_ROW
		END:
			capability = Negotiation.CAP_END
		KEEPALIVE:
			capability = Negotiation.CAP_KEEPALIVE
	return capability != 0 and (_negotiation.kinds() & capability) != 0


func _header(kind: int, frame: int) -> PackedByteArray:
	return encode_header(kind, frame, _config.player_count, _config.input_width, _identity, _digest, _negotiation.version())


## The agreed configuration digest binds the dimensions, the neutral input, the seed and the rules version.
## Both sides derive it from the same match, so a viewer configured for another match refuses every packet.
static func configuration_digest(config: Variant, seed: String, rules_version: String) -> PackedByteArray:
	if not config is Config:
		return PackedByteArray()
	if config.player_count < Config.MIN_PLAYERS or config.player_count > Config.MAX_PLAYERS:
		return PackedByteArray()
	if config.input_width < Config.MIN_INPUT_WIDTH or config.input_width > Config.MAX_INPUT_WIDTH or config.neutral_input.size() != config.input_width:
		return PackedByteArray()
	var seed_bytes: PackedByteArray = seed.to_utf8_buffer()
	var version_bytes: PackedByteArray = rules_version.to_utf8_buffer()
	if not _printable(seed_bytes) or not _printable(version_bytes):
		return PackedByteArray()
	var writer: StreamPeerBuffer = StreamPeerBuffer.new()
	writer.big_endian = false
	writer.put_u32(config.player_count)
	writer.put_u32(config.input_width)
	writer.put_data(config.neutral_input)
	writer.put_u32(seed_bytes.size())
	writer.put_data(seed_bytes)
	writer.put_u32(version_bytes.size())
	writer.put_data(version_bytes)
	var hashing: HashingContext = HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(writer.data_array)
	return hashing.finish().slice(0, DIGEST_BYTES)


## Append the keyed tag that authenticates the header and the body of one packet.
## The tag sits between the header and the body, so the body keeps its fixed offset.
static func authenticate(packet: PackedByteArray, key: PackedByteArray) -> PackedByteArray:
	if key.size() != KEY_BYTES or packet.size() < HEADER_BYTES - TAG_BYTES:
		return PackedByteArray()
	var context: HMACContext = HMACContext.new()
	context.start(HashingContext.HASH_SHA256, key)
	context.update(packet)
	var tag: PackedByteArray = context.finish().slice(0, TAG_BYTES)
	var signed: PackedByteArray = packet.slice(0, HEADER_BYTES - TAG_BYTES)
	signed.append_array(tag)
	signed.append_array(packet.slice(HEADER_BYTES - TAG_BYTES))
	return signed


## True when the packet carries the tag of its own header and body under the shared key.
static func tag_matches(packet: PackedByteArray, key: PackedByteArray) -> bool:
	if key.size() != KEY_BYTES or packet.size() < HEADER_BYTES:
		return false
	var unsigned: PackedByteArray = packet.slice(0, HEADER_BYTES - TAG_BYTES)
	unsigned.append_array(packet.slice(HEADER_BYTES))
	var expected: PackedByteArray = authenticate(unsigned, key)
	return _equal(expected, packet)


## True when the packet carries the expected envelope header fields.
static func header_matches(packet: PackedByteArray, kind: int, identity: PackedByteArray, digest: PackedByteArray, players: int, width: int) -> bool:
	if packet.size() < HEADER_BYTES or packet.slice(0, 4) != "FRGS".to_ascii_buffer() or packet[5] != kind:
		return false
	if packet.slice(12, 44) != identity or packet.slice(44, 60) != digest:
		return false
	return packet[6] == players and packet[7] == 0 and packet.decode_u32(8) == width


## Shared fixed-width writer for configured stream and host publisher implementations.
static func encode_header(
	kind: int, frame: int, players: int, width: int, identity: PackedByteArray, digest: PackedByteArray, version: int = VERSION
) -> PackedByteArray:
	if identity.size() != 32 or digest.size() != DIGEST_BYTES:
		return PackedByteArray()
	if kind not in [ROW, END, KEEPALIVE, OFFER, ACCEPT]:
		return PackedByteArray()
	if players < Config.MIN_PLAYERS or players > Config.MAX_PLAYERS or width < Config.MIN_INPUT_WIDTH or width > Config.MAX_INPUT_WIDTH:
		return PackedByteArray()
	if version < 1 or version > Negotiation.MAX_VERSION:
		return PackedByteArray()
	if frame < 0 or frame > Queue.FRAME_MAX or (kind == ROW and frame == Queue.FRAME_MAX) or (kind == KEEPALIVE and frame != 0):
		return PackedByteArray()
	if kind in [OFFER, ACCEPT] and frame != 0:
		return PackedByteArray()
	var buffer: StreamPeerBuffer = StreamPeerBuffer.new()
	buffer.big_endian = false
	buffer.put_data("FRGS".to_ascii_buffer())
	buffer.put_u8(version)
	buffer.put_u8(kind)
	buffer.put_u8(players)
	buffer.put_u8(0)
	buffer.put_u32(width)
	buffer.put_data(identity)
	buffer.put_data(digest)
	buffer.put_u32(frame)
	return buffer.data_array


## Byte comparison without an early exit, so a wrong tag does not leak its position.
static func _equal(first: PackedByteArray, second: PackedByteArray) -> bool:
	if first.size() != second.size():
		return false
	var difference: int = 0
	for index: int in range(first.size()):
		difference |= first[index] ^ second[index]
	return difference == 0


## The seed and the rules version travel as printable ASCII, so both sides agree on one encoding.
static func _printable(bytes: PackedByteArray) -> bool:
	for value: int in bytes:
		if value < 32 or value > 126:
			return false
	return true
