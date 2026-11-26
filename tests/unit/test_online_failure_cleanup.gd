extends RefCounted

# Value: protects=failed-room queue release; fails_when=SDK failure interrupts busy adapter detach; why_new=ordinary failure tests have no active transport callback
const Fixture = preload("res://tests/unit/test_online_example.gd")
const Lobby = preload("res://examples/online/lobby.gd")


class Client:
	extends Fixture.Client
	signal protocol_error(reason: String)
	signal server_error(message: String, code: int)
	signal signal_received(player: String, generation: String, payload: Variant)
	var control_inbox: Array[Array] = []
	var control_outbox: Array[Array] = []
	var closes: int = 0
	var close_reasons: Array[String] = []
	var attempts: int = 0
	var incoming: PackedByteArray = PackedByteArray()
	var relay_ref: WeakRef
	var accepted_received: int = 0
	var fail_send: bool = true
	var fail_poll: bool = false
	var polls: int = 0
	var departing_player: String = ""
	var queued_plan: RefCounted
	var plan_attempts: int = 0
	func poll() -> void:
		polls += 1
		var signals: Array[Array] = control_inbox.duplicate()
		control_inbox.clear()
		for packet: Array in signals:
			signal_received.emit(packet[0], packet[1], packet[2])
		if not departing_player.is_empty():
			var player: String = departing_player
			departing_player = ""
			player_left.emit(player)
		if queued_plan != null:
			var plan: RefCounted = queued_plan
			queued_plan = null
			plan_attempts += 1
			session_plan.emit(plan)
		if fail_poll:
			protocol_error.emit("queued peer departure")
	func get_room_code() -> String:
		return "ROOM01"
	func get_players() -> Array:
		return []
	func send_signal(player: String, generation: String, payload: Variant) -> Error:
		control_outbox.append([player, generation, payload])
		return OK
	func close(_code: int, reason: String) -> Error:
		closes += 1
		close_reasons.append(reason)
		return OK
	func send_game_data_binary(_bytes: PackedByteArray) -> Error:
		if not fail_send:
			return super.send_game_data_binary(_bytes)
		attempts += 1
		game_data_binary_received.emit(Fixture.V, 1, incoming)
		accepted_received = relay_ref.get_ref().status().received_packets
		protocol_error.emit("send failed")
		return ERR_INVALID_DATA


class BrowserMesh:
	extends Fixture.DirectFixture.FakeMesh
	var detach_calls: Array[bool] = []
	func poll() -> void:
		pass
	func detach() -> void:
		detach_calls.append(attached)
		super.detach()


func cases() -> PackedStringArray:
	return PackedStringArray(["relay_send_failure", "sdk_failure_deadline", "mesh_departure", "explicit_mesh_leave", "simultaneous_mesh_leave", "quiesced_departure_deadline"])


func _build(context: RefCounted, start_game: bool = true, local: String = Fixture.U, remote: String = Fixture.V) -> Dictionary:
	var lobby: Lobby = Lobby.new()
	var client: Client = Client.new()
	client.local = local
	var mesh: BrowserMesh = BrowserMesh.new()
	var transport: Fixture.MeshFixture.Transport = Fixture.MeshFixture.Transport.new()
	transport.local = local
	mesh.transport = transport
	var game: Fixture.Match = lobby.game_match
	context.equal(game.freeze(client, mesh, PackedStringArray([remote, local]), PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8])), OK, "real frozen room")
	var plan: Fixture.MembershipFixture.Plan = Fixture.MembershipFixture.Plan.new()
	plan.data.peers = [{"player_id": remote, "initiate": true}]
	client.session_plan.emit(plan)
	var config: Fixture.RelayFixture.SDKConfig = Fixture.RelayFixture.SDKConfig.new()
	config.max_buffered_bytes = 4096
	config.max_outbound_frame_bytes = 4096
	var info: Fixture.RelayFixture.Info = Fixture.RelayFixture.Info.new()
	if start_game:
		context.equal(game.start_transport(client, mesh, config, info, 0), OK, "real composed direct and relay adapters")
	lobby.client = client
	lobby.mesh = mesh
	lobby.state = "playing"
	lobby.has_readied = true
	client.protocol_error.connect(lobby._on_protocol_error)
	return {"lobby": lobby, "driver": game, "client": client, "mesh": mesh, "transport": transport, "config": config, "info": info}


