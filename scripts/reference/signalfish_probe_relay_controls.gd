extends RefCounted

# gdlint: disable=max-returns

const Relay = preload("res://addons/fortress_rollback/transport/signalfish_relay.gd")
const Envelope = preload("res://addons/fortress_rollback/transport/signalfish_relay_envelope.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Msgpack = preload("res://addons/signal_fish/protocol/sf_msgpack.gd")


func check(fixture: RefCounted) -> bool:
	var mode: Object = fixture.modes[0]
	mode.decode_msgpack_payloads = true
	var refusal: Relay = Relay.new()
	var options: Relay.Options = Relay.Options.new()
	options.max_packet_bytes = 1024
	var code: int = refusal.configure(fixture.clients[0], mode, fixture.infos[0], fixture.memberships[0], fixture.adapters[0], fixture.peers[0], options)
	mode.decode_msgpack_payloads = false
	if code != Relay.Code.INCOMPATIBLE_MODE:
		refusal.detach()
		return false
	var batch: Array[Peer.Packet] = fixture.peers[0].drain_outbox()
	if batch.is_empty() or fixture.relays[0].enqueue_batch(batch) != Relay.Code.OK:
		return false
	var before: Dictionary = fixture.relays[0].status()
	fixture.wires[0].buffered = 262144
	var blocked: Relay.Result = fixture.relays[0].poll(0)
	if blocked.code != Relay.Code.BACKPRESSURE or blocked.sent != 0 or fixture.relays[0].status().pending_packets != before.pending_packets:
		return false
	fixture.wires[0].buffered = 0
	fixture.wires[0].refuse_once = true
	var sdk_busy: Relay.Result = fixture.relays[0].poll(0)
	if sdk_busy.code != Relay.Code.BACKPRESSURE or sdk_busy.sent != 0 or fixture.relays[0].status().pending_packets != before.pending_packets:
		return false
	var retry: Relay.Result = fixture.relays[0].poll(0)
	if retry.code != Relay.Code.OK or retry.sent != 1 or fixture.wires[0].sent.size() != 1:
		return false
	if fixture.wires[0].attempts.size() != 2 or fixture.wires[0].attempts[0] != fixture.wires[0].attempts[1]:
		return false
	var sent: PackedByteArray = fixture.wires[0].sent[0]
	if sent.slice(57) != batch[0].bytes or sent.slice(5, 21) != fixture.session or sent.decode_u32(53) != batch[0].bytes.size():
		return false
	if fixture.relays[0].status().pending_packets != before.pending_packets - 1:
		return false
	var local: String = fixture.uuids[0]
	var remote: String = fixture.uuids[1]
	var unknown: String = "00000000-0000-0000-0000-000000000009"
	var session: PackedByteArray = fixture.session.duplicate()
	for defect: String in ["recipient", "source", "claim", "session", "encoding"]:
		var changed: PackedByteArray = session.duplicate()
		if defect == "session":
			changed[0] ^= 255
		var envelope: PackedByteArray = Envelope.encode(changed, local if defect == "claim" else remote, remote if defect == "recipient" else local, PackedByteArray([7]))
		var sender: String = unknown if defect == "source" else remote
		var encoded: Dictionary = Msgpack.encode({"from_player": sender.replace("-", "").hex_decode(), "encoding": "rkyv" if defect == "encoding" else "message_pack",
			"payload": envelope, "seq": 1, "epoch": 7})
		fixture.wires[0].packet_received.emit(encoded.bytes, false)
		var status: Dictionary = fixture.relays[0].status()
		var expected: int = Relay.Code.NOT_RECIPIENT
		if defect in ["source", "claim"]:
			expected = Relay.Code.WRONG_SOURCE
		elif defect == "session":
			expected = Relay.Code.WRONG_SESSION
		elif defect == "encoding":
			expected = Relay.Code.INCOMPATIBLE_MODE
		if status.last_receive_code != expected or status.received_packets != 0 or status.code != Relay.Code.OK:
			return false
	return true
