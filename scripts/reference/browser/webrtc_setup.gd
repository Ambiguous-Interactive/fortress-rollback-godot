extends RefCounted

# gdlint: disable=max-returns
const SDK = preload("res://addons/signal_fish/signal_fish_client.gd")
const SDKConfig = preload("res://addons/signal_fish/signal_fish_config.gd")
const Connection = preload("res://addons/fortress_rollback/transport/signalfish_webrtc_connection.gd")
const SDKMesh = preload("res://addons/signal_fish/webrtc/sf_webrtc_mesh.gd")
const Membership = preload("res://addons/fortress_rollback/transport/signalfish_membership.gd")
const Adapter = preload("res://addons/fortress_rollback/transport/signalfish_adapter.gd")
const Direct = preload("res://addons/fortress_rollback/transport/signalfish_webrtc.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const H = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const L = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")
const Game = preload("res://webrtc_game.gd")

func run(host: Node, count: int) -> bool:
	host.membership_frozen = false
	host.tearing_down = false
	host.stage = "connect"
	var client: SDK = SDK.new()
	host.clients.append(client)
	client.protocol_info.connect(func(info: RefCounted) -> void: host.infos[0] = info)
	client.lobby_state_changed.connect(func(_state: int, _players: PackedStringArray, all_ready: bool) -> void: host.lobby_ready[0] = all_ready)
	host._observe_client(client)
	client.room_joined.connect(func(info: RefCounted) -> void: host.room_infos[0] = info)
	client.game_data_binary_received.connect(func(_sender: String, _encoding: int, _bytes: PackedByteArray) -> void: host.received_binary += 1)
	var mode: SDKConfig = SDKConfig.new()
	mode.app_id = "fortress-live-webrtc"
	mode.endpoint_url = host.endpoint
	mode.protocol_version = 3
	mode.supported_transports = PackedStringArray(["relay", "webrtc"])
	mode.supported_topologies = PackedStringArray(["relay", "mesh"])
	mode.game_data_format = "message_pack"
	mode.auto_poll = false
	if client.configure(mode) != OK or client.connect_to_server() != OK: return false
	if not await host._wait(func() -> bool: return client.is_authenticated() and host.infos.size() == 1): return false
	host.stage = "room_join"
	var params: SDK.JoinRoomParams = SDK.JoinRoomParams.new()
	params.game_name = "fortress-webrtc-%d" % count
	params.player_name = "player%d" % host.local_index
	params.max_players = count
	params.supports_authority = false
	if host.local_index != 0:
		if not await host._wait(func() -> bool: return JavaScriptBridge.eval("window.fortressRoom || ''") != ""): return false
		params.room_code = JavaScriptBridge.eval("window.fortressRoom")
	if client.join_room(params) != OK: return false
	if not await host._wait(func() -> bool: return not client.get_room_code().is_empty()): return false
	JavaScriptBridge.eval("document.body.dataset.fortressRoom = " + JSON.stringify(client.get_room_code()))
	if not await host._wait(func() -> bool: return client.get_players().size() == count): return false
	host.stage = "freeze_membership"
	host.membership_frozen = true
	var roster: PackedStringArray = PackedStringArray()
	for player: RefCounted in host.clients[0].get_players(): roster.append(player.id)
	var session: PackedByteArray = PackedByteArray()
	session.resize(16)
	session.fill(count)
	for index: int in host.clients.size():
		var profile: T.Config = T.Config.new()
		profile.player_count = count
		var membership: Membership = Membership.new()
		var incarnation: PackedByteArray = PackedByteArray([host.local_index + 1, 0, 0, 0, 0, 0, 0, 0])
		if membership.configure(host.clients[index].get_player_id(), roster, session, incarnation, profile) != OK: return false
		host.memberships.append(membership)
		var mesh: SDKMesh = SDKMesh.new()
		mesh.peer_connection_factory = raw_connection if JavaScriptBridge.eval("window.fortressDefaultFactory || false") else Connection.create
		host.meshes.append(mesh)
		var adapter: Adapter = Adapter.new()
		host.adapters.append(adapter)
		if adapter.attach(host.clients[index], mesh, membership) != OK: return false
	host.stage = "ready"
	for sdk_client: SDK in host.clients:
		if sdk_client.set_ready() != OK: return false
	if not await host._wait(func() -> bool:
		for index: int in host.clients.size():
			if not host.lobby_ready.get(index, false): return false
		return true): return false
	host.stage = "start_game"
	if host.local_index == 0 and host.clients[0].start_game() != OK: return false
	if not await host._wait(func() -> bool:
		for adapter: Adapter in host.adapters:
			if adapter.status().route != "mesh": return false
		return true): return false
	host.stage = "connect_mesh"
	if not await host._wait(func() -> bool:
		var mp: Object = host.meshes[0].get_multiplayer_peer()
		if mp == null: return false
		mp.call("poll")
		var connected: Dictionary = mp.call("get_peers")
		if connected.size() != count - 1: return false
		for info: Dictionary in connected.values():
			if not info.get("connected", false): return false
		return true): return false
	var observed: Dictionary = host.meshes[0].get_multiplayer_peer().call("get_peers")
	for connection: Dictionary in observed.values():
		for channel: Object in connection.channels:
			print("GODOT_CHANNEL ", JSON.stringify({"label": channel.call("get_label"), "ordered": channel.call("is_ordered"),
				"life": channel.call("get_max_packet_life_time"), "retransmits": channel.call("get_max_retransmits"),
				"max_packet_size_method": channel.has_method("get_max_packet_size")}))
	host.stage = "configure_rollback"
	for index: int in host.clients.size():
		var config: Config = Config.new()
		config.player_count = count
		config.sync_test = false
		config.check_distance = 0
		config.max_snapshot_bytes = 4 + 4 * count
		config.storage_budget_bytes = 1048576
		var game: Game = Game.new(count, JavaScriptBridge.eval("window.fortressCorrupt || false"))
		host.games.append(game)
		var peer: Peer = Peer.new()
		host.peers.append(peer)
		var handshake: H.Options = H.Options.new()
		handshake.roundtrips = 1
		var lifecycle: L.Options = L.Options.new()
		lifecycle.enabled = false
		var configured: int = host.memberships[index].configure_peer(peer, config, game, handshake, I.Options.new(), lifecycle)
		if configured != I.Code.OK:
			host.errors.append("configure_peer_%d" % configured)
			return false
		var tokens: Array[PackedByteArray] = []
		for remote: int in count - 1: tokens.append(host._next_token())
		host._reset_transport_clock()
		var begun: int = peer.begin(0, tokens)
		if begun != I.Code.OK:
			host.errors.append("begin_%d" % begun)
			return false
		var direct: Direct = Direct.new()
		host.transports.append(direct)
		var options: Direct.Options = Direct.Options.new()
		options.max_packet_bytes = 1024
		options.max_sends_per_poll = 32
		var connected_code: int = direct.configure(host.meshes[index], host.memberships[index], host.adapters[index], peer, options)
		if connected_code != 0:
			host.errors.append("configure_direct_%d" % connected_code)
			return false
	return true



static func raw_connection() -> WebRTCPeerConnection:
	# Preserve the engine's original channel options while closing its unused default connection.
	var connection: WebRTCPeerConnection = WebRTCPeerConnection.new()
	connection.close()
	return connection


static func publish_progress(host: Node) -> void:
	if host.peers.is_empty(): return
	var peer: Peer = host.peers[0]
	var received: Array[int] = []
	var acked: Array[int] = []
	for endpoint_status: Dictionary in peer.network_status().peers.values():
		received.append(endpoint_status.last_received_frame)
		acked.append(endpoint_status.last_acked_frame)
	var progress: Dictionary = {"received": received, "acked": acked, "confirmed": peer.status().confirmed_frame}
	JavaScriptBridge.eval("document.body.dataset.fortressProgress = " + JSON.stringify(JSON.stringify(progress)))
