extends SceneTree

# gdlint: disable=max-returns

# Value: protects=actual SDK integration; fails_when=SDK public state or signal contract drifts; why_new=core suites run without SDK; seam=SDK public transport injection
const SDK = preload("res://addons/signal_fish/signal_fish_client.gd")
const SDKConfig = preload("res://addons/signal_fish/signal_fish_config.gd")
const SDKTransport = preload("res://addons/signal_fish/transport/sf_transport.gd")
const Msgpack = preload("res://addons/signal_fish/protocol/sf_msgpack.gd")
const SDKMesh = preload("res://addons/signal_fish/webrtc/sf_webrtc_mesh.gd")
const Membership = preload("res://addons/fortress_rollback/transport/signalfish_membership.gd")
const Adapter = preload("res://addons/fortress_rollback/transport/signalfish_adapter.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const H = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const S = preload("res://addons/fortress_rollback/core/session_types.gd")
const NewPeerProbe = preload("res://signalfish_probe_new_peer.gd")
const UUIDS: PackedStringArray = ["00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000002"]
const ROOM: String = "00000000-0000-0000-0000-000000000003"
const GENERATION: String = "00000000-0000-0000-0000-000000000004"
var received: Array[Dictionary] = []
var plans: Array[RefCounted] = []
var errors: Array[String] = []


class Game:
	extends RefCounted
	var ticks: int = 0
	func save_state(_frame: int, writer: RefCounted) -> Driver.SaveResult:
		writer.write_bytes(PackedByteArray([ticks]))
		var checksum: PackedByteArray = PackedByteArray()
		checksum.resize(16)
		checksum.encode_s64(0, ticks)
		return Driver.SaveResult.new(true, checksum)
	func load_state(_frame: int, reader: RefCounted) -> bool:
		var restored: RefCounted = reader.read_bytes(1)
		if restored.code != 0 or not reader.is_complete():
			return false
		ticks = restored.bytes[0]
		return true
	func simulate_frame(_frame: int, inputs: RefCounted) -> bool:
		for slot: int in 2:
			if inputs.read(slot).bytes.size() != 1:
				return false
		ticks += 1
		return true


class Wire:
	extends SDKTransport
	var sent: Array[PackedByteArray] = []
	func connect_to_url(_url: String) -> Error:
		opened.emit()
		return OK
	func send_text(_text: String) -> Error:
		return OK
	func send_binary(bytes: PackedByteArray) -> Error:
		sent.append(bytes.duplicate())
		return OK
	func get_ready_state() -> int:
		return WebSocketPeer.STATE_OPEN
	func close(code: int = 1000, reason: String = "") -> void:
		closed.emit(code, reason)
	func server_event(kind: String, data: Dictionary) -> void:
		packet_received.emit(JSON.stringify({"type": kind, "data": data}).to_utf8_buffer(), true)


func _initialize() -> void:
	var client: SDK = SDK.new()
	var wire: Wire = Wire.new()
	client.transport = wire
	client.protocol_error.connect(func(problem: String) -> void: errors.append(problem))
	client.session_plan.connect(func(plan: RefCounted) -> void: plans.append(plan))
	client.game_data_binary_received.connect(_on_binary)
	var options: SDKConfig = SDKConfig.new()
	options.app_id = "fortress-sdk-probe"
	options.endpoint_url = "ws://localhost:1"
	options.auto_poll = false
	options.protocol_version = 3
	options.game_data_format = "message_pack"
	if client.configure(options) != OK or client.connect_to_server() != OK:
		_fail(client, "SDK setup")
		return
	wire.server_event("Authenticated", {"app_name": "probe", "rate_limits": {"per_minute": 1, "per_hour": 1, "per_day": 1}})
	wire.server_event("ProtocolInfo", {"protocol_version": 3, "game_data_formats": ["message_pack"]})
	var players: Array[Dictionary] = []
	for uuid: String in UUIDS:
		players.append({"id": uuid, "name": "probe", "is_authority": false, "is_ready": true, "epoch": 7})
	wire.server_event("RoomJoined", {
		"room_id": ROOM, "room_code": "PROBE", "player_id": UUIDS[0], "game_name": "probe", "max_players": 2,
		"supports_authority": false, "current_players": players, "is_authority": false,
		"lobby_state": "finalized", "ready_players": [UUIDS[0], UUIDS[1]], "relay_type": "WebSocket"
	})
	if not errors.is_empty() or client.get_player_id() != UUIDS[0] or client.get_room_id() != ROOM or client.get_players().size() != 2:
		_fail(client, "SDK room decode %s" % errors)
		return
	var roster: PackedStringArray = PackedStringArray()
	for player: RefCounted in client.get_players():
		roster.append(player.id)
		if player.raw.get("epoch") != 7 or Membership.uuid_to_peer_id(player.id) != SDKMesh.uuid_to_peer_id(player.id):
			_fail(client, "SDK incarnation snapshot")
			return
	var membership: Membership = Membership.new()
	var profile: T.Config = T.Config.new()
	var session: PackedByteArray = PackedByteArray()
	session.resize(16)
	session.fill(3)
	var incarnation: PackedByteArray = PackedByteArray([7, 0, 0, 0, 0, 0, 0, 0])
	if membership.configure(client.get_player_id(), roster, session, incarnation, profile) != OK:
		_fail(client, "membership from SDK roster")
		return
	var mesh: SDKMesh = SDKMesh.new()
	var adapter: Adapter = Adapter.new()
	if adapter.attach(client, mesh, membership) != OK:
		mesh.free()
		_fail(client, "adapter actual SDK attachment")
		return
	wire.server_event("SessionPlan", {
		"generation": GENERATION, "topology": "host", "transport": "direct", "fallback": "relay",
		"peers": [{"player_id": UUIDS[1], "player_name": "probe", "is_authority": false, "initiate": false}], "ice_servers": []
	})
	if plans.size() != 1 or plans[0].generation != GENERATION or plans[0].peers[0].initiate or adapter.status().route != "relay_required":
		adapter.detach()
		mesh.free()
		_fail(client, "SDK plan decode")
		return
	if adapter.status().offerers.get(UUIDS[1]) != false or membership.slot(UUIDS[1]) != 1:
		adapter.detach()
		mesh.free()
		_fail(client, "SDK authoritative offerer mapping")
		return
	adapter.detach()
	mesh.free()
	var bytes: PackedByteArray = PackedByteArray([0, 255, 1, 128, 192])
	if client.send_game_data_binary(bytes) != OK or wire.sent != [bytes]:
		_fail(client, "SDK outbound pass-through")
		return
	var uuid_bytes: PackedByteArray = PackedByteArray()
	uuid_bytes.resize(16)
	uuid_bytes[15] = 2
	var encoded: Dictionary = Msgpack.encode({"from_player": uuid_bytes, "encoding": "message_pack", "payload": bytes, "seq": 1, "epoch": 7})
	if not encoded.ok:
		_fail(client, "wire fixture encode")
		return
	wire.packet_received.emit(encoded.bytes, false)
	if received.size() != 1 or received[0].sender != UUIDS[1] or received[0].bytes != bytes or not errors.is_empty():
		_fail(client, "SDK inbound attributed bytes %s" % errors)
		return
	if not _gameplay(client, wire, membership, session, profile):
		_fail(client, "actual SDK bytes to rollback gameplay")
		return
	if not NewPeerProbe.new().check(client, wire, session):
		_fail(client, "SDK additive peer identity fence")
		return
	mesh = SDKMesh.new()
	if adapter.attach(client, mesh, membership) != OK:
		mesh.free()
		_fail(client, "SDK lifecycle attachment")
		return
	wire.server_event("SessionPlan", {"generation": GENERATION, "topology": "relay", "transport": "relay", "fallback": "relay", "peers": []})
	if adapter.status().route != "relay":
		adapter.detach()
		mesh.free()
		_fail(client, "SDK lifecycle relay plan")
		return
	client.close()
	var ended: bool = adapter.status().route == "restart_required" and adapter.receive_relay(null, bytes, UUIDS[1], 0) == I.Code.WRONG_STATE
	adapter.detach()
	mesh.free()
	client.free()
	if not ended or not errors.is_empty():
		printerr("SDK close must fence adapter receive %s" % errors)
		quit(1)
		return
	print("FORTRESS_SIGNALFISH_SDK_OK")
	quit(0)


func _gameplay(client: SDK, wire: Wire, first: Membership, session: PackedByteArray, profile: T.Config) -> bool:
	var second: Membership = Membership.new()
	if second.configure(UUIDS[1], UUIDS, session, PackedByteArray([8, 0, 0, 0, 0, 0, 0, 0]), profile) != OK:
		return false
	var memberships: Array[Membership] = [first, second]
	var peers: Array[Peer] = []
	var games: Array[Game] = []
	for membership: Membership in memberships:
		var config: Config = Config.new()
		config.sync_test = false
		config.check_distance = 0
		config.max_snapshot_bytes = 1
		config.storage_budget_bytes = 100000
		var handshake: H.Options = H.Options.new()
		handshake.roundtrips = 1
		var game: Game = Game.new()
		var peer: Peer = Peer.new()
		if membership.configure_peer(peer, config, game, handshake, I.Options.new()) != I.Code.OK:
			return false
		var token: PackedByteArray = session.duplicate()
		token.fill(peers.size() + 1)
		if peer.begin(0, [token]) != I.Code.OK:
			return false
		peers.append(peer)
		games.append(game)
	for tick: int in 6:
		if not _deliver(client, wire, peers, memberships, tick):
			return false
	for frame: int in 70:
		var now_us: int = (frame + 1) * 16667
		for slot: int in 2:
			var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(slot, frame, PackedByteArray([1]))]
			if peers[slot].step(now_us, samples).code != S.Code.OK:
				return false
		if not _deliver(client, wire, peers, memberships, now_us) or not _deliver(client, wire, peers, memberships, now_us):
			return false
	return games[0].ticks == 70 and games[1].ticks == 70 and peers[0].status().confirmed_frame >= 68 and errors.is_empty()


