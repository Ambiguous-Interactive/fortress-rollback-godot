extends SceneTree

# gdlint: disable=constant-name,max-returns

# Value: protects=real native relay gameplay; fails_when=server lifecycle or binary delivery diverges; why_new=injected witnesses omit sockets; seam=SDK public API

const SDK = preload("res://addons/signal_fish/signal_fish_client.gd")
const SDKConfig = preload("res://addons/signal_fish/signal_fish_config.gd")
const SDKTypes = preload("res://addons/signal_fish/protocol/sf_types.gd")
const SDKMesh = preload("res://addons/signal_fish/webrtc/sf_webrtc_mesh.gd")
const Membership = preload("res://addons/fortress_rollback/transport/signalfish_membership.gd")
const Adapter = preload("res://addons/fortress_rollback/transport/signalfish_adapter.gd")
const Relay = preload("res://addons/fortress_rollback/transport/signalfish_relay.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const H = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const L = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")
const S = preload("res://addons/fortress_rollback/core/session_types.gd")
const RelayProbe = preload("res://signalfish_probe_relay.gd")
const Game = RelayProbe.Game
const FAILURE_SIGNALS: PackedStringArray = ["protocol_error", "server_error", "room_join_failed", "authentication_error", "connection_failed",
	"reconnection_failed", "disconnected", "going_away", "room_left", "reconnected"]
const MEMBERSHIP_SIGNALS: PackedStringArray = ["room_joined", "player_joined", "player_left", "player_reconnected", "spectator_joined", "new_peer"]
var clients: Array[SDK] = []
var modes: Array[SDKConfig] = []
var infos: Dictionary = {}
var ready: Dictionary = {}
var room_infos: Dictionary = {}
var adapters: Array[Adapter] = []
var meshes: Array[SDKMesh] = []
var memberships: Array[Membership] = []
var peers: Array[Peer] = []
var relays: Array[Relay] = []
var games: Array[Game] = []
var errors: Array[String] = []
var records: Array[Dictionary] = []
var received_binary: int = 0
var stage: String = "initial"
var simulated_us: int = 0
var endpoint: String = ""
var late_error: String = ""
var late_error_due: bool = false
var late_error_injected: bool = false
var membership_frozen: bool = false
var tearing_down: bool = false

func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() not in [1, 2] or not args[0].begins_with("ws://127.0.0.1:"):
		quit(1)
		return
	endpoint = args[0]
	if args.size() == 2:
		late_error = args[1]
		if late_error not in FAILURE_SIGNALS and late_error not in MEMBERSHIP_SIGNALS:
			quit(1)
			return
	_run.call_deferred()

func _run() -> void:
	var counts: PackedInt32Array = PackedInt32Array([2, 4, 8]) if late_error.is_empty() else PackedInt32Array([8])
	for count: int in counts:
		var ok: bool = await _setup(count)
		if ok:
			ok = await _play(count)
		ok = ok and _healthy(true)
		_cleanup()
		ok = ok and errors.is_empty()
		if not ok:
			var failure: Dictionary = {"players": count, "stage": stage, "errors": errors, "binary_receives": received_binary,
				"control": late_error, "control_injected": late_error_injected}
			print("LIVE_RELAY_FAILED ", JSON.stringify(failure))
			quit(1)
			return
	print("FORTRESS_LIVE_RELAY_RESULT ", JSON.stringify({"passed": true, "records": records, "binary_receives": received_binary}))
	quit(0)

