extends RefCounted

# Value: protects=frozen UUID membership and negotiated startup; fails_when=collisions alias or mismatched peers run; why_new=optional SDK seam; seam=SDK objects
const M = preload("res://addons/fortress_rollback/transport/signalfish_membership.gd")
const A = preload("res://addons/fortress_rollback/transport/signalfish_adapter.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const P = preload("res://addons/fortress_rollback/core/peer_session.gd")
const C = preload("res://addons/fortress_rollback/core/config.gd")
const H = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const L = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")
const Game = preload("res://tests/oracle/p2p_game.gd")
const U: String = "00000000-0000-0000-0000-000000000001"
const V: String = "00000000-0000-0000-0000-000000000002"
const W: String = "00000000-0000-0000-0000-000000000003"


func cases() -> PackedStringArray:
	return PackedStringArray(["ownership", "collision", "negotiation", "mismatch", "attribution", "plans", "lifecycle", "meshes"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"ownership":
			_ownership(context)
		"collision":
			_collision(context)
		"negotiation":
			_negotiate(context, "")
		"mismatch":
			for field: String in ["fps", "input_format", "roster", "snapshot_format"]:
				_negotiate(context, field)
		"attribution":
			_attribution(context)
		"plans":
			_plans(context)
		"lifecycle":
			_lifecycle(context)
		"meshes":
			_meshes(context)
	context.finish()


func _membership(context: RefCounted, local: String, roster: PackedStringArray, mismatch: String = "") -> M:
	var profile: T.Config = T.Config.new()
	profile.player_count = roster.size()
	profile.input_width = 4
	profile.neutral_input = PackedByteArray([0, 0, 0, 0])
	if mismatch in ["fps", "input_format", "snapshot_format"]:
		profile.set(mismatch, profile.get(mismatch) + 1)
	var membership: M = M.new()
	context.equal(membership.configure(local, roster, _bytes(7, 16), _bytes(1 if local == U else 2, 8), profile), OK, "membership configure")
	return membership


func _ownership(context: RefCounted) -> void:
	var roster: PackedStringArray = PackedStringArray([V, U])
	var membership: M = _membership(context, U, roster)
	var other: M = _membership(context, V, PackedStringArray([U, V]))
	context.equal(membership.handshake_message().config_digest, other.handshake_message().config_digest, "order independent full roster digest")
	context.equal(membership.handshake_message().config.roster, other.handshake_message().config.roster, "canonical core roster")
	context.equal(membership.handshake_message().config_digest.hex_encode(), "cee2305a945aa10e", "independent Python SHA256 full-roster/config golden")
	context.equal(membership.slot(U), 0, "stable UUID order")
	roster[0] = W
	var exposed: T.Message = membership.handshake_message()
	exposed.config.roster[0][0] ^= 255
	exposed.config.neutral_input[0] = 9
	exposed.config_digest[0] ^= 255
	context.equal(membership.handshake_message().config_digest, other.handshake_message().config_digest, "owned handshake digest")
	context.equal(membership.handshake_message().config.roster, other.handshake_message().config.roster, "owned nested roster")
	context.equal(membership.configure(U, PackedStringArray([U, W]), _bytes(9, 16), _bytes(1, 8), T.Config.new()), ERR_ALREADY_IN_USE, "active membership immutable")


func _collision(context: RefCounted) -> void:
	var first: String = "4afb61dd-c090-dd2c-6bc6-5eaf3da7eb69"
	var second: String = "47a5d0e7-f0f0-053e-880f-5fb4defc9ecf"
	context.equal(M.uuid_to_peer_id(first), 1697314605, "independent FNV collision fixture")
	context.equal(M.uuid_to_peer_id(second), 1697314605, "second collision fixture")
	var invalid: Array[PackedStringArray] = [
		PackedStringArray([first, second]), PackedStringArray([U, U]),
		PackedStringArray([U, "00000000-0000-0000-0000-00000000000A"]), PackedStringArray([U, "bad"])
	]
	for roster: PackedStringArray in invalid:
		var membership: M = M.new()
		context.equal(membership.configure(roster[0], roster, _bytes(7, 16), _bytes(1, 8), T.Config.new()) != OK, true, "reject alias or malformed roster")
		context.equal(membership.handshake_message(), null, "failure leaves unconfigured")


func _peer(context: RefCounted, membership: M) -> P:
	var config: C = C.new()
	config.player_count = membership.roster().size()
	config.sync_test = false
	config.check_distance = 0
	config.input_width = 4
	config.neutral_input = PackedByteArray([0, 0, 0, 0])
	config.max_snapshot_bytes = (config.player_count + 3) * 4
	config.storage_budget_bytes = 1048576
	var handshake: H.Options = H.Options.new()
	handshake.roundtrips = 1
	var lifecycle: L.Options = L.Options.new()
	lifecycle.enabled = false
	var peer: P = P.new()
	context.equal(membership.configure_peer(peer, config, Game.new(config.player_count), handshake, I.Options.new(), lifecycle), I.Code.OK, "actual peer configured")
	context.equal(config.local_players, PackedInt32Array([0, 1]), "caller config unchanged")
	var tokens: Array[PackedByteArray] = []
	for index: int in peer.peer_ids().size():
		tokens.append(_bytes(33 + index, 16))
	context.equal(peer.begin(0, tokens), I.Code.OK, "actual startup")
	return peer


func _negotiate(context: RefCounted, mismatch: String) -> void:
	var left: M = _membership(context, U, PackedStringArray([V, U]))
	var right_roster: PackedStringArray = PackedStringArray([U, W if mismatch == "roster" else V])
	var right_uuid: String = right_roster[1]
	var right: M = _membership(context, right_uuid, right_roster, mismatch)
	var first: P = _peer(context, left)
	var second: P = _peer(context, right)
	if not mismatch.is_empty():
		var left_request: PackedByteArray = first.drain_outbox()[0].bytes
		var right_request: PackedByteArray = second.drain_outbox()[0].bytes
		context.equal(right.receive(second, left_request, U, 0), I.Code.OK, "request decoded at config comparison")
		context.equal(left.receive(first, right_request, right_uuid, 0), I.Code.WRONG_SOURCE if mismatch == "roster" else I.Code.OK, "known identity attribution boundary")
		var right_status: Dictionary = second.network_status().peers.values()[0].handshake
		context.equal(right_status.mismatch.field, "roster" if mismatch == "roster" else mismatch, "specific configuration disagreement")
		context.equal(first.network_status().state, "synchronizing" if mismatch == "roster" else "terminated", "mismatch prevents first peer startup")
		context.equal(second.network_status().state, "terminated", "mismatch prevents second peer startup")
		return
	for tick: int in 6:
		for packet: P.Packet in first.drain_outbox():

			var result: int = right.receive(second, packet.bytes, U, tick)
			context.equal(result == I.Code.OK, true, "right receives attributed startup")
		for packet: P.Packet in second.drain_outbox():
			var result: int = left.receive(first, packet.bytes, right_uuid, tick)
			context.equal(result == I.Code.OK, true, "left receives attributed startup")
	context.equal(first.network_status().state == "running", mismatch.is_empty(), "startup requires all dimensions agree")
	context.equal(second.network_status().state == "running", mismatch.is_empty(), "both peers gate startup")


func _attribution(context: RefCounted) -> void:
	var left: M = _membership(context, U, PackedStringArray([U, V]))
	var right: M = _membership(context, V, PackedStringArray([U, V]))
	var first: P = _peer(context, left)
	var second: P = _peer(context, right)
	var packet: PackedByteArray = second.drain_outbox()[0].bytes
	context.equal(left.receive(first, packet, W, 0), I.Code.WRONG_SOURCE, "unknown full UUID")
	context.equal(left.receive(first, packet, U, 0), I.Code.WRONG_SOURCE, "self attribution")
	packet[8] ^= 1
	context.equal(left.receive(first, packet, V, 0), I.Code.WRONG_SOURCE, "old session identity rejected by endpoint")
	context.equal(first.network_status().state, "synchronizing", "invalid packet cannot start")


func _plans(context: RefCounted) -> void:
	var membership: M = _membership(context, U, PackedStringArray([U, V]))
	var client: FakeClient = FakeClient.new()
	var mesh: FakeMesh = FakeMesh.new()
	var adapter: A = A.new()
	context.equal(adapter.attach(client, mesh, membership), OK, "optional public SDK seam")
	var plan: Plan = Plan.new()
	client.session_plan.emit(plan)
	context.equal(adapter.status().route, "mesh", "mesh selected")
	context.equal(adapter.status().offerers[V], false, "server role preserved")
	plan.data.generation = W
	plan.data.peers[0].initiate = true
	client.session_plan.emit(plan)
	context.equal(adapter.status().generation, W, "opaque replacement generation")
	context.equal(adapter.status().offerers[V], true, "replacement role")
	context.equal(membership.slot(V), 1, "plan never renumbers slots")
	plan.data.topology = "host"
	client.session_plan.emit(plan)
	context.equal(adapter.status().route, "relay_required", "unsupported topology explicitly falls back")
	context.equal(mesh.attached, false, "unsupported mesh detached before consumption")
	plan.data.topology = "mesh"
	client.session_plan.emit(plan)
	context.equal(adapter.status().route, "restart_required", "mesh restoration requires restart")
	context.equal(mesh.attached, false, "unsafe synthetic plan replay forbidden")
	plan.data.peers[0].player_id = W
	client.session_plan.emit(plan)
	context.equal(adapter.status().route, "restart_required", "restart fence remains closed")
	adapter.detach()
	client.free()
	mesh.free()


func _lifecycle(context: RefCounted) -> void:
	for signal_name: String in ["room_left", "disconnected", "connection_failed", "reconnected", "room_joined", "player_left", "player_joined"]:
		var membership: M = _membership(context, U, PackedStringArray([U, V]))
		var client: FakeClient = FakeClient.new()
		var mesh: FakeMesh = FakeMesh.new()
		var adapter: A = A.new()
		context.equal(adapter.attach(client, mesh, membership), OK, "lifecycle attachment")
		client.session_plan.emit(Plan.new())
		client.emit_signal(signal_name)
		context.equal(adapter.status().route, "restart_required", "SDK lifetime change blocks ingress")
		client.session_plan.emit(Plan.new())
		context.equal(adapter.status().route, "restart_required", "late plan cannot resume old lifetime")
		context.equal(adapter.receive_mesh(null, PackedByteArray(), M.uuid_to_peer_id(V), 0), I.Code.WRONG_STATE, "mesh ingress fenced")
		context.equal(adapter.receive_relay(null, PackedByteArray(), V, 0), I.Code.WRONG_STATE, "relay ingress fenced")
		adapter.detach()
		client.free()
		mesh.free()
	for freed: String in ["client", "mesh"]:
		var membership: M = _membership(context, U, PackedStringArray([U, V]))
		var client: FakeClient = FakeClient.new()
		var mesh: FakeMesh = FakeMesh.new()
		var adapter: A = A.new()
		context.equal(adapter.attach(client, mesh, membership), OK, "owned Node lifetime setup")
		client.session_plan.emit(Plan.new())
		if freed == "client":
			client.free()
		else:
			mesh.free()
		context.equal(adapter.status().route, "restart_required", "freed SDK Node blocks ingress")
		context.equal(adapter.receive_mesh(null, PackedByteArray(), M.uuid_to_peer_id(V), 0), I.Code.WRONG_STATE, "freed Node cannot attribute traffic")
		adapter.detach()
		if is_instance_valid(client):
			client.free()
		if is_instance_valid(mesh):
			mesh.free()


func _meshes(context: RefCounted) -> void:
	for count: int in range(2, 9):
		var roster: PackedStringArray = PackedStringArray()
		for index: int in count:
			roster.append("00000000-0000-0000-0000-%012x" % (index + 1))
		var memberships: Array[M] = []
		var peers: Array[P] = []
		for index: int in count:
			var reordered: PackedStringArray = roster.duplicate()
			if index % 2 == 1:
				reordered.reverse()
			var membership: M = _membership(context, roster[index], reordered)
			memberships.append(membership)
			peers.append(_peer(context, membership))
			context.equal(membership.slot(roster[index]), index, "all supported player slots")
		for tick: int in 6:
			for sender: int in count:
				for packet: P.Packet in peers[sender].drain_outbox():
					for recipient: int in count:
						if memberships[recipient].identity(roster[recipient]) == packet.to:
							context.equal(memberships[recipient].receive(peers[recipient], packet.bytes, roster[sender], tick), I.Code.OK, "full mesh attributed negotiation")
		for index: int in count:
			context.equal(peers[index].network_status().state, "running", "every peer agrees at supported cardinality")
			context.equal(memberships[index].handshake_message().config_digest, memberships[0].handshake_message().config_digest, "all peers full digest equality")


func _bytes(first: int, width: int) -> PackedByteArray:
	var result: PackedByteArray = PackedByteArray()
	result.resize(width)
	result[0] = first
	return result


class FakeClient:
	extends Node
	signal session_plan(plan: Object)
	signal room_left
	signal disconnected
	signal connection_failed
	signal reconnected
	signal room_joined
	signal player_left
	signal player_joined

	func get_player_id() -> String:
		return U


class FakeMesh:
	extends Node
	var attached: bool = false

	func attach(_client: Object) -> Error:
		attached = true
		return OK

	func detach() -> void:
		attached = false


class Plan:
	extends RefCounted
	var data: Dictionary = {"generation": U, "topology": "mesh", "transport": "webrtc", "fallback": "relay", "peers": [{"player_id": V, "initiate": false}]}

	func to_dict() -> Dictionary:
		return data.duplicate(true)