func _deliver(client: SDK, wire: Wire, peers: Array[Peer], memberships: Array[Membership], now_us: int) -> bool:
	for slot: int in 2:
		for packet: Peer.Packet in peers[slot].drain_outbox():
			wire.sent.clear()
			if client.send_game_data_binary(packet.bytes) != OK or wire.sent != [packet.bytes]:
				return false
			var uuid_bytes: PackedByteArray = PackedByteArray()
			uuid_bytes.resize(16)
			uuid_bytes[15] = slot + 1
			var encoded: Dictionary = Msgpack.encode({"from_player": uuid_bytes, "encoding": "message_pack", "payload": wire.sent[0], "seq": 1, "epoch": 7})
			received.clear()
			wire.packet_received.emit(encoded.bytes, false)
			if received.size() != 1 or received[0].bytes != packet.bytes:
				return false
			if memberships[1 - slot].receive(peers[1 - slot], received[0].bytes, received[0].sender, now_us) != I.Code.OK:
				return false
		peers[slot].drain_events()
		peers[slot].drain_transitions()
	return true


func _on_binary(sender: String, encoding: int, bytes: PackedByteArray) -> void:
	received.append({"sender": sender, "encoding": encoding, "bytes": bytes.duplicate()})


func _fail(client: SDK, problem: String) -> void:
	printerr(problem)
	client.close()
	client.free()
	quit(1)
