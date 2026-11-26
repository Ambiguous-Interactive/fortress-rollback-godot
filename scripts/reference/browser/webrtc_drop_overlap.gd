extends "res://addons/fortress_rollback/transport/signalfish_webrtc.gd"

# gdlint: disable=constant-name,max-returns
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Drop = preload("res://addons/fortress_rollback/core/peer_drop_barrier.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const SECOND_GOODBYE: int = 42
const ACTIVE_WAIT_US: int = 18000000

var _session: Peer
var _factory: Callable
var _clock: int = 0
var _first: String
var _coordinator: String
var _pending_survivor: String
var _second: String
var _cutoff: bool = false
var _withheld: int = 0
var _goodbyes_sent: Dictionary = {}
var _trace: Array[Dictionary] = []
var _observed: Dictionary = {}


func configure(mesh: Object, membership: Membership, adapter: Adapter, peer: Peer, options: Types.Options = null) -> int:
	_session = peer
	return configure_packet_receiver(mesh, membership, adapter, _receive_boundary, options)


func poll(now_us: int, next_token_factory: Callable = Callable()) -> Types.Result:
	_clock = now_us
	_factory = next_token_factory
	if _first.is_empty():
		return super.poll(now_us, next_token_factory)
	_observe_agreement()
	var passing: Array[Peer.Packet] = []
	var controls: Array[Dictionary] = []
	for packet: Peer.Packet in _pending:
		var control: String = _control(packet.bytes)
		if _cutoff and control != "goodbye":
			_pending_bytes -= packet.bytes.size()
			continue
		if not control.is_empty():
			var recipient: String = _membership.uuid_for_peer_id(packet.to.decode_u32(0))
			if control == "commit" and _membership.local_uuid() == _coordinator and recipient == _pending_survivor:
				_pending_bytes -= packet.bytes.size()
				_withheld += 1
				_note("commit_withheld", recipient, packet.bytes)
				continue
			controls.append({"index": passing.size(), "kind": control, "peer": recipient, "bytes": packet.bytes})
		passing.append(packet)
	_pending = passing
	var result: Types.Result = super.poll(now_us, next_token_factory)
	for entry: Dictionary in controls:
		if int(entry.index) >= result.sent:
			break
		if entry.kind == "goodbye":
			_goodbyes_sent[entry.peer] = int(_goodbyes_sent.get(entry.peer, 0)) + 1
		_note(entry.kind + "_sent", entry.peer, entry.bytes)
	return result


func _receive_boundary(sender: String, bytes: PackedByteArray) -> int:
	if _cutoff or _session.status().lifecycle == S.Lifecycle.TERMINATED:
		return I.Code.OK
	var control: String = "" if _first.is_empty() else _control(bytes)
	if control == "commit" and sender == _coordinator and _membership.local_uuid() == _second:
		var sent: int = int(JavaScriptBridge.eval("window.fortressRtc.sent"))
		_note("commit_at_cutoff", sender, bytes, {"sent": sent})
		_cutoff = true
		_pending.clear()
		_pending_bytes = 0
		return I.Code.OK
	var token: Variant = _factory.call(sender) if _factory.is_valid() else null
	var result: int = _adapter.receive_mesh(_session, bytes, Membership.uuid_to_peer_id(sender), _clock, token)
	if not control.is_empty() and result == I.Code.OK:
		_note(control + "_received", sender, bytes)
	if not _first.is_empty():
		_observe_agreement()
	return result


func _control(bytes: PackedByteArray) -> String:
	if bytes.size() < 7 or bytes[6] not in [T.Kind.DROP_BARRIER, T.Kind.GOODBYE]:
		return ""
	var limits: T.Limits = T.Limits.new()
	limits.player_count = 4
	var decoded: T.Result = Codec.decode(bytes, limits)
	if decoded.code != T.Code.OK:
		return ""
	var message: T.Message = decoded.message
	if message.kind == T.Kind.GOODBYE:
		return "goodbye" if message.reason == SECOND_GOODBYE else ""
	if message.phase == Drop.Phase.COMMIT:
		return "commit"
	if message.phase == Drop.Phase.ABORT:
		return "abort"
	if message.phase == Drop.Phase.REPORT:
		if message.stage == Drop.Stage.READY:
			return "ready"
		if message.stage == Drop.Stage.COMMITTED:
			return "ack"
	return ""


func _note(kind: String, uuid: String, bytes: PackedByteArray = PackedByteArray(), detail: Dictionary = {}) -> void:
	var key: String = kind + ":" + uuid
	if _observed.has(key):
		return
	_observed[key] = true
	_trace.append({"kind": kind, "peer": uuid, "us": _clock, "bytes": bytes.hex_encode(), "detail": detail})


func _observe_agreement() -> void:
	var target: String = _membership.identity(_first).hex_encode()
	var barrier: Drop.Barrier = _session._drops.barrier(target)
	if barrier == null:
		return
	if barrier.certified or barrier.certificates.size() == 2:
		_note("certified", _first, PackedByteArray(), {"cut": barrier.cut, "digest": "%016x" % barrier.digest,
			"certificates": barrier.certificates.keys()})
	if _session._drops.is_dropped(target):
		_note("frozen", _first, PackedByteArray(), {"cut": _session._core.frozen_frame(_membership.slot(_first)), "value": barrier.value.hex_encode()})


func run_overlap(host: Node, first: String) -> bool:
	host.stage = "peer_drop_overlap_confirmation"
	if not await host._wait(func() -> bool: return _recover_prefix(host), true):
		return false
	JavaScriptBridge.eval("document.body.dataset.fortressDropReady = 'true'")
	if not await host._wait(func() -> bool: return JavaScriptBridge.eval("window.fortressDropGo || false"), true):
		return false
	_first = first
	var roster: PackedStringArray = _membership.roster()
	var survivors: PackedStringArray = roster.duplicate()
	survivors.remove_at(survivors.find(first))
	_coordinator = survivors[0]
	_pending_survivor = survivors[1]
	_second = survivors[2]
	var local: String = _membership.local_uuid()
	var slot: int = _membership.slot(local)
	var prefix: int = _session.status().confirmed_frame
	var original: Array[String] = _history(host, prefix)
	host.stage = "peer_drop_overlap"
	host._update_transport_clock()
	_clock = host.transport_us
	var complete: bool = true
	if local == first:
		_note("silent", local)
	else:
		var sample: Driver.LocalInput = Driver.LocalInput.new(slot, 7, PackedByteArray([host._sample(7, slot)]))
		var samples: Array[Driver.LocalInput] = [sample]
		if _session.step(_clock, samples).code != S.Code.OK:
			return false
		JavaScriptBridge.eval("document.body.dataset.fortressFrame = '7'")
		complete = await _wait_for_overlap(host, local)
	var target: String = _membership.identity(first).hex_encode()
	var barrier: Drop.Barrier = _session._drops.barrier(target)
	host.records.append({
		"uuid": local, "slot": slot, "roster": roster, "room": host.clients[0].get_room_id(),
		"session_id": _membership.handshake_message().session_id.hex_encode(), "connection": _session._local_connection.hex_encode(),
		"confirmed_prefix": prefix,
		"original": original, "final": _history(host, prefix), "trace": _trace, "withheld": _withheld,
		"frame": _session.status().current_frame, "reason": S.reason_text(_session.status().reason),
		"freeze_frame": _session._core.frozen_frame(_membership.slot(first)), "state": barrier.state if barrier != null else "",
		"frozen_value": barrier.value.hex_encode() if _session._drops.is_dropped(target) else "",
		"acknowledged": barrier.acknowledged.keys() if barrier != null else [],
		"sent_at_end": int(JavaScriptBridge.eval("window.fortressRtc.sent")), "goodbyes_sent": _goodbyes_sent,
	})
	return complete


func _recover_prefix(host: Node) -> bool:
	host._update_transport_clock()
	var result: Driver.StepResult = _session.recover(host.transport_us)
	if result.code != S.Code.OK or result.frame_before != result.frame_after:
		host.errors.append("overlap_prefix_recovery_%d" % result.code)
		return false
	return _session.status().confirmed_frame == 6


func _wait_for_overlap(host: Node, local: String) -> bool:
	var until: int = host._ticks_usec() + ACTIVE_WAIT_US
	while host._ticks_usec() < until:
		if not host._healthy():
			return false
		host.clients[0].poll()
		host.meshes[0].poll()
		host._update_transport_clock()
		_clock = host.transport_us
		var code: int = _session.poll(_clock, host._poll_tokens(_session))
		if code != I.Code.OK:
			host.errors.append("overlap_peer_poll_%d" % code)
			return false
		if not _flush(host):
			return false
		if _cutoff:
			if _session.close(_clock, SECOND_GOODBYE) != I.Code.OK or not _flush(host):
				host.errors.append("overlap_close")
				return false
			_note("silent", local)
			return true
		if _session.status().lifecycle == S.Lifecycle.TERMINATED:
			if not _flush(host):
				return false
			_note("terminated", local)
			return true
		await host._wait_turn()
	host.errors.append("overlap_deadline")
	return false


func _flush(host: Node) -> bool:
	_observe_events()
	var accepted: int = enqueue_batch(_session.drain_outbox())
	if accepted != Code.OK:
		host.errors.append("overlap_direct_enqueue_%d" % accepted)
		return false
	var result: Types.Result = poll(_clock, host._next_token)
	if result.code != Code.OK:
		host.errors.append("overlap_direct_poll_%d_peer_%d" % [result.code, result.peer_code])
		return false
	_observe_events()
	return true


func _observe_events() -> void:
	for event: Dictionary in _session.drain_events():
		if event.kind in ["disconnected", "peer_drop_pending", "peer_drop_unconfirmed", "peer_dropped"]:
			var uuid: String = _uuid_for_identity(event.peer)
			_note(event.kind, uuid, PackedByteArray(), {"reason": event.get("reason"), "frame": event.get("frame")})
	_session.drain_transitions()


func _uuid_for_identity(identity: PackedByteArray) -> String:
	for uuid: String in _membership.roster():
		if _membership.identity(uuid) == identity:
			return uuid
	return ""


func _history(host: Node, confirmed: int) -> Array[String]:
	var rows: Array[String] = []
	for frame: int in range(1, confirmed + 2):
		var state: PackedByteArray = host.games[0].history.get(frame, PackedByteArray())
		rows.append(state.hex_encode())
	return rows
