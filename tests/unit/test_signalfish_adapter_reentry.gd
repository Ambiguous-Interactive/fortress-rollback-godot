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


class GetterClient:
	extends Client
	var callback: Callable
	var boundary: String
	var armed: bool = true

	func attempt(stage: String) -> void:
		if armed and stage == boundary:
			armed = false
			callback.call()

	func get_player_id() -> String:
		attempt("player")
		return super.get_player_id()

	func get_room_id() -> String:
		attempt("room")
		return super.get_room_id()

	func is_connected_to_server() -> bool:
		attempt("connected")
		return super.is_connected_to_server()

	func is_authenticated() -> bool:
		attempt("authenticated")
		return super.is_authenticated()


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


class PlanMesh:
	extends CallbackMesh
	var consumed: Array[Dictionary] = []
	var peers: Dictionary = {}

	func attach(value: Fixture.Client) -> Error:
		var code: Error = super.attach(value)
		value.session_plan.connect(_consume_plan)
		return code

	func detach() -> void:
		if client != null and client.session_plan.is_connected(_consume_plan):
			client.session_plan.disconnect(_consume_plan)
		peers.clear()
		super.detach()

	func _open(uuid: String, initiate: bool) -> void:
		if client != null and not peers.has(uuid):
			peers[uuid] = initiate
			super._open(uuid, initiate)

	func _consume_plan(plan: Object) -> void:
		# The pinned SDK independently consumes session_plan and opens its listed peers.
		if client == null or client.get_room_id().is_empty():
			return
		var data: Dictionary = plan.call("to_dict")
		consumed.append(data)
		for entry: Dictionary in data.peers:
			_open(entry.player_id, entry.initiate)


class CallbackPlan:
	extends Fixture.Plan
	var callback: Callable

	func to_dict() -> Dictionary:
		callback.call()
		return super.to_dict()


func cases() -> PackedStringArray:
	return PackedStringArray(
		[
			"relay_teardown",
			"attach_failure",
			"attach_plan",
			"plan_detach",
			"refusal_plan",
			"detach_replace",
			"attach_getters",
			"lifetime_getters",
			"getter_plans",
			"getter_plan_refusal",
			"plan_conversion"
		]
	)


func run_case(name: String, context: RefCounted) -> void:
	if name == "plan_conversion":
		_plan_conversion(context)
		context.finish()
		return
	if name == "getter_plan_refusal":
		_getter_plan_refusal(context)
		context.finish()
		return
	if name == "getter_plans":
		_getter_plans(context)
		context.finish()
		return
	if name == "lifetime_getters":
		_lifetime_getters(context)
		context.finish()
		return
	if name == "attach_getters":
		_attach_getters(context)
		context.finish()
		return
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