func _setup(count: int) -> bool:
	membership_frozen = false
	tearing_down = false
	stage = "connect"
	for index: int in count:
		var client: SDK = SDK.new()
		clients.append(client)
		client.protocol_info.connect(func(info: RefCounted) -> void: infos[index] = info)
		client.lobby_state_changed.connect(func(_state: int, _players: PackedStringArray, all_ready: bool) -> void: ready[index] = all_ready)
		_observe_client(client)
		client.room_joined.connect(func(info: RefCounted) -> void: room_infos[index] = info)
		client.game_data_binary_received.connect(func(_sender: String, _encoding: int, _bytes: PackedByteArray) -> void: received_binary += 1)
		var mode: SDKConfig = SDKConfig.new()
		modes.append(mode)
		mode.app_id = "fortress-live-relay"
		mode.endpoint_url = endpoint
		mode.protocol_version = 3
		mode.game_data_format = "message_pack"
		mode.auto_poll = false
		if client.configure(mode) != OK or client.connect_to_server() != OK:
			return false
	if not await _wait(func() -> bool:
		for client: SDK in clients:
			if not client.is_authenticated(): return false
		return infos.size() == count):
		return false
	stage = "room_create"
	var params: SDK.JoinRoomParams = SDK.JoinRoomParams.new()
	params.game_name = "fortress-live-%d" % count
	params.player_name = "player0"
	params.max_players = count
	params.supports_authority = false
	if clients[0].join_room(params) != OK or not await _wait(func() -> bool: return not clients[0].get_room_code().is_empty()):
		return false
	stage = "room_join"
	for index: int in range(1, count):
		params = SDK.JoinRoomParams.new()
		params.game_name = "fortress-live-%d" % count
		params.player_name = "player%d" % index
		params.room_code = clients[0].get_room_code()
		params.supports_authority = false
		if clients[index].join_room(params) != OK:
			return false
	if not await _wait(func() -> bool:
		for client: SDK in clients:
			if client.get_players().size() != count: return false
		return true):
		return false
	stage = "freeze_membership"
	membership_frozen = true
	var roster: PackedStringArray = PackedStringArray()
	for player: RefCounted in clients[0].get_players(): roster.append(player.id)
	var session: PackedByteArray = PackedByteArray()
	session.resize(16)
	session.fill(count)
	for index: int in count:
		var profile: T.Config = T.Config.new()
		profile.player_count = count
		var membership: Membership = Membership.new()
		var incarnation: PackedByteArray = PackedByteArray([index + 1, 0, 0, 0, 0, 0, 0, 0])
		if membership.configure(clients[index].get_player_id(), roster, session, incarnation, profile) != OK: return false
		memberships.append(membership)
		var mesh: SDKMesh = SDKMesh.new()
		meshes.append(mesh)
		var adapter: Adapter = Adapter.new()
		adapters.append(adapter)
		if adapter.attach(clients[index], mesh, membership) != OK: return false
	stage = "ready"
	for client: SDK in clients:
		if client.set_ready() != OK: return false
	if not await _wait(func() -> bool:
		for index: int in count:
			if not ready.get(index, false): return false
		return true): return false
	stage = "start_game"
	if clients[0].start_game() != OK: return false
	if not await _wait(func() -> bool:
		for adapter: Adapter in adapters:
			if adapter.status().route != "relay": return false
		return true): return false
	stage = "configure_rollback"
	for index: int in count:
		var config: Config = Config.new()
		config.player_count = count
		config.sync_test = false
		config.check_distance = 0
		config.max_snapshot_bytes = 4 + 4 * count
		config.storage_budget_bytes = 1048576
		var game: Game = Game.new(count)
		games.append(game)
		var peer: Peer = Peer.new()
		peers.append(peer)
		var handshake: H.Options = H.Options.new()
		handshake.roundtrips = 1
		var lifecycle: L.Options = L.Options.new()
		lifecycle.enabled = false
		if memberships[index].configure_peer(peer, config, game, handshake, I.Options.new(), lifecycle) != I.Code.OK: return false
		var tokens: Array[PackedByteArray] = []
		for remote: int in count - 1:
			var token: PackedByteArray = session.duplicate()
			token[0] = index + 1
			token[1] = remote + 1
			tokens.append(token)
		if peer.begin(0, tokens) != I.Code.OK: return false
		var relay: Relay = Relay.new()
		relays.append(relay)
		var options: Relay.Options = Relay.Options.new()
		options.max_packet_bytes = 1024
		options.max_sends_per_poll = 32
		options.max_receives_per_poll = 32
		if relay.configure(clients[index], modes[index], infos[index], memberships[index], adapters[index], peer, options) != 0: return false
	simulated_us = 0
	return true

func _play(count: int) -> bool:
	stage = "handshake"
	if not await _wait(func() -> bool:
		for peer: Peer in peers:
			if peer.network_status().state != "running": return false
		return true, true): return false
	stage = "gameplay"
	for frame: int in 40:
		simulated_us = (frame + 1) * 16667
		for index: int in count:
			var slot: int = memberships[index].slot(clients[index].get_player_id())
			var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(slot, frame, PackedByteArray([_input(frame, slot)]))]
			if peers[index].step(simulated_us, samples).code != S.Code.OK: return false
		if not await _wait(func() -> bool:
			for peer: Peer in peers:
				if peer.status().confirmed_frame < frame - 1: return false
			return true, true): return false
		for turn: int in 8:
			late_error_due = count == 8 and frame == 39 and turn == 7 and not late_error.is_empty()
			if not _service(): return false
			await create_timer(0.002).timeout
	for client: SDK in clients: client.poll()
	if not _healthy(true): return false
	stage = "canonical_state"
	var comparisons: int = 0
	var minimum_confirmed: int = 2147483647
	for index: int in count:
		minimum_confirmed = mini(minimum_confirmed, peers[index].status().confirmed_frame)
		if peers[index].status().confirmed_frame < 38: return false
		for frame: int in range(1, 39):
			var expected: PackedByteArray = PackedByteArray()
			expected.resize(4 + 4 * count)
			expected.encode_u32(0, frame)
			for slot: int in count:
				var value: int = 0
				for previous: int in frame: value += _input(previous, slot)
				expected.encode_u32(4 + 4 * slot, value)
			if games[index].history.get(frame) != expected: return false
			comparisons += 1
	if not _healthy(true): return false
	records.append({"players": count, "frames_submitted": 40, "minimum_confirmed": minimum_confirmed, "canonical_comparisons": comparisons})
	return true

