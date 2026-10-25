class_name FortressSignalFishSpectatorHost
extends RefCounted

# gdlint: disable=constant-name,max-returns
const Publisher = preload("res://addons/fortress_rollback/core/spectator_publisher.gd")
const Stream = preload("res://addons/fortress_rollback/core/spectator_stream.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const S = preload("res://addons/fortress_rollback/core/session_types.gd")
const Types = preload("res://addons/fortress_rollback/transport/signalfish_relay_types.gd")
const ViewerRelay = preload("res://addons/fortress_rollback/transport/signalfish_spectator_relay.gd")
const Membership = preload("res://addons/fortress_rollback/transport/signalfish_membership.gd")
const Code = Types.Code
const FINALIZED: int = 5


class Options:
	extends RefCounted
	var max_packet_bytes: int = 65479
	var max_sends_per_poll: int = 8
	var max_socket_buffered_bytes: int = 262144
	var offer_retry_us: int = 1000000
	var keepalive_interval_us: int = 1000000


var _client: WeakRef
var _sdk_config: WeakRef
var _publisher: Publisher
var _host: Session
var _source_config: RefCounted
var _player: String
var _room: String
var _viewer: String
var _options: Options
var _callbacks: Dictionary = {}
var _failure: int = Code.OK
var _busy: bool = false
var _checking: bool = false
var _revision: int = 0
var _last_poll: int = -1
var _last_offer: int = -1
var _last_sent: int = -1
var _pulse_next: bool = false


## Publish one pre-admitted viewer's stream from frame zero, without changing player membership.
func configure(
	client: Object,
	sdk_config: Object,
	protocol_info: Object,
	host: Session,
	viewer_uuid: String,
	identity: PackedByteArray,
	key: PackedByteArray,
	digest: PackedByteArray,
	options: Options = null
) -> int:
	if _client != null or _busy or _checking:
		return Code.WRONG_STATE
	_busy = true
	var code: int = _configure(client, sdk_config, protocol_info, host, viewer_uuid, identity, key, digest, options)
	_busy = false
	return code


func _configure(
	client: Object,
	sdk_config: Object,
	protocol_info: Object,
	host: Session,
	viewer_uuid: String,
	identity: PackedByteArray,
	key: PackedByteArray,
	digest: PackedByteArray,
	options: Options
) -> int:
	var revision: int = _revision
	var controls: Options = Options.new() if options == null else options
	if client == null or sdk_config == null or protocol_info == null or host == null or not Membership.valid_uuid(viewer_uuid) or not _valid_options(controls):
		return Code.INVALID_ARGUMENT
	for method: String in ["get_room_id", "get_player_id", "get_session_state", "get_connection_state", "get_buffered_amount", "send_game_data_binary"]:
		if not client.has_method(method):
			return Code.INVALID_ARGUMENT
	if not protocol_info.has_method("to_dict"):
		return Code.INVALID_ARGUMENT
	# Variant crosses the optional SDK protocol-info boundary.
	var info: Variant = protocol_info.call("to_dict")
	if not info is Dictionary or not info.get("capabilities") is Array or info.capabilities.size() > 64 or "spectator_relay" not in info.capabilities:
		return Code.INCOMPATIBLE_MODE
	if not info.get("protocol_version") is int or info.protocol_version < 3 or not ViewerRelay._raw_mode(sdk_config):
		return Code.INCOMPATIBLE_MODE
	if not info.get("game_data_formats") is Array or info.game_data_formats.size() > 16 or "message_pack" not in info.game_data_formats:
		return Code.INCOMPATIBLE_MODE
	for field: String in ["max_outbound_frame_bytes", "max_buffered_bytes"]:
		if not sdk_config.get(field) is int or sdk_config.get(field) < controls.max_packet_bytes:
			return Code.TOO_LARGE
	if not info.get("max_outbound_message_size") is int or info.max_outbound_message_size < controls.max_packet_bytes + 128:
		return Code.TOO_LARGE
	if client.call("get_connection_state") != ViewerRelay.CONNECTED or client.call("get_session_state") != FINALIZED:
		return Code.WRONG_STATE
	var player: Variant = client.call("get_player_id")
	var room: Variant = client.call("get_room_id")
	if not player is String or not Membership.valid_uuid(player) or not room is String or room.is_empty() or player == viewer_uuid:
		return Code.WRONG_STATE
	var publisher: Publisher = Publisher.new()
	if publisher.configure(host, identity, key, digest, controls.max_packet_bytes) != S.Code.OK:
		return Code.INVALID_ARGUMENT
	if revision != _revision:
		return Code.WRONG_STATE
	_client = weakref(client)
	_sdk_config = weakref(sdk_config)
	_publisher = publisher
	_host = host
	_source_config = host._config
	_player = player
	_room = room
	_viewer = viewer_uuid
	_options = Options.new()
	for field: String in ["max_packet_bytes", "max_sends_per_poll", "max_socket_buffered_bytes", "offer_retry_us", "keepalive_interval_us"]:
		_options.set(field, controls.get(field))
	_revision += 1
	var installed_revision: int = _revision
	var owner: WeakRef = weakref(self)
	for signal_name: String in ViewerRelay.LIFETIME_SIGNALS:
		if client.has_signal(signal_name):
			_callbacks[signal_name] = func(_a: Variant = null, _b: Variant = null, _c: Variant = null, _d: Variant = null) -> void:
				var target: RefCounted = owner.get_ref()
				if target != null and target._revision == installed_revision:
					target._failure = Code.WRONG_STATE
			client.connect(signal_name, _callbacks[signal_name])
	return Code.OK


## Deliver ACCEPT only after a separate service authenticates the pre-admitted viewer UUID.
## SDK spectator game-data sends are forbidden; packet authentication alone does not admit a viewer.
func receive_accept(authenticated_viewer_uuid: String, packet: PackedByteArray) -> Types.Result:
	var gate: int = _gate()
	if gate != Code.OK or _busy:
		return Types.Result.new(gate if gate != Code.OK else Code.WRONG_STATE)
	if authenticated_viewer_uuid != _viewer:
		return Types.Result.new(Code.WRONG_SOURCE)
	return _peer_result(_publisher.receive_accept(packet))


## Bounded SDK sends retain exact refused rows. Time is monotonic, injected microseconds.
func poll(now_us: int) -> Types.Result:
	var result: Types.Result = Types.Result.new(_gate())
	if result.code != Code.OK:
		return result
	if _busy or now_us < 0 or now_us < _last_poll:
		result.code = Code.INVALID_ARGUMENT
		return result
	_last_poll = now_us
	if _host._mutation_code() == S.Code.BUSY:
		result.code = Code.BACKPRESSURE
		return result
	var revision: int = _revision
	_busy = true
	var blocked: bool = false
	for _index: int in _options.max_sends_per_poll:
		var packet: PackedByteArray
		var offered: bool = _publisher.agreement_version() == 0
		if offered:
			if _publisher.agreement_reason() != S.Code.OK:
				result.peer_code = _publisher.agreement_reason()
				result.code = Code.PEER_FAILURE
				break
			if _last_offer >= 0 and now_us - _last_offer < _options.offer_retry_us:
				break
			packet = _publisher.encode_offer()
		else:
			var prepared: S.InputResult = _publisher.prepare_packet()
			result.peer_code = prepared.code
			if prepared.code == S.Code.TERMINATED:
				break
			if prepared.code not in [S.Code.OK, S.Code.PREDICTION_STALL]:
				result.code = Code.BACKPRESSURE if prepared.code == S.Code.BUSY else Code.PEER_FAILURE
				break
			var heartbeat: PackedByteArray = _heartbeat(now_us)
			packet = heartbeat if _pulse_next and not heartbeat.is_empty() else prepared.bytes
			if prepared.code == S.Code.PREDICTION_STALL:
				packet = heartbeat
			if not packet.is_empty() and packet[5] == Stream.KEEPALIVE:
				_pulse_next = false
		if packet.is_empty():
			break
		result.code = _send(packet)
		if result.code != Code.OK:
			if result.code == Code.BACKPRESSURE and packet[5] in [Stream.ROW, Stream.END]:
				blocked = true
				_pulse_next = true
				if not _heartbeat(now_us).is_empty():
					continue
			break
		_last_sent = now_us
		result.sent += 1
		if offered:
			_last_offer = now_us
			break
		if packet[5] == Stream.KEEPALIVE:
			break
		_pulse_next = false
		result.peer_code = _publisher.acknowledge_packet(packet)
		if result.peer_code != S.Code.OK:
			result.code = Code.BACKPRESSURE if result.peer_code == S.Code.BUSY else Code.PEER_FAILURE
			break
	_busy = false
	if blocked and result.code == Code.OK:
		result.code = Code.BACKPRESSURE
	if revision != _revision:
		result.code = Code.WRONG_STATE
		return result
	if result.code not in [Code.OK, Code.BACKPRESSURE]:
		_failure = result.code
	return result


## Freeze the fully confirmed exclusive end; poll sends the remaining rows, then END.
func finish_host() -> Types.Result:
	var gate: int = _gate()
	if gate != Code.OK or _busy:
		return Types.Result.new(gate if gate != Code.OK else Code.WRONG_STATE)
	return _peer_result(_publisher.finish_host())


func status() -> Dictionary:
	return {"code": _gate(), "next_frame": _publisher.next_frame() if _publisher != null else 0, "agreed_version": _publisher.agreement_version() if _publisher != null else 0}


## Detach publication only; player gameplay and confirmation remain owned by the caller.
func detach() -> void:
	_revision += 1
	var client: Object = _client.get_ref() if _client != null else null
	if is_instance_valid(client):
		for signal_name: String in _callbacks:
			if client.is_connected(signal_name, _callbacks[signal_name]):
				client.disconnect(signal_name, _callbacks[signal_name])
	_callbacks.clear()
	_client = null
	_sdk_config = null
	_publisher = null
	_host = null
	_source_config = null
	_failure = Code.OK
	_last_poll = -1
	_last_offer = -1
	_last_sent = -1
	_pulse_next = false


func _heartbeat(now_us: int) -> PackedByteArray:
	if _last_sent >= 0 and now_us - _last_sent < _options.keepalive_interval_us:
		return PackedByteArray()
	return _publisher.encode_keepalive()


func _send(packet: PackedByteArray) -> int:
	var gate: int = _gate()
	if gate != Code.OK:
		return gate
	var client: Object = _client.get_ref()
	var revision: int = _revision
	# Variant validates SDK/custom transport returns before coercion.
	var buffered: Variant = client.call("get_buffered_amount")
	if revision != _revision:
		return Code.WRONG_STATE
	gate = _gate()
	if gate != Code.OK:
		return gate
	if not buffered is int or buffered < 0:
		return Code.SDK_FAILURE
	if buffered > _options.max_socket_buffered_bytes - packet.size():
		return Code.BACKPRESSURE
	var sent: Variant = client.call("send_game_data_binary", packet.duplicate())
	if revision != _revision:
		return Code.WRONG_STATE
	gate = _gate()
	if gate != Code.OK:
		return gate
	if not sent is int:
		return Code.SDK_FAILURE
	return Code.OK if sent == OK else (Code.BACKPRESSURE if sent in [ERR_BUSY, ERR_OUT_OF_MEMORY] else Code.SDK_FAILURE)


func _gate() -> int:
	if _client == null or _checking:
		return Code.WRONG_STATE
	if _failure != Code.OK:
		return _failure
	_checking = true
	var revision: int = _revision
	var client: Object = _client.get_ref()
	var config: Object = _sdk_config.get_ref()
	var host: Session = _host
	var failure: int = Code.OK
	if not is_instance_valid(client) or not is_instance_valid(config):
		failure = Code.WRONG_STATE
	elif not ViewerRelay._raw_mode(config):
		failure = Code.INCOMPATIBLE_MODE
	elif (
		not config.get("max_outbound_frame_bytes") is int
		or config.get("max_outbound_frame_bytes") < _options.max_packet_bytes
		or not config.get("max_buffered_bytes") is int
		or config.get("max_buffered_bytes") < _options.max_packet_bytes
	):
		failure = Code.TOO_LARGE
	elif (
		client.call("get_connection_state") != ViewerRelay.CONNECTED
		or client.call("get_session_state") != FINALIZED
		or client.call("get_room_id") != _room
		or client.call("get_player_id") != _player
		or host._config != _source_config
	):
		failure = Code.WRONG_STATE
	elif host._mutation_code() not in [S.Code.OK, S.Code.BUSY]:
		failure = Code.PEER_FAILURE
	_checking = false
	if revision != _revision:
		return Code.WRONG_STATE
	_failure = failure
	return _failure


static func _valid_options(options: Options) -> bool:
	return (
		options.max_packet_bytes >= Stream.NEGOTIATION_BYTES
		and options.max_packet_bytes <= 65479
		and options.max_sends_per_poll >= 1
		and options.max_sends_per_poll <= 4096
		and options.max_socket_buffered_bytes >= options.max_packet_bytes
		and options.max_socket_buffered_bytes <= 16777216
		and options.offer_retry_us >= 1
		and options.offer_retry_us <= 60000000
		and options.keepalive_interval_us >= 1
		and options.keepalive_interval_us <= 60000000
	)


static func _peer_result(code: int) -> Types.Result:
	var result: Types.Result = Types.Result.new(Code.OK if code == S.Code.OK else (Code.BACKPRESSURE if code in [S.Code.BUSY, S.Code.PREDICTION_STALL] else Code.PEER_FAILURE))
	result.peer_code = code
	return result
