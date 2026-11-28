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
var physical_closed: bool = false
var send_budget: int = 0
var receive_budget: int = 0
var route_budget: int = 0
var uuid: String = ""
var overlap_recipient: String = ""
var relay_payloads: Dictionary = {}
var pressure_refusals: int = 0
var pressure_post_wrap_refusals: int = 0
var pressure_retries: int = 0
var refused_head: PackedByteArray = PackedByteArray()
var refused_input: Dictionary = {}
var retried_inputs: Array[Dictionary] = []
var received_inputs: Dictionary = {}
var recording_tail: Dictionary = {}
var final_input: Dictionary = {}

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
	_observe_relay(host, host.recording_pressure)
	return true

func _observe_relay(host: Node, capture_recording: bool = false) -> void:
	host.clients[0].game_data_binary_received.connect(func(sender: String, encoding: int, bytes: PackedByteArray) -> void:
		var decoded: RefCounted = Relay.Envelope.decode(bytes, 1024)
		if encoding == 1 and decoded.code == 0 and decoded.sender == sender and decoded.recipient == uuid \
			and decoded.session == host.memberships[0].handshake_message().session_id:
			accepted_binary += 1
			var limits: T.Limits = T.Limits.new()
			limits.player_count = host.player_count
			var input: T.Result = Codec.decode(decoded.payload, limits)
			if input.code != T.Code.OK: return
			if capture_recording and _post_wrap_input(input.message):
				var envelope: String = bytes.hex_encode()
				if host.asymmetric.is_phase_input(input.message.start_frame + input.message.frame_count):
					JavaScriptBridge.eval("window.fortressRecordingAdmit(" + JSON.stringify(envelope) + ")")
				if received_inputs.size() >= 512 and not received_inputs.has(envelope):
					host.errors.append("recording_pressure_receipt_overflow")
				else:
					received_inputs[envelope] = true
				if final_input.is_empty() and input.message.start_frame + input.message.frame_count == host.frame_count:
					final_input = {"envelope": envelope, "frame": host.peers[0].status().current_frame,
						"turn": host.pressure_service_turn, "stage": host.stage}
			if not _early_input(input.message): return
			var payload: String = decoded.payload.hex_encode()
			if relay_payloads.size() >= 128 and not relay_payloads.has(payload):
				host.errors.append("mixed_capture_overflow")
			else:
				relay_payloads[payload] = true)

func _early_input(message: T.Message) -> bool:
	return message.kind == T.Kind.INPUT and message.start_frame >= 0 \
		and message.start_frame + message.frame_count <= 3

func _post_wrap_input(message: T.Message) -> bool:
	return message.kind == T.Kind.INPUT and message.start_frame > 128


func recording_tail_barrier(host: Node) -> bool:
	var peer: Peer = host.peers[0]
	var frame: int = peer.status().current_frame
	var endpoints: Array = peer.network_status().peers.values()
	if frame != host.frame_count or endpoints.size() != 1 or endpoints[0].last_received_frame != frame - 2 or not final_input.is_empty():
		host.errors.append("recording_tail_early_delivery")
		return false
	recording_tail = {"frame": frame, "received_frame": endpoints[0].last_received_frame,
		"turn": host.pressure_service_turn, "loads": host.games[0].loads}
	JavaScriptBridge.eval("document.body.dataset.fortressRecordingTail = '%d'" % frame)
	if await host._wait_cleanup("window.fortressRecordingTailReleased || false"):
		return true
	host.errors.append("recording_tail_release_timeout")
	return false


func recording_tail_result(host: Node) -> Dictionary:
	var peer: Peer = host.peers[0]
	var endpoints: Array = peer.network_status().peers.values()
	return {"held": recording_tail, "receipt": final_input, "after": {"frame": peer.status().current_frame,
		"confirmed_frame": peer.status().confirmed_frame, "received_frame": endpoints[0].last_received_frame, "loads": host.games[0].loads}}


func has_pending() -> bool:
	return not pending.is_empty()


## True when the composed routes hold no queued work and took nothing off the wire.
func idle() -> bool:
	return pending.is_empty() and fallback.idle()

