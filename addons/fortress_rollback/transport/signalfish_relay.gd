class_name FortressSignalFishRelay
extends RefCounted

# gdlint: disable=constant-name,max-returns
const Types = preload("res://addons/fortress_rollback/transport/signalfish_relay_types.gd")
const Envelope = preload("res://addons/fortress_rollback/transport/signalfish_relay_envelope.gd")
const Membership = preload("res://addons/fortress_rollback/transport/signalfish_membership.gd")
const Adapter = preload("res://addons/fortress_rollback/transport/signalfish_adapter.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const S = preload("res://addons/fortress_rollback/core/session_types.gd")
const Code = Types.Code
const Options = Types.Options
const Result = Types.Result

var _client: WeakRef = null
var _sdk_config: WeakRef = null
var _membership: Membership
var _adapter: Adapter
var _peer: Peer
var _options: Types.Options
var _session: PackedByteArray = PackedByteArray()
var _pending: Array[PackedByteArray] = []
var _received: Array[Envelope.Decoded] = []
var _pending_bytes: int = 0
var _received_bytes: int = 0
# Variant carries the peer's nullable handshake token owned by the current FIFO head.
var _receive_token: Variant = null
var _receive_token_ready: bool = false
var _failure: int = Code.OK
var _last_receive: int = Code.OK
var _rejected: int = 0
var _ignored: int = 0
var _busy: bool = false


## Use actual SDK config and ProtocolInfo observed before joining; JSON fallback is refused.
func configure(client: Object, sdk_config: Object, protocol_info: Object, membership: Membership, adapter: Adapter, peer: Peer, options: Types.Options = null) -> int:
	if _client != null:
		return Code.WRONG_STATE
	var controls: Types.Options = Types.Options.new() if options == null else options
	if client == null or sdk_config == null or protocol_info == null or membership == null or adapter == null or peer == null or not Types.valid_options(controls):
		return Code.INVALID_ARGUMENT
	if not client.has_method("send_game_data_binary") or not client.has_signal("game_data_binary_received") or not protocol_info.has_method("to_dict"):
		return Code.INVALID_ARGUMENT
	# Variant is the optional SDK's public protocol-info object boundary.
	var data: Variant = protocol_info.call("to_dict")
	if not data is Dictionary or not data.get("game_data_formats") is Array or data.game_data_formats.size() > 16:
		return Code.INCOMPATIBLE_MODE
	if not protocol_info.get("protocol_version") is int or protocol_info.get("protocol_version") < 3 or "message_pack" not in data.game_data_formats or not _raw_mode(sdk_config):
		return Code.INCOMPATIBLE_MODE
	for field: String in ["max_outbound_frame_bytes", "max_inbound_frame_bytes", "max_buffered_bytes", "max_inbound_packets_per_poll"]:
		if not sdk_config.get(field) is int or sdk_config.get(field) < 1:
			return Code.INVALID_ARGUMENT
	if sdk_config.get("max_inbound_packets_per_poll") > 4096:
		return Code.INVALID_ARGUMENT
	var frame_size: int = controls.max_packet_bytes + Envelope.HEADER_BYTES
	if sdk_config.get("max_buffered_bytes") < frame_size:
		return Code.TOO_LARGE
	if sdk_config.get("max_outbound_frame_bytes") < frame_size or sdk_config.get("max_inbound_frame_bytes") < frame_size + 128:
		return Code.TOO_LARGE
	if not protocol_info.get("max_outbound_message_size") is int or protocol_info.get("max_outbound_message_size") < frame_size + 128:
		return Code.TOO_LARGE
	if membership.handshake_message() == null or client.call("get_player_id") != membership.local_uuid():
		return Code.INVALID_ARGUMENT
	_client = weakref(client)
	_sdk_config = weakref(sdk_config)
	_membership = membership
	_adapter = adapter
	_peer = peer
	_options = Types.copy_options(controls)
	_session = membership.handshake_message().session_id
	client.connect("game_data_binary_received", _on_binary)
	return Code.OK


## Atomic batch ownership: retain the caller's drained batch until this returns OK.
## Every accepted packet is copied. A refusal leaves the caller's batch unchanged.
func enqueue_batch(packets: Array[Peer.Packet]) -> int:
	var gate: int = _gate()
	if gate != Code.OK:
		return gate
	if _busy:
		return Code.WRONG_STATE
	if packets.size() > _options.max_pending_packets or packets.size() + _pending.size() > _options.max_pending_packets:
		return Code.BACKPRESSURE
	var needed: int = 0
	var destinations: Array[String] = []
	for packet: Peer.Packet in packets:
		if packet == null or packet.bytes.is_empty():
			return Code.INVALID_ARGUMENT
		if packet.bytes.size() > _options.max_packet_bytes:
			return Code.TOO_LARGE
		needed += Envelope.HEADER_BYTES + packet.bytes.size()
		if needed > _options.max_pending_bytes - _pending_bytes:
			return Code.BACKPRESSURE
		var uuid: String = ""
		for member: String in _membership.roster():
			if _membership.identity(member) == packet.to:
				uuid = member
		if uuid.is_empty() or uuid == _membership.local_uuid():
			return Code.WRONG_SOURCE
		destinations.append(uuid)
	for index: int in packets.size():
		_pending.append(Envelope.encode(_session, _membership.local_uuid(), destinations[index], packets[index].bytes))
	_pending_bytes += needed
	return Code.OK


## Drain bounded work with injected time. Recoverable peer/SDK pressure retains the exact FIFO head.
## next_token_factory(from_uuid) returns each next unique handshake token, if required.
func poll(now_us: int, next_token_factory: Callable = Callable()) -> Types.Result:
	var gate: int = _gate()
	if gate != Code.OK:
		return Types.Result.new(gate)
	if _busy or now_us < 0:
		return Types.Result.new(Code.INVALID_ARGUMENT)
	_busy = true
	var result: Types.Result = Types.Result.new()
	for _index: int in mini(_options.max_receives_per_poll, _received.size()):
		var incoming: Envelope.Decoded = _received[0]
		if not _receive_token_ready:
			var candidate: Variant = next_token_factory.call(incoming.sender) if next_token_factory.is_valid() else null
			result.code = _gate()
			if result.code != Code.OK:
				break
			if candidate != null and (not candidate is PackedByteArray or candidate.size() != 16):
				_receive_token = null
				_failure = Code.INVALID_ARGUMENT
				result.code = _failure
				break
			_receive_token = candidate.duplicate() if candidate is PackedByteArray else null
			_receive_token_ready = true
		result.code = _gate()
		if result.code != Code.OK:
			break
		result.peer_code = _adapter.receive_relay(_peer, incoming.payload, incoming.sender, now_us, _receive_token)
		if result.peer_code != I.Code.OK:
			# Event-capacity pressure can commit termination; only a live peer can retry.
			if result.peer_code == I.Code.BACKPRESSURE and _peer.status().lifecycle == S.Lifecycle.RUNNING:
				result.code = Code.BACKPRESSURE
				break
			result.code = Code.PEER_FAILURE
			_failure = result.code
			break
		_received.pop_front()
		_received_bytes -= incoming.payload.size() + Envelope.HEADER_BYTES
		_receive_token = null
		_receive_token_ready = false
		result.received += 1
	var receive_pressure: bool = result.code == Code.BACKPRESSURE
	if result.code in [Code.OK, Code.BACKPRESSURE]:
		for _index: int in mini(_options.max_sends_per_poll, _pending.size()):
			result.code = _gate()
			if result.code != Code.OK:
				break
			var client: Object = _client.get_ref()
			var transport: Object = client.get("transport")
			if not is_instance_valid(transport) or not transport.has_method("get_buffered_amount"):
				_failure = Code.SDK_FAILURE
				result.code = _failure
				break
			var buffered: int = transport.call("get_buffered_amount")
			if buffered < 0 or buffered > _options.max_socket_buffered_bytes - _pending[0].size():
				result.code = Code.BACKPRESSURE
				break
			var sent: Error = client.call("send_game_data_binary", _pending[0].duplicate())
			if sent != OK:
				result.code = Code.BACKPRESSURE if sent == ERR_BUSY else Code.SDK_FAILURE
				if sent != ERR_BUSY:
					_failure = result.code
				break
			_pending_bytes -= _pending[0].size()
			_pending.pop_front()
			result.sent += 1
	if receive_pressure and result.code == Code.OK:
		result.code = Code.BACKPRESSURE
	_busy = false
	return result


func status() -> Dictionary:
	return {"code": _gate(), "pending_packets": _pending.size(), "pending_bytes": _pending_bytes, "received_packets": _received.size(),
		"received_bytes": _received_bytes, "last_receive_code": _last_receive, "rejected": _rejected, "ignored": _ignored}


func detach() -> void:
	if _busy:
		_failure = Code.WRONG_STATE
		return
	var client: Object = _client.get_ref() if _client != null else null
	if is_instance_valid(client) and client.is_connected("game_data_binary_received", _on_binary):
		client.disconnect("game_data_binary_received", _on_binary)
	_client = null
	_sdk_config = null
	_membership = null
	_adapter = null
	_peer = null
	_pending.clear()
	_received.clear()
	_pending_bytes = 0
	_received_bytes = 0
	_receive_token = null
	_receive_token_ready = false
	_failure = Code.OK


func _on_binary(from_uuid: String, encoding: int, bytes: PackedByteArray) -> void:
	var gate: int = _gate()
	if gate != Code.OK:
		_last_receive = gate
		return
	if encoding != 1:
		_reject(Code.INCOMPATIBLE_MODE)
		return
	if not Membership.valid_uuid(from_uuid) or from_uuid == _membership.local_uuid() or _membership.slot(from_uuid) < 0:
		_reject(Code.WRONG_SOURCE)
		return
	var decoded: Envelope.Decoded = Envelope.decode(bytes, _options.max_packet_bytes)
	if decoded.code != Code.OK:
		_reject(decoded.code)
		return
	if decoded.sender != from_uuid:
		_reject(Code.WRONG_SOURCE)
		return
	if decoded.session != _session:
		_reject(Code.WRONG_SESSION)
		return
	if decoded.recipient != _membership.local_uuid():
		_ignored += 1
		_last_receive = Code.NOT_RECIPIENT
		return
	if _received.size() >= _options.max_received_packets or bytes.size() > _options.max_received_bytes - _received_bytes:
		_failure = Code.RECEIVE_OVERFLOW
		_reject(_failure)
		return
	_received.append(decoded)
	_received_bytes += bytes.size()
	_last_receive = Code.OK


func _gate() -> int:
	if _client == null:
		return Code.WRONG_STATE
	if _failure != Code.OK:
		return _failure
	var client: Object = _client.get_ref()
	var config: Object = _sdk_config.get_ref()
	if not is_instance_valid(client) or not is_instance_valid(config) or not _raw_mode(config) or config.get("max_inbound_packets_per_poll") > 4096:
		return Code.INCOMPATIBLE_MODE
	if _adapter.status().route not in ["mesh", "relay", "relay_required"]:
		return Code.WRONG_STATE
	return Code.OK


func _reject(code: int) -> void:
	_last_receive = code
	_rejected += 1


static func _raw_mode(config: Object) -> bool:
	return config.get("game_data_format") == "message_pack" and config.get("decode_msgpack_payloads") == false


func matches_session(membership: Membership, adapter: Adapter, peer: Peer) -> bool:
	return _membership == membership and _adapter == adapter and _peer == peer and _client != null


func packet_limit() -> int:
	return 0 if _options == null else _options.max_packet_bytes
