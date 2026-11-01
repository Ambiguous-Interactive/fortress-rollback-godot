extends "res://signalfish_spectator_live.gd"

var physical_departure_frame: int = -1
var resumed_frame: int = -1
var host_left_observed: bool = false


func _run() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	runtime = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	for index: int in 2:
		var client: SDK = SDK.new()
		clients.append(client)
		var config: SDKConfig = SDKConfig.new()
		config.app_id = "fortress-live-relay"
		config.protocol_version = 3
		config.game_data_format = "message_pack"
		config.decode_msgpack_payloads = false
		config.auto_poll = false
		modes.append(config)
		client.spectator_disconnected.connect(func(id: String, _reason: int, _spectators: Array) -> void:
			if id == viewer_uuid and index == 0:
				departure_observed = true
				physical_departure_frame = -1 if host_session == null else host_session.status().current_frame
		)
		client.player_left.connect(func(id: String) -> void:
			if index == 1 and departure_started and id == admission.host:
				host_left_observed = true
		)
		client.protocol_info.connect(func(info: RefCounted) -> void: protocol[index] = info)
		client.lobby_state_changed.connect(func(_state: int, _players: PackedStringArray, all_ready: bool) -> void: ready[index] = all_ready)
		for signal_name: String in ["protocol_error", "server_error", "authentication_error", "connection_failed", "disconnected", "room_join_failed"]:
			client.connect(signal_name, func(_a: Variant = null, _b: Variant = null) -> void: _error(signal_name, index))
		if client.configure(config) != OK or client.connect_to_server(runtime.endpoint) != OK:
			_fail("browser host SDK setup")
			return
	if not await _wait(func() -> bool: return protocol.size() == 2 and clients.all(func(c: SDK) -> bool: return c.is_authenticated()), "host login"):
		return
	var room: SDK.JoinRoomParams = SDK.JoinRoomParams.new()
	room.game_name = "fortress-spectator-browser"
	room.player_name = "host"
	room.max_players = 2
	room.supports_authority = false
	clients[0].join_room(room)
	if not await _wait(func() -> bool: return not clients[0].get_room_code().is_empty(), "host room"):
		return
	room = SDK.JoinRoomParams.new()
	room.game_name = "fortress-spectator-browser"
	room.player_name = "remote"
	room.room_code = clients[0].get_room_code()
	clients[1].join_room(room)
	if not await _wait(func() -> bool: return clients[0].get_players().size() == 2, "seated room"):
		return
	var response: Dictionary = await _http("/room", runtime.host_token, {"code": room.room_code, "game": room.game_name})
	if response.status != 200:
		_fail("room provisioning")
		return
	var deadline: int = Time.get_ticks_usec() + 15000000
	while viewer_uuid.is_empty() and Time.get_ticks_usec() < deadline:
		response = await _http("/viewer", runtime.host_token)
		if response.status == 200:
			viewer_uuid = response.body.viewer
		else:
			await create_timer(0.1).timeout
	if viewer_uuid.is_empty():
		_fail("browser viewer registration")
		return
	clients[0].set_ready()
	clients[1].set_ready()
	if not await _wait(func() -> bool: return ready.get(0, false), "seated readiness"):
		return
	clients[0].start_game()
	if not await _wait(func() -> bool: return clients[0].get_session_state() == Host.FINALIZED, "host finalized"):
		return
	host_session = Session.new()
	host_game = Game.new()
	if host_session.configure(_config(false)) != S.Code.OK:
		_fail("host config")
		return
	host_driver = Driver.new(host_session, host_game)
	var digest: PackedByteArray = Stream.configuration_digest_with_state(_config(true), "1701", "live-spectator-v1", host_game.canonical_bytes())
	admission = {
		"viewer": viewer_uuid,
		"host": clients[0].get_player_id(),
		"room": clients[0].get_room_id(),
		"identity": runtime.identity,
		"key": runtime.key,
		"digest": digest.hex_encode(),
		"initial_state": host_game.canonical_bytes().hex_encode(),
		"players": 2,
		"width": 1,
		"neutral": "00",
		"seed": "1701",
		"rules": "live-spectator-v1"
	}
	if runtime.get("browser_fault") == "initial-state":
		admission.initial_state = "ff".repeat(24)
	elif runtime.get("browser_fault") == "room-identity":
		admission.room = "foreign-room"
	response = await _http("/admit", runtime.host_token, admission)
	if response.status != 200:
		_fail("browser admission")
		return
	publication = Host.new()
	var options: Host.Options = Host.Options.new()
	options.max_packet_bytes = 1024
	if (
		publication.configure(
			clients[0], modes[0], protocol[0], host_session, viewer_uuid, String(runtime.identity).hex_decode(), String(runtime.key).hex_decode(), digest, options
		)
		!= Transport.Code.OK
	):
		_fail("browser publication configuration")
		return
	var accepted: bool = false
	deadline = Time.get_ticks_usec() + 15000000
	while not accepted and Time.get_ticks_usec() < deadline:
		publication.poll(_now())
		response = await _http("/take", runtime.host_token)
		if response.body.has("packet"):
			accepted = publication.receive_accept(response.body.viewer, String(response.body.packet).hex_decode()).code == Transport.Code.OK
		await process_frame
	if not accepted:
		_fail("browser authenticated ACCEPT")
		return
	for frame: int in FRAMES:
		if frame == 20 and runtime.get("browser_fault") == "host-departure":
			await _depart_selected_host()
			return
		if frame == 20 and runtime.get("browser_fault") == "viewer-departure":
			if not await _wait(func() -> bool: return departure_observed, "paused exported viewer departure"):
				return
			resumed_frame = host_session.status().current_frame
			if publication.poll(_now()).code != Transport.Code.WRONG_STATE:
				_fail("departed browser publication still active")
				return
		if frame >= 3:
			host_session.receive_input(1, frame - 3, _input(frame - 3, 1))
		var inputs: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, frame, _input(frame, 0))]
		if host_driver.step(_now(), inputs).code != S.Code.OK:
			_fail("browser host step")
			return
		publication.poll(_now())
		await process_frame
	for frame: int in range(FRAMES - 3, FRAMES):
		host_session.receive_input(1, frame, _input(frame, 1))
	if host_driver.recover(_now()).code != S.Code.OK or host_game.canonical_bytes() != _expected(FRAMES):
		_fail("browser host canonical repair")
		return
	var departed: bool = runtime.get("browser_fault") == "viewer-departure"
	if departed and publication.poll(_now()).code != Transport.Code.WRONG_STATE:
		_fail("browser viewer departure kept publication live")
		return
	if not departed and publication.finish_host().code != Transport.Code.OK:
		_fail("browser host finish")
		return
	deadline = Time.get_ticks_usec() + 15000000
	var done: bool = false
	while not done and Time.get_ticks_usec() < deadline:
		if not departed:
			publication.poll(_now())
		response = await _http("/done", runtime.host_token)
		done = response.status == 200
		await process_frame
	if (
		done
		and not await _wait(
			func() -> bool: return not clients[0].get_spectators().any(func(info: RefCounted) -> bool: return info.id == viewer_uuid), "exported viewer socket teardown"
		)
	):
		return
	if not done or not errors.is_empty() or clients[0].get_players().size() != 2 or host_session.status().confirmed_frame != FRAMES - 1:
		_fail("browser final host audit")
		return
	completed = true
	print(
		"FORTRESS_BROWSER_HOST_RESULT ",
		JSON.stringify(
			{
				"passed": true,
				"frames": FRAMES,
				"host_rollbacks": host_session.statistics().rollback_count,
				"seated_players": clients[0].get_players().size(),
				"confirmed": host_session.status().confirmed_frame,
				"viewer_departure_observed": departure_observed,
				"host_frame_at_departure": physical_departure_frame,
				"host_resumed_frame": resumed_frame,
				"publication_stopped": departed and publication.status().code == Transport.Code.WRONG_STATE
			}
		)
	)
	_cleanup()
	quit(0)


