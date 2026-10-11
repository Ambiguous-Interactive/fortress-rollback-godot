extends RefCounted

# gdlint: disable=max-returns

# Actual SDK wire injection verifies relay framing, bounded retries and confirmed gameplay bytes.
const SDK = preload("res://addons/signal_fish/signal_fish_client.gd")
const SDKConfig = preload("res://addons/signal_fish/signal_fish_config.gd")
const SDKTransport = preload("res://addons/signal_fish/transport/sf_transport.gd")
const SDKMesh = preload("res://addons/signal_fish/webrtc/sf_webrtc_mesh.gd")
const Msgpack = preload("res://addons/signal_fish/protocol/sf_msgpack.gd")
const Membership = preload("res://addons/fortress_rollback/transport/signalfish_membership.gd")
const Adapter = preload("res://addons/fortress_rollback/transport/signalfish_adapter.gd")
const Relay = preload("res://addons/fortress_rollback/transport/signalfish_relay.gd")
const Controls = preload("res://signalfish_probe_relay_controls.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const H = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const S = preload("res://addons/fortress_rollback/core/session_types.gd")
var clients: Array[SDK] = []
var wires: Array[Wire] = []
var meshes: Array[SDKMesh] = []
var memberships: Array[Membership] = []
var adapters: Array[Adapter] = []
var relays: Array[Relay] = []
var peers: Array[Peer] = []
var games: Array[Game] = []
var modes: Array[SDKConfig] = []
var infos: Array[RefCounted] = []
var uuids: PackedStringArray = PackedStringArray()
var session: PackedByteArray = PackedByteArray()
var comparisons: int = 0
var broadcasts: int = 0
var records: Array[Dictionary] = []


class Game:
	extends RefCounted
	var frame: int = 0
	var values: PackedInt64Array = PackedInt64Array()
	var history: Dictionary = {}
	func _init(count: int) -> void:
		values.resize(count)
	func bytes() -> PackedByteArray:
		var result: PackedByteArray = PackedByteArray()
		result.resize(4 + 4 * values.size())
		result.encode_u32(0, frame)
		for slot: int in values.size():
			result.encode_u32(4 + slot * 4, values[slot])
		return result
	func save_state(_frame: int, writer: RefCounted) -> Driver.SaveResult:
		var state: PackedByteArray = bytes()
		var hash: HashingContext = HashingContext.new()
		hash.start(HashingContext.HASH_SHA256)
		hash.update(state)
		return Driver.SaveResult.new(writer.write_bytes(state) == 0, hash.finish().slice(0, 16))
	func load_state(_frame: int, reader: RefCounted) -> bool:
		var result: RefCounted = reader.read_bytes(bytes().size())
		if result.code != 0 or not reader.is_complete():
			return false
		frame = result.bytes.decode_u32(0)
		for slot: int in values.size():
			values[slot] = result.bytes.decode_u32(4 + slot * 4)
		return true
	func simulate_frame(_frame: int, inputs: RefCounted) -> bool:
		for slot: int in values.size():
			var input: RefCounted = inputs.read(slot)
			if input.bytes.size() != 1:
				return false
			values[slot] += input.bytes[0]
		frame += 1
		history[frame] = bytes()
		return true


class Wire:
	extends SDKTransport
	var sent: Array[PackedByteArray] = []
	var buffered: int = 0
	var seq: int = 0
	var refuse_once: bool = false
	var delay_close: bool = false
	var attempts: Array[PackedByteArray] = []
	func connect_to_url(_url: String) -> Error:
		opened.emit()
		return OK
	func send_text(_text: String) -> Error:
		return OK
	func send_binary(bytes: PackedByteArray) -> Error:
		attempts.append(bytes.duplicate())
		if refuse_once:
			refuse_once = false
			return ERR_BUSY
		sent.append(bytes.duplicate())
		return OK
	func get_buffered_amount() -> int:
		return buffered
	func get_ready_state() -> int:
		return WebSocketPeer.STATE_OPEN
	func close(code: int = 1000, reason: String = "") -> void:
		if not delay_close:
			closed.emit(code, reason)
	func event(kind: String, data: Dictionary) -> void:
		packet_received.emit(JSON.stringify({"type": kind, "data": data}).to_utf8_buffer(), true)


func check() -> bool:
	for count: int in [2, 4, 8]:
		var before: int = comparisons
		var ok: bool = _setup(count) and _play(count)
		records.append({"players": count, "canonical_comparisons": comparisons - before, "frames_submitted": 40})
		_cleanup()
		if not ok:
			printerr("relay SDK witness failed at %d players" % count)
			return false
	print("FORTRESS_SIGNALFISH_RELAY_RESULT ", JSON.stringify({"records": records, "broadcast_deliveries": broadcasts}))
	return comparisons == 14 * 38 and broadcasts > 0


func _setup(count: int) -> bool:
	uuids.clear()
	session.resize(16)
	session.fill(41)
	for slot: int in count:
		uuids.append("00000000-0000-0000-0000-%012x" % (slot + 1))
	var roster: Array[Dictionary] = []
	for uuid: String in uuids:
		roster.append({"id": uuid, "name": "relay", "is_authority": false, "is_ready": true, "epoch": 7})
	for slot: int in count:
		var client: SDK = SDK.new()
		var wire: Wire = Wire.new()
		client.transport = wire
		clients.append(client)
		wires.append(wire)
		client.protocol_info.connect(func(info: RefCounted) -> void: infos.append(info))
		var mode: SDKConfig = SDKConfig.new()
		mode.app_id = "fortress-relay-probe"
		mode.endpoint_url = "ws://localhost:1"
		mode.protocol_version = 3
		mode.game_data_format = "message_pack"
		mode.auto_poll = false
		modes.append(mode)
		if client.configure(mode) != OK or client.connect_to_server() != OK:
			return false
		wire.event("Authenticated", {"app_name": "relay", "rate_limits": {"per_minute": 1, "per_hour": 1, "per_day": 1}})
		wire.event("ProtocolInfo", {"protocol_version": 3, "game_data_formats": ["message_pack"], "max_outbound_message_size": 131072})
		wire.event("RoomJoined", {"room_id": uuids[0], "room_code": "RELAY", "player_id": uuids[slot], "game_name": "relay", "max_players": count,
			"supports_authority": false, "current_players": roster, "is_authority": false, "lobby_state": "finalized", "ready_players": [], "relay_type": "WebSocket"})
		var membership: Membership = Membership.new()
		var profile: T.Config = T.Config.new()
		profile.player_count = count
		var incarnation: PackedByteArray = PackedByteArray([slot + 1, 0, 0, 0, 0, 0, 0, 0])
		if membership.configure(client.get_player_id(), uuids, session, incarnation, profile) != OK:
			return false
		memberships.append(membership)
		var mesh: SDKMesh = SDKMesh.new()
		meshes.append(mesh)
		var adapter: Adapter = Adapter.new()
		adapters.append(adapter)
		if adapter.attach(client, mesh, membership) != OK:
			return false
		wire.event("SessionPlan", {"generation": uuids[0], "topology": "relay", "transport": "relay", "fallback": "relay", "peers": []})
		var config: Config = Config.new()
		config.player_count = count
		config.sync_test = false
		config.check_distance = 0
		config.max_snapshot_bytes = 4 + 4 * count
		config.storage_budget_bytes = 1048576
		var handshake: H.Options = H.Options.new()
		handshake.roundtrips = 1
		var game: Game = Game.new(count)
		games.append(game)
		var peer: Peer = Peer.new()
		peers.append(peer)
		if membership.configure_peer(peer, config, game, handshake, I.Options.new()) != I.Code.OK:
			return false
		var tokens: Array[PackedByteArray] = []
		for remote: int in count - 1:
			tokens.append(session.duplicate())
		if peer.begin(0, tokens) != I.Code.OK:
			return false
		var relay: Relay = Relay.new()
		relays.append(relay)
		var options: Relay.Options = Relay.Options.new()
		options.max_packet_bytes = 1024
		options.max_sends_per_poll = 1
		if relay.configure(client, mode, infos[slot], membership, adapter, peer, options) != 0:
			return false
	return true


func _play(count: int) -> bool:
	if not Controls.new().check(self):
		return false
	for tick: int in 32:
		if not _service(tick):
			return false
	for frame: int in 40:
		var now: int = (frame + 1) * 16667
		for slot: int in count:
			var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(slot, frame, PackedByteArray([_input(frame, slot)]))]
			if peers[slot].step(now, samples).code != S.Code.OK:
				return false
		for roundtrip: int in 8:
			if not _service(now):
				return false
	for slot: int in count:
		if peers[slot].status().confirmed_frame < 38:
			return false
		for frame: int in range(1, 39):
			var expected: PackedByteArray = PackedByteArray()
			expected.resize(4 + 4 * count)
			expected.encode_u32(0, frame)
			for player: int in count:
				var value: int = 0
				for previous: int in frame:
					value += _input(previous, player)
				expected.encode_u32(4 + 4 * player, value)
			if games[slot].history.get(frame) != expected:
				return false
			comparisons += 1
	return true


