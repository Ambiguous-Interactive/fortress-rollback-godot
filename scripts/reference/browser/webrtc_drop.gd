extends RefCounted

const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Direct = preload("res://addons/fortress_rollback/transport/signalfish_webrtc.gd")
const S = preload("res://addons/fortress_rollback/core/session_types.gd")
const Drop = preload("res://addons/fortress_rollback/core/peer_drop_barrier.gd")
const Envelope = preload("res://addons/fortress_rollback/transport/signalfish_relay_envelope.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
var events: Array[Dictionary] = []
var relay_barriers: Array[String] = []
var _host: Node = null
var _foreign_enabled: bool = false
var _foreign_sent: int = 0


func observe_relay(host: Node) -> void:
	host.clients[0].game_data_binary_received.connect(func(sender: String, encoding: int, bytes: PackedByteArray) -> void:
		var envelope: RefCounted = Envelope.decode(bytes, 1024)
		if encoding != 1 or envelope.code != 0 or envelope.sender != sender \
			or envelope.recipient != host.clients[0].get_player_id() \
			or envelope.session != host.memberships[0].handshake_message().session_id:
			return
		var limits: T.Limits = T.Limits.new()
		limits.player_count = host.player_count
		var decoded: T.Result = Codec.decode(envelope.payload, limits)
		if decoded.code != T.Code.OK or decoded.message.kind != T.Kind.DROP_BARRIER \
			or decoded.message.sender_id != host.memberships[0].identity(sender) or decoded.message.session_id != envelope.session:
			return
		var packet: String = envelope.payload.hex_encode()
		if packet in relay_barriers:
			return
		if relay_barriers.size() >= 128:
			host.errors.append("peer_drop_relay_capture_overflow")
			return
		relay_barriers.append(packet))


func observed(event: Dictionary) -> void:
	if event.kind in ["peer_drop_pending", "peer_dropped", "peer_drop_unconfirmed"]:
		events.append(event.duplicate(true))
	if event.kind == "peer_drop_pending":
		_publish_foreign()


## A non-coordinating survivor publishes a well-formed prepare for the departed
## target. The coordinator must refuse it because only the lowest surviving slot
## may propose, and the real agreement must keep its own cut and value.
func _publish_foreign() -> void:
	if not _foreign_enabled or _host == null or _foreign_sent > 0:
		return
	if _host.player_count != 3 or _host.local_index not in [0, 1]:
		return
	var peer: RefCounted = _host.peers[0]
	# The destination is the only remote peer still in the match; peer ids are
	# indexed in the session's own remote order, not by browser page index.
	var destination: int = -1
	for candidate: int in range(peer.peer_ids().size()):
		if not peer._drops.is_gone(peer.peer_ids()[candidate].hex_encode()):
			if destination >= 0:
				return
			destination = candidate
	if destination < 0:
		return
	for identity: PackedByteArray in peer.peer_ids():
		var barrier: Drop.Barrier = peer._drops.barrier(identity.hex_encode())
		if barrier == null or barrier.state != Drop.PENDING or barrier.role != Drop.Role.FOLLOWER:
			continue
		var payload: Dictionary = peer._drops._payload(barrier, Drop.Phase.PREPARE, Drop.Stage.NONE, 0)
		payload["cut"] = 2
		payload["cut_digest"] = 999
		# A few copies cross the real unreliable channel; the coordinator counts
		# each refused prepare, so a lost copy still leaves a delivered receipt.
		for _copy: int in 3:
			var code: int = peer._drops._publish(peer, destination, payload)
			if code != 0:
				_host.errors.append("peer_drop_foreign_publish_%d" % code)
				return
			_foreign_sent += 1


func run(host: Node, count: int) -> bool:
	_host = host
	_foreign_enabled = bool(JavaScriptBridge.eval("window.fortressDropForeign || false"))
	if JavaScriptBridge.eval("window.fortressDropRelay || false"):
		observe_relay(host)
	host.stage = "handshake"
	if not await host._wait(func() -> bool: return host.peers[0].network_status().state == "running", true):
		return false
	JavaScriptBridge.eval("document.body.dataset.fortressUuid = " + JSON.stringify(host.clients[0].get_player_id()))
	JavaScriptBridge.eval("document.body.dataset.fortressHandshakeReady = 'true'")
	if not await host._wait(func() -> bool: return JavaScriptBridge.eval("window.fortressFirstStepReady || false"), true):
		return false
	var peer: RefCounted = host.peers[0]
	var slot: int = host.memberships[0].slot(host.clients[0].get_player_id())
	var departing_uuid: String = JavaScriptBridge.eval("window.fortressDepartingUuid")
	var departing_slot: int = host.memberships[0].slot(departing_uuid)
	var departing_identity: PackedByteArray = host.memberships[0].identity(departing_uuid)
	var second_departure: bool = bool(JavaScriptBridge.eval("window.fortressDropSecond || false"))
	var second_uuid: String = JavaScriptBridge.eval("window.fortressSecondUuid || ''")
	var second_identity: PackedByteArray = host.memberships[0].identity(second_uuid) if not second_uuid.is_empty() else PackedByteArray()
	var missing_history: bool = bool(JavaScriptBridge.eval("window.fortressDropMissing || false"))
	var rollback_departure: bool = bool(JavaScriptBridge.eval("window.fortressDropRollback || false"))
	if missing_history and host.local_index == 2:
		var own_slot: int = host.memberships[0].slot(host.clients[0].get_player_id())
		var target_slot: int = 2147483647
		for candidate: int in range(count):
			if candidate != own_slot:
				target_slot = mini(target_slot, candidate)
		var roster: PackedStringArray = host.memberships[0].roster()
		host.transports[0].arm_drop(host.memberships[0].identity(roster[target_slot]), 4, 6, own_slot)
	for frame: int in 7:
		if not missing_history:
			if not await host._wait(
				func() -> bool:
					for endpoint: Dictionary in peer.network_status().peers.values():
						if endpoint.last_received_frame < frame - 1:
							return false
					return true,
				true
			):
				return false
		host._update_transport_clock()
		var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(slot, frame, PackedByteArray([host._sample(frame, slot)]))]
		if peer.step(host.transport_us, samples).code != S.Code.OK:
			return false
		JavaScriptBridge.eval("document.body.dataset.fortressFrame = '%d'" % frame)
		if frame == 0 and not await host._wait_cleanup("window.fortressFirstDeliveryReady || false"):
			return false
		if not host._service_batch():
			return false
		await host.get_tree().create_timer(0.002).timeout
	JavaScriptBridge.eval("document.body.dataset.fortressDropReady = 'true'")
	if JavaScriptBridge.eval("window.fortressDropClose || false"):
		host.stage = "peer_drop_readiness"
		if not await host._wait(func() -> bool: return JavaScriptBridge.eval("window.fortressDropArm || false"), true):
			return false
		host.stage = "peer_drop_physical_departure"
		JavaScriptBridge.eval("document.body.dataset.fortressDropPaused = 'true'")
		if not await host._wait_passive(
			func() -> bool: return JavaScriptBridge.eval("window.fortressDropGo || false"), host.PHYSICAL_DEPARTURE_WAIT_US
		):
			host.errors.append("physical_departure_wait_timeout")
			return false
	elif not await host._wait(
		func() -> bool: return JavaScriptBridge.eval("window.fortressDropGo || false"),
		not (rollback_departure and host.local_index == 2)
	):
		return false
	var pending_at_detection: int = -1
	if host.local_index == 2:
		var submitted: int = 7
		var held_packets: int = 0
		var sent_packets: int = 0
		if rollback_departure:
			# Step first and hold the packet: its receipts must end at frame six so
			# both survivors still predict frame seven before the departure lands.
			host._update_transport_clock()
			var closing: Array[Driver.LocalInput] = [Driver.LocalInput.new(slot, 7, PackedByteArray([host._sample(7, slot)]))]
			if peer.step(host.transport_us, closing).code != S.Code.OK:
				return false
			var held: Array[Peer.Packet] = peer.drain_outbox()
			if held.is_empty():
				host.errors.append("peer_drop_rollback_empty")
				return false
			held_packets = held.size()
			JavaScriptBridge.eval("document.body.dataset.fortressFrame = '7'")
			JavaScriptBridge.eval("document.body.dataset.fortressDropPrepared = '7'")
			if not await host._wait(func() -> bool: return JavaScriptBridge.eval("window.fortressDropSend || false")):
				return false
			var waiting: Dictionary = host.transports[0].status()
			if waiting.get("pending_packets", 0) != 0:
				host.errors.append("peer_drop_rollback_busy")
				return false
			if host.transports[0].enqueue_batch(held) != 0:
				host.errors.append("peer_drop_rollback_enqueue")
				return false
			host._update_transport_clock()
			var sent: Direct.Result = host.transports[0].poll(host.transport_us, host._next_token)
			if sent.code != 0:
				host.errors.append("peer_drop_rollback_send_%d" % sent.code)
				return false
			if sent.sent < held.size():
				host.errors.append("peer_drop_rollback_unsent")
				return false
			host.sent_packets += sent.sent
			host.received_packets += sent.received
			sent_packets = sent.sent
			JavaScriptBridge.eval("document.body.dataset.fortressDropSubmitted = '7'")
			if not await host._wait(func() -> bool: return JavaScriptBridge.eval("window.fortressDropRelease || false")):
				return false
			submitted = 8
		var missing_inputs: Dictionary = {}
		if host.transports[0].has_method("drop_report"):
			missing_inputs = host.transports[0].drop_report()
		host.records.append(
			{
				"players": count,
				"departed": true,
				"departure_sequence": 1,
				"slot": slot,
				"frames_submitted": submitted,
				"held_packets": held_packets,
				"sent_packets": sent_packets,
				"uuid": host.clients[0].get_player_id(),
				"roster": host.memberships[0].roster(),
				"missing_inputs": missing_inputs,
			}
		)
		return true
	host._update_transport_clock()
	var predicted: Array[Driver.LocalInput] = [Driver.LocalInput.new(slot, 7, PackedByteArray([host._sample(7, slot)]))]
	if peer.step(host.transport_us, predicted).code != S.Code.OK:
		return false
	JavaScriptBridge.eval("document.body.dataset.fortressFrame = '7'")
	if rollback_departure:
		host.stage = "peer_drop_rollback"
		if not await host._wait(func() -> bool: return peer.status().pending_rollback_frame == 7, true):
			host.errors.append("peer_drop_rollback_pending")
			return false
		for event: Dictionary in events:
			if event.kind in ["peer_dropped", "peer_drop_pending"]:
				host.errors.append("peer_drop_rollback_prefreeze")
				return false
		if peer._drops.barrier(departing_identity.hex_encode()) != null:
			host.errors.append("peer_drop_rollback_prefreeze")
			return false
		# Capture the correction before the drop wait: the freeze must not be
		# able to manufacture the pending marker the validator trusts.
		pending_at_detection = peer.status().pending_rollback_frame
		# Publish the armed correction before waiting for the drop, so the
		# release gate never depends on detection.
		JavaScriptBridge.eval("document.body.dataset.fortressPendingRollback = '7'")
	host.stage = "peer_drop_agreement"
	if not await host._wait(
		func() -> bool:
			for row: Dictionary in peer.diagnostics().peers:
				if row.get("dropped", false):
					return true
			return false,
		true
	):
		return false
	if not rollback_departure:
		pending_at_detection = peer.status().pending_rollback_frame
	var barrier: Drop.Barrier = peer._drops.barrier(departing_identity.hex_encode())
	if barrier == null or barrier.state != Drop.COMMITTED or barrier.value != PackedByteArray([host._sample(barrier.cut, departing_slot)]):
		host.errors.append("peer_drop_certificate")
		return false
	var cut: int = barrier.cut
	if rollback_departure and (pending_at_detection != 7 or cut != 7):
		host.errors.append("peer_drop_rollback_pending")
		return false
	var cuts: Dictionary = {departing_slot: cut}
	var prediction_gap: int = peer.status().current_frame - cut - 1
	if rollback_departure and prediction_gap != 0:
		host.errors.append("peer_drop_rollback_gap_%d" % prediction_gap)
		return false
	if not rollback_departure and prediction_gap < 1:
		return false
	if JavaScriptBridge.eval("window.fortressDropCorrupt || false"):
		host.games[0].corrupt_continuation = true
	host.stage = "peer_drop_gameplay"
	var comparisons: int = 0
	var loop_end: int = 12 if second_departure else 40
	for frame: int in range(8, loop_end):
		if not await host._wait(
			func() -> bool:
				for row: Dictionary in peer.diagnostics().peers:
					if not row.get("dropped", false) and row.last_received_frame < frame - 1:
						return false
				return true,
			true
		):
			return false
		host._update_transport_clock()
		var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(slot, frame, PackedByteArray([host._sample(frame, slot)]))]
		if peer.step(host.transport_us, samples).code != S.Code.OK:
			return false
		JavaScriptBridge.eval("document.body.dataset.fortressFrame = '%d'" % frame)
		if frame >= 10:
			if host.games[0].history.get(frame - 2) != expected(host, frame - 2, count, cuts):
				host.errors.append("peer_drop_canonical_%d" % (frame - 2))
				return false
			comparisons += 1
		if not host._service_batch():
			return false
		await host.get_tree().create_timer(0.002).timeout
	var certificates: Array[Dictionary] = []
	for identity: String in barrier.certificates:
		var certificate: Dictionary = barrier.certificates[identity]
		certificates.append({"peer": identity, "cut": certificate.cut, "digest": "%016x" % int(certificate.digest)})
	var dropped_frames: Dictionary = {}
	var dropped_count: int = 0
	var pending_events: int = 0
	for event: Dictionary in events:
		if event.kind == "peer_dropped":
			dropped_count += 1
			dropped_frames[event.peer.hex_encode()] = event.frame
		elif event.kind == "peer_drop_pending":
			pending_events += 1
	var row: Dictionary = {
		"players": count,
		"departed": false,
		"slot": slot,
		"uuid": host.clients[0].get_player_id(),
		"roster": host.memberships[0].roster(),
		"participants": barrier.participants,
		"certificate_rows": certificates,
		"digest": "%016x" % barrier.digest,
		"departing_slot": departing_slot,
		"frames_submitted": 40,
		"prediction_gap": prediction_gap,
		"pending_at_detection": pending_at_detection,
		"freeze_frame": cut,
		"frozen_value": barrier.value.hex_encode(),
		"state": barrier.state,
		"role": barrier.role,
		"certified": barrier.certified,
		"certificates": barrier.certificates.size(),
		"drop_events": 0,
		"drop_frames": dropped_frames,
		"pending_events": pending_events,
		"commit_ack_peers": barrier.commit_acks.keys(),
		"acknowledged_peers": barrier.acknowledged.keys(),
		"history_donor": barrier.history.donor,
		"history_first": barrier.history.first,
		"history_cut": barrier.history.cut,
		"history_installed": barrier.history.installed,
		"minimum_confirmed": peer.status().confirmed_frame,
		"canonical_comparisons": 38,
		"active_comparisons": comparisons,
		"rollback_loads": host.games[0].loads,
		"foreign_sent": _foreign_sent,
		"foreign_received": barrier.refused_proposals,
		"foreign_cut": barrier.refused_cut,
		"foreign_digest": barrier.refused_digest,
		"relay_barriers": relay_barriers.duplicate(),
		"session_id": host.memberships[0].handshake_message().session_id.hex_encode(),
		"target_generation": barrier.generations[0],
		"operation": barrier.operation,
		"coordinator": barrier.coordinator,
		"coordinator_generation": barrier.coordinator_generation,
		"target_set_digest": "%016x" % barrier.target_set_digest,
		"direct": host._transport_totals(),
		"mixed": host.mixed.report() if host.mixed_enabled else {}
	}
	if second_departure and host.local_index == 1:
		for frame: int in range(1, 11):
			if host.games[0].history.get(frame) != expected(host, frame, count, cuts):
				host.errors.append("peer_drop_canonical_%d" % frame)
				return false
		row["departed"] = true
		row["departure_sequence"] = 2
		row["frames_submitted"] = 12
		row["canonical_comparisons"] = 10
		row["drop_events"] = dropped_count
		host.records.append(row)
		return true
	if second_departure:
		if second_identity.is_empty():
			host.errors.append("peer_drop_second_identity")
			return false
		host.stage = "peer_drop_second_departure"
		if not await host._wait(
			func() -> bool: return peer._drops.is_dropped(second_identity.hex_encode()), true
		):
			return false
		var second_cut: int = peer._drops.freeze_frame(second_identity.hex_encode())
		var second_frontier: int = peer.status().confirmed_frame
		var second_slot: int = host.memberships[0].slot(second_uuid)
		if second_cut < 0 or second_slot < 0:
			host.errors.append("peer_drop_second_freeze")
			return false
		cuts[second_slot] = second_cut
		host.stage = "peer_drop_gameplay"
		for frame: int in range(12, 40):
			host._update_transport_clock()
			var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(slot, frame, PackedByteArray([host._sample(frame, slot)]))]
			if peer.step(host.transport_us, samples).code != S.Code.OK:
				return false
			JavaScriptBridge.eval("document.body.dataset.fortressFrame = '%d'" % frame)
			if host.games[0].history.get(frame - 2) != expected(host, frame - 2, count, cuts):
				host.errors.append("peer_drop_canonical_%d" % (frame - 2))
				return false
			comparisons += 1
			if not host._service_batch():
				return false
			await host.get_tree().create_timer(0.002).timeout
		dropped_frames.clear()
		dropped_count = 0
		pending_events = 0
		for event: Dictionary in events:
			if event.kind == "peer_dropped":
				dropped_count += 1
				dropped_frames[event.peer.hex_encode()] = event.frame
			elif event.kind == "peer_drop_pending":
				pending_events += 1
		row["drop_frames"] = dropped_frames
		row["pending_events"] = pending_events
		row["commit_ack_peers"] = barrier.commit_acks.keys()
		row["acknowledged_peers"] = barrier.acknowledged.keys()
		row["active_comparisons"] = comparisons
		row["drop_events"] = 2
		row["second_slot"] = second_slot
		row["second_freeze_frame"] = second_cut
		row["second_frontier"] = second_frontier
		row["second_frozen_value"] = PackedByteArray([host._sample(second_cut, second_slot)]).hex_encode()
	host.stage = "final_confirmation"
	if not await host._wait(func() -> bool: return peer.status().confirmed_frame >= 38, true):
		return false
	for frame: int in range(1, 39):
		if host.games[0].history.get(frame) != expected(host, frame, count, cuts):
			host.errors.append("peer_drop_canonical_%d" % frame)
			return false
	for event: Dictionary in events:
		if event.kind == "peer_drop_unconfirmed":
			host.errors.append("peer_drop_unconfirmed")
			return false
	if dropped_count != (2 if second_departure else 1):
		host.errors.append("peer_drop_publication")
		return false
	row["drop_events"] = dropped_count
	row["minimum_confirmed"] = peer.status().confirmed_frame
	row["rollback_loads"] = host.games[0].loads
	row["direct"] = host._transport_totals()
	host.records.append(row)
	return true


static func expected(host: Node, frame: int, count: int, cuts: Dictionary) -> PackedByteArray:
	var result: PackedByteArray = PackedByteArray()
	result.resize(4 + 4 * count)
	result.encode_u32(0, frame)
	for slot: int in count:
		var cut: int = int(cuts.get(slot, 2147483647))
		var value: int = 0
		for previous: int in frame:
			var sample_frame: int = mini(previous, cut) if previous > cut else previous
			value = (value * 33 + host._sample(sample_frame, slot)) & 0xffffffff
		result.encode_u32(4 + 4 * slot, value)
	return result
