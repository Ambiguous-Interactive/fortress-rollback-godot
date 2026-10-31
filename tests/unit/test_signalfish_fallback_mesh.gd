extends RefCounted

# Value: protects=mixed transport correction and restoration; fails_when=overlap changes confirmed history or blocked links stop healthy links; seam=real three-peer sessions
const F = preload("res://addons/fortress_rollback/transport/signalfish_fallback.gd")
const U = preload("res://tests/unit/test_signalfish_fallback.gd")
const M = preload("res://tests/unit/test_signalfish_membership.gd")
const D = preload("res://tests/unit/test_signalfish_webrtc.gd")
const R = preload("res://tests/unit/test_signalfish_relay.gd")
const Direct = preload("res://addons/fortress_rollback/transport/signalfish_webrtc.gd")
const Relay = preload("res://addons/fortress_rollback/transport/signalfish_relay.gd")
const P = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const E = preload("res://addons/fortress_rollback/transport/signalfish_relay_envelope.gd")
const Reference = preload("res://tests/oracle/reference_game.gd")
const ROSTER: PackedStringArray = [M.U, M.V, M.W]


func cases() -> PackedStringArray:
	return PackedStringArray(["mixed_restore"])


func run_case(_name: String, context: RefCounted) -> void:
	var baseline: PackedByteArray = _exercise(context, false)
	var switched: PackedByteArray = _exercise(context, true)
	context.bytes_equal(switched, baseline, 20, "fallback and overlap match canonical direct baseline")
	context.state(20, switched)
	context.finish()


func _build(context: RefCounted, index: int, replay_frames: int = 0, client_override: Client = null) -> Dictionary:
	var helper: RefCounted = M.new()
	var membership: RefCounted = helper._membership(context, ROSTER[index], ROSTER)
	var config: M.C = M.C.new()
	config.player_count = 3
	config.sync_test = false
	config.check_distance = 0
	config.input_width = 4
	config.neutral_input = PackedByteArray([0, 0, 0, 0])
	config.max_snapshot_bytes = 24
	config.replay_max_frames = replay_frames
	config.storage_budget_bytes = 1048576
	var game: M.Game = M.Game.new(3)
	var handshake: M.H.Options = M.H.Options.new()
	handshake.roundtrips = 1
	var lifecycle: M.L.Options = M.L.Options.new()
	lifecycle.enabled = false
	var peer: P = P.new()
	context.equal(membership.configure_peer(peer, config, game, handshake, M.I.Options.new(), lifecycle), F.Code.OK, "configure real mesh peer")
	var tokens: Array[PackedByteArray] = [helper._bytes(33, 16), helper._bytes(34, 16)]
	context.equal(peer.begin(0, tokens), F.Code.OK, "begin real mesh peer")
	var client: Client = Client.new() if client_override == null else client_override
	client.local = ROSTER[index]
	var transport: Transport = Transport.new()
	transport.local = ROSTER[index]
	var mesh: D.FakeMesh = D.FakeMesh.new()
	mesh.transport = transport
	var adapter: M.A = M.A.new()
	context.equal(adapter.attach(client, mesh, membership), OK, "attach mesh SDK")
	var plan: M.Plan = M.Plan.new()
	plan.data.peers.clear()
	for uuid: String in ROSTER:
		if uuid != client.local:
			plan.data.peers.append({"player_id": uuid, "initiate": client.local < uuid})
	client.session_plan.emit(plan)
	var sdk_config: R.SDKConfig = R.SDKConfig.new()
	var info: R.Info = R.Info.new()
	var relay_options: Relay.Options = Relay.Options.new()
	relay_options.max_packet_bytes = 512
	var relay: Relay = Relay.new()
	context.equal(relay.configure(client, sdk_config, info, membership, adapter, peer, relay_options), F.Code.OK, "configure standby relay")
	var direct_options: Direct.Options = Direct.Options.new()
	direct_options.max_packet_bytes = 512
	var direct: Direct = Direct.new()
	context.equal(direct.configure(mesh, membership, adapter, peer, direct_options), F.Code.OK, "configure direct")
	var options: F.Options = F.Options.new()
	options.fallback_after_us = 20
	options.restore_after_us = 10
	var fallback: F = F.new()
	context.equal(fallback.configure(direct, relay, membership, adapter, peer, options), F.Code.OK, "configure mixed coordinator")
	return {
		"fallback": fallback,
		"direct": direct,
		"relay": relay,
		"membership": membership,
		"peer": peer,
		"game": game,
		"client": client,
		"mesh": mesh,
		"adapter": adapter,
		"config": sdk_config,
		"info": info,
		"transport": transport,
		"confirmed": -1,
		"loads": 0,
		"fault_loads": 0,
		"comparisons": 0,
		"saved": {},
		"fault_comparisons": 0,
		"session_id": membership.handshake_message().session_id
	}


