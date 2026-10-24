extends RefCounted

const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const S = preload("res://addons/fortress_rollback/core/session_types.gd")
const Drop = preload("res://addons/fortress_rollback/core/peer_drop_barrier.gd")
var events: Array[Dictionary] = []


func observed(event: Dictionary) -> void:
	if event.kind in ["peer_drop_pending", "peer_dropped", "peer_drop_unconfirmed"]:
		events.append(event.duplicate(true))


func run(host: Node, count: int) -> bool:
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
	for frame: int in 7:
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
		host.stage = "peer_drop_physical_departure"
		if not await host._wait_passive(
			func() -> bool: return JavaScriptBridge.eval("window.fortressDropGo || false"), host.PHYSICAL_DEPARTURE_WAIT_US
		):
			host.errors.append("physical_departure_wait_timeout")
			return false
	elif not await host._wait(func() -> bool: return JavaScriptBridge.eval("window.fortressDropGo || false"), true):
		return false
	if host.local_index == 2:
		host.records.append(
			{"players": count, "departed": true, "slot": slot, "frames_submitted": 7, "uuid": host.clients[0].get_player_id(), "roster": host.memberships[0].roster()}
		)
		return true
	host._update_transport_clock()
	var predicted: Array[Driver.LocalInput] = [Driver.LocalInput.new(slot, 7, PackedByteArray([host._sample(7, slot)]))]
	if peer.step(host.transport_us, predicted).code != S.Code.OK:
		return false
	JavaScriptBridge.eval("document.body.dataset.fortressFrame = '7'")
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
	var barrier: Drop.Barrier = null
	for remote: PackedByteArray in peer.peer_ids():
		var candidate: Drop.Barrier = peer._drops.barrier(remote.hex_encode())
		if candidate != null:
			barrier = candidate
	if barrier == null or barrier.state != Drop.COMMITTED or barrier.value != PackedByteArray([host._sample(barrier.cut, departing_slot)]):
		host.errors.append("peer_drop_certificate")
		return false
	var cut: int = barrier.cut
	var prediction_gap: int = peer.status().current_frame - cut - 1
	if prediction_gap < 1:
		return false
	if JavaScriptBridge.eval("window.fortressDropCorrupt || false"):
		host.games[0].corrupt_continuation = true
	host.stage = "peer_drop_gameplay"
	var comparisons: int = 0
	for frame: int in range(8, 40):
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
			if host.games[0].history.get(frame - 2) != expected(host, frame - 2, count, departing_slot, cut):
				host.errors.append("peer_drop_canonical_%d" % (frame - 2))
				return false
			comparisons += 1
		if not host._service_batch():
			return false
		await host.get_tree().create_timer(0.002).timeout
	host.stage = "final_confirmation"
	if not await host._wait(func() -> bool: return peer.status().confirmed_frame >= 38, true):
		return false
	for frame: int in range(1, 39):
		if host.games[0].history.get(frame) != expected(host, frame, count, departing_slot, cut):
			host.errors.append("peer_drop_canonical_%d" % frame)
			return false
	var dropped: int = 0
	for event: Dictionary in events:
		if event.kind == "peer_dropped":
			dropped += 1
		if event.kind == "peer_drop_unconfirmed":
			host.errors.append("peer_drop_unconfirmed")
			return false
	if dropped != 1:
		host.errors.append("peer_drop_publication")
		return false
	var certificates: Array[Dictionary] = []
	for identity: String in barrier.certificates:
		var certificate: Dictionary = barrier.certificates[identity]
		certificates.append({"peer": identity, "cut": certificate.cut, "digest": "%016x" % int(certificate.digest)})
	host.records.append(
		{
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
			"freeze_frame": cut,
			"frozen_value": barrier.value.hex_encode(),
			"state": barrier.state,
			"role": barrier.role,
			"certified": barrier.certified,
			"certificates": barrier.certificates.size(),
			"drop_events": dropped,
			"minimum_confirmed": peer.status().confirmed_frame,
			"canonical_comparisons": 38,
			"active_comparisons": comparisons,
			"rollback_loads": host.games[0].loads,
			"direct": host._transport_totals(),
			"mixed": host.mixed.report() if host.mixed_enabled else {}
		}
	)
	return true


static func expected(host: Node, frame: int, count: int, departed: int, cut: int) -> PackedByteArray:
	var result: PackedByteArray = PackedByteArray()
	result.resize(4 + 4 * count)
	result.encode_u32(0, frame)
	for slot: int in count:
		var value: int = 0
		for previous: int in frame:
			var sample_frame: int = mini(previous, cut) if slot == departed else previous
			value = (value * 33 + host._sample(sample_frame, slot)) & 0xffffffff
		result.encode_u32(4 + 4 * slot, value)
	return result