func service(host: Node) -> bool:
	_record_bounds()
	if not physical_closed and host.local_index == 0 and host.peers[0].status().current_frame == 5 \
		and JavaScriptBridge.eval("window.fortressPhysicalClose || false"):
		if overlap == null or overlap_recipient.is_empty():
			host.errors.append("physical_close_missing_destination")
			return false
		var transport: Object = host.meshes[0].get_multiplayer_peer()
		var destination: int = host.memberships[0].uuid_to_peer_id(overlap_recipient)
		if not transport.call("has_peer", destination):
			host.errors.append("physical_close_missing_peer")
			return false
		var entry: Dictionary = transport.call("get_peer", destination)
		entry.channels[2].close()
		physical_closed = true
	if pending.is_empty(): pending = host.peers[0].drain_outbox()
	if not pending.is_empty():
		var code: int = fallback.enqueue_batch(pending)
		if code == Relay.Code.OK:
			if not host.drop_enabled and host.local_index == 0 and overlap == null and host.peers[0].status().current_frame == 3:
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
	if host.recording_pressure and not refused_head.is_empty():
		if relay._pending.is_empty() or relay._pending[0].envelope != refused_head:
			host.errors.append("recording_pressure_head_changed")
			return false
	var blocked_reads: int = -1
	if host.recording_pressure and retried_inputs.size() < 2 and refused_input.is_empty() and host.peers[0].status().current_frame > 129:
		blocked_reads = int(JavaScriptBridge.eval("window.fortressRtc.relayPostWrapBlockedReads"))
	var result: Relay.Result = fallback.poll(host.transport_us, host._next_token)
	if result.code not in [Relay.Code.OK, Relay.Code.BACKPRESSURE]:
		host.errors.append("mixed_poll_%d_peer_%d" % [result.code, result.peer_code])
		return false
	if host.recording_pressure:
		if not refused_head.is_empty() and relay._sent > 0:
			pressure_retries += 1
			refused_head.clear()
			if not refused_input.is_empty():
				refused_input["retry_turn"] = host.pressure_service_turn
				retried_inputs.append(refused_input)
				refused_input = {}
				JavaScriptBridge.eval("window.fortressRecordingRefusedHead = ''")
		if result.code == Relay.Code.BACKPRESSURE and not relay._pending.is_empty():
			pressure_refusals += 1
			if host.peers[0].status().current_frame > 128: pressure_post_wrap_refusals += 1
			refused_head = relay._pending[0].envelope.duplicate()
			if blocked_reads >= 0:
				var current_reads: int = int(JavaScriptBridge.eval("window.fortressRtc.relayPostWrapBlockedReads"))
				if current_reads == blocked_reads + 1: _capture_refused_input(host, current_reads)
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

func _capture_refused_input(host: Node, blocked_read: int) -> void:
	var envelope: RefCounted = Relay.Envelope.decode(refused_head, 1024)
	if envelope.code != Relay.Code.OK: return
	var limits: T.Limits = T.Limits.new()
	limits.player_count = host.player_count
	var packet: T.Result = Codec.decode(envelope.payload, limits)
	if packet.code != T.Code.OK or not _post_wrap_input(packet.message): return
	for earlier: Dictionary in retried_inputs:
		if earlier.start_frame == packet.message.start_frame: return
	var hex: String = refused_head.hex_encode()
	if not JavaScriptBridge.eval("window.fortressArmRecordingHead(" + JSON.stringify(hex) + ")"): return
	refused_input = {"envelope": hex, "start_frame": packet.message.start_frame, "frame": host.peers[0].status().current_frame,
		"refused_turn": host.pressure_service_turn, "blocked_read": blocked_read}


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
		if decoded.code != T.Code.OK or not _early_input(decoded.message): continue
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
		"pressure_refusals": pressure_refusals, "pressure_post_wrap_refusals": pressure_post_wrap_refusals,
		"pressure_retries": pressure_retries, "refused_head_bytes": refused_head.size(),
		"retried_inputs": retried_inputs, "received_inputs": received_inputs.keys(),
		"overlap": {} if overlap == null else {"recipient": overlap_recipient, "payload": overlap.bytes.hex_encode()}}

func detach() -> void:
	fallback.detach()
	relay.detach()
	pending.clear()