func run_case(name: String, context: RefCounted) -> void:
	if name == "sdk_failure_deadline":
		_clock_failure(context)
		context.finish()
		return
	if name == "quiesced_departure_deadline":
		for code: int in [0, 1, 2, 3]:
			_quiesced_departure_deadline(context, code)
		_quiesced_departure_deadline(context, 0, true)
		context.finish()
		return
	if name == "simultaneous_mesh_leave":
		for first: int in 2:
			_simultaneous_mesh_leave(context, first)
		context.finish()
		return
	if name == "explicit_mesh_leave":
		for unavailable: bool in [false, true]:
			_explicit_mesh_leave(context, unavailable)
		context.finish()
		return
	if name == "mesh_departure":
		for initial_state: String in ["lobby", "starting", "playing"]:
			_mesh_departure(context, initial_state)
		context.finish()
		return
	var fixture: Dictionary = _build(context)
	var lobby: Lobby = fixture.lobby
	var client: Client = fixture.client
	var game: Fixture.Match = fixture.driver
	var transport: Fixture.MeshFixture.Transport = fixture.transport
	game.fallback.detach()
	# Configure the real coordinator before any work, with immediate relay fallback.
	var options: Fixture.Fallback.Options = Fixture.Fallback.Options.new()
	options.fallback_after_us = 0
	options.max_routes_per_poll = 1
	context.equal(game.fallback.configure(game.direct, game.relay, game.membership, game.adapter, game.peer, options), Fixture.Fallback.Code.OK, "real bounded fallback")
	transport.channel.buffered = 2000000
	var packets: Array[Fixture.Peer.Packet] = []
	for value: int in 2:
		packets.append(Fixture.Peer.Packet.new(game.membership.identity(Fixture.V), PackedByteArray([value + 1])))
	context.equal(game.fallback.enqueue_batch(packets), Fixture.Fallback.Code.OK, "own multiple packets across coordinator and relay")
	client.relay_ref = weakref(game.relay)
	client.incoming = Fixture.Match.Relay.Envelope.encode(game.membership.handshake_message().session_id, Fixture.V, Fixture.U, PackedByteArray([1]))
	lobby.tick(0, 0)
	context.equal(client.attempts, 1, "actual relay send enters synchronous SDK failure callback")
	context.equal(lobby.state, "failed", "callback terminates original lobby")
	context.equal(lobby.message, "SignalFish: send failed Leave, then create or join a fresh room.", "first SDK cause survives unwind")
	context.equal(game.fallback.status().pending_packets, 0, "coordinator releases packets after callback unwinds")
	context.equal(game.relay.status().pending_packets, 0, "relay releases refused send after callback unwinds")
	context.equal(client.accepted_received, 1, "actual addressed relay ingress accepted during send callback")
	context.equal(game.relay.status().received_packets, 0, "relay releases accepted ingress after callback unwinds")
	context.equal(client.is_connected("game_data_binary_received", game.relay._on_binary), false, "relay releases SDK callback after unwind")
	context.equal(game.has_started, false, "detached game remains stopped")
	var revision: int = game.adapter.status().lifetime_revision
	lobby.tick(1, 0)
	context.equal(client.attempts, 1, "terminal polling never retries gameplay")
	context.equal(game.adapter.status().lifetime_revision, revision, "completed cleanup does not repeatedly replace lifetime")
	lobby.disconnect_room()
	context.finish()


func _mesh_departure(context: RefCounted, initial_state: String) -> void:
	var fixture: Dictionary = _build(context, initial_state == "playing")
	var lobby: Lobby = fixture.lobby
	lobby.state = initial_state
	var client: Client = fixture.client
	var mesh: BrowserMesh = fixture.mesh
	var game: Fixture.Match = fixture.driver
	context.equal(mesh.attached, true, "the SDK mesh is attached during " + initial_state)
	context.equal(game.has_started, initial_state == "playing", "only the playing fixture has started transport")
	game.adapter.retain_mesh_on_player_departure = true
	game.adapter.mesh_departed.connect(lobby._on_mesh_departure)
	var outcomes: Array[Array] = []
	client.player_left.connect(func(_player: String) -> void:
		outcomes.append([lobby.state, game.has_started, game.adapter.status().route])
	)
	var detach_calls: Array[bool] = mesh.detach_calls
	var close_reasons: Array[String] = client.close_reasons
	client.departing_player = Fixture.V
	lobby.tick(0, 0)
	context.equal(outcomes, [["failed", false, "restart_required"]], "later SDK handlers see the stopped match")
	context.equal(lobby.state, "failed", "departure stops the lobby")
	context.equal(game.has_started, false, "departure stops gameplay immediately")
	context.equal(game.adapter.status().route, "restart_required", "departure revokes byte routing")
	context.equal(detach_calls.is_empty(), true, "departure keeps survivor mesh attached")
	context.equal(client.closes, 0, "departure does not cascade into a new socket close")
	var mesh_events: Array[Object] = []
	client.session_plan.connect(func(plan: Object) -> void: mesh_events.append(plan))
	client.queued_plan = Fixture.MembershipFixture.Plan.new()
	lobby.tick(1, 0)
	context.equal(client.polls, 2, "failed native mesh services the signaling socket")
	context.equal(client.plan_attempts, 1, "a later SDK plan reaches the polled client")
	context.equal(mesh_events.is_empty(), true, "the held mesh ignores later SDK plans")
	context.equal(client.attempts, 0, "terminal mesh performs no gameplay sends")
	lobby.disconnect_room()
	context.equal(detach_calls, [true], "Leave detaches the retained mesh before disposal")
	context.equal(close_reasons, ["Leaving example room"], "Leave closes the retained socket once")
	context.equal(lobby.state, "offline", "Leave returns to the lobby")