func _attach_getters(context: RefCounted) -> void:
	for boundary: String in ["player", "room"]:
		for operation: String in ["control", "detach", "nested", "replace", "ended", "remote_ended"]:
			var membership: Membership = Membership.new()
			var session: PackedByteArray = PackedByteArray()
			session.resize(16)
			var incarnation: PackedByteArray = PackedByteArray()
			incarnation.resize(8)
			context.equal(
				membership.configure(Fixture.LOCAL, PackedStringArray([Fixture.LOCAL, Fixture.REMOTE]), session, incarnation, Protocol.Config.new()), OK, "getter frozen roster"
			)
			var client: GetterClient = GetterClient.new()
			var mesh: CallbackMesh = CallbackMesh.new()
			var adapter: Adapter = Adapter.new()
			var nested: Array[int] = []
			client.boundary = boundary
			client.callback = func() -> void:
				match operation:
					"detach":
						adapter.detach()
					"nested":
						nested.append(adapter.attach(client, mesh, membership))
					"replace":
						adapter.detach()
						nested.append(adapter.attach(client, mesh, membership))
					"ended":
						client.room_left.emit()
					"remote_ended":
						client.player_reconnected.emit(Fixture.REMOTE)
			var result: Error = adapter.attach(client, mesh, membership)
			context.equal(client.armed, false, "actual SDK getter callback ran: " + boundary)
			if operation in ["control", "nested"]:
				context.equal(result, OK, "healthy outer attachment survives: " + operation)
				context.equal(mesh.client == client, true, "healthy attachment owns mesh once")
				context.equal(client.session_plan.get_connections().size(), 1, "healthy attachment has one plan listener")
				if operation == "nested":
					context.equal(nested, [ERR_ALREADY_IN_USE], "getter cannot replace active setup")
			else:
				if operation == "replace":
					context.equal(nested, [ERR_ALREADY_IN_USE], "detached getter cannot replace setup before outer attach returns")
				context.equal(result, ERR_UNAVAILABLE, "getter cancellation refuses attach: " + boundary)
				context.equal(mesh.client == null, true, "canceled getter never starts mesh: " + boundary)
				context.equal(client.session_plan.get_connections().size(), 0, "canceled getter retains no plan listener: " + boundary)
				context.equal(client.new_peer.get_connections().size(), 0, "canceled getter retains no additive listener: " + boundary)
			adapter.detach()
			context.equal(client.room_left.get_connections().size(), 0, "final detach releases lifecycle observer")
			client.callback = Callable()
			client.free()
			mesh.free()


func _lifetime_getters(context: RefCounted) -> void:
	for boundary: String in ["connected", "authenticated", "player", "room"]:
		for operation: String in ["status", "plan", "new_peer"]:
			var membership: Membership = Membership.new()
			var session: PackedByteArray = PackedByteArray()
			session.resize(16)
			var incarnation: PackedByteArray = PackedByteArray()
			incarnation.resize(8)
			context.equal(
				membership.configure(Fixture.LOCAL, PackedStringArray([Fixture.LOCAL, Fixture.REMOTE]), session, incarnation, Protocol.Config.new()), OK, "live getter roster"
			)
			var client: GetterClient = GetterClient.new()
			var mesh: CallbackMesh = CallbackMesh.new()
			var adapter: Adapter = Adapter.new()
			client.armed = false
			context.equal(adapter.attach(client, mesh, membership), OK, "ordinary attachment precedes getter teardown")
			client.session_plan.emit(Fixture.Plan.new())
			client.boundary = boundary
			client.callback = adapter.detach
			client.armed = true
			match operation:
				"status":
					adapter.status()
				"plan":
					client.session_plan.emit(Fixture.Plan.new())
				"new_peer":
					client.new_peer.emit(Fixture.REMOTE, false)
			context.equal(client.armed, false, "live SDK getter actually triggers teardown: " + boundary)
			context.equal(adapter.status().route, "unconfigured", "old operation cannot overwrite getter detach: " + operation)
			context.equal(mesh.client == null, true, "getter teardown releases mesh")
			context.equal(client.session_plan.get_connections().size(), 0, "getter teardown releases plan listener")
			context.equal(client.new_peer.get_connections().size(), 0, "getter teardown releases additive listeners")
			adapter.detach()
			client.callback = Callable()
			client.free()
			mesh.free()