func _exercise(context: RefCounted, switch_paths: bool) -> PackedByteArray:
	var fixtures: Array[Dictionary] = []
	for index: int in 3:
		fixtures.append(_build(context, index))
	var now: int = 0
	for _round: int in 12:
		_service(context, fixtures, now, switch_paths)
		now += 1
	for fixture: Dictionary in fixtures:
		context.equal(fixture.peer.network_status().state, "running", "actual mesh synchronized")
	var prefixes: Array[PackedByteArray] = _prefixes(context)
	var saw_mixed: bool = false
	var saw_restored: bool = false
	var sends_before_restore: int = 0
	for frame: int in 20:
		if switch_paths and frame == 3:
			fixtures[0].transport.blocked[M.M.uuid_to_peer_id(M.V)] = true
			fixtures[1].transport.blocked[M.M.uuid_to_peer_id(M.U)] = true
		if frame == 10:
			sends_before_restore = fixtures[0].transport.direct_sends.get(M.M.uuid_to_peer_id(M.V), 0)
			fixtures[0].transport.blocked.clear()
			fixtures[1].transport.blocked.clear()
		for index: int in 3:
			var fixture: Dictionary = fixtures[index]
			var inputs: Array[Driver.LocalInput] = [Driver.LocalInput.new(index, frame, _sample(index, frame))]
			var result: Driver.StepResult = fixture.peer.step(now, inputs)
			context.equal(result.code, 0, "real game advances exactly once")
			context.equal(result.frame_before, frame, "transport switch preserves original simulation frame")
			context.equal(result.frame_after, frame + 1, "transport switch never restarts or skips simulation")
			for request: Dictionary in fixture.game.requests:
				if request.kind == "load":
					fixture.loads += 1
					if frame >= 3 and frame < 10:
						fixture.fault_loads += 1
				if request.kind == "save":
					fixture.saved[request.frame] = request.state_bytes.hex_decode()
			for saved_frame: int in fixture.saved:
				if saved_frame > 0 and saved_frame <= frame and saved_frame <= fixture.peer.status().confirmed_frame + 1:
					context.bytes_equal(fixture.saved[saved_frame], prefixes[saved_frame], saved_frame, "corrected confirmed prefix uses original input log")
					fixture.comparisons += 1
					if frame >= 3 and frame < 10 and saved_frame >= 4:
						fixture.fault_comparisons += 1
			fixture.game.requests.clear()
		for _round: int in 8:
			_service(context, fixtures, now, switch_paths)
			now += 1
		var routes: Array = fixtures[0].fallback.status().relay_peers
		if frame >= 6 and frame < 10 and switch_paths:
			saw_mixed = saw_mixed or (routes == [M.V] and fixtures[2].fallback.status().relay_peers.is_empty())
		if frame >= 14 and routes.is_empty():
			saw_restored = true
	if switch_paths:
		context.equal(saw_mixed, true, "failed link relays while third peer stays direct")
		context.equal(saw_restored, true, "same session restores direct after relay drains")
		context.equal(fixtures[0].transport.direct_sends.get(M.M.uuid_to_peer_id(M.V), 0) > sends_before_restore, true, "actual direct output resumes after channel recovery")
		context.equal(fixtures[0].transport.relay_deliveries > 0, true, "relay packets reached actual endpoints")
		context.equal(fixtures[0].transport.direct_deliveries > 0, true, "direct packets reached actual endpoints")
	var canonical: PackedByteArray = prefixes[20]
	for fixture: Dictionary in fixtures:
		context.equal(fixture.loads > 0, true, "every peer performed actual snapshot restoration")
		context.equal(fixture.comparisons > 0, true, "every peer compared corrected confirmed prefixes")
		if switch_paths:
			context.equal(fixture.fault_comparisons > 0, true, "confirmed canonical prefixes compared while fault remains active")
			context.equal(fixture.fault_loads > 0, true, "actual rollback repairs gameplay while fallback fault remains active")
			context.equal(fixture.transport.duplicates > 0, true, "identical valid bytes overlap on direct and relay")
		context.bytes_equal(fixture.membership.handshake_message().session_id, fixture.session_id, 20, "fallback preserves frozen rollback lifetime")
		context.equal(fixture.peer.status().current_frame, 20, "same session retains full completed history")
		context.equal(fixture.peer.status().confirmed_frame >= 18, true, "remote receipt confirms advanced history")
		context.bytes_equal(fixture.game.game.bytes(), canonical, 20, "all actual games converge")
		U.new().destroy(fixture)
	return canonical


