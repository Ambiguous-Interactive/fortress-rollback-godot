extends RefCounted

# Value: protects=owned per-peer fallback and lifetime fences; fails_when=refused direct work is lost, reordered or sent after teardown; seam=production adapters
const F = preload("res://addons/fortress_rollback/transport/signalfish_fallback.gd")
const D = preload("res://tests/unit/test_signalfish_webrtc.gd")
const R = preload("res://tests/unit/test_signalfish_relay.gd")
const M = preload("res://tests/unit/test_signalfish_membership.gd")
const A = preload("res://addons/fortress_rollback/transport/signalfish_adapter.gd")
const Direct = preload("res://addons/fortress_rollback/transport/signalfish_webrtc.gd")
const Relay = preload("res://addons/fortress_rollback/transport/signalfish_relay.gd")
const P = preload("res://addons/fortress_rollback/core/peer_session.gd")
const E = preload("res://addons/fortress_rollback/transport/signalfish_relay_envelope.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["overlap", "unready", "busy", "atomic", "clock", "relay_plan", "plan_fence", "room_fence", "reentry", "fatal_relay",
		"fairness", "restore", "readiness_gap", "transport_replacement", "timer_recovery"])


func run_case(name: String, context: RefCounted) -> void:
	var fixture: Dictionary = build(context, name == "fairness")
	match name:
		"overlap":
			context.equal(fixture.relay.poll(0).code, F.Code.OK, "relay serviceable during mesh plan")
		"unready", "busy", "clock":
			_pressure(context, fixture, name)
		"fairness":
			fixture.mesh.transport.connected = false
			var queued: Array[P.Packet] = [packet(fixture, 7), P.Packet.new(fixture.membership.identity(M.W), PackedByteArray([8]))]
			context.equal((fixture.fallback as F).enqueue_batch(queued), F.Code.OK, "own mixed peers at minimum budget")
			for now: int in 3:
				fixture.fallback.poll(now)
			context.equal(fixture.mesh.transport.sent, [PackedByteArray([8])], "blocked head cannot starve healthy peer")
			context.equal(fixture.fallback.status().pending_packets, 1, "blocked peer remains retained")
		"restore":
			_restore(context, fixture)
		"readiness_gap":
			_readiness_gap(context, fixture)
		"transport_replacement":
			(fixture.fallback as F).enqueue_batch([packet(fixture, 9)])
			fixture.mesh.transport = SelectiveTransport.new()
			context.equal(fixture.fallback.poll(0).code, F.Code.WRONG_STATE, "replacement transport fails coordinator lifetime")
			context.equal(fixture.fallback.poll(10).code, F.Code.WRONG_STATE, "transport failure cannot become relay fallback")
			context.equal(fixture.client.sent.size(), 0, "lifetime failure never publishes relay output")
			context.equal(fixture.fallback.status().pending_packets, 1, "fenced caller output retained")
		"timer_recovery":
			_timer_recovery(context, fixture)
		"atomic":
			_atomic(context, fixture)
		"relay_plan", "plan_fence", "room_fence":
			_fences(context, fixture, name)
		"reentry":
			fixture.mesh.transport.on_poll = fixture.fallback.detach
			(fixture.fallback as F).enqueue_batch([packet(fixture, 9)])
			context.equal(fixture.fallback.poll(0).code, F.Code.WRONG_STATE, "callback detach latched")
			context.equal(fixture.mesh.transport.sent.size() + fixture.client.sent.size(), 0, "callback detach sends nothing")
		"fatal_relay":
			var envelope: PackedByteArray = E.encode(fixture.membership.handshake_message().session_id, M.V, M.U, PackedByteArray([1]))
			for _index: int in 3:
				fixture.client.game_data_binary_received.emit(M.V, 1, envelope)
			context.equal((fixture.fallback as F).enqueue_batch([packet(fixture, 9)]), F.Code.RECEIVE_OVERFLOW, "relay failure fences direct output")
			context.equal(fixture.fallback.poll(0).code, F.Code.RECEIVE_OVERFLOW, "relay overflow terminal")
	destroy(fixture)
	context.finish()