func _wait(condition: Callable, use_relay: bool = false) -> bool:
	for attempt: int in 3000:
		for client: SDK in clients: client.poll()
		if use_relay and not _service(): return false
		if not errors.is_empty(): return false
		if condition.call(): return true
		await create_timer(0.002).timeout
	return false

func _service() -> bool:
	if not _healthy(): return false
	for index: int in clients.size():
		clients[index].poll()
		if not errors.is_empty(): return false
		var packets: Array[Peer.Packet] = peers[index].drain_outbox()
		if not packets.is_empty() and relays[index].enqueue_batch(packets) != 0: return false
		var result: Relay.Result = relays[index].poll(simulated_us)
		if result.code != 0: return false
		peers[index].drain_events()
		peers[index].drain_transitions()
	if late_error_due:
		_inject_late_error()
	return _healthy()

func _observe_client(client: SDK) -> void:
	# Variant defaults match the optional payloads of the pinned SDK's different public signals.
	for signal_name: String in FAILURE_SIGNALS:
		client.connect(signal_name, func(_first: Variant = null, _second: Variant = null) -> void: _record_failure(signal_name))
	for signal_name: String in MEMBERSHIP_SIGNALS:
		client.connect(signal_name, func(_first: Variant = null, _second: Variant = null) -> void:
			if membership_frozen: _record_failure(signal_name))

func _record_failure(signal_name: String) -> void:
	if not tearing_down: errors.append(signal_name)

func _healthy(final: bool = false) -> bool:
	if not errors.is_empty(): return false
	for index: int in clients.size():
		if not clients[index].is_connected_to_server() or not clients[index].is_authenticated(): return false
		if clients[index].get_player_id() != memberships[index].local_uuid() or clients[index].get_room_id() != room_infos[index].room_id: return false
		if adapters[index].status().route != "relay" or relays[index].status().code != 0: return false
		if final and peers[index].network_status().state != "running": return false
	return true

func _inject_late_error() -> void:
	# Private witness control: inject through the actual SDK after the final gameplay drain.
	late_error_due = false
	late_error_injected = true
	match late_error:
		"protocol_error", "connection_failed": clients[0].emit_signal(late_error, "late witness control")
		"authentication_error", "room_join_failed", "reconnection_failed", "server_error": clients[0].emit_signal(late_error, "late witness control", 999)
		"disconnected": clients[0].disconnected.emit(999, "late witness control")
		"going_away": clients[0].going_away.emit(999, 999)
		"room_left": clients[0].room_left.emit()
		"player_left", "player_reconnected": clients[0].emit_signal(late_error, clients[0].get_player_id())
		"player_joined": clients[0].player_joined.emit(clients[0].get_players()[0])
		"room_joined": clients[0].room_joined.emit(room_infos[0])
		"reconnected": clients[0].reconnected.emit(room_infos[0], [])
		"spectator_joined": clients[0].spectator_joined.emit(SDKTypes.SpectatorJoinedInfo.new())
		"new_peer": clients[0].new_peer.emit(clients[0].get_players()[1].id, false)

static func _input(frame: int, slot: int) -> int:
	return (frame * 17 + slot * 31 + 1) & 255

func _cleanup() -> void:
	tearing_down = true
	for relay: Relay in relays: relay.detach()
	for adapter: Adapter in adapters: adapter.detach()
	for mesh: SDKMesh in meshes: mesh.free()
	for client: SDK in clients:
		client.close()
		client.free()
	clients.clear()
	modes.clear()
	infos.clear()
	ready.clear()
	room_infos.clear()
	adapters.clear()
	meshes.clear()
	memberships.clear()
	peers.clear()
	relays.clear()
	games.clear()