func _service(now: int) -> bool:
	for sender: int in clients.size():
		var batch: Array[Peer.Packet] = peers[sender].drain_outbox()
		if not batch.is_empty() and relays[sender].enqueue_batch(batch) != 0:
			return false
		if relays[sender].poll(now).code != 0:
			return false
		for bytes: PackedByteArray in wires[sender].sent:
			wires[sender].seq += 1
			var encoded: Dictionary = Msgpack.encode({"from_player": uuids[sender].replace("-", "").hex_decode(), "encoding": "message_pack", "payload": bytes,
				"seq": wires[sender].seq, "epoch": 7})
			for recipient: int in clients.size():
				if recipient != sender:
					wires[recipient].packet_received.emit(encoded.bytes, false)
					broadcasts += 1
		wires[sender].sent.clear()
	for relay: Relay in relays:
		if relay.poll(now).code != 0:
			return false
	return true


static func _input(frame: int, slot: int) -> int:
	return (frame * 17 + slot * 31 + 1) & 255


func _cleanup() -> void:
	for relay: Relay in relays:
		relay.detach()
	for adapter: Adapter in adapters:
		adapter.detach()
	for mesh: SDKMesh in meshes:
		mesh.free()
	for client: SDK in clients:
		client.close()
		client.free()
	clients.clear()
	wires.clear()
	meshes.clear()
	memberships.clear()
	adapters.clear()
	relays.clear()
	peers.clear()
	games.clear()
	modes.clear()
	infos.clear()
