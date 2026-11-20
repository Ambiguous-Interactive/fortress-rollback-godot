extends RefCounted

# gdlint: disable=max-returns
const SDK = preload("res://addons/signal_fish/signal_fish_client.gd")
const SDKConfig = preload("res://addons/signal_fish/signal_fish_config.gd")
const Multiplayer = preload("res://addons/fortress_rollback/transport/signalfish_webrtc_multiplayer_peer.gd")
const Connection = preload("res://addons/fortress_rollback/transport/signalfish_webrtc_connection.gd")
const SDKMesh = preload("res://addons/signal_fish/webrtc/sf_webrtc_mesh.gd")
const Membership = preload("res://addons/fortress_rollback/transport/signalfish_membership.gd")
const Adapter = preload("res://addons/fortress_rollback/transport/signalfish_adapter.gd")
const Direct = preload("res://addons/fortress_rollback/transport/signalfish_webrtc.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
const DirectTypes = preload("res://addons/fortress_rollback/transport/signalfish_webrtc_types.gd")
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
	mode.decode_msgpack_payloads = false
	mode.auto_poll = false
	if client.configure(mode) != OK or client.connect_to_server() != OK:
		return false
	if not await host._wait(func() -> bool: return client.is_authenticated() and host.infos.size() == 1):
		return false
	host.stage = "room_join"
	var params: SDK.JoinRoomParams = SDK.JoinRoomParams.new()
	params.game_name = "fortress-webrtc-%d" % count
	params.player_name = "player%d" % host.local_index
	params.max_players = count
	params.supports_authority = false
	if host.local_index != 0:
		if not await host._wait(func() -> bool: return JavaScriptBridge.eval("window.fortressRoom || ''") != ""):
			return false
		params.room_code = JavaScriptBridge.eval("window.fortressRoom")
	if client.join_room(params) != OK:
		return false
	if not await host._wait(func() -> bool: return not client.get_room_code().is_empty()):
		return false
	JavaScriptBridge.eval("document.body.dataset.fortressRoom = " + JSON.stringify(client.get_room_code()))
	if not await host._wait(func() -> bool: return client.get_players().size() == count):
		return false
	host.stage = "freeze_membership"
	host.membership_frozen = true
	var roster: PackedStringArray = PackedStringArray()
	for player: RefCounted in host.clients[0].get_players():
		roster.append(player.id)
	var session: PackedByteArray = PackedByteArray()
	session.resize(16)
	session.fill(count)
	for index: int in host.clients.size():
		var profile: T.Config = T.Config.new()
		profile.player_count = count
		var membership: Membership = Membership.new()
		var incarnation: PackedByteArray = PackedByteArray([host.local_index + 1, 0, 0, 0, 0, 0, 0, 0])
		if membership.configure(host.clients[index].get_player_id(), roster, session, incarnation, profile) != OK:
			return false
		host.memberships.append(membership)
		var mesh: SDKMesh = SDKMesh.new()
		mesh.multiplayer_peer_factory = Multiplayer.create
		mesh.peer_connection_factory = raw_connection if JavaScriptBridge.eval("window.fortressDefaultFactory || false") else Connection.create
		host.meshes.append(mesh)
		var adapter: Adapter = Adapter.new()
		host.adapters.append(adapter)
		if adapter.attach(host.clients[index], mesh, membership) != OK:
			return false
	host.stage = "ready"
	for sdk_client: SDK in host.clients:
		if sdk_client.set_ready() != OK:
			return false
	if not await host._wait(
		func() -> bool:
			for index: int in host.clients.size():
				if not host.lobby_ready.get(index, false):
					return false
			return true
	):
		return false
	host.stage = "start_game"
	if host.local_index == 0 and host.clients[0].start_game() != OK:
		return false
	if not await host._wait(
		func() -> bool:
			for adapter: Adapter in host.adapters:
				if adapter.status().route != "mesh":
					return false
			return true
	):
		return false
	host.stage = "connect_mesh"
	if not await host._wait(
		func() -> bool:
			var mp: Object = host.meshes[0].get_multiplayer_peer()
			if mp == null:
				return false
			mp.call("poll")
			var connected: Dictionary = mp.call("get_peers")
			if connected.size() != count - 1:
				return false
			for info: Dictionary in connected.values():
				if not info.get("connected", false):
					return false
			return true
	):
		return false
	var observed: Dictionary = host.meshes[0].get_multiplayer_peer().call("get_peers")
	for connection: Dictionary in observed.values():
		for channel: Object in connection.channels:
			print(
				"GODOT_CHANNEL ",
				JSON.stringify(
					{
						"label": channel.call("get_label"),
						"ordered": channel.call("is_ordered"),
						"life": channel.call("get_max_packet_life_time"),
						"retransmits": channel.call("get_max_retransmits"),
						"max_packet_size_method": channel.has_method("get_max_packet_size")
					}
				)
			)
	host.stage = "configure_rollback"
	for index: int in host.clients.size():
		var config: Config = Config.new()
		config.player_count = count
		config.sync_test = false
		config.check_distance = 0
		config.max_snapshot_bytes = 4 + 4 * count
		if host.mixed_enabled:
			config.replay_max_frames = host.frame_count
			config.diagnostic_version = "fortress-webrtc-integer-v1"
			config.diagnostic_seed = "0"
		config.storage_budget_bytes = 1048576
		var game: Game = Game.new(count, JavaScriptBridge.eval("window.fortressCorrupt || false"))
		host.games.append(game)
		var peer: Peer = Peer.new()
		host.peers.append(peer)
		var handshake: H.Options = H.Options.new()
		handshake.roundtrips = 1
		var lifecycle: L.Options = L.Options.new()
		lifecycle.enabled = host.drop_enabled
		if host.drop_enabled:
			lifecycle.disconnect_behavior = L.Disconnect.CONTINUE
			lifecycle.disconnect_notify_us = 2000000
			lifecycle.disconnect_timeout_us = 5000000
			lifecycle.drop_barrier_timeout_us = 4000000
		var configured: int = host.memberships[index].configure_peer(peer, config, game, handshake, I.Options.new(), lifecycle)
		if configured != I.Code.OK:
			host.errors.append("configure_peer_%d" % configured)
			return false
		var tokens: Array[PackedByteArray] = []
		for remote: int in count - 1:
			tokens.append(host._next_token())
		host._reset_transport_clock()
		var begun: int = peer.begin(0, tokens)
		if begun != I.Code.OK:
			host.errors.append("begin_%d" % begun)
			return false
		var direct: Direct = DropDirect.new() if bool(JavaScriptBridge.eval("window.fortressDropMissing || false")) else Direct.new()
		host.transports.append(direct)
		var options: Direct.Options = host._direct_options()
		var connected_code: int = direct.configure(host.meshes[index], host.memberships[index], host.adapters[index], peer, options)
		if connected_code != 0:
			host.errors.append("configure_direct_%d" % connected_code)
			return false
	if host.mixed_enabled and not host.mixed.configure(host, mode):
		return false
	return true


class DropDirect:
	extends Direct

	## The missing-history witness withholds only the departing slot's original
	## input rows on one selected link. Every other packet keeps the production
	## transport path.
	var _drop_identity: PackedByteArray = PackedByteArray()
	var _drop_slot: int = -1
	var _drop_from: int = -1
	var _drop_through: int = -1
	var _unsupported: int = 0
	var _overlaps: int = 0
	var _frames: Dictionary = {}

	func arm_drop(identity: PackedByteArray, from_frame: int, through_frame: int, slot: int) -> void:
		_drop_identity = identity.duplicate()
		_drop_from = from_frame
		_drop_through = through_frame
		_drop_slot = slot

	func poll(now_us: int, next_token_factory: Callable = Callable()) -> DirectTypes.Result:
		_withhold_missing_inputs()
		return super.poll(now_us, next_token_factory)

	func drop_report() -> Dictionary:
		var frames: Array[int] = []
		for frame: int in _frames.keys():
			frames.append(frame)
		frames.sort()
		return {"dropped": frames.size(), "from": _drop_from, "through": _drop_through,
			"frames": frames, "overlaps": _overlaps, "slot": _drop_slot, "unsupported": _unsupported}

	func _withhold_missing_inputs() -> void:
		if _drop_identity.is_empty() or _membership == null or _peer == null:
			return
		var current: int = _peer.status().current_frame - 1
		if current < _drop_from or current > _drop_through:
			return
		var limits: T.Limits = T.Limits.new()
		limits.player_count = _membership.roster().size()
		limits.max_packet_bytes = 65536
		var kept: Array[Peer.Packet] = []
		for packet: Peer.Packet in _pending:
			if packet == null or packet.bytes.size() < 4 or _destination(packet) != _drop_identity:
				kept.append(packet)
				continue
			var decoded: T.Result = Codec.decode(packet.bytes, limits)
			if decoded.code != T.Code.OK or decoded.message.kind != T.Kind.INPUT:
				kept.append(packet)
				continue
			if decoded.message.players.size() != 1 or decoded.message.players[0] != _drop_slot:
				_unsupported += 1
				kept.append(packet)
				continue
			var start: int = decoded.message.start_frame
			var last: int = start + decoded.message.frame_count - 1
			if start > _drop_through or last < _drop_from:
				kept.append(packet)
				continue
			var pieces: Array[Peer.Packet] = _trim_input(packet, decoded.message, limits)
			for frame: int in range(maxi(start, _drop_from), mini(last, _drop_through) + 1):
				_frames[frame] = true
			for piece: Peer.Packet in pieces:
				kept.append(piece)
				_pending_bytes += piece.bytes.size()
			_pending_bytes = maxi(0, _pending_bytes - packet.bytes.size())
		_pending = kept

	func _trim_input(packet: Peer.Packet, message: T.Message, limits: T.Limits) -> Array[Peer.Packet]:
		var result: Array[Peer.Packet] = []
		var count: int = message.frame_count
		var slots: int = message.players.size()
		if count < 1 or slots < 1 or message.data.size() % (count * slots) != 0:
			_overlaps += 1
			var fallback: Array[Peer.Packet] = []
			fallback.append(packet)
			return fallback
		var width: int = message.data.size() / (count * slots)
		limits.input_width = width
		var start: int = message.start_frame
		var run_start: int = -1
		var run_end: int = -1
		for offset: int in range(count):
			var frame: int = start + offset
			if frame >= _drop_from and frame <= _drop_through:
				if run_start >= 0:
					var piece: Peer.Packet = _segment(packet, message, limits, run_start, run_end)
					if piece != null:
						result.append(piece)
				run_start = -1
				continue
			if run_start < 0:
				run_start = frame
			run_end = frame
		if run_start >= 0:
			var piece: Peer.Packet = _segment(packet, message, limits, run_start, run_end)
			if piece != null:
				result.append(piece)
		return result

	func _segment(packet: Peer.Packet, message: T.Message, limits: T.Limits, start: int, last: int) -> Peer.Packet:
		var piece: T.Message = T.Message.new()
		piece.kind = T.Kind.INPUT
		piece.session_id = message.session_id.duplicate()
		piece.sender_id = message.sender_id.duplicate()
		piece.connection_id = message.connection_id.duplicate()
		piece.start_frame = start
		piece.ack_frame = message.ack_frame
		piece.frame_count = last - start + 1
		piece.players = message.players.duplicate()
		for status: T.Status in message.statuses:
			piece.statuses.append(status)
		var width: int = message.data.size() / (message.frame_count * message.players.size())
		var offset: int = (start - message.start_frame) * message.players.size() * width
		piece.data = message.data.slice(offset, offset + piece.frame_count * message.players.size() * width)
		var encoded: T.Result = Codec.encode(piece, limits)
		if encoded.code != T.Code.OK:
			_overlaps += 1
			return null
		return Peer.Packet.new(packet.to, encoded.bytes)

	func _destination(packet: Peer.Packet) -> PackedByteArray:
		return _membership.identity(_membership.uuid_for_peer_id(packet.to.decode_u32(0)))


static func raw_connection() -> WebRTCPeerConnection:
	return RawConnection.new(WebRTCPeerConnection.new())


class RawConnection:
	extends Connection

	func _create_data_channel(label: String, config: Dictionary) -> WebRTCDataChannel:
		# Isolate the channel-option control while retaining production ICE identity and cleanup.
		return _inner.create_data_channel(label, config)


static func publish_progress(host: Node) -> void:
	if host.peers.is_empty():
		return
	var peer: Peer = host.peers[0]
	var received: Array[int] = []
	var acked: Array[int] = []
	for endpoint_status: Dictionary in peer.network_status().peers.values():
		received.append(endpoint_status.last_received_frame)
		acked.append(endpoint_status.last_acked_frame)
	var progress: Dictionary = {"received": received, "acked": acked, "confirmed": peer.status().confirmed_frame}
	JavaScriptBridge.eval("document.body.dataset.fortressProgress = " + JSON.stringify(JSON.stringify(progress)))