func _service(context: RefCounted, fixtures: Array[Dictionary], now: int, overlap: bool) -> void:
	for fixture: Dictionary in fixtures:
		context.equal(fixture.peer.poll(now), 0, "service actual peer protocol")
		var packets: Array[P.Packet] = fixture.peer.drain_outbox()
		context.equal((fixture.fallback as F).enqueue_batch(packets), F.Code.OK, "handoff actual protocol batch")
		var result: F.Result = fixture.fallback.poll(now)
		context.equal(result.code in [F.Code.OK, F.Code.BACKPRESSURE], true, "bounded composed transport service")
	for fixture: Dictionary in fixtures:
		var confirmed: int = fixture.peer.status().confirmed_frame
		context.equal(confirmed >= fixture.confirmed, true, "confirmation never regresses across route switches")
		for endpoint: Dictionary in fixture.peer.network_status().peers.values():
			context.equal(confirmed <= endpoint.last_received_frame, true, "confirmation cannot invent actual remote receipt")
		fixture.confirmed = confirmed
		fixture.peer.drain_events()
		fixture.peer.drain_transitions()
	for fixture: Dictionary in fixtures:
		var source: String = fixture.client.local
		for packet: Dictionary in fixture.transport.routed:
			for target: Dictionary in fixtures:
				if M.M.uuid_to_peer_id(target.client.local) == packet.target:
					_deliver(target, source, packet.bytes, false, overlap)
		fixture.transport.routed.clear()
		for envelope: PackedByteArray in fixture.client.sent:
			var decoded: E.Decoded = E.decode(envelope, 512)
			for target: Dictionary in fixtures:
				if target.client.local == decoded.recipient:
					_deliver(target, source, decoded.payload, true, overlap)
		fixture.client.sent.clear()


func _deliver(target: Dictionary, source: String, bytes: PackedByteArray, relay: bool, overlap: bool) -> void:
	if overlap:
		target.transport.duplicates += 1
	if not relay or overlap:
		target.transport.incoming.append({"source": M.M.uuid_to_peer_id(source), "channel": 0, "mode": 0, "bytes": bytes.duplicate()})
		target.transport.direct_deliveries += 1
	if relay or overlap:
		var envelope: PackedByteArray = E.encode(target.membership.handshake_message().session_id, source, target.client.local, bytes)
		target.client.game_data_binary_received.emit(source, 1, envelope)
		target.transport.relay_deliveries += 1


func _sample(player: int, frame: int) -> PackedByteArray:
	# The final repeated sample makes its prediction canonical without an extra game tick.
	return PackedByteArray([mini(frame, 18) + player + 1, 0, 0, 0])


func _prefixes(context: RefCounted) -> Array[PackedByteArray]:
	var game: RefCounted = Reference.new(3, 2)
	var result: Array[PackedByteArray] = [game.bytes()]
	for frame: int in 20:
		var inputs: Array[Dictionary] = []
		for player: int in 3:
			inputs.append({"player": player, "bytes": _sample(player, frame).hex_encode(), "status": "confirmed"})
		context.equal(game.advance(inputs), "", "independent original-input replay")
		result.append(game.bytes())
	return result


class Client:
	extends R.Client
	var local: String = ""

	func get_player_id() -> String:
		return local


class Transport:
	extends D.Transport
	var local: String = ""
	var blocked: Dictionary = {}
	var routed: Array[Dictionary] = []
	var direct_deliveries: int = 0
	var relay_deliveries: int = 0
	var duplicates: int = 0
	var direct_sends: Dictionary = {}

	func get_unique_id() -> int:
		return M.M.uuid_to_peer_id(local)

	func get_peer(id: int) -> Dictionary:
		return {"connected": not blocked.has(id), "channels": [channel, channel, channel]}

	func put_packet(bytes: PackedByteArray) -> Error:
		direct_sends[target] = int(direct_sends.get(target, 0)) + 1
		routed.append({"target": target, "bytes": bytes.duplicate()})
		return OK
