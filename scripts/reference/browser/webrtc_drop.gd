extends RefCounted

const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const Direct = preload("res://addons/fortress_rollback/transport/signalfish_webrtc.gd")
const S = preload("res://addons/fortress_rollback/core/session_types.gd")
const Drop = preload("res://addons/fortress_rollback/core/peer_drop_barrier.gd")
const Envelope = preload("res://addons/fortress_rollback/transport/signalfish_relay_envelope.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const DirectTypes = preload("res://addons/fortress_rollback/transport/signalfish_webrtc_types.gd")
## Larger than every resend round inside the live barrier timeout, so the
## lost-history control never lets a chunk through after the arm runs out.
const LOST_HISTORY_DROP_COUNT: int = 10000
## The post-termination observation window: a local-frontier fallback must not
## advance a frame after the survivor already reported the terminal outcome.
const LOST_HISTORY_SETTLE_US: int = 250000
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
		if _host != null:
			_host.pending_seen = true
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
		# A transient queue refusal on one copy is retried by the next copy; only
		# a batch that cannot queue anything is a harness error.
		var last_code: int = 0
		for _copy: int in 3:
			last_code = peer._drops._publish(peer, destination, payload)
			if last_code == 0:
				_foreign_sent += 1
		if _foreign_sent == 0:
			_host.errors.append("peer_drop_foreign_publish_%d" % last_code)


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
	var peer: Peer = host.peers[0]
	var slot: int = host.memberships[0].slot(host.clients[0].get_player_id())
	var departing_uuid: String = JavaScriptBridge.eval("window.fortressDepartingUuid")
	var departing_slot: int = host.memberships[0].slot(departing_uuid)
	var departing_identity: PackedByteArray = host.memberships[0].identity(departing_uuid)
	var departing_key: String = departing_identity.hex_encode()
	var second_departure: bool = bool(JavaScriptBridge.eval("window.fortressDropSecond || false"))
	var second_boundary: String = JavaScriptBridge.eval("window.fortressSecondBoundary || ''")
	var final_turn: int = 40 if second_boundary.is_empty() else 44
	var second_uuid: String = JavaScriptBridge.eval("window.fortressSecondUuid || ''")
	var second_identity: PackedByteArray = host.memberships[0].identity(second_uuid) if not second_uuid.is_empty() else PackedByteArray()
	var missing_history: bool = bool(JavaScriptBridge.eval("window.fortressDropMissing || false"))
	var history_lost: bool = bool(JavaScriptBridge.eval("window.fortressDropHistoryLost || false"))
	var unequal_history: bool = missing_history and not history_lost
	var opening_expected: int = -1
	var expected_target_receipt: int = -1
	var coordinator_identity: PackedByteArray = PackedByteArray()
	var exposed_before: Array[Dictionary] = []
	var commit_loss: bool = bool(JavaScriptBridge.eval("window.fortressDropCommit || false"))
	var rollback_departure: bool = bool(JavaScriptBridge.eval("window.fortressDropRollback || false"))
	var room_departure: bool = bool(JavaScriptBridge.eval("window.fortressDropRoom || false"))
	var room_continue: bool = bool(JavaScriptBridge.eval("window.fortressDropRoomContinue || false"))
	var room_after_drop: bool = bool(JavaScriptBridge.eval("window.fortressDropRoomAfterDrop || false"))
	var room_before_drop: bool = bool(JavaScriptBridge.eval("window.fortressDropRoomBeforeDrop || false"))
	var process_missing: bool = bool(JavaScriptBridge.eval("window.fortressDropProcessMissing || false"))
	var process_death: bool = bool(JavaScriptBridge.eval("window.fortressDropProcess || false"))
	if commit_loss:
		# The surviving roles publish opposite halves of the commit exchange.
		for transport: Variant in host.transports:
			if transport.has_method("arm_commit_drop"):
				transport.arm_commit_drop(1)
	if missing_history:
		var roster: PackedStringArray = host.memberships[0].roster()
		var recipient_slot: int = 1 if departing_slot == 0 else 0
		coordinator_identity = host.memberships[0].identity(roster[recipient_slot])
		if host.local_index == 2:
			host.transports[0].arm_drop(coordinator_identity, 4, 6, slot)
		else:
			if unequal_history:
				opening_expected = 2 if slot == recipient_slot else 3
				expected_target_receipt = 3 if slot == recipient_slot else 6
				# The proposer needs the departing endpoint's receipt for the donor's slot.
				if slot != recipient_slot:
					host.transports[0].arm_drop(departing_identity, 3, 6, slot)
			# The selected donor sends the retained history. Drop its first
			# chunk so the recipient must retry before it installs the rows.
			# The lost-history control withholds every chunk until the barrier
			# expires, so the recipient can never install the interval. Arm
			# every owned transport; a page with more than one local client
			# must not leave the donor link unarmed.
			for transport: Variant in host.transports:
				if transport.has_method("arm_history_drop"):
					transport.arm_history_drop(LOST_HISTORY_DROP_COUNT if history_lost else 1)
	var steps_taken: int = 0
	for frame: int in 7:
		if unequal_history and frame == 4:
			# Frame four carries the real receipt for the other side's original frame three.
			host.stage = "peer_drop_opening_receipts"
			var receipt_key: String = coordinator_identity.hex_encode() if host.local_index == 2 else departing_key
			if not await host._wait(func() -> bool: return peer.network_status().peers[receipt_key].last_received_frame >= 3, true):
				return false
		if not missing_history or (unequal_history and frame <= 3):
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
		steps_taken += 1
		JavaScriptBridge.eval("document.body.dataset.fortressFrame = '%d'" % frame)
		if frame == 0 and not await host._wait_cleanup("window.fortressFirstDeliveryReady || false"):
			return false
		if not host._service_batch():
			return false
		await host.get_tree().create_timer(0.002).timeout
	if host.drop_overlap:
		return await host.transports[0].run_overlap(host, departing_uuid)
	if opening_expected >= 0:
		host.stage = "peer_drop_before_unequal_frontiers"
		if not await host._wait(
			func() -> bool:
				return peer.network_status().peers[departing_key].last_received_frame >= expected_target_receipt \
					and peer.status().confirmed_frame >= opening_expected,
			true
		):
			return false
		host._update_transport_clock()
		var recovered: Driver.StepResult = peer.recover(host.transport_us)
		exposed_before = _exposed_row(peer, opening_expected, count)
		if recovered.code != S.Code.OK or peer.status().confirmed_frame != opening_expected or exposed_before.is_empty():
			host.errors.append("peer_drop_missing_before_exposure")
			return false
		if peer.network_status().peers[departing_key].last_received_frame != expected_target_receipt:
			host.errors.append("peer_drop_missing_before_target_receipt")
			return false
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
	elif room_departure:
		if process_death and host.local_index == 2:
			if not await _wait_process_hold(host):
				return false
		elif process_missing and host.local_index == 2:
			var outcome: int = await _wait_gate_keepalive(host)
			if outcome == 1:
				host.errors.append("peer_drop_room_gate_released")
			elif outcome == 0:
				host.errors.append("peer_drop_room_gate")
			else:
				host.errors.append("peer_drop_room_gate_timeout")
			return false
		elif not await host._wait_passive(func() -> bool: return JavaScriptBridge.eval("window.fortressDropGo || false"), 4000000):
			host.errors.append("peer_drop_room_gate")
			return false
	elif not await host._wait(
		func() -> bool: return JavaScriptBridge.eval("window.fortressDropGo || false"),
		not (rollback_departure and host.local_index == 2)
	):
		return false
	if room_departure:
		if host.local_index == 2:
			if room_after_drop or room_before_drop:
				if not await _wait_room_after_gate(host):
					return false
			return await _run_room_departure(host, count, slot, departing_uuid, steps_taken)
		if room_before_drop:
			return await _run_pending_room_fence(host, count, slot, departing_uuid, departing_slot, departing_identity, steps_taken)
		if not room_after_drop:
			return await _run_room_fence(host, count, slot, departing_uuid, departing_slot, departing_identity, room_continue, steps_taken)
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
			missing_inputs = host.transports[0].drop_report(unequal_history)
		host.records.append(
			{
				"players": count,
				"departed": true,
				"departure_sequence": 1,
				"slot": slot,
				"frames_submitted": submitted,
				"session_id": host.memberships[0].handshake_message().session_id.hex_encode(),
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
	if history_lost:
		return await _run_history_lost(host, count, slot, departing_slot, departing_identity, steps_taken)
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
	var serial_ready: Dictionary = {}
	var serial_release: String = ""
	if not second_boundary.is_empty():
		host.stage = "peer_drop_first_commit_ack"
		# The follower observed COMMIT to reach this point. Only the proposer
		# has a remaining acknowledgement to receive in this three-page room.
		if barrier.role == Drop.Role.PROPOSER:
			if not await host._wait(
				func() -> bool: return not barrier.broken and barrier.acknowledged.has(barrier.participants[0]), true
			):
				return false
		serial_ready = {
			"commit_boundary": peer.status().current_frame,
			"commit_acks": barrier.acknowledged.keys(),
			"uuid": host.clients[0].get_player_id(),
			"first_target": departing_uuid,
			"session_id": host.memberships[0].handshake_message().session_id.hex_encode(),
			"operation": barrier.operation,
			"digest": "%016x" % barrier.digest
		}
		loop_end = 8 if second_boundary == "after-ack" else 40
	host.stage = "peer_drop_gameplay"
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
	if not second_boundary.is_empty():
		if second_boundary == "last-turn":
			host.stage = "peer_drop_last_turn_receipt"
			if not await host._wait(func() -> bool: return peer.status().confirmed_frame == loop_end - 1, true):
				return false
		serial_ready["departure_boundary"] = peer.status().current_frame
		serial_ready["confirmation"] = peer.status().confirmed_frame
		JavaScriptBridge.eval("document.body.dataset.fortressSerialReady = " + JSON.stringify(JSON.stringify(serial_ready)))
		if host.local_index == 1:
			host.stage = "peer_drop_second_release"
			if not await host._wait(
				func() -> bool: return JavaScriptBridge.eval("typeof window.fortressSecondRelease === 'string'"), true
			):
				return false
			serial_release = JavaScriptBridge.eval(
				"(() => { const release = window.fortressSecondRelease; window.fortressSecondRelease = null; return release; })()"
			)
			# Receipt confirmation can precede correction of the last sampled
			# turn. Repair at the held boundary without another local input.
			var recovered: Driver.StepResult = peer.recover(host.transport_us)
			if recovered.code != S.Code.OK or recovered.frame_before != loop_end or recovered.frame_after != loop_end:
				host.errors.append("peer_drop_second_recovery")
				return false
	if commit_loss:
		host.stage = "peer_drop_commit_exchange"
		if not await host._wait(
			func() -> bool:
				if barrier.role == Drop.Role.PROPOSER:
					return not barrier.acknowledged.is_empty()
				return int(host.transports[0].commit_report().get("resends", 0)) > 0,
			true
		):
			return false
	var certificates: Array[Dictionary] = []
	for identity: String in barrier.certificates:
		var certificate: Dictionary = barrier.certificates[identity]
		certificates.append({"peer": identity, "cut": certificate.cut, "digest": "%016x" % int(certificate.digest)})
	var dropped_frames: Dictionary = {}
	var dropped_count: int = 0
	var pending_events: int = 0
	var opening_frontier: int = -1
	for event: Dictionary in events:
		if event.kind == "peer_dropped":
			dropped_count += 1
			dropped_frames[event.peer.hex_encode()] = event.frame
		elif event.kind == "peer_drop_pending":
			pending_events += 1
			if event.peer == departing_identity and not dropped_frames.has(departing_key):
				opening_frontier = event.frame
	var history: Dictionary = host.transports[0].history_report() if host.transports[0].has_method("history_report") else {}
	var commit: Dictionary = host.transports[0].commit_report() if host.transports[0].has_method("commit_report") else {}
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
		"frames_submitted": final_turn,
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
		"history_dropped": int(history.get("dropped", 0)),
		"history_resends": int(history.get("resends", 0)),
		"history_drop_chunk": int(history.get("chunk", -1)),
		"history_drop_operation": int(history.get("operation", -1)),
		"history_drop_count": int(history.get("count", 0)),
		"commit_dropped": int(commit.get("dropped", 0)),
		"commit_batch_duplicates": int(commit.get("batch_duplicates", 0)),
		"commit_resends": int(commit.get("resends", 0)),
		"commit_operation": int(commit.get("operation", -1)),
		"commit_cut": int(commit.get("cut", -1)),
		"commit_digest": "%016x" % int(commit.get("digest", 0)),
		"commit_slot": int(commit.get("slot", -1)),
		"commit_retry_slot": int(commit.get("retry_slot", -1)),
		"commit_first": str(commit.get("first", "")),
		"commit_retry": str(commit.get("retry", "")),
		"commit_delay_us": int(commit.get("delay_us", -1)),
		"minimum_confirmed": peer.status().confirmed_frame,
		"canonical_comparisons": final_turn - 2,
		"active_comparisons": comparisons,
		"rollback_loads": host.games[0].loads,
		"foreign_sent": _foreign_sent,
		"foreign_received": barrier.refused_proposals,
		"foreign_cut": barrier.refused_cut,
		"foreign_digest": barrier.refused_digest,
		"foreign_reason": barrier.refused_reason,
		"relay_barriers": relay_barriers.duplicate(),
		"session_id": host.memberships[0].handshake_message().session_id.hex_encode(),
		"target_generation": barrier.generations[0],
		"operation": barrier.operation,
		"coordinator": barrier.coordinator,
		"coordinator_generation": barrier.coordinator_generation,
		"target_set_digest": "%016x" % barrier.target_set_digest,
		"roster_digest": "%016x" % barrier.roster_digest,
		"direct": host._transport_totals(),
		"mixed": host.mixed.report() if host.mixed_enabled else {}
	}
	if missing_history:
		if pending_events != 1 or opening_frontier != barrier.upper or dropped_frames.get(departing_key, -1) != cut:
			host.errors.append("peer_drop_missing_opening_frontier")
			return false
		row["opening_frontier"] = opening_frontier
		var opening_target: Vector2i = barrier.receipts.get(departing_slot, Vector2i(-1, -1))
		if opening_target.y != expected_target_receipt:
			host.errors.append("peer_drop_missing_opening_target_receipt")
			return false
		row["opening_target_receipt"] = opening_target.y
		var exposed_after: Array[Dictionary] = _exposed_row(peer, opening_frontier, count)
		if opening_frontier != opening_expected or exposed_before != exposed_after or exposed_after.is_empty():
			host.errors.append("peer_drop_missing_exposed_input")
			return false
		row["exposed_before"] = exposed_before
		row["exposed_after"] = exposed_after
		if barrier.role == Drop.Role.FOLLOWER:
			row["withheld_from_departing"] = host.transports[0].drop_report(true)
	if not serial_ready.is_empty():
		row["serial_ready"] = serial_ready
	if second_departure and host.local_index == 1:
		var last_comparison: int = 10 if second_boundary.is_empty() else serial_ready.confirmation + 1
		for frame: int in range(1, last_comparison + 1):
			if host.games[0].history.get(frame) != expected(host, frame, count, cuts):
				host.errors.append("peer_drop_canonical_%d" % frame)
				return false
		row["departed"] = true
		row["departure_sequence"] = 2
		row["frames_submitted"] = loop_end
		row["canonical_comparisons"] = last_comparison
		if not serial_ready.is_empty():
			row["serial_departure_boundary"] = peer.status().current_frame
			row["serial_release"] = serial_release
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
		for frame: int in range(loop_end, final_turn):
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
	host.stage = "final_confirmation"
	if not await host._wait(func() -> bool: return peer.status().confirmed_frame >= final_turn - 2, true):
		return false
	if second_departure:
		var frozen_row: S.FrameInputs = peer.confirmed_inputs(int(row["second_freeze_frame"]) + 1)
		if frozen_row == null:
			host.errors.append("peer_drop_second_frozen_row")
			return false
		var frozen: S.InputResult = frozen_row.read(int(row["second_slot"]))
		if frozen.code != S.Code.OK or frozen.status != Queue.Status.DISCONNECTED:
			host.errors.append("peer_drop_second_value")
			return false
		row["second_frozen_value"] = frozen.bytes.hex_encode()
	var serial_canonical: PackedStringArray = []
	for frame: int in range(1, final_turn - 1):
		var actual: PackedByteArray = host.games[0].history.get(frame, PackedByteArray())
		if actual != expected(host, frame, count, cuts):
			host.errors.append("peer_drop_canonical_%d" % frame)
			return false
		if not serial_ready.is_empty():
			serial_canonical.append(actual.hex_encode())
	if not serial_ready.is_empty():
		row["serial_canonical"] = serial_canonical
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
	# The final confirmation wait services transport, so a late acknowledgement
	# must reach the row even though the row was built before that wait.
	row["commit_ack_peers"] = barrier.commit_acks.keys()
	row["acknowledged_peers"] = barrier.acknowledged.keys()
	if room_after_drop:
		if not await _finish_after_drop(host, row, count, departing_uuid, departing_slot, departing_identity, cuts):
			return false
	host.records.append(row)
	return true


## The donor's retained bytes never reach the recipient. The barrier must
## expire and end the match: no survivor freezes the departed slot, installs a
## partial interval or continues from an unverified local frontier.
func _exposed_row(peer: Peer, frame: int, count: int) -> Array[Dictionary]:
	var input_row: S.FrameInputs = peer.confirmed_inputs(frame)
	if input_row == null:
		return []
	var row: Array[Dictionary] = []
	for slot: int in range(count):
		var input: S.InputResult = input_row.read(slot)
		if input.code != S.Code.OK or input.status != Queue.Status.CONFIRMED:
			return []
		row.append({"bytes": input.bytes.hex_encode(), "status": input.status})
	return row


func _run_history_lost(host: Node, count: int, slot: int, departing_slot: int,
		departing_identity: PackedByteArray, steps_taken: int) -> bool:
	var peer: RefCounted = host.peers[0]
	host.stage = "peer_drop_history_lost"
	# The terminal path must keep servicing each survivor's own barrier timeout
	# after a peer stops or a real transport reports backpressure; the ordinary
	# service batch treats both as fatal for a label that expects continuation.
	host.tearing_down = true
	var reason: String = ""
	var terminal_peer_code: int = -1
	var terminal_transport_code: int = -1
	var terminal_enqueue_code: int = 0
	var started_us: int = Time.get_ticks_usec()
	while Time.get_ticks_usec() - started_us < 15000000:
		host._update_transport_clock()
		for index: int in range(host.peers.size()):
			host.clients[index].poll()
			host.meshes[index].poll()
			if host.peers[index].status().lifecycle == S.Lifecycle.TERMINATED:
				continue
			terminal_peer_code = host.peers[index].poll(host.transport_us, host._poll_tokens(host.peers[index]))
			if terminal_peer_code not in [I.Code.OK, I.Code.BACKPRESSURE]:
				host.errors.append("peer_drop_history_lost_peer_%d" % terminal_peer_code)
				return false
			if host.peers[index].status().lifecycle == S.Lifecycle.TERMINATED:
				# The poll that timed the barrier out also closed the local
				# links; do not read them as a transport failure.
				for event: Dictionary in host.peers[index].drain_events():
					if String(event.get("kind", "")) == "peer_drop_unconfirmed":
						reason = String(event.get("reason", ""))
					host.drop_witness.observed(event)
				continue
			var packets: Array = host.peers[index].drain_outbox()
			if not packets.is_empty():
				terminal_enqueue_code = host.transports[index].enqueue_batch(packets)
				if terminal_enqueue_code not in [0, DirectTypes.Code.BACKPRESSURE]:
					host.errors.append("peer_drop_history_lost_enqueue_%d" % terminal_enqueue_code)
					return false
			var sent: Direct.Result = host.transports[index].poll(host.transport_us, host._next_token)
			terminal_transport_code = sent.code
			if terminal_transport_code not in [0, DirectTypes.Code.BACKPRESSURE, DirectTypes.Code.PEER_FAILURE]:
				# The other survivor may close its link after its own timeout;
				# that terminal wind-down is expected here.
				host.errors.append("peer_drop_history_lost_transport_%d" % terminal_transport_code)
				return false
			host.sent_packets += sent.sent
			host.received_packets += sent.received
			for event: Dictionary in host.peers[index].drain_events():
				if String(event.get("kind", "")) == "peer_drop_unconfirmed":
					reason = String(event.get("reason", ""))
				host.drop_witness.observed(event)
		if peer.status().lifecycle == S.Lifecycle.TERMINATED:
			break
		await host.get_tree().create_timer(0.002).timeout
	var barrier: Drop.Barrier = peer._drops.barrier(departing_identity.hex_encode())
	if barrier == null or barrier.state != Drop.FAILED or peer.status().lifecycle != S.Lifecycle.TERMINATED:
		host.errors.append("peer_drop_history_lost_barrier_%s_%d" % [
			"missing" if barrier == null else barrier.state, peer.status().lifecycle])
		return false
	var pending_events: int = 0
	var drop_events: int = 0
	for event: Dictionary in events:
		if event.kind == "peer_drop_pending":
			pending_events += 1
		elif event.kind == "peer_dropped":
			drop_events += 1
		elif event.kind == "peer_drop_unconfirmed" and reason.is_empty():
			reason = String(event.get("reason", ""))
	if drop_events != 0 or pending_events != 1 or reason != "timeout":
		host.errors.append("peer_drop_history_lost_outcome")
		return false
	# Observe one bounded window after the terminal decision. Exercise the
	# forward and poll paths, not only the SDK: a regression that let a
	# terminated peer advance must change the frame here.
	var terminated_frame: int = peer.status().current_frame
	var attempted: Array[Driver.LocalInput] = [Driver.LocalInput.new(slot, terminated_frame, PackedByteArray([host._sample(terminated_frame, slot)]))]
	var post_terminal: Driver.StepResult = peer.step(host.transport_us, attempted)
	if post_terminal.code == S.Code.OK or peer.status().current_frame != terminated_frame:
		host.errors.append("peer_drop_history_lost_continued_%d" % post_terminal.code)
		return false
	var settled_us: int = Time.get_ticks_usec()
	while Time.get_ticks_usec() - settled_us < LOST_HISTORY_SETTLE_US:
		for index: int in range(host.clients.size()):
			host.clients[index].poll()
			host.meshes[index].poll()
		peer.poll(host.transport_us, host._poll_tokens(peer))
		if peer.status().current_frame != terminated_frame:
			host.errors.append("peer_drop_history_lost_settle")
			return false
		await host.get_tree().create_timer(0.002).timeout
	var final_frame: int = peer.status().current_frame
	var confirmed_prefix: int = barrier.upper
	var comparisons: int = 0
	for frame: int in range(1, confirmed_prefix + 1):
		if host.games[0].history.get(frame) != expected(host, frame, count, {}):
			host.errors.append("peer_drop_history_lost_canonical_%d" % frame)
			return false
		comparisons += 1
	# Read the authoritative freeze state; a frozen slot must fail the control,
	# not be masked by a constant row field. The departed slot must be part of
	# the target set, or the no-freeze evidence would not cover it.
	if not barrier.slots.has(departing_slot):
		host.errors.append("peer_drop_history_lost_target")
		return false
	var targets: Array[int] = []
	var frozen_frame: int = -1
	for target: int in barrier.slots:
		targets.append(target)
		var observed_freeze: int = peer._core.frozen_frame(target)
		if observed_freeze >= 0:
			host.errors.append("peer_drop_history_lost_frozen_%d" % observed_freeze)
			return false
		if target == departing_slot:
			frozen_frame = observed_freeze
	var history: Dictionary = {}
	for transport: Variant in host.transports:
		if transport.has_method("history_report"):
			var report: Dictionary = transport.history_report()
			if int(report.get("dropped", 0)) > int(history.get("dropped", 0)):
				history = report
	host.records.append(
		{
			"players": count,
			"departed": false,
			"slot": slot,
			"uuid": host.clients[0].get_player_id(),
			"roster": host.memberships[0].roster(),
			"participants": barrier.participants,
			"target_slots": targets,
			"departing_slot": departing_slot,
			"frames_submitted": steps_taken + 1,
			"final_frame": final_frame,
			"frames_after_terminal": final_frame - terminated_frame,
			"post_terminal_code": post_terminal.code,
			"barrier_cut": barrier.cut,
			"prediction_gap": final_frame - barrier.cut - 1,
			"freeze_frame": frozen_frame,
			"state": barrier.state,
			"failed": true,
			"failure_reason": reason,
			"lifecycle": "terminated",
			"role": barrier.role,
			"certified": barrier.certified,
			"certificates": barrier.certificates.size(),
			"terminal_peer_code": terminal_peer_code,
			"terminal_transport_code": terminal_transport_code,
			"terminal_enqueue_code": terminal_enqueue_code,
			"drop_events": 0,
			"drop_frames": {},
			"pending_events": pending_events,
			"history_donor": barrier.history.donor,
			"history_first": barrier.history.first,
			"history_cut": barrier.history.cut,
			"history_installed": barrier.history.installed,
			"history_dropped": int(history.get("dropped", 0)),
			"history_resends": int(history.get("resends", 0)),
			"history_drop_chunk": int(history.get("chunk", -1)),
			"history_drop_operation": int(history.get("operation", -1)),
			"history_drop_count": int(history.get("count", 0)),
			"history_drop_chunks": history.get("chunks", []),
			"minimum_confirmed": peer.status().confirmed_frame,
			"confirmed_prefix": confirmed_prefix,
			"canonical_comparisons": comparisons,
			"rollback_loads": host.games[0].loads,
			"session_id": host.memberships[0].handshake_message().session_id.hex_encode(),
			"target_generation": barrier.generations[0],
			"operation": barrier.operation,
			"coordinator": barrier.coordinator,
			"coordinator_generation": barrier.coordinator_generation,
			"target_set_digest": "%016x" % barrier.target_set_digest,
			"direct": host._transport_totals(),
			"mixed": {},
		}
	)
	return true


## A committed coordinated drop keeps its certified freeze and canonical history
## when the server later announces a room departure. The survivors stop servicing
## the rollback endpoint after the drop completes and poll only the SDK client
## until the membership fence latches.
func _finish_after_drop(host: Node, row: Dictionary, count: int, departing_uuid: String,
		departing_slot: int, departing_identity: PackedByteArray, cuts: Dictionary) -> bool:
	var peer: RefCounted = host.peers[0]
	var barrier: Drop.Barrier = peer._drops.barrier(departing_identity.hex_encode())
	if row.get("state") != Drop.COMMITTED or barrier == null or barrier.state != Drop.COMMITTED \
		or not (row.get("freeze_frame") is int) or row.get("freeze_frame") < 0 \
		or row.get("frozen_value", "") == "":
		host.errors.append("peer_drop_room_after_drop_uncertified")
		return false
	host.stage = "peer_drop_room_after_drop"
	JavaScriptBridge.eval("document.body.dataset.fortressDropComplete = 'true'")
	var fenced: bool = await _wait_membership_fence(host, departing_uuid)
	if not fenced:
		host.errors.append("peer_drop_room_after_drop_fence")
		return false
	var status: Dictionary = host.adapters[0].status()
	var fence_frame: int = peer.status().current_frame
	var measured: Array = await _measure_post_fence(host, peer, fence_frame)
	var final_frame: int = measured[0]
	var frames_after_fence: int = measured[1]
	var frozen_roster: PackedStringArray = host.memberships[0].roster()
	var room_roster_after: PackedStringArray = _live_roster(host)
	var history_comparisons: int = 0
	for frame: int in range(1, 39):
		if host.games[0].history.get(frame) != expected(host, frame, count, cuts):
			host.errors.append("peer_drop_room_after_drop_history_%d" % frame)
			return false
		history_comparisons += 1
	row["room_fenced"] = true
	row["fence_route"] = status.route
	row["fence_error"] = int(status.error)
	row["fence_lifetime_revision"] = int(status.lifetime_revision)
	row["fence_frame"] = fence_frame
	row["final_frame"] = final_frame
	row["frames_after_fence"] = frames_after_fence
	row["player_left_events"] = host.room_player_left.duplicate()
	row["frozen_roster"] = frozen_roster
	row["room_roster_after"] = room_roster_after
	row["departed_slot"] = departing_slot
	row["departed_uuid"] = departing_uuid
	row["local_uuid"] = host.clients[0].get_player_id()
	row["session_id"] = host.memberships[0].handshake_message().session_id.hex_encode()
	row["barrier_committed"] = barrier.state == Drop.COMMITTED
	row["barrier_open"] = barrier != null
	row["fence_history_comparisons"] = history_comparisons
	JavaScriptBridge.eval("document.body.dataset.fortressRoomFenced = 'true'")
	JavaScriptBridge.eval("document.body.dataset.fortressFrame = '%d'" % final_frame)
	if frames_after_fence != 0:
		host.errors.append("peer_drop_room_continued")
		return false
	if int(row["frames_submitted"]) != fence_frame or departing_slot < 0 \
		or departing_slot >= frozen_roster.size() or frozen_roster[departing_slot] != departing_uuid \
		or room_roster_after.size() != count - 1 or room_roster_after.has(departing_uuid):
		host.errors.append("peer_drop_room_after_drop_identity")
		return false
	return true


func _wait_room_after_gate(host: Node) -> bool:
	host.stage = "peer_drop_room_after_gate"
	var started_us: int = Time.get_ticks_usec()
	while Time.get_ticks_usec() - started_us < 180000000:
		host.clients[0].poll()
		if JavaScriptBridge.eval("window.fortressDropRoomAfter || false"):
			return true
		await host.get_tree().create_timer(0.002).timeout
	host.errors.append("peer_drop_room_after_gate")
	return false


## The process witness holds page 2 alive until the Node closes its browser
## context. The page keeps its signaling client polled; the Node reads a
## sentinel immediately before the close to prove the context, not a page
## timeout, ended the socket.
func _wait_process_hold(host: Node) -> bool:
	var started_us: int = Time.get_ticks_usec()
	while Time.get_ticks_usec() - started_us < 120000000:
		host.clients[0].poll()
		var connected: bool = host.clients[0].is_connected_to_server()
		var authenticated: bool = host.clients[0].is_authenticated()
		var room: String = host.clients[0].get_room_code()
		var healthy: bool = host.errors.is_empty() and connected and authenticated and not room.is_empty()
		JavaScriptBridge.eval("document.body.dataset.fortressHoldHealthy = '%s'" % ("true" if healthy else "false"))
		JavaScriptBridge.eval("document.body.dataset.fortressHoldConnected = '%s'" % ("true" if connected else "false"))
		JavaScriptBridge.eval("document.body.dataset.fortressHoldAuthenticated = '%s'" % ("true" if authenticated else "false"))
		JavaScriptBridge.eval("document.body.dataset.fortressHoldRoom = " + JSON.stringify(room))
		JavaScriptBridge.eval("document.body.dataset.fortressHoldErrors = '%d'" % host.errors.size())
		if not healthy:
			if host.errors.is_empty():
				host.errors.append("peer_drop_room_process_hold_unhealthy")
			return false
		await host.get_tree().create_timer(0.002).timeout
	host.errors.append("peer_drop_room_process_hold_timeout")
	return false


## The missing-event control keeps the departing page's room socket alive while
## the survivors wait for a server event that never arrives. The Node releases
## the hold only after both survivor fence waits have failed. Returns 0 for the
## released hold, 1 if a gate unexpectedly opened, and -1 for the timeout.
func _wait_gate_keepalive(host: Node) -> int:
	var started_us: int = Time.get_ticks_usec()
	while Time.get_ticks_usec() - started_us < 30000000:
		host.clients[0].poll()
		if JavaScriptBridge.eval("window.fortressDropGo || false"):
			host.hold_ms = int((Time.get_ticks_usec() - started_us) / 1000)
			return 1
		if JavaScriptBridge.eval("window.fortressDropRoomGiveUp || false"):
			host.hold_ms = int((Time.get_ticks_usec() - started_us) / 1000)
			return 0
		await host.get_tree().create_timer(0.002).timeout
	host.hold_ms = int((Time.get_ticks_usec() - started_us) / 1000)
	return -1


## Measure the post-fence frame over a short wall-clock window. The room event
## must not advance the simulation; the measured delta is the evidence, not a
## literal.
func _measure_post_fence(host: Node, peer: RefCounted, fence_frame: int) -> Array:
	var started_us: int = Time.get_ticks_usec()
	while Time.get_ticks_usec() - started_us < 250000:
		host.clients[0].poll()
		if peer.status().current_frame != fence_frame:
			return [peer.status().current_frame, peer.status().current_frame - fence_frame]
		await host.get_tree().create_timer(0.002).timeout
	return [peer.status().current_frame, peer.status().current_frame - fence_frame]


func _live_roster(host: Node) -> PackedStringArray:
	var live: PackedStringArray = PackedStringArray()
	for player: RefCounted in host.clients[0].get_players():
		live.append(player.id)
	return live


## A real room departure ends the frozen membership. The departing page leaves
## the room and records the live event; the survivors observe the server event,
## latch the adapter fence and never submit another input.
func _run_room_departure(host: Node, count: int, slot: int, uuid: String, steps_taken: int) -> bool:
	var room_code: String = host.clients[0].get_room_code()
	var leave_code: int = host.clients[0].leave_room()
	if leave_code != 0:
		host.errors.append("peer_drop_room_leave_%d" % leave_code)
		return false
	var started_us: int = Time.get_ticks_usec()
	while Time.get_ticks_usec() - started_us < 30000000:
		host.clients[0].poll()
		if host.room_left_seen:
			break
		await host.get_tree().create_timer(0.002).timeout
	if not host.room_left_seen:
		host.errors.append("peer_drop_room_left_missing")
		return false
	var kind: String = "room_left"
	if JavaScriptBridge.eval("window.fortressDropRoomAfterDrop || false"):
		kind = "room_left_after_drop"
	elif JavaScriptBridge.eval("window.fortressDropRoomBeforeDrop || false"):
		kind = "room_left_before_drop"
	host.records.append({
		"players": count,
		"departed": true,
		"departure_sequence": 1,
		"departure_kind": kind,
		"slot": slot,
		"frames_submitted": steps_taken,
		"uuid": uuid,
		"roster": host.memberships[0].roster(),
		"room_code_before": room_code,
		"room_code_after": host.clients[0].get_room_code(),
		"room_left": true,
		"connected": host.clients[0].is_connected_to_server(),
		"authenticated": host.clients[0].is_authenticated(),
		"session_id": host.memberships[0].handshake_message().session_id.hex_encode(),
	})
	JavaScriptBridge.eval("document.body.dataset.fortressRoomLeft = 'true'")
	return true


func _run_pending_room_fence(host: Node, count: int, slot: int, departing_uuid: String, departing_slot: int,
		departing_identity: PackedByteArray, steps_taken: int) -> bool:
	var peer: RefCounted = host.peers[0]
	host.stage = "peer_drop_room_pending"
	var pending: bool = false
	var started_us: int = Time.get_ticks_usec()
	while Time.get_ticks_usec() - started_us < 20000000:
		if host.pending_seen:
			pending = true
			break
		if not host._service():
			return false
		if host.pending_seen:
			pending = true
			break
		await host.get_tree().create_timer(0.002).timeout
	var barrier: Drop.Barrier = peer._drops.barrier(departing_identity.hex_encode())
	if not pending or barrier == null or barrier.state != Drop.PENDING:
		host.errors.append("peer_drop_room_pending_missing")
		return false
	JavaScriptBridge.eval("document.body.dataset.fortressDropPending = 'true'")
	var fence_frame: int = peer.status().current_frame
	if not await _wait_membership_fence(host, departing_uuid):
		host.errors.append("peer_drop_room_pending_fence")
		return false
	var status: Dictionary = host.adapters[0].status()
	var frozen_roster: PackedStringArray = host.memberships[0].roster()
	var room_roster_after: PackedStringArray = _live_roster(host)
	var measured: Array = await _measure_post_fence(host, peer, fence_frame)
	var final_frame: int = measured[0]
	var frames_after_fence: int = measured[1]
	var drop_events: int = 0
	var pending_events: int = 0
	for event: Dictionary in events:
		if event.kind == "peer_dropped":
			drop_events += 1
		elif event.kind == "peer_drop_pending":
			pending_events += 1
	var comparisons: int = 0
	for frame: int in range(1, fence_frame):
		if host.games[0].history.get(frame) != expected(host, frame, count, {}):
			host.errors.append("peer_drop_room_pending_history_%d" % frame)
			return false
		comparisons += 1
	var row: Dictionary = {
		"players": count,
		"departed": false,
		"slot": slot,
		"uuid": host.clients[0].get_player_id(),
		"roster": frozen_roster,
		"frames_submitted": steps_taken,
		"fence_frame": fence_frame,
		"final_frame": final_frame,
		"frames_after_fence": frames_after_fence,
		"room_fenced": true,
		"fence_route": status.route,
		"fence_error": int(status.error),
		"fence_lifetime_revision": int(status.lifetime_revision),
		"player_left_events": host.room_player_left.duplicate(),
		"frozen_roster": frozen_roster,
		"room_roster_after": room_roster_after,
		"departed_slot": departing_slot,
		"departed_uuid": departing_uuid,
		"local_uuid": host.clients[0].get_player_id(),
		"session_id": host.memberships[0].handshake_message().session_id.hex_encode(),
		"drop_events": drop_events,
		"drop_pending_events": pending_events,
		"barrier_open": true,
		"barrier_state": barrier.state,
		"barrier_certified": barrier.certified,
		"barrier_value": barrier.value.hex_encode(),
		"freeze_frame": -1,
		"canonical_comparisons": comparisons,
		"canonical_unchanged": true,
		"direct": host._transport_totals(),
		"mixed": host.mixed.report() if host.mixed_enabled else {},
	}
	if fence_frame != 7 or status.route != "restart_required" or departing_slot < 0 \
		or departing_slot >= frozen_roster.size() or slot == departing_slot \
		or frozen_roster[departing_slot] != departing_uuid:
		host.errors.append("peer_drop_room_pending_fence")
		return false
	if room_roster_after.size() != count - 1 or room_roster_after.has(departing_uuid):
		host.errors.append("peer_drop_room_pending_identity")
		return false
	if drop_events != 0 or pending_events != 1 or barrier.certified or not barrier.value.is_empty():
		host.errors.append("peer_drop_room_pending_certified")
		return false
	JavaScriptBridge.eval("document.body.dataset.fortressRoomFenced = 'true'")
	JavaScriptBridge.eval("document.body.dataset.fortressFrame = '%d'" % final_frame)
	if frames_after_fence != 0:
		host.errors.append("peer_drop_room_continued")
		return false
	host.records.append(row)
	return true


func _wait_membership_fence(host: Node, departing_uuid: String) -> bool:
	var started_us: int = Time.get_ticks_usec()
	while Time.get_ticks_usec() - started_us < 10000000:
		host.clients[0].poll()
		if host.room_player_left.has(departing_uuid) and host.adapters[0].status().route == "restart_required":
			return true
		await host.get_tree().create_timer(0.002).timeout
	return false


func _run_room_fence(host: Node, count: int, slot: int, departing_uuid: String, departing_slot: int,
		departing_identity: PackedByteArray, continue_after_fence: bool, steps_taken: int) -> bool:
	var peer: RefCounted = host.peers[0]
	var fence_frame: int = peer.status().current_frame
	host.stage = "peer_drop_room_fence"
	var fenced: bool = await _wait_membership_fence(host, departing_uuid)
	print("ROOM_FENCE ", host.local_index, " departing=", departing_uuid, " events=", host.room_player_left, " route=", host.adapters[0].status().route)
	if not fenced:
		host.errors.append("peer_drop_room_fence")
		return false
	var status: Dictionary = host.adapters[0].status()
	var frozen_roster: PackedStringArray = host.memberships[0].roster()
	var room_roster_after: PackedStringArray = _live_roster(host)
	var drop_events: int = 0
	var pending_events: int = 0
	for event: Dictionary in events:
		if event.kind == "peer_dropped":
			drop_events += 1
		elif event.kind == "peer_drop_pending":
			pending_events += 1
	var barrier_open: bool = peer._drops.barrier(departing_identity.hex_encode()) != null
	var row: Dictionary = {
		"players": count,
		"departed": false,
		"slot": slot,
		"uuid": host.clients[0].get_player_id(),
		"roster": frozen_roster,
		"frames_submitted": steps_taken,
		"fence_frame": fence_frame,
		"final_frame": fence_frame,
		"frames_after_fence": 0,
		"room_fenced": true,
		"fence_route": status.route,
		"fence_error": int(status.error),
		"fence_lifetime_revision": int(status.lifetime_revision),
		"player_left_events": host.room_player_left.duplicate(),
		"departed_slot": departing_slot,
		"departed_uuid": departing_uuid,
		"frozen_roster": frozen_roster,
		"room_roster_after": room_roster_after,
		"local_uuid": host.clients[0].get_player_id(),
		"session_id": host.memberships[0].handshake_message().session_id.hex_encode(),
		"drop_events": drop_events,
		"drop_pending_events": pending_events,
		"barrier_open": barrier_open,
		"direct": host._transport_totals(),
		"mixed": host.mixed.report() if host.mixed_enabled else {},
	}
	if fence_frame != 7 or status.route != "restart_required" or departing_slot < 0 \
		or departing_slot >= frozen_roster.size() or slot == departing_slot \
		or frozen_roster[departing_slot] != departing_uuid:
		host.errors.append("peer_drop_room_fence")
		return false
	if room_roster_after.size() != count - 1 or room_roster_after.has(departing_uuid) \
		or host.clients[0].get_player_id() == departing_uuid:
		host.errors.append("peer_drop_room_identity")
		return false
	if drop_events != 0 or pending_events != 0 or barrier_open:
		host.errors.append("peer_drop_room_drop_publication")
		return false
	JavaScriptBridge.eval("document.body.dataset.fortressRoomFenced = 'true'")
	JavaScriptBridge.eval("document.body.dataset.fortressFrame = '%d'" % fence_frame)
	if continue_after_fence:
		host._update_transport_clock()
		var continued: Array[Driver.LocalInput] = [Driver.LocalInput.new(slot, fence_frame, PackedByteArray([host._sample(fence_frame, slot)]))]
		var code: int = peer.step(host.transport_us, continued).code
		if code != S.Code.OK:
			host.errors.append("peer_drop_room_continue_step_%d" % code)
			return false
		steps_taken += 1
		var after_frame: int = peer.status().current_frame
		row["frames_submitted"] = steps_taken
		row["final_frame"] = after_frame
		row["frames_after_fence"] = after_frame - fence_frame
		row["continue_code"] = code
		JavaScriptBridge.eval("document.body.dataset.fortressFrame = '%d'" % after_frame)
		host.records.append(row)
		host.stage = "peer_drop_room"
		host.errors.append("peer_drop_room_continued")
		return false
	var observed_started: int = Time.get_ticks_usec()
	while Time.get_ticks_usec() - observed_started < 250000:
		host.clients[0].poll()
		if peer.status().current_frame != fence_frame:
			row["final_frame"] = peer.status().current_frame
			row["frames_after_fence"] = peer.status().current_frame - fence_frame
			host.records.append(row)
			host.errors.append("peer_drop_room_continued")
			return false
		await host.get_tree().create_timer(0.002).timeout
	row["frames_submitted"] = steps_taken
	row["final_frame"] = peer.status().current_frame
	row["frames_after_fence"] = peer.status().current_frame - fence_frame
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