func _depart_selected_host() -> void:
	for frame: int in range(17, 20):
		host_session.receive_input(1, frame, _input(frame, 1))
	if host_driver.recover(_now()).code != S.Code.OK or host_game.canonical_bytes() != _expected(20):
		_fail("departing host original canonical repair")
		return
	var response: Dictionary = {}
	var deadline: int = _now() + 15000000
	while _now() < deadline and errors.is_empty():
		publication.poll(_now())
		response = await _http("/paused", runtime.host_token)
		if response.status == 200:
			break
		await process_frame
	if response.get("status") != 200 or response.body.frame < 8 or response.body.buffered_rows < 2:
		_fail("host departure lacks exported buffered pause")
		return
	var paused_boundary: int = response.body.frame
	departure = "host"
	departure_started = true
	clients[0].close()
	if not await _wait(func() -> bool: return host_left_observed, "remote seated host departure"):
		return
	var stopped: bool = publication.poll(_now()).code == Transport.Code.WRONG_STATE
	if clients[0].get_connection_state() == Relay.CONNECTED or not stopped:
		_fail("selected host socket or publication stayed active")
		return
	deadline = _now() + 15000000
	while _now() < deadline and errors.is_empty():
		response = await _http("/done", runtime.host_token)
		if response.status == 200:
			break
		await process_frame
	for _drain: int in 3:
		await process_frame
	if response.status != 200 or not errors.is_empty() or host_game.canonical_bytes() != _expected(20):
		_fail("selected host departure final audit")
		return
	completed = true
	print("FORTRESS_BROWSER_HOST_RESULT ", JSON.stringify({
		"passed": true, "departure": "host", "frames": host_game.frame,
		"host_rollbacks": host_session.statistics().rollback_count,
		"confirmed": host_session.status().confirmed_frame, "socket_closed": clients[0].get_connection_state() != Relay.CONNECTED,
		"remote_host_departure_observed": host_left_observed, "publication_stopped": stopped,
		"viewer_paused_frame": paused_boundary
	}))
	_cleanup()
	quit(0)
