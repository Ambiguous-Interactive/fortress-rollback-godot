class_name FortressSignalFishSpectatorRelay
extends RefCounted

# gdlint: disable=constant-name,max-returns
const Stream = preload("res://addons/fortress_rollback/core/spectator_stream.gd")
const Membership = preload("res://addons/fortress_rollback/transport/signalfish_membership.gd")
const Types = preload("res://addons/fortress_rollback/transport/signalfish_relay_types.gd")
const SessionTypes = preload("res://addons/fortress_rollback/core/session_types.gd")
const Code = Types.Code
# Public SignalFishClient.SessionState.SPECTATING on the reviewed and qualified SDKs.
const SPECTATING: int = 6
const CONNECTED: int = 2
const LIFETIME_SIGNALS: Array[String] = [
	"room_left", "room_joined", "spectator_joined", "spectator_left", "disconnected", "connection_failed", "reconnected", "authentication_error", "reconnection_failed"
]


class Options:
	extends RefCounted
	var max_packet_bytes: int = 65479
	var max_received_packets: int = 128
	var max_received_bytes: int = 1048576
	var max_receives_per_poll: int = 8


var _client: WeakRef
var _sdk_config: WeakRef
var _stream: Stream
var _session: RefCounted
var _source_config: RefCounted
var _identity: PackedByteArray
var _player: String
var _revision: int = 0
var _callbacks: Dictionary = {}
var _room: String
var _host: String
var _options: Options
var _received: Array[PackedByteArray] = []
var _received_bytes: int = 0
var _failure: int = Code.OK
var _last_receive: int = Code.OK
var _rejected: int = 0
var _traffic: int = 0
var _busy: bool = false
var _accept: PackedByteArray = PackedByteArray()


## Attach after the SDK installs a spectator baseline, using an already configured stream.
## This receive-only bridge never seats a viewer or sends through the read-only SDK role.
## poll() can hand acceptance to a caller-supplied separate authenticated control path.
func configure(client: Object, sdk_config: Object, protocol_info: Object, stream: Stream, host_uuid: String, options: Options = null) -> int:
	if _client != null:
		return Code.WRONG_STATE
	var controls: Options = Options.new() if options == null else options
	if client == null or sdk_config == null or protocol_info == null or stream == null or not Membership.valid_uuid(host_uuid) or not _valid_options(controls):
		return Code.INVALID_ARGUMENT
	for method: String in ["get_room_id", "get_session_state", "get_connection_state", "get_player_id"]:
		if not client.has_method(method):
			return Code.INVALID_ARGUMENT
	if not client.has_signal("game_data_binary_received") or not protocol_info.has_method("to_dict"):
		return Code.INVALID_ARGUMENT
	# Variant crosses the optional SDK's public protocol-info boundary.
	var info: Variant = protocol_info.call("to_dict")
	if not info is Dictionary or not info.get("capabilities") is Array or info.capabilities.size() > 64:
		return Code.INCOMPATIBLE_MODE
	if "spectator_relay" not in info.capabilities or not info.get("protocol_version") is int or info.protocol_version < 3 or not _raw_mode(sdk_config):
		return Code.INCOMPATIBLE_MODE
	if not info.get("game_data_formats") is Array or info.game_data_formats.size() > 16 or "message_pack" not in info.game_data_formats:
		return Code.INCOMPATIBLE_MODE
	for field: String in ["max_inbound_frame_bytes", "max_buffered_bytes", "max_inbound_packets_per_poll"]:
		if not sdk_config.get(field) is int or sdk_config.get(field) < 1:
			return Code.INVALID_ARGUMENT
	if sdk_config.get("max_inbound_packets_per_poll") > 4096:
		return Code.INVALID_ARGUMENT
	if sdk_config.get("max_inbound_frame_bytes") < controls.max_packet_bytes + 128 or sdk_config.get("max_buffered_bytes") < controls.max_packet_bytes:
		return Code.TOO_LARGE
	if client.call("get_connection_state") != CONNECTED or client.call("get_session_state") != SPECTATING:
		return Code.WRONG_STATE
	if not client.call("get_player_id") is String or not client.call("get_room_id") is String or client.call("get_room_id").is_empty():
		return Code.WRONG_STATE
	var session: RefCounted = stream.playback_session()
	if session == null or session._config == null or session._config != stream._config or session._mutation_code() != SessionTypes.Code.OK:
		return Code.WRONG_STATE
	if max(Stream.NEGOTIATION_BYTES, Stream.HEADER_BYTES + session._config.player_count * (session._config.input_width + 1)) > controls.max_packet_bytes:
		return Code.TOO_LARGE
	_client = weakref(client)
	_sdk_config = weakref(sdk_config)
	_stream = stream
	_session = session
	_source_config = session._config
	_identity = stream._identity.duplicate()
	_room = client.call("get_room_id")
	_player = client.call("get_player_id")
	_host = host_uuid
	_options = Options.new()
	for field: String in ["max_packet_bytes", "max_received_packets", "max_received_bytes", "max_receives_per_poll"]:
		_options.set(field, controls.get(field))
	_revision += 1
	var revision: int = _revision
	var owner: WeakRef = weakref(self)
	_callbacks.game_data_binary_received = func(from_uuid: String, encoding: int, bytes: PackedByteArray) -> void:
		var target: RefCounted = owner.get_ref()
		if target != null and target._revision == revision:
			target._on_binary(from_uuid, encoding, bytes)
	client.connect("game_data_binary_received", _callbacks.game_data_binary_received)
	for signal_name: String in LIFETIME_SIGNALS:
		if client.has_signal(signal_name):
			_callbacks[signal_name] = func(_a: Variant = null, _b: Variant = null, _c: Variant = null, _d: Variant = null) -> void:
				var target: RefCounted = owner.get_ref()
				if target != null and target._revision == revision:
					target._on_lifetime_ended()
			client.connect(signal_name, _callbacks[signal_name])
	return Code.OK


