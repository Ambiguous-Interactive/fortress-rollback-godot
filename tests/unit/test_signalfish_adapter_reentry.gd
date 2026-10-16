extends RefCounted

# Value: protects=terminal adapter lifetimes during synchronous SDK callbacks; fails_when=outer plan/attach revives ended state; seam=public SDK calls and signals
const Fixture = preload("res://tests/unit/test_signalfish_adapter.gd")
const Membership = preload("res://addons/fortress_rollback/transport/signalfish_membership.gd")
const Adapter = preload("res://addons/fortress_rollback/transport/signalfish_adapter.gd")
const Protocol = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")


class Client:
	extends Fixture.Client
	signal room_left


class CallbackMesh:
	extends Fixture.MeshStub
	var on_attach: Callable
	var on_detach: Callable
	var detaches: int = 0

	func attach(value: Fixture.Client) -> Error:
		var code: Error = super.attach(value)
		if on_attach.is_valid():
			on_attach.call()
		return code

	func detach() -> void:
		detaches += 1
		var callback: Callable = on_detach
		on_detach = Callable()
		if callback.is_valid():
			callback.call()
		super.detach()


class CallbackPlan:
	extends Fixture.Plan
	var callback: Callable

	func to_dict() -> Dictionary:
		callback.call()
		return super.to_dict()


func cases() -> PackedStringArray:
	return PackedStringArray(["relay_teardown", "attach_failure", "attach_plan", "plan_detach", "refusal_plan", "detach_replace"])


func run_case(name: String, context: RefCounted) -> void:
	var membership: Membership = Membership.new()
	var session: PackedByteArray = PackedByteArray()
	session.resize(16)
	var incarnation: PackedByteArray = PackedByteArray()
	incarnation.resize(8)
	context.equal(membership.configure(Fixture.LOCAL, PackedStringArray([Fixture.LOCAL, Fixture.REMOTE]), session, incarnation, Protocol.Config.new()), OK, "frozen roster")
	var client: Client = Client.new()
	var mesh: CallbackMesh = CallbackMesh.new()
	var adapter: Adapter = Adapter.new()
	if name == "attach_failure":
		mesh.on_attach = client.room_left.emit
		context.equal(adapter.attach(client, mesh, membership), ERR_UNAVAILABLE, "synchronous room loss overrides attach success")
		context.equal(adapter.status().route, "restart_required", "attach cannot overwrite terminal route")
		context.equal(mesh.detaches, 1, "failed attach releases mesh once")
	elif name == "attach_plan":
		mesh.on_attach = client.session_plan.emit.bind(Fixture.Plan.new())
		context.equal(adapter.attach(client, mesh, membership), OK, "initial synchronous plan accepted")
		context.equal(adapter.status().route, "mesh", "attach preserves the accepted initial plan")
	else:
		context.equal(adapter.attach(client, mesh, membership), OK, "attach optional SDK")
		client.session_plan.emit(Fixture.Plan.new())
		if name == "refusal_plan":
			var relay: Fixture.Plan = Fixture.Plan.new()
			relay.data.topology = "relay"
			relay.data.transport = "relay"
			mesh.on_detach = client.session_plan.emit.bind(relay)
			var invalid: Fixture.Plan = Fixture.Plan.new()
			invalid.data.generation = "invalid"
			client.session_plan.emit(invalid)
			context.equal(adapter.status().route, "blocked", "refused plan cannot accept relay inside teardown")
			context.equal(adapter.status().error, ERR_INVALID_DATA, "refusal retains actual error")
		elif name == "detach_replace":
			var replacement_client: Client = Client.new()
			var replacement_mesh: CallbackMesh = CallbackMesh.new()
			var codes: Array[int] = []
			mesh.on_detach = func() -> void:
				adapter.detach()
				codes.append(adapter.attach(replacement_client, replacement_mesh, membership))
			adapter.detach()
			context.equal(codes, [ERR_ALREADY_IN_USE], "replacement cannot open inside active teardown")
			context.equal(replacement_mesh.client, null, "refused replacement owns no SDK callbacks")
			context.equal(adapter.status().route, "unconfigured", "outer detach releases old ownership")
			context.equal(adapter.attach(replacement_client, replacement_mesh, membership), OK, "replacement may open after teardown returns")
			adapter.detach()
			replacement_client.free()
			replacement_mesh.free()
		elif name == "relay_teardown":
			mesh.on_detach = client.room_left.emit
			var relay: Fixture.Plan = Fixture.Plan.new()
			relay.data.topology = "relay"
			relay.data.transport = "relay"
			client.session_plan.emit(relay)
			context.equal(adapter.status().route, "restart_required", "outer relay plan cannot revive terminal callback")
			context.equal(mesh.detaches, 1, "teardown cannot recursively detach same mesh")
			context.equal(adapter.receive_relay(null, PackedByteArray([1]), Fixture.REMOTE, 0), I.Code.WRONG_STATE, "terminal route cannot deliver bytes")
		else:
			var plan: CallbackPlan = CallbackPlan.new()
			plan.callback = adapter.detach
			client.session_plan.emit(plan)
			context.equal(adapter.status().route, "unconfigured", "plan conversion cannot republish detached ownership")
	adapter.detach()
	client.free()
	mesh.free()
	context.finish()
