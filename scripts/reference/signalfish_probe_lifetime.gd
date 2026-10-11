extends RefCounted

# Actual SDK transitions must fence bytes accepted before the event, with no outbound batch to reveal a send failure.
const Fixture = preload("res://signalfish_probe_relay.gd")
const Envelope = preload("res://addons/fortress_rollback/transport/signalfish_relay_envelope.gd")
const Relay = preload("res://addons/fortress_rollback/transport/signalfish_relay.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Msgpack = preload("res://addons/signal_fish/protocol/sf_msgpack.gd")
var count: int = 0


func check() -> bool:
	for kind: String in ["authentication", "connection", "reconnection", "remote_reconnection", "spectator", "close", "operation"]:
		var fixture: Fixture = Fixture.new()
		if not fixture._setup(2):
			fixture._cleanup()
			return false
		var packet: Peer.Packet = fixture.peers[1].drain_outbox()[0]
		var framed: PackedByteArray = Envelope.encode(fixture.session, fixture.uuids[1], fixture.uuids[0], packet.bytes)
		var wire: Dictionary = Msgpack.encode({"from_player": fixture.uuids[1].replace("-", "").hex_decode(), "encoding": "message_pack",
			"payload": framed, "seq": 1, "epoch": 7})
		fixture.wires[0].packet_received.emit(wire.bytes, false)
		var ok: bool = fixture.relays[0].status().received_packets == 1
		match kind:
			"authentication":
				fixture.wires[0].event("AuthenticationError", {"error": "room authentication failed", "error_code": "UNAUTHORIZED"})
				ok = ok and not fixture.clients[0].is_authenticated() and fixture.clients[0].get_room_id().is_empty()
			"connection":
				fixture.wires[0].failed.emit("connection lost")
				ok = ok and not fixture.clients[0].is_connected_to_server()
			"reconnection":
				fixture.wires[0].event("ReconnectionFailed", {"reason": "expired", "error_code": "RECONNECTION_EXPIRED"})
				ok = ok and not fixture.clients[0].is_connected_to_server()
			"remote_reconnection":
				fixture.wires[0].event("PlayerReconnected", {"player_id": fixture.uuids[1], "epoch": 8})
			"spectator":
				fixture.wires[0].event("SpectatorJoined", {"room_id": fixture.uuids[1], "room_code": "VIEW", "spectator_id": fixture.uuids[0],
					"game_name": "relay", "current_players": [], "current_spectators": [], "lobby_state": "finalized"})
				ok = ok and fixture.clients[0].get_room_id() == fixture.uuids[1]
			"close":
				fixture.wires[0].delay_close = true
				fixture.clients[0].close()
				ok = ok and not fixture.clients[0].is_connected_to_server()
			"operation":
				fixture.wires[0].event("RoomJoinFailed", {"reason": "invalid room", "error_code": "INVALID_ROOM_CODE"})
		var result: Relay.Result = fixture.relays[0].poll(0)
		if kind == "operation":
			ok = ok and fixture.adapters[0].status().route == "relay" and result.code == Relay.Code.OK and result.received == 1 and result.peer_code == 0
		else:
			ok = ok and fixture.adapters[0].status().route == "restart_required" and result.code == Relay.Code.WRONG_STATE and result.received == 0
			fixture.wires[0].packet_received.emit(wire.bytes, false)
			ok = ok and fixture.relays[0].status().received_packets == 1
			ok = ok and fixture.relays[0].enqueue_batch([packet]) == Relay.Code.WRONG_STATE
		fixture._cleanup()
		if not ok:
			printerr("SDK lifetime fence failed: %s" % kind)
			return false
		count += 1
	return count == 7