## Poll elapsed expiry before any buffered packet, even while playback is paused or blocked.
## BUSY and row pressure preserve the exact FIFO head for the next poll.
## send_accept(packet) returns an Error from a separate authenticated control transport.
## OK means transport acceptance, not host receipt. ERR_BUSY/ERR_OUT_OF_MEMORY retry exact bytes.
func poll(now_us: int, send_accept: Callable = Callable()) -> Types.Result:
	var result: Types.Result = Types.Result.new(_gate())
	if result.code != Code.OK:
		_stop_owned_viewer()
		return result
	if _busy:
		result.code = Code.WRONG_STATE
		return result
	if _stream.host_deadline_elapsed(now_us):
		_failure = Code.PEER_FAILURE
		result.code = _failure
		result.peer_code = SessionTypes.Code.PROTOCOL_FAILED
		_stop_owned_viewer()
		return result
	_busy = true
	var revision: int = _revision
	result.activity = _traffic
	_traffic = 0
	result.peer_code = _stream.poll(now_us)
	if result.peer_code == SessionTypes.Code.OK:
		for _index: int in mini(_options.max_receives_per_poll, _received.size()):
			result.code = _gate()
			if result.code != Code.OK:
				break
			var received_kind: int = _received[0][5]
			result.peer_code = _stream.receive_packet(_received[0], now_us)
			if result.peer_code in [SessionTypes.Code.BUSY, SessionTypes.Code.NETWORK_BACKPRESSURE]:
				break
			_received_bytes -= _received[0].size()
			_received.pop_front()
			if result.peer_code != SessionTypes.Code.OK:
				_rejected += 1
				if _session.status().lifecycle == SessionTypes.Lifecycle.TERMINATED:
					break
			else:
				result.received += 1
				if received_kind == Stream.OFFER:
					_accept = _stream.encode_accept()
	if result.code == Code.OK and result.peer_code != SessionTypes.Code.OK:
		result.code = Code.BACKPRESSURE if result.peer_code in [SessionTypes.Code.BUSY, SessionTypes.Code.NETWORK_BACKPRESSURE] else Code.PEER_FAILURE
	if result.code in [Code.OK, Code.BACKPRESSURE] and not _accept.is_empty() and send_accept.is_valid() and _session._mutation_code() == SessionTypes.Code.OK:
		var control_code: int = _send_accept(send_accept)
		if control_code != Code.OK:
			result.code = control_code
	_busy = false
	if _revision != revision:
		result.code = Code.WRONG_STATE
		return result
	if result.code not in [Code.OK, Code.BACKPRESSURE, Code.PEER_FAILURE]:
		_stop_owned_viewer()
	if _session != null and _session.status().lifecycle == SessionTypes.Lifecycle.TERMINATED:
		_clear_received()
	return result


func status() -> Dictionary:
	return {
		"code": _gate(),
		"received_packets": _received.size(),
		"received_bytes": _received_bytes,
		"accept_pending": not _accept.is_empty(),
		"rejected": _rejected,
		"last_receive_code": _last_receive
	}


## Detaching retires this playback lifetime; configure a fresh stream for a new room.
func detach() -> void:
	_revision += 1
	_stop_owned_viewer()
	var client: Object = _client.get_ref() if _client != null else null
	if is_instance_valid(client):
		for signal_name: String in _callbacks:
			if client.is_connected(signal_name, _callbacks[signal_name]):
				client.disconnect(signal_name, _callbacks[signal_name])
	_callbacks.clear()
	_client = null
	_sdk_config = null
	_stream = null
	_session = null
	_source_config = null
	_received.clear()
	_received_bytes = 0
	_accept = PackedByteArray()
	_failure = Code.OK
	_last_receive = Code.OK
	_rejected = 0
	_traffic = 0


