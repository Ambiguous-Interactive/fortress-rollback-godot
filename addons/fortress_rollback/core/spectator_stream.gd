class_name FortressSpectatorStream
extends RefCounted

# gdlint: disable=constant-name,max-returns
const Spectator = preload("res://addons/fortress_rollback/core/spectator_session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Code = Types.Code
const VERSION: int = 2
const HEADER_BYTES: int = 80
const DIGEST_BYTES: int = 16
const TAG_BYTES: int = 16
const KEY_BYTES: int = 32
const ROW: int = 1
const END: int = 2
const KEEPALIVE: int = 3

## Confirmed-row byte envelope, separate from the player protocol.
## Every packet carries a keyed tag over its header and body, so only a host
## that holds the shared key can produce a packet the viewer accepts.
## One packet owns one complete row. Caller-owned transport retries refused packets.
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


## Identity is session (16 bytes), host (8 bytes), then connection lifetime (8 bytes).
## The key authenticates the host, the digest binds the agreed match configuration.
## Reconfiguration creates a fresh viewer; create a fresh game/driver with playback_session().
## The caller's playback policy survives reconfiguration when it still fits the new ring.
func configure(
	config: Config, identity: PackedByteArray, key: PackedByteArray, digest: PackedByteArray, now_us: int, timeout_us: int, max_packet_bytes: int
) -> int:
	if config == null or identity.size() != 32 or key.size() != KEY_BYTES or digest.size() != DIGEST_BYTES or now_us < 0 or timeout_us < 1:
		return Code.INVALID_CONFIGURATION
	if config.validate() != Code.OK or not config.spectator or HEADER_BYTES + config.player_count * config.input_width > max_packet_bytes:
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
	if policy.size() == 3:
		# A policy that no longer fits the new ring falls back to the session defaults.
		session.set_playback(policy[0], policy[1], policy[2])
	return Code.OK


func playback_session() -> Spectator:
	return _session


## Encode only host-confirmed complete rows. Empty bytes mean invalid dimensions or frame.
## The host must obtain its rows through confirmed_inputs(), after correction completes.
func encode_row(frame: int, inputs: Array[PackedByteArray]) -> PackedByteArray:
	if _config == null or _session._config != _config or frame < 0 or frame >= Queue.FRAME_MAX or inputs.size() != _config.player_count:
		return PackedByteArray()
	for bytes: PackedByteArray in inputs:
		if bytes.size() != _config.input_width:
			return PackedByteArray()
	var packet: PackedByteArray = _header(ROW, frame)
	for bytes: PackedByteArray in inputs:
		packet.append_array(bytes)
	return authenticate(packet, _key)


## Exclusive final frame; END may arrive before its rows, which remain receivable until complete.
func encode_end(final_frame: int) -> PackedByteArray:
	if _config == null or _session._config != _config or final_frame < 0 or final_frame > Queue.FRAME_MAX:
		return PackedByteArray()
	return authenticate(_header(END, final_frame), _key)


## Authenticated host liveness without input progress; requires a receiver supporting kind 3.
## Send before the timeout while confirmation stalls or row delivery is backpressured.
func encode_keepalive() -> PackedByteArray:
	if _config == null or _session._config != _config:
		return PackedByteArray()
	return authenticate(_header(KEEPALIVE, 0), _key)


## No receive queue is retained. Backpressure/BUSY leave this packet caller-owned for retry.
## Foreign identity, foreign configuration and forged packets are inert. Conflicting accepted history is terminal.
func receive_packet(packet: PackedByteArray, now_us: int) -> int:
	if _session == null:
		return Code.NOT_CONFIGURED
	if _session._config != _config:
		return Code.INVALID_CONFIGURATION
	if packet.size() < HEADER_BYTES or packet.slice(12, 44) != _identity:
		return Code.PROTOCOL_FAILED
	var kind: int = packet[5]
	var expected_size: int = HEADER_BYTES + (_config.player_count * _config.input_width if kind == ROW else 0)
	if (
		packet.size() != expected_size
		or packet.slice(0, 4) != "FRGS".to_ascii_buffer()
		or packet[4] != VERSION
		or kind not in [ROW, END, KEEPALIVE]
		or packet[6] != _config.player_count
		or packet[7] != 0
		or packet.decode_u32(8) != _config.input_width
		or packet.slice(44, 60) != _digest
	):
		return Code.PROTOCOL_FAILED
	if not tag_matches(packet, _key):
		return Code.PROTOCOL_FAILED
	var frame: int = packet.decode_u32(60)
	if frame > Queue.FRAME_MAX or (kind == ROW and frame == Queue.FRAME_MAX) or (kind == KEEPALIVE and frame != 0):
		return Code.INVALID_FRAME
	var code: int = poll(now_us)
	if code != Code.OK:
		return code
	if _is_finished:
		return Code.TERMINATED
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
		code = _session.receive_host_frame(frame, row).code
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


func _header(kind: int, frame: int) -> PackedByteArray:
	return encode_header(kind, frame, _config.player_count, _config.input_width, _identity, _digest)


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


## Shared fixed-width writer for configured stream and host publisher implementations.
static func encode_header(kind: int, frame: int, players: int, width: int, identity: PackedByteArray, digest: PackedByteArray) -> PackedByteArray:
	if identity.size() != 32 or digest.size() != DIGEST_BYTES or kind not in [ROW, END, KEEPALIVE]:
		return PackedByteArray()
	if players < Config.MIN_PLAYERS or players > Config.MAX_PLAYERS or width < Config.MIN_INPUT_WIDTH or width > Config.MAX_INPUT_WIDTH:
		return PackedByteArray()
	if frame < 0 or frame > Queue.FRAME_MAX or (kind == ROW and frame == Queue.FRAME_MAX) or (kind == KEEPALIVE and frame != 0):
		return PackedByteArray()
	var buffer: StreamPeerBuffer = StreamPeerBuffer.new()
	buffer.big_endian = false
	buffer.put_data("FRGS".to_ascii_buffer())
	buffer.put_u8(VERSION)
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
