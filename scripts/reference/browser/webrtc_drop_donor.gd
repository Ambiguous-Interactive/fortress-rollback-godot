extends RefCounted

# Value: protects=room fence during receipt of real donor history; fails_when=physical departure installs a pending row or changes exposed history;
# why_new=ordinary loss keeps the selected donor in the room; seam=attributed WebRTC receive and SDK PlayerLeft
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
const Drop = preload("res://addons/fortress_rollback/core/peer_drop_barrier.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const S = preload("res://addons/fortress_rollback/core/session_types.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
# The controller has 30 seconds to witness the held packet before selecting its action.
const ACTION_WAIT_US: int = 35000000
const SDK_NOTICE_WAIT_US: int = 10000000


static func hold(host: Node, target: String, donor: String) -> Dictionary:
	host.stage = "peer_drop_donor_history_hold"
	var peer: Peer = host.peers[0]
	if not await host._wait(func() -> bool: return not host.transports[0].held_history().is_empty(), true):
		return {}
	var membership: RefCounted = host.memberships[0]
	var barrier: Drop.Barrier = peer._drops.barrier(membership.identity(target).hex_encode())
	var packet: PackedByteArray = host.transports[0].held_history()
	var limits: T.Limits = T.Limits.new()
	limits.player_count = host.player_count
	var decoded: T.Result = Codec.decode(packet, limits)
	var donor_slot: int = membership.slot(donor)
	var target_slot: int = membership.slot(target)
	if decoded.code != T.Code.OK or barrier == null or not _pending_missing(peer, barrier, target_slot, donor_slot):
		host.errors.append("peer_drop_donor_history_not_pending")
		return {}
	var message: T.Message = decoded.message
	if message.sender_id != membership.identity(donor) or message.session_id != membership.handshake_message().session_id \
		or message.operation != barrier.operation or message.coordinator != barrier.coordinator or message.available_through != donor_slot \
		or message.bound != barrier.history.first or message.cut != barrier.history.cut or message.chunk_index != 0 or message.chunk_count != 1:
		host.errors.append("peer_drop_donor_history_identity")
		return {}
	var state: Dictionary = _snapshot(host)
	if state.is_empty():
		host.errors.append("peer_drop_donor_history_prefix")
		return {}
	var row: Dictionary = {
		"recipient": host.local_uuid, "donor": donor, "target": target,
		"roster": membership.roster(), "session_id": message.session_id.hex_encode(),
		"operation": barrier.operation, "target_set_digest": "%016x" % barrier.target_set_digest,
		"target_generation": barrier.generations[0], "packet": packet.hex_encode(),
		"revision": host.adapters[0].status().lifetime_revision, "state": state,
	}
	JavaScriptBridge.eval("document.body.dataset.fortressDonorHistoryHeld = " + JSON.stringify(JSON.stringify(row)))
	return row


static func release(host: Node, target: String) -> bool:
	host.stage = "peer_drop_donor_history_release"
	if not await host._wait_passive(func() -> bool: return bool(JavaScriptBridge.eval("window.fortressReleaseDonorHistory || false")), 4000000):
		host.errors.append("peer_drop_donor_history_release_missing")
		return false
	host._update_transport_clock()
	var code: int = host.transports[0].release_history(host.transport_us)
	var peer: Peer = host.peers[0]
	var membership: RefCounted = host.memberships[0]
	var barrier: Drop.Barrier = peer._drops.barrier(membership.identity(target).hex_encode())
	# The held packet alone must install the rows before another transport poll.
	if code != I.Code.OK or not barrier.history.installed or peer._core.received_frames()[membership.slot(target)] != 6:
		host.errors.append("peer_drop_donor_history_release_%d" % code)
		return false
	return true


static func wait_fence(host: Node, donor: String) -> Dictionary:
	if not await _wait_action(host, donor):
		return {}
	host.stage = "peer_drop_donor_membership_fence"
	var started: int = Time.get_ticks_usec()
	while Time.get_ticks_usec() - started < SDK_NOTICE_WAIT_US:
		host.clients[0].poll()
		var status: Dictionary = host.adapters[0].status()
		if host.room_player_left.has(donor) and status.route == "restart_required":
			var roster: PackedStringArray = PackedStringArray()
			for player: RefCounted in host.clients[0].get_players():
				roster.append(player.id)
			return {
				"action_ready": donor, "events": host.room_player_left.duplicate(), "live_roster": roster,
				"revision": status.lifetime_revision, "route": status.route, "error": status.error,
				"connected": host.clients[0].is_connected_to_server(), "authenticated": host.clients[0].is_authenticated(),
				"mesh_detached": host.meshes[0].get_multiplayer_peer() == null,
			}
		await host._wait_turn()
	host.errors.append("peer_drop_donor_membership_fence_missing")
	return {}


static func _wait_action(host: Node, donor: String) -> bool:
	host.stage = "peer_drop_donor_action"
	var started: int = Time.get_ticks_usec()
	while Time.get_ticks_usec() - started < ACTION_WAIT_US:
		if JavaScriptBridge.eval("window.fortressDonorActionReady") == donor:
			return true
		host.clients[0].poll()
		if not host.errors.is_empty() or not host.room_player_left.is_empty() or host.adapters[0].status().route != "mesh":
			host.errors.append("peer_drop_donor_membership_changed_before_action")
			return false
		await host._wait_turn()
	host.errors.append("peer_drop_donor_action_missing")
	return false


static func finish_fence(host: Node, target: String, donor: String, held: Dictionary, events: Array[Dictionary]) -> bool:
	var fence: Dictionary = await wait_fence(host, donor)
	if fence.is_empty():
		return false
	var peer: Peer = host.peers[0]
	var membership: RefCounted = host.memberships[0]
	var barrier: Drop.Barrier = peer._drops.barrier(membership.identity(target).hex_encode())
	var before_refusal: Dictionary = _snapshot(host)
	host._update_transport_clock()
	var code: int = host.transports[0].release_history(host.transport_us)
	var after_refusal: Dictionary = _snapshot(host)
	var event_names: Array[String] = []
	for event: Dictionary in events:
		event_names.append(event.kind)
	if code != I.Code.WRONG_STATE or before_refusal != held.state or after_refusal != held.state \
		or not _pending_missing(peer, barrier, membership.slot(target), membership.slot(donor)) or event_names != ["peer_drop_pending"]:
		host.errors.append("peer_drop_donor_history_fence_changed_state")
		return false
	var status: S.Status = peer.status()
	host.records.append({
		"uuid": host.local_uuid, "fence": fence, "held": held, "refusal": code, "after": after_refusal,
		"rollback": {"lifecycle": S.Lifecycle.find_key(status.lifecycle).to_lower(), "barrier": barrier.state, "events": event_names,
			"installed": barrier.history.installed, "certified": barrier.certified, "target_freeze": peer._core.frozen_frame(membership.slot(target)),
			"donor_freeze": peer._core.frozen_frame(membership.slot(donor))},
	})
	return true


static func _pending_missing(peer: Peer, barrier: Drop.Barrier, target: int, donor: int) -> bool:
	return barrier != null and barrier.state == Drop.PENDING and barrier.role == Drop.Role.PROPOSER and not barrier.certified \
		and not barrier.history.installed and barrier.history.donor == donor and barrier.history.first == 4 and barrier.history.cut == 6 \
		and peer._core.received_frames()[target] == 3 and peer._core.frozen_frame(target) == -1 and peer._core.frozen_frame(donor) == -1


static func _snapshot(host: Node) -> Dictionary:
	var peer: Peer = host.peers[0]
	var status: S.Status = peer.status()
	var replay: RefCounted = peer.replay()
	if replay == null or replay.frame_count() < 1:
		return {}
	var rows: Array[Array] = []
	var canonical: Array[String] = []
	for frame: int in replay.frame_count():
		var row: S.FrameInputs = replay.inputs(frame)
		if row == null:
			return {}
		var samples: Array[Array] = []
		for slot: int in host.player_count:
			var sample: S.InputResult = row.read(slot)
			samples.append([sample.bytes.hex_encode(), sample.status])
		rows.append(samples)
		var saved: PackedByteArray = host.games[0].history.get(frame + 1, PackedByteArray())
		canonical.append(saved.hex_encode())
	var replay_hash: HashingContext = HashingContext.new()
	replay_hash.start(HashingContext.HASH_SHA256)
	replay_hash.update(replay.to_bytes())
	return {
		"frame": status.current_frame, "confirmed": status.confirmed_frame, "state": host.games[0].bytes().hex_encode(),
		"replay_sha256": replay_hash.finish().hex_encode(), "replay": rows, "canonical": canonical,
	}
