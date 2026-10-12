extends RefCounted

# gdlint: disable=constant-name,max-returns
const Relay = preload("res://addons/fortress_rollback/transport/signalfish_relay.gd")
const Fallback = preload("res://addons/fortress_rollback/transport/signalfish_fallback.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")

var relay: Relay = Relay.new()
var fallback: Fallback = Fallback.new()
var pending: Array[Peer.Packet] = []
var switched: bool = false
var restored: bool = false
var maximum_pending: int = 0
var maximum_relay_pending: int = 0
var maximum_relay_received: int = 0
var previous_confirmed: int = -1
var previous_frame: int = 0
var accepted_binary: int = 0
var overlap_packets: int = 0
var overlap: Peer.Packet
var duplicated: bool = false
var send_budget: int = 0
var receive_budget: int = 0
var route_budget: int = 0
var uuid: String = ""
var overlap_recipient: String = ""
var relay_payloads: Dictionary = {}

func configure(host: Node, mode: Object) -> bool:
	uuid = host.memberships[0].local_uuid()
	var options: Relay.Options = Relay.Options.new()
	options.max_packet_bytes = 1024
	if not JavaScriptBridge.eval("window.fortressMixedDefault || false"):
		options.max_sends_per_poll = 32
		options.max_receives_per_poll = 32
	send_budget = options.max_sends_per_poll
	receive_budget = options.max_receives_per_poll
	if relay.configure(host.clients[0], mode, host.infos[0], host.memberships[0], host.adapters[0], host.peers[0], options) != 0:
		host.errors.append("mixed_relay_configure")
		return false
	var controls: Fallback.Options = Fallback.Options.new()
	controls.fallback_after_us = 50000
	controls.restore_after_us = 50000
	if JavaScriptBridge.eval("window.fortressDisableFallback || false"): controls.fallback_after_us = 60000000
	route_budget = controls.max_routes_per_poll
	if fallback.configure(host.transports[0], relay, host.memberships[0], host.adapters[0], host.peers[0], controls) != 0:
		host.errors.append("mixed_fallback_configure")
		return false
	host.clients[0].game_data_binary_received.connect(func(sender: String, encoding: int, bytes: PackedByteArray) -> void:
		var decoded: RefCounted = Relay.Envelope.decode(bytes, 1024)
		if encoding == 1 and decoded.code == 0 and decoded.sender == sender and decoded.recipient == uuid \
			and decoded.session == host.memberships[0].handshake_message().session_id:
			accepted_binary += 1
			var payload: String = decoded.payload.hex_encode()
			if relay_payloads.size() >= 128 and not relay_payloads.has(payload):
				host.errors.append("mixed_capture_overflow")
			else:
				relay_payloads[payload] = true)
	return true

func has_pending() -> bool:
	return not pending.is_empty()

func service(host: Node) -> bool:
	_record_bounds()
	if pending.is_empty(): pending = host.peers[0].drain_outbox()
	if not pending.is_empty():
		var code: int = fallback.enqueue_batch(pending)
		if code == Relay.Code.OK:
			if host.local_index == 0 and overlap == null and host.peers[0].status().current_frame == 3:
				_capture_overlap(host)
			pending = []
		elif code != Relay.Code.BACKPRESSURE:
			host.errors.append("mixed_enqueue_%d" % code)
			return false
	if overlap != null and not duplicated and host.peers[0].status().current_frame >= 8:
		var duplicate: Array[Peer.Packet] = [overlap]
		var code: int = relay.enqueue_batch(duplicate)
		if code == Relay.Code.OK:
			duplicated = true
			overlap_packets += 1
		elif code != Relay.Code.BACKPRESSURE:
			host.errors.append("mixed_overlap_%d" % code)
			return false
	var result: Relay.Result = fallback.poll(host.transport_us, host._next_token)
	if result.code not in [Relay.Code.OK, Relay.Code.BACKPRESSURE]:
		host.errors.append("mixed_poll_%d_peer_%d" % [result.code, result.peer_code])
		return false
	host.sent_packets += result.sent
	host.received_packets += result.received
	var state: Dictionary = fallback.status()
	_record_bounds()
	if not state.relay_peers.is_empty(): switched = true
	if switched and state.relay_peers.is_empty(): restored = true
	var core: RefCounted = host.peers[0].status()
	if core.confirmed_frame < previous_confirmed or core.current_frame < previous_frame:
		host.errors.append("mixed_history_reset")
		return false
	previous_confirmed = core.confirmed_frame
	previous_frame = core.current_frame
	return true

func _record_bounds() -> void:
	var state: Dictionary = fallback.status()
	maximum_pending = maxi(maximum_pending, state.pending_packets)
	maximum_relay_pending = maxi(maximum_relay_pending, state.relay.pending_packets)
	maximum_relay_received = maxi(maximum_relay_received, state.relay.received_packets)

func _capture_overlap(host: Node) -> void:
	var limits: T.Limits = T.Limits.new()
	limits.player_count = host.player_count
	for packet: Peer.Packet in pending:
		var decoded: T.Result = Codec.decode(packet.bytes, limits)
		if decoded.code != T.Code.OK or decoded.message.kind != T.Kind.INPUT: continue
		overlap = Peer.Packet.new(packet.to.duplicate(), packet.bytes.duplicate())
		for member: String in host.memberships[0].roster():
			if host.memberships[0].identity(member) == packet.to: overlap_recipient = member
		return

func report() -> Dictionary:
	return {"switched": switched, "restored": restored, "relay_peers": fallback.status().relay_peers.size(),
		"maximum_pending": maximum_pending, "maximum_relay_pending": maximum_relay_pending,
		"maximum_relay_received": maximum_relay_received, "accepted_binary": accepted_binary, "overlap_packets": overlap_packets,
		"caller_pending": pending.size(), "route_budget": route_budget, "send_budget": send_budget, "receive_budget": receive_budget,
		"uuid": uuid, "relay_payloads": relay_payloads.keys(),
		"overlap": {} if overlap == null else {"recipient": overlap_recipient, "payload": overlap.bytes.hex_encode()}}

func detach() -> void:
	fallback.detach()
	relay.detach()
	pending.clear()