func _getter_plans(context: RefCounted) -> void:
	for event: String in ["plan", "directive"]:
		for boundary: String in ["connected", "authenticated", "player", "room"]:
			for operation: String in ["status", "plan", "new_peer"]:
				for outcome: String in ["control", "healthy", "invalid", "ended", "detach"]:
					var membership: Membership = _membership(context)
					var client: GetterClient = GetterClient.new()
					var mesh: PlanMesh = PlanMesh.new()
					var adapter: Adapter = Adapter.new()
					client.armed = false
					context.equal(adapter.attach(client, mesh, membership), OK, "getter plan attachment")
					client.session_plan.emit(Fixture.Plan.new())
					context.equal(mesh.consumed.size(), 1, "ordinary SDK plan is consumed")
					mesh.opened.clear()
					# A prior initialization failure may leave the authorized SDK peer absent.
					mesh.peers.clear()
					var emitted: CallbackPlan = CallbackPlan.new()
					emitted.data.generation = Fixture.REMOTE
					var conversions: Array[int] = []
					emitted.callback = func() -> void: conversions.append(1)
					client.boundary = boundary
					client.callback = func() -> void:
						if outcome != "control":
							if event == "plan":
								client.session_plan.emit(emitted)
							else:
								client.new_peer.emit(Fixture.REMOTE, false)
						if outcome == "invalid":
							match boundary:
								"connected":
									client.connected_state = false
								"authenticated":
									client.authenticated_state = false
								"player":
									client.player = Fixture.REMOTE
								"room":
									client.room = Fixture.REMOTE
						elif outcome == "ended":
							client.room_left.emit()
						elif outcome == "detach":
							adapter.detach()
					client.armed = true
					var observed: Dictionary
					match operation:
						"status":
							observed = adapter.status()
						"plan":
							client.session_plan.emit(Fixture.Plan.new())
						"new_peer":
							client.new_peer.emit(Fixture.REMOTE, false)
					if operation != "status":
						# Do not let a second getter check repair the operation under test.
						client.connected_state = true
						client.authenticated_state = true
						client.player = Fixture.LOCAL
						client.room = Fixture.LOCAL
						observed = adapter.status()
					var label: String = event + "/" + boundary + "/" + operation + "/" + outcome
					if outcome == "control":
						context.equal(observed.route, "mesh", "ordinary healthy lifetime supports plans: " + label)
						context.equal(mesh.consumed.size(), 2 if operation == "plan" else 1, "ordinary SDK consumption preserved: " + label)
					else:
						context.equal(observed.route, "unconfigured" if outcome == "detach" else "restart_required", "reentrant lifetime fails closed: " + label)
						context.equal(observed.error, OK if outcome == "detach" else ERR_UNAVAILABLE, "reentry retains terminal cause: " + label)
						context.equal(mesh.consumed.size(), 1, "getter plan never reaches SDK consumer: " + label)
						context.equal(mesh.opened.is_empty(), true, "getter plan and enclosing directive cannot open SDK peers: " + label)
						context.equal(mesh.client, null, "reentry immediately detaches SDK consumer: " + label)
					context.equal(conversions.size(), 0, "reentrant plan is never converted: " + label)
					adapter.detach()
					client.callback = Callable()
					emitted.callback = Callable()
					client.free()
					mesh.free()


func _getter_plan_refusal(context: RefCounted) -> void:
	for operation: String in ["repeat", "prior_refusal", "replace"]:
		var membership: Membership = _membership(context)
		var client: GetterClient = GetterClient.new()
		var mesh: PlanMesh = PlanMesh.new()
		var adapter: Adapter = Adapter.new()
		client.armed = false
		context.equal(adapter.attach(client, mesh, membership), OK, "refusal attachment")
		client.session_plan.emit(Fixture.Plan.new())
		var retained: Array[WeakRef] = []
		var conversions: Array[int] = []
		var replacement: Client = Client.new()
		var replacement_mesh: PlanMesh = PlanMesh.new()
		client.boundary = "connected"
		client.callback = func() -> void:
			for index: int in range(16):
				var plan: CallbackPlan = CallbackPlan.new()
				plan.callback = func() -> void: conversions.append(index)
				retained.append(weakref(plan))
				client.session_plan.emit(plan)
			if operation == "repeat":
				client.armed = true
			elif operation == "replace":
				adapter.detach()
				context.equal(adapter.attach(replacement, replacement_mesh, membership), ERR_ALREADY_IN_USE, "replacement waits for active getter validation")
		if operation == "prior_refusal":
			client.new_peer.emit(Fixture.COLLISION, true)
			client.session_plan.emit(Fixture.Plan.new())
			client.new_peer.emit(Fixture.REMOTE, false)
		client.armed = true
		var observed: Dictionary = adapter.status()
		if operation == "replace":
			context.equal(observed.route, "unconfigured", "old getter cannot publish after detachment")
			context.equal(adapter.attach(replacement, replacement_mesh, membership), OK, "replacement attaches after getter returns")
			context.equal(replacement_mesh.consumed.is_empty(), true, "replacement consumes no old plan")
		else:
			context.equal(observed.route, "restart_required", "reentry requires fresh attachment")
			context.equal(observed.error, ERR_INVALID_DATA if operation == "prior_refusal" else ERR_UNAVAILABLE, "later plans preserve first refusal cause")
			if operation == "repeat":
				for iteration: int in range(8):
					adapter.status()
			context.equal(mesh.detaches, 1, "repeated getter plans detach mesh once")
		context.equal(mesh.consumed.size(), 1, "only original ordinary plan reaches SDK")
		context.equal(conversions.is_empty(), true, "reentrant plan storm performs no conversion")
		for reference: WeakRef in retained:
			context.equal(reference.get_ref(), null, "refused plan is never retained")
		adapter.detach()
		client.callback = Callable()
		client.free()
		mesh.free()
		replacement.free()
		replacement_mesh.free()