func build(context: RefCounted, three_peers: bool = false) -> Dictionary:
	var helper: RefCounted = M.new()
	var roster: PackedStringArray = PackedStringArray([M.U, M.V, M.W]) if three_peers else PackedStringArray([M.U, M.V])
	var membership: RefCounted = helper._membership(context, M.U, roster)
	var peer: P = helper._peer(context, membership)
	var client: R.Client = R.Client.new()
	var mesh: D.FakeMesh = D.FakeMesh.new()
	mesh.transport = SelectiveTransport.new()
	var adapter: A = A.new()
	context.equal(adapter.attach(client, mesh, membership), OK, "attach mesh plan")
	var plan: M.Plan = M.Plan.new()
	if three_peers:
		plan.data.peers.append({"player_id": M.W, "initiate": false})
	client.session_plan.emit(plan)
	var config: R.SDKConfig = R.SDKConfig.new()
	var info: R.Info = R.Info.new()
	var relay_options: Relay.Options = Relay.Options.new()
	relay_options.max_packet_bytes = 512
	relay_options.max_pending_packets = 2
	relay_options.max_received_packets = 2
	relay_options.max_sends_per_poll = 1
	relay_options.max_receives_per_poll = 1
	var relay: Relay = Relay.new()
	context.equal(relay.configure(client, config, info, membership, adapter, peer, relay_options), F.Code.OK, "standby binary relay")
	var direct_options: Direct.Options = Direct.Options.new()
	direct_options.max_packet_bytes = 512
	direct_options.max_pending_packets = 2
	direct_options.max_sends_per_poll = 1
	var direct: Direct = Direct.new()
	context.equal(direct.configure(mesh, membership, adapter, peer, direct_options), F.Code.OK, "direct configured")
	var options: F.Options = F.Options.new()
	options.fallback_after_us = 10
	options.max_pending_packets = 2
	options.max_routes_per_poll = 1 if three_peers else 2
	options.restore_after_us = 5
	var fallback: F = F.new()
	context.equal(fallback.configure(direct, relay, membership, adapter, peer, options), F.Code.OK, "coordinator configured")
	return {"fallback": fallback, "direct": direct, "relay": relay, "membership": membership, "peer": peer,
		"client": client, "mesh": mesh, "adapter": adapter, "config": config, "info": info}


func destroy(fixture: Dictionary) -> void:
	fixture.fallback.detach()
	fixture.direct.detach()
	fixture.relay.detach()
	fixture.adapter.detach()
	fixture.client.free()
	fixture.mesh.free()


func packet(fixture: Dictionary, value: int) -> P.Packet:
	return P.Packet.new(fixture.membership.identity(M.V), PackedByteArray([value]))


func _pressure(context: RefCounted, fixture: Dictionary, name: String) -> void:
	fixture.mesh.transport.connected = name != "unready" and name != "clock"
	fixture.mesh.transport.busy = name == "busy"
	var packets: Array[P.Packet] = [packet(fixture, 11), packet(fixture, 22)]
	context.equal((fixture.fallback as F).enqueue_batch(packets), F.Code.OK, "own batch")
	packets[0].bytes[0] = 99
	packets[1].to[0] ^= 1
	var start: int = 9223372036854775797 if name == "clock" else 0
	context.equal(fixture.fallback.poll(start).code, F.Code.BACKPRESSURE, "direct refusal retains work")
	context.equal(fixture.fallback.status().pending_packets, 2, "both packets remain coordinator owned")
	context.equal(fixture.direct.status().pending_packets, 0, "direct retry ownership reclaimed")
	context.equal(fixture.fallback.poll(start + 9).sent, 0, "no early relay")
	fixture.client.busy = true
	context.equal(fixture.fallback.poll(start + 10).code, F.Code.BACKPRESSURE, "relay busy retains work after exact deadline")
	context.equal(fixture.fallback.status().relay_peers, [M.V], "fallback selects frozen peer")
	context.equal(fixture.relay.status().pending_packets, 2, "relay owns original FIFO")
	fixture.client.busy = false
	fixture.mesh.transport.connected = true
	fixture.mesh.transport.busy = false
	context.equal(fixture.fallback.poll(start + 10).sent, 1, "retained head sends")
	context.equal(fixture.fallback.poll(start + 10).sent, 1, "retained tail sends")
	context.equal(fixture.mesh.transport.sent.size(), 0, "relay selection remains stable after direct recovers")
	context.equal(E.decode(fixture.client.sent[0], 512).payload, PackedByteArray([11]), "original first bytes")
	context.equal(E.decode(fixture.client.sent[1], 512).payload, PackedByteArray([22]), "original FIFO tail")
	context.equal(fixture.fallback.poll(start + 9).code, F.Code.INVALID_ARGUMENT, "backward clock refused")


func _atomic(context: RefCounted, fixture: Dictionary) -> void:
	var packets: Array[P.Packet] = [packet(fixture, 1), P.Packet.new(PackedByteArray([1]), PackedByteArray([2]))]
	context.equal((fixture.fallback as F).enqueue_batch(packets), F.Code.WRONG_SOURCE, "invalid member refuses entire batch")
	context.equal(fixture.fallback.status().pending_packets, 0, "no partial ownership")
	context.equal((fixture.fallback as F).enqueue_batch([packet(fixture, 1), packet(fixture, 2)]), F.Code.OK, "fill bounded queue")
	context.equal((fixture.fallback as F).enqueue_batch([packet(fixture, 3)]), F.Code.BACKPRESSURE, "capacity enforced")
	context.equal(fixture.fallback.status().pending_bytes, 2, "exact accounting")
	context.equal(fixture.fallback.poll(0).sent, 1, "direct adapter send work retained")
	context.equal(fixture.fallback.poll(1).sent, 1, "reclaimed unsent tail retried")
	context.equal(fixture.fallback.status().pending_bytes, 0, "all ownership released")