func _on_binary(from_uuid: String, encoding: int, bytes: PackedByteArray) -> void:
	if _client == null:
		return
	_traffic += 1
	var code: int = _gate()
	if code != Code.OK:
		_last_receive = code
		_stop_owned_viewer()
		return
	if from_uuid != _host or encoding != 1:
		_reject(Code.WRONG_SOURCE if from_uuid != _host else Code.INCOMPATIBLE_MODE)
		return
	if bytes.size() > _options.max_packet_bytes:
		_reject(Code.TOO_LARGE)
		return
	if bytes.size() < Stream.HEADER_BYTES or not Stream.header_matches(bytes, bytes[5], _identity, _stream._digest, _source_config.player_count, _source_config.input_width):
		_reject(Code.INVALID_ENVELOPE)
		return
	if not Stream.tag_matches(bytes, _stream._key):
		_reject(Code.INVALID_ENVELOPE)
		return
	if _received.size() >= _options.max_received_packets or bytes.size() > _options.max_received_bytes - _received_bytes:
		_failure = Code.RECEIVE_OVERFLOW
		_reject(_failure)
		_stop_owned_viewer()
		return
	if bytes[5] == Stream.KEEPALIVE:
		_received.push_front(bytes.duplicate())
	else:
		_received.append(bytes.duplicate())
	_received_bytes += bytes.size()
	_last_receive = Code.OK


func _gate() -> int:
	if _client == null:
		return Code.WRONG_STATE
	if _failure != Code.OK:
		return _failure
	var client: Object = _client.get_ref()
	var config: Object = _sdk_config.get_ref()
	if not is_instance_valid(client) or not is_instance_valid(config):
		_failure = Code.WRONG_STATE
	elif (
		not _raw_mode(config)
		or not config.get("max_inbound_packets_per_poll") is int
		or config.get("max_inbound_packets_per_poll") < 1
		or config.get("max_inbound_packets_per_poll") > 4096
	):
		_failure = Code.INCOMPATIBLE_MODE
	elif (
		client.call("get_connection_state") != CONNECTED
		or client.call("get_player_id") != _player
		or client.call("get_room_id") != _room
		or client.call("get_session_state") != SPECTATING
	):
		_failure = Code.WRONG_STATE
	elif _stream.playback_session() != _session or _stream._identity != _identity or _session._config != _source_config:
		_failure = Code.WRONG_STATE
	return _failure


func _on_lifetime_ended() -> void:
	if _client != null:
		_failure = Code.WRONG_STATE
		_stop_owned_viewer()


func _stop_owned_viewer() -> void:
	if _session != null and _session._config == _source_config:
		_session.terminate(SessionTypes.Code.PROTOCOL_FAILED)
	_clear_received()


func _clear_received() -> void:
	_received.clear()
	_received_bytes = 0
	_accept = PackedByteArray()


func _send_accept(sender: Callable) -> int:
	var revision: int = _revision
	# Variant is application transport output, validated before any coercion.
	var sent: Variant = sender.call(_accept.duplicate())
	if _revision != revision:
		return Code.WRONG_STATE
	var gate: int = _gate()
	if gate != Code.OK:
		return gate
	var state: int = _session._mutation_code()
	if state not in [SessionTypes.Code.OK, SessionTypes.Code.BUSY]:
		_failure = Code.PEER_FAILURE
		return _failure
	if not sent is int:
		_failure = Code.SDK_FAILURE
		return _failure
	if sent in [ERR_BUSY, ERR_OUT_OF_MEMORY]:
		return Code.BACKPRESSURE
	if sent != OK:
		_failure = Code.SDK_FAILURE
		return _failure
	_accept = PackedByteArray()
	return Code.BACKPRESSURE if state == SessionTypes.Code.BUSY else Code.OK


func _reject(code: int) -> void:
	_last_receive = code
	_rejected += 1


static func _raw_mode(config: Object) -> bool:
	return config.get("game_data_format") == "message_pack" and config.get("decode_msgpack_payloads") == false


static func _valid_options(options: Options) -> bool:
	return (
		options.max_packet_bytes >= Stream.NEGOTIATION_BYTES
		and options.max_packet_bytes <= 65479
		and options.max_received_packets >= 1
		and options.max_received_packets <= 4096
		and options.max_received_bytes >= options.max_packet_bytes
		and options.max_received_bytes <= 16777216
		and options.max_receives_per_poll >= 1
		and options.max_receives_per_poll <= options.max_received_packets
	)