static func to_wire_string(code: int) -> String:
	return ["", "SIGNAL_RATE_LIMITED", "SIGNAL_TARGET_NOT_FOUND", "SIGNAL_TOO_LARGE"][code]


func _leave_fixture(context: RefCounted, local: String, remote: String) -> Dictionary:
	var fixture: Dictionary = _build(context, true, local, remote)
	var lobby: Lobby = fixture.lobby
	var client: Client = fixture.client
	lobby.backend = "native"
	lobby._sdk_error_codes = get_script()
	fixture.driver.adapter.retain_mesh_on_player_departure = true
	fixture.driver.adapter.mesh_departed.connect(lobby._on_mesh_departure)
	# Production connects the SDK callbacks before freeze. Use the same dispatcher here.
	lobby._callbacks = Lobby.Callbacks.new(lobby, lobby._connection_revision)
	client.signal_received.connect(lobby._callbacks.on_mesh_departure_signal)
	client.server_error.connect(lobby._callbacks.on_server_error)
	return fixture


# Delay the survivor's SDK poll past the initial Leave. A missing acknowledgment must time out once.
func _explicit_mesh_leave(context: RefCounted, unavailable: bool) -> void:
	var initiator: Dictionary = _leave_fixture(context, Fixture.U, Fixture.V)
	var survivor: Dictionary = _leave_fixture(context, Fixture.V, Fixture.U)
	var leaver: Lobby = initiator.lobby
	var remaining: Lobby = survivor.lobby
	var leaving_client: Client = initiator.client
	var remaining_client: Client = survivor.client
	var node: Node = Fixture.Scene.instantiate()
	node.set("controller", leaver)
	node.call("_ready")
	var detach_calls: Array[bool] = initiator.mesh.detach_calls
	var close_reasons: Array[String] = leaving_client.close_reasons
	var controls: Array[Array] = leaving_client.control_outbox
	node.call("_leave")
	var room_code: LineEdit = node.get("room_code")
	context.equal(room_code.text, "", "Leave clears the old room code while waiting for the SDK")
	context.equal(leaver.game_match.has_started, false, "Leave stops the leaver's gameplay immediately")
	context.equal(detach_calls, [], "Leave holds reciprocal RTC connections while the survivor can still send")
	context.equal(close_reasons, [], "Leave holds the SDK socket during quiescence")
	context.equal(controls.size(), 1, "Leave sends one addressed prepare to the frozen survivor")
	if controls.size() != 1:
		remaining.disconnect_room()
		node.free()
		return
	var start: int = leaver._departure_started_us
	var deadline: int = start + Lobby.MESH_LEAVE_WAIT_US
	var prepare: Array = controls[0]
	context.equal(prepare[0], Fixture.V, "prepare uses the remote UUID")
	node.call("_leave")
	context.equal(controls.size(), 1, "duplicate Leave neither closes nor resends")
	leaving_client.control_inbox.append([Fixture.V, "stale", {"fortress_mesh_departure_v1": "quiesced"}])
	leaving_client.control_inbox.append([Fixture.ROOM, prepare[1], {"fortress_mesh_departure_v1": "quiesced"}])
	leaving_client.fail_poll = unavailable
	leaver.tick(deadline - 1, 0)
	context.equal(close_reasons, [], "stale or foreign ACKs and failed signaling cannot end the wait early")
	context.equal(remaining.game_match.has_started, true, "delayed survivor is still sending until its prepare runs")
	if unavailable:
		leaver.tick(deadline, 0)
		context.equal(remaining_client.control_outbox, [], "unavailable survivor produced no acknowledgment")
	else:
		remaining_client.control_inbox.append([Fixture.U, prepare[1], prepare[2]])
		remaining.tick(deadline - 1, 0)
		context.equal(remaining.game_match.has_started, false, "survivor stops gameplay before acknowledgment")
		context.equal(survivor.mesh.detach_calls, [], "prepare retains survivor links for real SDK removal")
		context.equal(remaining_client.close_reasons, [], "prepare retains survivor signaling")
		context.equal(remaining_client.control_outbox.size(), 1, "survivor acknowledges the validated prepare")
		if remaining_client.control_outbox.size() == 1:
			var reply: Array = remaining_client.control_outbox[0]
			leaving_client.control_inbox.append([Fixture.V, reply[1], reply[2]])
			leaver.tick(deadline - 1, 0)
		remaining_client.departing_player = Fixture.U
		remaining.tick(deadline, 0)
		context.equal(remaining.state, "failed", "real SDK departure completes the survivor's stop")
		context.equal(survivor.mesh.detach_calls, [], "SDK departure retains unrelated survivor connections")
	context.equal(leaver.state, "offline", "Leave completes after acknowledgment or timeout")
	context.equal(detach_calls, [true], "Leave detaches once after quiescence settles")
	context.equal(close_reasons, ["Leaving example room"], "Leave closes the original SDK socket once")
	leaver.tick(deadline + 1, 0)
	context.equal(close_reasons.size(), 1, "late service cannot close the disposed socket again")
	remaining.disconnect_room()
	node.free()