func _membership(context: RefCounted) -> Membership:
	var membership: Membership = Membership.new()
	var session: PackedByteArray = PackedByteArray()
	session.resize(16)
	var incarnation: PackedByteArray = PackedByteArray()
	incarnation.resize(8)
	context.equal(membership.configure(Fixture.LOCAL, PackedStringArray([Fixture.LOCAL, Fixture.REMOTE]), session, incarnation, Protocol.Config.new()), OK, "frozen roster")
	return membership


func _plan_conversion(context: RefCounted) -> void:
	for operation: String in ["nested", "directive", "detach_replace"]:
		var membership: Membership = _membership(context)
		var client: Client = Client.new()
		var mesh: PlanMesh = PlanMesh.new()
		var adapter: Adapter = Adapter.new()
		var replacement: Client = Client.new()
		var replacement_mesh: PlanMesh = PlanMesh.new()
		context.equal(adapter.attach(client, mesh, membership), OK, "conversion attachment")
		client.session_plan.emit(Fixture.Plan.new())
		mesh.peers.clear()
		mesh.opened.clear()
		var callbacks: Array[int] = []
		var replacements: Array[int] = []
		var plan: CallbackPlan = CallbackPlan.new()
		plan.callback = func() -> void:
			if not callbacks.is_empty():
				return
			callbacks.append(1)
			if operation == "nested":
				client.session_plan.emit(Fixture.Plan.new())
			elif operation == "directive":
				client.new_peer.emit(Fixture.REMOTE, false)
			else:
				adapter.detach()
				replacements.append(adapter.attach(replacement, replacement_mesh, membership))
		client.session_plan.emit(plan)
		context.equal(callbacks.size(), 1, "actual plan conversion callback runs")
		context.equal(mesh.consumed.size(), 1, "SDK consumes neither enclosing nor nested unstable plan")
		context.equal(mesh.opened.is_empty(), true, "unstable conversion cannot open absent SDK peer")
		if operation in ["nested", "directive"]:
			context.equal(adapter.status().route, "restart_required", "nested conversion plan requires restart")
			context.equal(adapter.status().error, ERR_UNAVAILABLE, "conversion reentry retains cause")
		else:
			context.equal(replacements, [ERR_ALREADY_IN_USE], "replacement waits until old plan callback returns")
			context.equal(adapter.status().route, "unconfigured", "outer conversion cannot revive detached ownership")
			context.equal(adapter.attach(replacement, replacement_mesh, membership), OK, "replacement opens after plan callback returns")
		adapter.detach()
		plan.callback = Callable()
		client.free()
		mesh.free()
		replacement.free()
		replacement_mesh.free()