func _fences(context: RefCounted, fixture: Dictionary, name: String) -> void:
	(fixture.fallback as F).enqueue_batch([packet(fixture, 9)])
	var plan: M.Plan = M.Plan.new()
	if name == "relay_plan":
		plan.data.topology = "relay"
		plan.data.transport = "relay"
		plan.data.peers.clear()
		fixture.client.session_plan.emit(plan)
	elif name == "plan_fence":
		plan.data.generation = M.V
		fixture.client.session_plan.emit(plan)
	else:
		fixture.client.room_left.emit()
	context.equal(fixture.fallback.poll(0).code, F.Code.OK if name == "relay_plan" else F.Code.WRONG_STATE, "accepted relay or terminal fence")
	context.equal(fixture.client.sent.size(), 1 if name == "relay_plan" else 0, "only accepted relay plan publishes")
	context.equal(fixture.mesh.transport.sent.size(), 0, "fenced direct sends nothing")


func _restore(context: RefCounted, fixture: Dictionary) -> void:
	fixture.mesh.transport.connected = false
	(fixture.fallback as F).enqueue_batch([packet(fixture, 1)])
	fixture.fallback.poll(0)
	fixture.fallback.poll(10)
	context.equal(fixture.fallback.status().relay_peers, [M.V], "link switched to relay")
	fixture.mesh.transport.connected = true
	fixture.client.busy = true
	(fixture.fallback as F).enqueue_batch([packet(fixture, 2)])
	fixture.fallback.poll(11)
	(fixture.fallback as F).enqueue_batch([packet(fixture, 3)])
	fixture.fallback.poll(16)
	context.equal(fixture.mesh.transport.sent.size(), 0, "restoration waits for accepted relay FIFO")
	fixture.client.busy = false
	fixture.fallback.poll(17)
	fixture.fallback.poll(18)
	(fixture.fallback as F).enqueue_batch([packet(fixture, 4)])
	fixture.fallback.poll(19)
	context.equal(fixture.mesh.transport.sent, [PackedByteArray([4])], "ready direct resumes only after older relay sends")
	context.equal(fixture.fallback.status().relay_peers.is_empty(), true, "direct route restored")


class SelectiveTransport:
	extends D.Transport

	func get_peer(id: int) -> Dictionary:
		return {"connected": connected or id != M.M.uuid_to_peer_id(M.V), "channels": [channel, channel, channel]}


func _readiness_gap(context: RefCounted, fixture: Dictionary) -> void:
	fixture.mesh.transport.connected = false
	(fixture.fallback as F).enqueue_batch([packet(fixture, 1)])
	fixture.fallback.poll(0)
	fixture.fallback.poll(10)
	fixture.mesh.transport.connected = true
	fixture.fallback.poll(11)
	fixture.mesh.transport.connected = false
	fixture.fallback.poll(12)
	fixture.mesh.transport.connected = true
	fixture.fallback.poll(16)
	context.equal(fixture.fallback.status().relay_peers, [M.V], "idle unavailable poll resets readiness grace")
	fixture.fallback.poll(20)
	context.equal(fixture.fallback.status().relay_peers, [M.V], "restoration refuses one tick early")
	fixture.fallback.poll(21)
	context.equal(fixture.fallback.status().relay_peers.is_empty(), true, "idle healthy polls restore at exact grace deadline")


func _timer_recovery(context: RefCounted, fixture: Dictionary) -> void:
	(fixture.fallback as F).enqueue_batch([packet(fixture, 1), packet(fixture, 2)])
	fixture.mesh.transport.connected = false
	fixture.fallback.poll(0)
	fixture.mesh.transport.connected = true
	context.equal(fixture.fallback.poll(1).sent, 1, "direct recovery demonstrates successful publication")
	context.equal(fixture.fallback.status().pending_packets, 1, "send work limit retains healthy tail")
	context.equal(fixture.fallback.poll(10).sent, 1, "healthy retained tail publishes at former grace deadline")
	context.equal(fixture.client.sent.size(), 0, "old failure timer cannot relay a recovered channel")
	context.equal(fixture.mesh.transport.sent, [PackedByteArray([1]), PackedByteArray([2])], "both packets remain direct in original order")