func _quiesced_departure_deadline(context: RefCounted, code: int, timely_departure: bool = false) -> void:
	var fixture: Dictionary = _leave_fixture(context, Fixture.V, Fixture.U)
	var lobby: Lobby = fixture.lobby
	var client: Client = fixture.client
	var mesh: BrowserMesh = fixture.mesh
	var started: int = 100
	var cutoff: int = started + 3_000_000
	var prepare: Array = [Fixture.U, lobby.game_match.adapter.status().generation, {Lobby.MESH_DEPARTURE_SIGNAL: "prepare"}]
	client.control_inbox.append(prepare)
	lobby.tick(started, 0)
	context.equal(lobby.state, "quiesced", "prepare waits for the SDK departure")
	context.equal(client.control_outbox.size(), 1, "survivor submits its acknowledgment")
	if code > 0:
		client.server_error.emit("SignalFish signal refused", code)
	if timely_departure:
		client.departing_player = Fixture.U
		lobby.tick(cutoff, 0)
		context.equal(lobby.state, "failed", "queued PlayerLeft wins at the cutoff and completes the normal survivor stop")
		context.equal(mesh.detach_calls, [], "timely SDK departure retains remaining links beyond the cutoff")
		context.equal(client.close_reasons, [], "timely SDK departure retains signaling until explicit Leave")
		lobby.disconnect_room()
		return
	if code == 3:
		context.equal(lobby.state, "failed", "an unrelated signaling error immediately fails the room")
	else:
		client.control_inbox.append(prepare)
		lobby.tick(cutoff - 1, 0)
		context.equal(lobby.state, "quiesced", "acknowledgment success or ordinary refusal waits for real departure until cutoff")
		context.equal(client.close_reasons, [], "survivor keeps signaling attached through the delivery allowance")
		context.equal(client.control_outbox.size(), 1, "duplicate prepare does not repeat acknowledgment")
		lobby.tick(cutoff, 0)
		context.equal(lobby.state, "failed", "missing PlayerLeft fails and releases the survivor at the exact cutoff")
		var timeout_cause: String = lobby.message
		context.equal(timeout_cause.begins_with("SignalFish did not confirm"), true, "failure identifies the absent confirmation")
		client.departing_player = Fixture.U
		lobby.tick(cutoff + 1, 0)
		context.equal(client.departing_player, "", "failed socket service consumes the late event")
		context.equal(lobby.message, timeout_cause, "late PlayerLeft cannot change the timeout cause")
	context.equal(mesh.detach_calls, [true], "terminal survivor releases the SDK mesh once")
	context.equal(client.close_reasons, ["Online example failed"], "terminal survivor closes its SDK socket once")
	lobby.disconnect_room()


