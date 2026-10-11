extends RefCounted

# Value: protects=additive SDK peer identity/role fencing; fails_when=NewPeer bypasses frozen plan; why_new=plan tests omit additive events; seam=SDK public signals
const M = preload("res://addons/fortress_rollback/transport/signalfish_membership.gd")
const A = preload("res://addons/fortress_rollback/transport/signalfish_adapter.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const LOCAL: String = "00000000-0000-0000-0000-000000000001"
const REMOTE: String = "4afb61dd-c090-dd2c-6bc6-5eaf3da7eb69"
const COLLISION: String = "47a5d0e7-f0f0-053e-880f-5fb4defc9ecf"


func cases() -> PackedStringArray:
	return PackedStringArray(["new_peer"])


func run_case(_name: String, context: RefCounted) -> void:
	for kind: String in ["matching", "role_changed", "collision", "local", "before_plan", "relay"]:
		var membership: M = M.new()
		var session: PackedByteArray = PackedByteArray()
		session.resize(16)
		var incarnation: PackedByteArray = PackedByteArray()
		incarnation.resize(8)
		context.equal(membership.configure(LOCAL, PackedStringArray([LOCAL, REMOTE]), session, incarnation, T.Config.new()), OK, "frozen roster")
		var client: Client = Client.new()
		var mesh: MeshStub = MeshStub.new()
		var adapter: A = A.new()
		context.equal(adapter.attach(client, mesh, membership), OK, "guard attaches before mesh listener")
		var plan: Plan = Plan.new()
		if kind == "relay":
			plan.data.topology = "relay"
			plan.data.transport = "relay"
		if kind != "before_plan":
			client.session_plan.emit(plan)
		var uuid: String = COLLISION if kind == "collision" else (LOCAL if kind == "local" else REMOTE)
		client.new_peer.emit(uuid, kind == "role_changed")
		if kind == "matching":
			context.equal(adapter.status().route, "mesh", "known matching directive keeps route")
			context.equal(mesh.opened, PackedStringArray([REMOTE]), "known matching directive reaches mesh")
		else:
			context.equal(adapter.status().route, "restart_required", "unsafe additive directive latches restart")
			context.equal(mesh.opened.is_empty(), true, "unsafe directive cannot initialize SDK peer")
			context.equal(adapter.receive_mesh(null, PackedByteArray(), M.uuid_to_peer_id(uuid), 0), I.Code.WRONG_STATE, "numeric alias cannot reach protocol")
			context.equal(adapter.receive_relay(null, PackedByteArray(), REMOTE, 0), I.Code.WRONG_STATE, "relay ingress also fenced")
			client.session_plan.emit(Plan.new())
			context.equal(adapter.status().route, "restart_required", "late plan cannot undo membership fence")
		adapter.detach()
		client.free()
		mesh.free()
	context.finish()


class Client:
	extends Node
	signal session_plan(plan: Object)
	signal new_peer(peer_id: String, you_initiate: bool)
	func get_player_id() -> String:
		return LOCAL


class MeshStub:
	extends Node
	var client: Client = null
	var opened: PackedStringArray = PackedStringArray()
	func attach(value: Client) -> Error:
		client = value
		client.new_peer.connect(_open)
		return OK
	func detach() -> void:
		if client != null and client.new_peer.is_connected(_open):
			client.new_peer.disconnect(_open)
		client = null
	func _open(uuid: String, _initiate: bool) -> void:
		if client != null:
			opened.append(uuid)


class Plan:
	extends RefCounted
	var data: Dictionary = {"generation": LOCAL, "topology": "mesh", "transport": "webrtc", "fallback": "relay", "peers": [{"player_id": REMOTE, "initiate": false}]}
	func to_dict() -> Dictionary:
		return data.duplicate(true)
