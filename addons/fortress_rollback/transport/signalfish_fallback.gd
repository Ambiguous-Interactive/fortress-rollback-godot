class_name FortressSignalFishFallback
extends RefCounted

# gdlint: disable=constant-name,max-returns
const Direct = preload("res://addons/fortress_rollback/transport/signalfish_webrtc.gd")
const Relay = preload("res://addons/fortress_rollback/transport/signalfish_relay.gd")
const Membership = preload("res://addons/fortress_rollback/transport/signalfish_membership.gd")
const Adapter = preload("res://addons/fortress_rollback/transport/signalfish_adapter.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Code = Relay.Code
const Result = Relay.Result


class Options:
	extends RefCounted
	var fallback_after_us: int = 1000000
	var restore_after_us: int = 1000000
	var max_pending_packets: int = 128
	var max_pending_bytes: int = 1048576
	var max_routes_per_poll: int = 8


var _direct: Direct
var _relay: Relay
var _membership: Membership
var _adapter: Adapter
var _options: Options
var _revision: int = -1
var _last_now: int = -1
var _route_cursor: int = 0
var _pending: Array[Peer.Packet] = []
var _pending_bytes: int = 0
# Last poll's traffic and sends, so a caller can tell an idle route from a busy one.
var _activity: int = 0
var _sent: int = 0
var _unavailable_since: Dictionary = {}
var _relay_peers: Dictionary = {}
var _ready_since: Dictionary = {}
var _failure: int = Code.OK
var _busy: bool = false
var _detach_requested: bool = false


## Both transports must use the same frozen membership, adapter and PeerSession.
## Reserve their outgoing queues and poll calls exclusively for this coordinator.
func configure(direct: Direct, relay: Relay, membership: Membership, adapter: Adapter, peer: Peer, options: Options = null) -> int:
	if _relay != null or _busy:
		return Code.WRONG_STATE
	var controls: Options = Options.new() if options == null else options
	if direct == null or relay == null or membership == null or adapter == null or peer == null or controls.fallback_after_us < 0 \
		or controls.fallback_after_us > 60000000 or controls.restore_after_us < 0 or controls.restore_after_us > 60000000 \
		or controls.max_pending_packets < 1 or controls.max_pending_packets > 4096 \
		or controls.max_pending_bytes < mini(direct.packet_limit(), relay.packet_limit()) or controls.max_pending_bytes > 16777216 \
		or controls.max_routes_per_poll < 1 or controls.max_routes_per_poll > controls.max_pending_packets:
		return Code.INVALID_ARGUMENT
	if not direct.matches_session(membership, adapter, peer) or not relay.matches_session(membership, adapter, peer) \
		or direct.status().pending_packets != 0 or relay.status().pending_packets != 0 or relay.status().code != Code.OK or adapter.status().route != "mesh":
		return Code.WRONG_STATE
	_direct = direct
	_relay = relay
	_membership = membership
	_adapter = adapter
	_revision = adapter.status().lifetime_revision
	_options = Options.new()
	for field: String in ["fallback_after_us", "restore_after_us", "max_pending_packets", "max_pending_bytes", "max_routes_per_poll"]:
		_options.set(field, controls.get(field))
	return Code.OK


## Atomic ownership: retain the entire drained PeerSession batch until OK.
func enqueue_batch(packets: Array[Peer.Packet]) -> int:
	var gate: int = _gate()
	if gate != Code.OK or _busy:
		return gate if gate != Code.OK else Code.WRONG_STATE
	if packets.size() > _options.max_pending_packets - _pending.size():
		return Code.BACKPRESSURE
	var needed: int = 0
	for packet: Peer.Packet in packets:
		if packet == null or packet.bytes.is_empty():
			return Code.INVALID_ARGUMENT
		if packet.bytes.size() > mini(_direct.packet_limit(), _relay.packet_limit()):
			return Code.TOO_LARGE
		if _uuid(packet.to).is_empty():
			return Code.WRONG_SOURCE
		needed += packet.bytes.size()
		if needed > _options.max_pending_bytes - _pending_bytes:
			return Code.BACKPRESSURE
	for packet: Peer.Packet in packets:
		_pending.append(Peer.Packet.new(packet.to.duplicate(), packet.bytes.duplicate()))
	_pending_bytes += needed
	return Code.OK


## Monotonic injected time decides per-peer fallback; simulation history is untouched.
## Direct restoration waits for readiness and all accepted relay output to drain.
func poll(now_us: int, next_token_factory: Callable = Callable()) -> Relay.Result:
	var gate: int = _gate()
	if gate != Code.OK:
		return Result.new(gate)
	if _busy or now_us < 0 or now_us < _last_now:
		return Result.new(Code.INVALID_ARGUMENT)
	_busy = true
	_last_now = now_us
	_observe_readiness(now_us)
	var result: Relay.Result = Result.new()
	var blocked: Dictionary = {}
	var remaining: Array[Peer.Packet] = []
	var direct_batch: Array[Peer.Packet] = []
	var work: int = 0
	for packet: Peer.Packet in _fair_pending():
		var uuid: String = _uuid(packet.to)
		if _failure != Code.OK or work >= _options.max_routes_per_poll or blocked.has(uuid):
			remaining.append(packet)
			continue
		work += 1
		var route: String = _adapter.status().route
		var readiness: int = _direct.send_readiness(packet.to, packet.bytes.size()) if route == "mesh" else Code.WRONG_STATE
		if readiness == Code.WRONG_STATE and route == "mesh":
			_failure = readiness
			remaining.append(packet)
			continue
		if readiness != Code.OK and not _unavailable_since.has(uuid):
			_unavailable_since[uuid] = now_us
		if route in ["relay", "relay_required"] or (_unavailable_since.has(uuid) and now_us - int(_unavailable_since[uuid]) >= _options.fallback_after_us):
			_relay_peers[uuid] = true
		var batch: Array[Peer.Packet] = [packet]
		var code: int = _relay.enqueue_batch(batch) if _relay_peers.has(uuid) else (_direct.enqueue_batch(batch) if readiness == Code.OK else Code.BACKPRESSURE)
		if code == Code.OK:
			_pending_bytes -= packet.bytes.size()
			if not _relay_peers.has(uuid):
				direct_batch.append(packet)
		else:
			remaining.append(packet)
			blocked[uuid] = true
			result.code = code
	_pending = remaining
	var direct_result: Relay.Result = _direct.poll(now_us, next_token_factory)
	for index: int in direct_result.sent:
		_unavailable_since.erase(_uuid(direct_batch[index].to))
	var refused: String = _uuid(_direct.refused_destination())
	if not refused.is_empty() and not _unavailable_since.has(refused):
		_unavailable_since[refused] = now_us
	var reclaimed: Array[Peer.Packet] = _direct.reclaim_pending()
	for packet: Peer.Packet in reclaimed:
		_pending_bytes += packet.bytes.size()
	_pending = reclaimed + _pending
	result.sent += direct_result.sent
	result.received += direct_result.received
	result.activity = direct_result.activity
	result.peer_code = direct_result.peer_code
	if direct_result.code in [Code.PEER_FAILURE, Code.INVALID_ARGUMENT] \
		or (direct_result.code == Code.WRONG_STATE and _adapter.status().route == "mesh"):
		_failure = direct_result.code
	elif _gate() == Code.OK:
		var relay_result: Relay.Result = _relay.poll(now_us, next_token_factory)
		result.sent += relay_result.sent
		result.received += relay_result.received
		result.activity += relay_result.activity
		result.peer_code = relay_result.peer_code
		if relay_result.code not in [Code.OK, Code.BACKPRESSURE]:
			_failure = relay_result.code
		elif relay_result.code == Code.BACKPRESSURE or direct_result.code == Code.BACKPRESSURE or not _pending.is_empty():
			result.code = Code.BACKPRESSURE
		else:
			result.code = Code.OK
	for uuid: String in _unavailable_since.keys():
		if not _relay_peers.has(uuid) and not _has_pending(uuid):
			_unavailable_since.erase(uuid)
	_activity = result.activity
	_sent = result.sent
	_busy = false
	gate = _gate()
	if gate != Code.OK:
		result.code = gate
	if _detach_requested:
		detach()
	return result


## True when the composed routes took nothing off the wire, sent nothing and hold no queued work.
## A refused packet still counts as traffic, so valid work queued behind it is never left queued.
func idle() -> bool:
	if _activity > 0 or _sent > 0 or not _pending.is_empty():
		return false
	if _direct == null or _relay == null:
		return true
	return _direct.idle() and _relay.idle()


func status() -> Dictionary:
	return {"code": _gate(), "pending_packets": _pending.size(), "pending_bytes": _pending_bytes,
		"relay_peers": _relay_peers.keys(), "direct": {} if _direct == null else _direct.status(), "relay": {} if _relay == null else _relay.status()}


func _gate() -> int:
	if _relay == null:
		return Code.WRONG_STATE
	if _failure != Code.OK:
		return _failure
	var state: Dictionary = _adapter.status()
	if state.route not in ["mesh", "relay", "relay_required"] or (state.route == "mesh" and state.lifetime_revision != _revision):
		_failure = Code.WRONG_STATE
	if _failure == Code.OK and state.route == "mesh" and _direct.status().code == Code.WRONG_STATE:
		_failure = Code.WRONG_STATE
	if _failure == Code.OK and _relay.status().code != Code.OK:
		_failure = _relay.status().code
	return _failure


func _uuid(identity: PackedByteArray) -> String:
	for uuid: String in _membership.roster():
		if uuid != _membership.local_uuid() and _membership.identity(uuid) == identity:
			return uuid
	return ""


func _has_pending(uuid: String) -> bool:
	for packet: Peer.Packet in _pending:
		if _uuid(packet.to) == uuid:
			return true
	return false


## Detach the coordinator before releasing its transport objects.
func detach() -> void:
	if _busy:
		_detach_requested = true
		_failure = Code.WRONG_STATE
		_direct.detach()
		_relay.detach()
		return
	_direct = null
	_relay = null
	_membership = null
	_adapter = null
	_pending.clear()
	_pending_bytes = 0
	_activity = 0
	_sent = 0
	_unavailable_since.clear()
	_relay_peers.clear()
	_ready_since.clear()
	_revision = -1
	_last_now = -1
	_route_cursor = 0
	_failure = Code.OK
	_detach_requested = false


func _fair_pending() -> Array[Peer.Packet]:
	var ordered: Array[Peer.Packet] = []
	var roster: PackedStringArray = _membership.roster()
	for offset: int in roster.size():
		var uuid: String = roster[(_route_cursor + offset) % roster.size()]
		for packet: Peer.Packet in _pending:
			if _uuid(packet.to) == uuid:
				ordered.append(packet)
	_route_cursor = (_route_cursor + 1) % roster.size()
	return ordered


func _observe_readiness(now_us: int) -> void:
	for uuid: String in _relay_peers.keys():
		if _adapter.status().route != "mesh" or _direct.send_readiness(_membership.identity(uuid), 1) != Code.OK:
			_ready_since.erase(uuid)
			continue
		if not _ready_since.has(uuid):
			_ready_since[uuid] = now_us
		if now_us - int(_ready_since[uuid]) >= _options.restore_after_us and _relay.status().pending_packets == 0:
			_relay_peers.erase(uuid)
			_unavailable_since.erase(uuid)
			_ready_since.erase(uuid)