func _simultaneous_mesh_leave(context: RefCounted, first: int) -> void:
	var fixtures: Array[Dictionary] = [_leave_fixture(context, Fixture.U, Fixture.V), _leave_fixture(context, Fixture.V, Fixture.U)]
	var ordered: Array[Dictionary] = [fixtures[first], fixtures[1 - first]]
	var clients: Array[Client] = [ordered[0].client, ordered[1].client]
	var lobbies: Array[Lobby] = [ordered[0].lobby, ordered[1].lobby]
	var closes: Array[Array] = [clients[0].close_reasons, clients[1].close_reasons]
	for lobby: Lobby in lobbies:
		lobby.leave(10)
	for index: int in 2:
		var prepare: Array = clients[1 - index].control_outbox[0]
		clients[index].control_inbox.append([clients[1 - index].local, prepare[1], prepare[2]])
		lobbies[index].tick(11, 0)
		context.equal(lobbies[index].game_match.has_started, false, "simultaneous Leave quiesces locally before acknowledging")
		context.equal(closes[index], [], "sending an ACK cannot close before receiving the reciprocal ACK")
		context.equal(clients[index].control_outbox.size(), 2, "a leaving player acknowledges the other leaver")
	var first_uuid: String = clients[0].local
	var reply_to_second: Array = clients[0].control_outbox[1]
	var reply_to_first: Array = clients[1].control_outbox[1]
	clients[0].control_inbox.append([clients[1].local, reply_to_first[1], reply_to_first[2]])
	lobbies[0].tick(12, 0)
	context.equal(lobbies[0].state, "offline", "first poll closes once the reciprocal ACK arrives")
	clients[1].player_left.emit(first_uuid)
	context.equal(lobbies[1].state, "leaving", "SDK removal of the first leaver keeps the second close pending")
	clients[1].control_inbox.append([first_uuid, reply_to_second[1], reply_to_second[2]])
	lobbies[1].tick(12, 0)
	context.equal(lobbies[1].state, "offline", "second poll still services the reciprocal ACK after SDK removal")
	context.equal(closes, [["Leaving example room"], ["Leaving example room"]], "both sockets close once in either poll order")


# Value: protects=elapsed liveness before SDK departures; fails_when=queued SDK failure skips overdue protocol polling; why_new=direct Match expiry has no SDK poll callback
func _clock_failure(context: RefCounted) -> void:
	var helper: RefCounted = Fixture.new()
	for offset: int in [0, 1]:
		var fixture: Dictionary = _build(context)
		var fixtures: Array[Dictionary] = [fixture, helper._fixture(context, Fixture.V)]
		var client: Client = fixture.client
		client.fail_send = false
		for round_index: int in 100:
			for item: Dictionary in fixtures:
				item.driver.tick(round_index * 16667, 0)
			helper._deliver(fixtures)
		var game: Fixture.Match = fixture.driver
		context.equal(game.peer.network_status().state, "running", "real peers synchronize before SDK departure deadline")
		var endpoint: Dictionary = game.peer.network_status().peers.values()[0]
		var resume: int = endpoint.last_recv_us + 2000000 + offset
		var frame: int = game.peer.status().current_frame
		var buffered: int = fixture.transport.incoming.size()
		context.equal(buffered > 0, true, "actual valid remote packets wait across suspended service")
		var lobby: Lobby = fixture.lobby
		lobby._epoch = 5000000
		lobby._last_now = lobby._epoch + game._last_now
		client.fail_poll = true
		lobby.tick(lobby._epoch + resume, 0)
		context.equal(lobby._last_now, lobby._epoch + resume, "host clock keeps full elapsed resume")
		context.equal(game.peer.network_status().last_now_us, resume, "protocol clock consumes exact full elapsed time before SDK callbacks")
		context.equal(client.polls, 1 if offset == 0 else 0, "only unexpired boundary services queued SDK departure")
		context.equal(game.peer.status().current_frame, frame, "deadline adjudication and SDK departure never advance gameplay")
		context.equal(fixture.transport.incoming.size(), buffered, "deadline preflight never consumes buffered gameplay")
		context.equal(lobby.state, "failed", "expiry or SDK departure preserves terminal room outcome")
		if offset == 0:
			context.equal(lobby.message, "SignalFish: queued peer departure Leave, then create or join a fresh room.", "exact boundary preserves SDK cause")
		else:
			context.equal(game.failure.is_empty(), false, "overdue expiry is resolved before queued departure")
		lobby.disconnect_room()
		fixtures[1].driver.detach()
		fixtures[1].client.free()
		fixtures[1].mesh.free()
