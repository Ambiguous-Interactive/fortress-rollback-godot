class_name FortressSignalFishWebRTC
extends RefCounted

# gdlint: disable=constant-name,max-returns
const Types = preload("res://addons/fortress_rollback/transport/signalfish_webrtc_types.gd")
const Membership = preload("res://addons/fortress_rollback/transport/signalfish_membership.gd")
const Adapter = preload("res://addons/fortress_rollback/transport/signalfish_adapter.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const S = preload("res://addons/fortress_rollback/core/session_types.gd")
const Code = Types.Code
const Options = Types.Options
const Result = Types.Result

var _mesh: WeakRef = null
var _transport: WeakRef = null
var _membership: Membership
var _adapter: Adapter
var _peer: Peer
var _options: Types.Options
var _generation: String = ""
var _revision: int = -1
var _pending: Array[Peer.Packet] = []
var _pending_bytes: int = 0
var _incoming: PackedByteArray = PackedByteArray()
var _source: int = 0
# Variant is the peer protocol's nullable next-round handshake token.
var _token: Variant = null
var _token_ready: bool = false
var _failure: int = Code.OK
var _busy: bool = false
var _rejected: int = 0
var _refused_destination: PackedByteArray = PackedByteArray()


## Exclusive PacketPeer consumer: never assign this mesh peer to MultiplayerAPI.
## Configure after its accepted mesh plan; a changed plan requires a new lifetime.
func configure(mesh: Object, membership: Membership, adapter: Adapter, peer: Peer, options: Types.Options = null) -> int:
	if _mesh != null or _busy:
		return Code.WRONG_STATE
	if mesh == null or membership == null or adapter == null or peer == null or not mesh.has_method("get_multiplayer_peer"):
		return Code.INVALID_ARGUMENT
	var controls: Types.Options = Types.Options.new() if options == null else options
	if not Types.valid_options(controls) or membership.handshake_message() == null:
		return Code.INVALID_ARGUMENT
	var state: Dictionary = adapter.status()
	if state.route != "mesh":
		return Code.WRONG_STATE
	var transport: Object = mesh.call("get_multiplayer_peer")
	if transport == null:
		return Code.WRONG_STATE
	for method: String in ["poll", "get_connection_status", "get_unique_id", "has_peer", "get_peer", "get_packet_peer", "get_packet_channel", "get_packet_mode",
		"get_available_packet_count", "get_packet", "get_packet_error", "set_target_peer", "set_transfer_mode", "set_transfer_channel", "put_packet"]:
		if not transport.has_method(method):
			return Code.INVALID_ARGUMENT
	if transport.call("get_connection_status") != MultiplayerPeer.CONNECTION_CONNECTED:
		return Code.WRONG_STATE
	if transport.call("get_unique_id") != Membership.uuid_to_peer_id(membership.local_uuid()):
		return Code.WRONG_SOURCE
	_mesh = weakref(mesh)
	_transport = weakref(transport)
	_membership = membership
	_adapter = adapter
	_peer = peer
	_options = Types.copy_options(controls)
	_generation = state.generation
	_revision = state.lifetime_revision
	return Code.OK


## Atomic ownership: caller retains the entire drained batch until OK.
func enqueue_batch(packets: Array[Peer.Packet]) -> int:
	if _busy:
		return Code.WRONG_STATE
	var gate: int = _gate()
	if gate != Code.OK:
		return gate
	if packets.size() > _options.max_pending_packets - _pending.size():
		return Code.BACKPRESSURE
	var needed: int = 0
	var destinations: Array[int] = []
	for packet: Peer.Packet in packets:
		if packet == null or packet.bytes.is_empty():
			return Code.INVALID_ARGUMENT
		if packet.bytes.size() > _options.max_packet_bytes:
			return Code.TOO_LARGE
		needed += packet.bytes.size()
		if needed > _options.max_pending_bytes - _pending_bytes:
			return Code.BACKPRESSURE
		var destination: int = 0
		for uuid: String in _membership.roster():
			if uuid != _membership.local_uuid() and _membership.identity(uuid) == packet.to:
				destination = Membership.uuid_to_peer_id(uuid)
		if destination == 0:
			return Code.WRONG_SOURCE
		destinations.append(destination)
	for index: int in packets.size():
		_pending.append(Peer.Packet.new(PackedByteArray(), packets[index].bytes.duplicate()))
		# Packet destination bytes store a private fixed-width Godot peer ID.
		_pending.back().to.resize(4)
		_pending.back().to.encode_u32(0, destinations[index])
	_pending_bytes += needed
	return Code.OK


## SDK mesh.poll handles signaling; this pumps the actual MultiplayerPeer once.
## Work and socket backlog are independently bounded; refusal retains each FIFO head.
func poll(now_us: int, next_token_factory: Callable = Callable()) -> Types.Result:
	if _busy or now_us < 0:
		return Types.Result.new(Code.INVALID_ARGUMENT)
	_refused_destination.clear()
	var gate: int = _gate()
	if gate != Code.OK:
		return Types.Result.new(gate)
	_busy = true
	var transport: Object = _transport.get_ref()
	transport.call("poll")
	var result: Types.Result = Types.Result.new(_gate())
	if result.code == Code.OK:
		_receive(transport, now_us, next_token_factory, result)
	var receive_pressure: bool = result.code == Code.BACKPRESSURE
	if result.code in [Code.OK, Code.BACKPRESSURE]:
		for _index: int in mini(_options.max_sends_per_poll, _pending.size()):
			result.code = _gate()
			if result.code != Code.OK:
				break
			var packet: Peer.Packet = _pending[0]
			var destination: int = packet.to.decode_u32(0)
			result.code = _channel_gate(transport, destination, packet.bytes.size())
			if result.code != Code.OK:
				_refused_destination = _membership.identity(_membership.uuid_for_peer_id(destination))
				break
			transport.call("set_target_peer", destination)
			transport.call("set_transfer_mode", MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
			transport.call("set_transfer_channel", 0)
			var code: Error = transport.call("put_packet", packet.bytes.duplicate())
			if code != OK:
				_refused_destination = _membership.identity(_membership.uuid_for_peer_id(destination))
				result.code = Code.BACKPRESSURE if code == ERR_BUSY else Code.SDK_FAILURE
				if code != ERR_BUSY:
					_failure = result.code
				break
			_pending_bytes -= packet.bytes.size()
			_pending.pop_front()
			result.sent += 1
	if receive_pressure and result.code == Code.OK:
		result.code = Code.BACKPRESSURE
	_busy = false
	return result


func _receive(transport: Object, now_us: int, factory: Callable, result: Types.Result) -> void:
	for _index: int in _options.max_receives_per_poll:
		result.code = _gate()
		if result.code != Code.OK:
			return
		if _incoming.is_empty():
			if transport.call("get_available_packet_count") <= 0:
				return
			# Engine attribution addresses the NEXT packet, so capture before get_packet advances it.
			_source = transport.call("get_packet_peer")
			var channel: int = transport.call("get_packet_channel")
			var mode: int = transport.call("get_packet_mode")
			_incoming = transport.call("get_packet")
			_incoming = _incoming.duplicate()
			if transport.call("get_packet_error") != OK:
				_failure = Code.SDK_FAILURE
				result.code = _failure
				return
			var uuid: String = _membership.uuid_for_peer_id(_source)
			if uuid.is_empty() or uuid == _membership.local_uuid() or channel != 0 or mode != MultiplayerPeer.TRANSFER_MODE_UNRELIABLE \
				or _incoming.is_empty() or _incoming.size() > _options.max_packet_bytes:
				_rejected += 1
				_incoming.clear()
				continue
		if not _token_ready:
			var candidate: Variant = factory.call(_membership.uuid_for_peer_id(_source)) if factory.is_valid() else null
			result.code = _gate()
			if result.code != Code.OK:
				return
			if candidate != null and (not candidate is PackedByteArray or candidate.size() != 16):
				_token = null
				_failure = Code.INVALID_ARGUMENT
				result.code = _failure
				return
			_token = candidate.duplicate() if candidate is PackedByteArray else null
			_token_ready = true
		result.code = _gate()
		if result.code != Code.OK:
			return
		result.peer_code = _adapter.receive_mesh(_peer, _incoming.duplicate(), _source, now_us, _token)
		if result.peer_code in [I.Code.WRONG_SOURCE, I.Code.WRONG_CONNECTION]:
			_rejected += 1
			_incoming.clear()
			_token = null
			_token_ready = false
			continue
		if result.peer_code != I.Code.OK:
			if result.peer_code == I.Code.BACKPRESSURE and _peer.status().lifecycle == S.Lifecycle.RUNNING:
				result.code = Code.BACKPRESSURE
			else:
				_failure = Code.PEER_FAILURE
				result.code = _failure
			return
		_incoming.clear()
		_token = null
		_token_ready = false
		result.received += 1


func _channel_gate(transport: Object, destination: int, size: int) -> int:
	if not transport.call("has_peer", destination):
		return Code.BACKPRESSURE
	var entry: Dictionary = transport.call("get_peer", destination)
	if not entry.get("connected", false):
		return Code.BACKPRESSURE
	if not entry.get("channels") is Array or entry.channels.size() < 3:
		return Code.INCOMPATIBLE_MODE
	# Engine channel zero selects array index 2 (SCTP id 3) for UNRELIABLE.
	if not entry.channels[2] is Object:
		return Code.INCOMPATIBLE_MODE
	var channel: Object = entry.channels[2]
	for method: String in ["get_ready_state", "is_ordered", "get_buffered_amount", "get_max_packet_life_time"]:
		if not is_instance_valid(channel) or not channel.has_method(method):
			return Code.INCOMPATIBLE_MODE
	if channel.call("get_ready_state") != WebRTCDataChannel.STATE_OPEN:
		return Code.BACKPRESSURE
	if channel.call("is_ordered") or channel.get("write_mode") != WebRTCDataChannel.WRITE_MODE_BINARY \
		or channel.call("get_max_packet_life_time") != 1:
		return Code.INCOMPATIBLE_MODE
	var buffered: int = channel.call("get_buffered_amount")
	return Code.BACKPRESSURE if buffered < 0 or buffered > _options.max_socket_buffered_bytes - size else Code.OK


func _gate() -> int:
	if _mesh == null:
		return Code.WRONG_STATE
	if _failure != Code.OK:
		return _failure
	var mesh: Object = _mesh.get_ref()
	var transport: Object = _transport.get_ref()
	var state: Dictionary = _adapter.status()
	if not is_instance_valid(mesh) or not is_instance_valid(transport) or state.route != "mesh" or state.generation != _generation or state.lifetime_revision != _revision:
		_failure = Code.WRONG_STATE
	elif mesh.call("get_multiplayer_peer") != transport or transport.call("get_connection_status") != MultiplayerPeer.CONNECTION_CONNECTED \
		or transport.call("get_unique_id") != Membership.uuid_to_peer_id(_membership.local_uuid()):
		_failure = Code.WRONG_STATE
	return _failure


func status() -> Dictionary:
	return {"code": _gate(), "pending_packets": _pending.size(), "pending_bytes": _pending_bytes,
		"received_packets": 0 if _incoming.is_empty() else 1, "received_bytes": _incoming.size(), "rejected": _rejected}


func detach() -> void:
	if _busy:
		_failure = Code.WRONG_STATE
		return
	_mesh = null
	_transport = null
	_membership = null
	_adapter = null
	_peer = null
	_pending.clear()
	_pending_bytes = 0
	_incoming.clear()
	_token = null
	_token_ready = false
	_generation = ""
	_revision = -1
	_failure = Code.OK
	_refused_destination.clear()


## Return unsent packets to their owner, including after a transport lifetime ends.
## This does not authorize their transmission on a replacement direct transport.
func reclaim_pending() -> Array[Peer.Packet]:
	var packets: Array[Peer.Packet] = []
	if _busy or _membership == null:
		return packets
	for packet: Peer.Packet in _pending:
		var uuid: String = _membership.uuid_for_peer_id(packet.to.decode_u32(0))
		packets.append(Peer.Packet.new(_membership.identity(uuid), packet.bytes.duplicate()))
	_pending.clear()
	_pending_bytes = 0
	return packets


func send_readiness(identity: PackedByteArray, size: int) -> int:
	if size < 1:
		return Code.INVALID_ARGUMENT
	if _options != null and size > _options.max_packet_bytes:
		return Code.TOO_LARGE
	var gate: int = _gate()
	if gate != Code.OK:
		return gate
	for uuid: String in _membership.roster():
		if uuid != _membership.local_uuid() and _membership.identity(uuid) == identity:
			var readiness: int = _channel_gate(_transport.get_ref(), Membership.uuid_to_peer_id(uuid), size)
			gate = _gate()
			return readiness if gate == Code.OK else gate
	return Code.WRONG_SOURCE


func matches_session(membership: Membership, adapter: Adapter, peer: Peer) -> bool:
	return _membership == membership and _adapter == adapter and _peer == peer and _mesh != null


func packet_limit() -> int:
	return 0 if _options == null else _options.max_packet_bytes


## Owned destination of the actual send refusal in the last poll, or empty.
func refused_destination() -> PackedByteArray:
	return _refused_destination.duplicate()
