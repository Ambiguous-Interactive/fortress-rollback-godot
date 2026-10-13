extends RefCounted

# Value: protects=expiry before retained transport retry; fails_when=pressure freezes clocks or stale traffic revives expiry; why_new=ordinary timeout has no retained batch
const Fixture = preload("res://tests/unit/test_online_example.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


class PressuredTransport:
	extends Fixture.RefusedCoordinator
	var delegate: Fixture.Fallback
	func poll(now_us: int, factory: Callable = Callable()) -> Result:
		return delegate.poll(now_us, factory)
	func detach() -> void:
		delegate.detach()


func cases() -> PackedStringArray:
	return PackedStringArray(["pressured_handshake_expiry", "saturated_handshake_expiry", "pressured_running_expiry", "short_suspend"])


func run_case(name: String, context: RefCounted) -> void:
	var helper: RefCounted = Fixture.new()
	var fixtures: Array[Dictionary] = [helper._fixture(context, Fixture.U), helper._fixture(context, Fixture.V)]
	if name not in ["pressured_handshake_expiry", "saturated_handshake_expiry"]:
		for round_index: int in 100:
			for fixture: Dictionary in fixtures:
				fixture.driver.tick(round_index * 16667, Simulation.RIGHT)
			helper._deliver(fixtures)
		for fixture: Dictionary in fixtures:
			context.equal(fixture.driver.peer.network_status().state, "running", "actual peers synchronize before suspension")
	if name == "short_suspend":
		var frames: PackedInt32Array = PackedInt32Array()
		for fixture: Dictionary in fixtures:
			frames.append(fixture.driver.peer.status().current_frame)
		for index: int in 2:
			var fixture: Dictionary = fixtures[index]
			fixture.driver.tick(2400000, Simulation.LEFT)
			context.equal(fixture.driver.failure, "", "sub-timeout elapsed suspension preserves session")
			context.equal(fixture.driver.peer.status().current_frame <= frames[index] + 1, true, "elapsed time does not create catch-up simulation")
			context.equal(fixture.driver.peer.network_status().last_now_us, 2400000, "protocol uses full elapsed host time")
		for round_index: int in 60:
			helper._deliver(fixtures)
			for fixture: Dictionary in fixtures:
				fixture.driver.tick(2400000 + round_index * 16667, Simulation.LEFT)
				context.equal(fixture.driver.failure, "", "actual original-input recovery after short suspension")
		for index: int in 2:
			context.equal(fixtures[index].driver.peer.status().confirmed_frame > frames[index] + 30, true, "confirmation progresses after resume")
	else:
		var fixture: Dictionary = fixtures[0]
		var coordinator: Fixture.RefusedCoordinator = Fixture.RefusedCoordinator.new()
		var buffered: Array[Dictionary] = []
		if name == "pressured_running_expiry":
			buffered.assign(fixture.transport.incoming.duplicate(true))
			context.equal(buffered.is_empty(), false, "retain actual valid remote packets for overdue resume")
			var transport: PressuredTransport = PressuredTransport.new()
			transport.delegate = fixture.driver.fallback
			coordinator = transport
		else:
			fixture.driver.fallback.detach()
		fixture.driver.fallback = coordinator
		var is_handshake: bool = name in ["pressured_handshake_expiry", "saturated_handshake_expiry"]
		var start: int = 0 if is_handshake else 1666700
		fixture.driver.tick(start, Simulation.RIGHT)
		if name == "saturated_handshake_expiry":
			for round_index: int in range(1, 150):
				fixture.driver.tick(round_index * 200001, Simulation.RIGHT)
			context.equal(fixture.driver.failure, "", "bounded token pressure remains recoverable before expiry")
		context.equal(fixture.driver._pending.is_empty(), false, "actual drained batch remains caller-owned under pressure")
		var deadline: int = 30000000
		if name == "pressured_running_expiry":
			var endpoints: Dictionary = fixture.driver.peer.network_status().peers
			deadline = endpoints.values()[0].last_recv_us + 2000000
		fixture.driver.tick(deadline, Simulation.LEFT)
		context.equal(fixture.driver.failure, "", "exact expiry boundary remains eligible")
		var attempts: int = coordinator.attempts
		var frame: int = fixture.driver.peer.status().current_frame
		fixture.transport.incoming.append_array(buffered)
		fixture.driver.tick(deadline + 1, Simulation.LEFT)
		context.equal(fixture.driver.failure.is_empty(), false, "retained output cannot suppress expiry on resume")
		context.equal(coordinator.attempts, attempts, "expiry is adjudicated before retrying retained transport")
		if name == "pressured_running_expiry":
			context.equal(fixture.transport.incoming.size(), buffered.size(), "expired resume never consumes valid buffered gameplay")
		context.equal(fixture.driver.peer.status().current_frame, frame, "expired session never advances")
		fixture.driver.tick(deadline + 1000000, Simulation.RIGHT)
		context.equal(fixture.driver.peer.status().current_frame, frame, "late service cannot resurrect expired game")
	for fixture: Dictionary in fixtures:
		fixture.driver.detach()
		fixture.mesh.free()
		fixture.client.free()
	context.finish()
