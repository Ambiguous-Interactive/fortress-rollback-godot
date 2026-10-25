extends RefCounted

# Value: protects=network final history without another outgoing input; fails_when=peer recovery samples or skips controls; why_new=driver seam bypasses byte mesh; seam=none
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Fixture = preload("res://tests/unit/test_peer_session.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const L = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")
const Game = preload("res://tests/oracle/p2p_game.gd")
const Reference = preload("res://tests/oracle/reference_game.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")


class RecoveryGame:
	extends Game
	var peer_ref: WeakRef
	var reentry_codes: PackedInt32Array = PackedInt32Array()
	var fail_simulation: bool = false

	func _record(kind: String, frame: int, inputs: Array[Dictionary]) -> void:
		super._record(kind, frame, inputs)
		if peer_ref != null:
			reentry_codes.append(peer_ref.get_ref().recover(4000).code)

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		return false if fail_simulation else super.simulate_frame(frame, inputs)


func cases() -> PackedStringArray:
	return PackedStringArray(["final_mesh", "guards", "callbacks", "timeout", "idle_confirmation"])


func run_case(name: String, context: RefCounted) -> void:
	context.equal(Peer.new().has_method("recover"), true, "public peer recovery exists")
	if Peer.new().has_method("recover"):
		call("_" + name, context)
	context.finish()


func _final_mesh(context: RefCounted) -> void:
	for count: int in [2, 3, 8]:
		var fixture: RefCounted = Fixture.new()
		var mesh: Dictionary = fixture._build(context, count)
		for frame: int in range(3):
			mesh.now += 1000
			fixture._tick(context, mesh)
		# No gameplay bytes arrive until every peer has simulated its intended final frame.
		fixture._deliver(context, mesh, fixture._drain(mesh))
		fixture._deliver(context, mesh, fixture._drain(mesh))
		var expected: RefCounted = Reference.new(count, 2)
		for frame: int in range(3):
			var rows: Array[Dictionary] = []
			for player: int in range(count):
				rows.append({"player": player, "bytes": fixture._sample(player, frame).hex_encode(), "status": "confirmed"})
			context.equal(expected.advance(rows), "", "independent final actual history")
		for index: int in range(count):
			mesh.games[index].requests.clear()
			var peer: RefCounted = mesh.peers[index]
			var recovered: RefCounted = peer.recover(mesh.now + 1)
			context.equal(recovered.code, Types.Code.OK, "repair network peer without new sample")
			context.equal(recovered.frame_before, 3, "network recovery starts at exact final frame")
			context.equal(recovered.frame_after, 3, "network recovery adds no final frame")
			context.bytes_equal(mesh.games[index].game.bytes(), expected.bytes(), 3, "byte mesh recovers independent final state")
			for state: Dictionary in peer.network_status().peers.values():
				context.equal(state.last_submitted_frame, 2, "recovery publishes no new local input")
			context.equal(peer.recover(mesh.now + 2).code, Types.Code.OK, "repeat network recovery")
			context.equal(peer.recover(mesh.now).code, Types.Code.INVALID_TIME, "network recovery validates monotonic clock")


func _guards(context: RefCounted) -> void:
	_terminal_limits(context)
	context.equal(Peer.new().recover(0).code, Types.Code.NOT_CONFIGURED, "unconfigured peer recovery")
	var fixture: RefCounted = Fixture.new()
	var mesh: Dictionary = fixture._build(context, 2, 0, false, 128, false)
	context.equal(mesh.peers[0].recover(0).code, Types.Code.NOT_SYNCHRONIZED, "recovery cannot bypass handshake")
	mesh = fixture._build(context, 2, 0, false, 128, true, false, 8, L.Options.new())
	var peer: RefCounted = mesh.peers[0]
	peer._busy = true
	context.equal(peer.recover(0).code, Types.Code.BUSY, "outer peer ownership guard")
	peer._busy = false
	for sample: Driver.LocalInput in fixture._inputs(mesh, 0):
		context.equal(peer._core.submit_local_input(sample.player, sample.sample_frame, sample.bytes).code, Types.Code.OK, "expert batch stages its sample")
	context.equal(peer._core.begin_advance().code, Types.Code.READY, "expert batch owns requests")
	var endpoints: Dictionary = peer.network_status().peers
	context.equal(peer.step(1, fixture._inputs(mesh, 0)).code, Types.Code.BUSY, "expert batch rejects peer advancement")
	context.equal(peer.recover(1).code, Types.Code.BUSY, "expert batch rejects peer recovery")
	context.equal(peer.status().lifecycle, Types.Lifecycle.RUNNING, "busy preflight leaves game running")
	context.equal(peer.network_status().peers, endpoints, "busy preflight leaves endpoint controls unchanged")
	context.equal(peer.drain_outbox().is_empty(), true, "busy preflight sends no goodbye")
	context.equal(peer.close(1), I.Code.OK, "explicit peer close")
	context.equal(peer.recover(2).code, Types.Code.TERMINATED, "recovery cannot resume terminal peer")


# Value: protects=peer terminal limits before input or wire mutation; fails_when=wrapper stalls or stages first;
# why_new=driver controls bypass the peer wrapper; seam=existing counter fixtures
func _terminal_limits(context: RefCounted) -> void:
	for counter: String in ["_current", "_batch_id"]:
		for operation: String in ["missing", "complete", "recover"]:
			var fixture: RefCounted = Fixture.new()
			var mesh: Dictionary = fixture._build(context, 2)
			var peer: Peer = mesh.peers[0]
			peer._core.set(counter, 2147483647 if counter == "_current" else 9223372036854775807)
			var before: int = peer.status().current_frame
			var receipts: PackedInt64Array = peer._core.received_frames()
			var endpoints: Dictionary = peer.network_status().peers
			var notices: Array[int] = []
			peer.step_completed.connect(func(code: int, _before: int, _after: int) -> void: notices.append(code))
			var empty: Array[Driver.LocalInput] = []
			var result: Driver.StepResult = peer.recover(1) if operation == "recover" else peer.step(1, fixture._inputs(mesh, 0) if operation == "complete" else empty)
			context.equal(result.code, Types.Code.FRAME_EXHAUSTED, "peer terminal limit precedes " + operation)
			context.equal(result.reason, Types.Code.FRAME_EXHAUSTED, "peer result retains terminal exhaustion")
			context.equal(peer.status().lifecycle, Types.Lifecycle.TERMINATED, "peer exhaustion cannot remain retryable")
			context.equal(result.frame_after, before, "peer exhausted frontier stays fixed")
			context.equal(peer._core.received_frames(), receipts, "exhaustion retains no local sample")
			context.equal(peer.network_status().peers, endpoints, "exhaustion publishes no endpoint input")
			context.equal(peer.drain_outbox().is_empty(), true, "exhaustion emits no new packet with controls disabled")
			context.equal(mesh.games[0].requests.is_empty(), true, "exhaustion invokes no game callback")
			context.equal(notices, [Types.Code.FRAME_EXHAUSTED], "one final exhaustion notification")
			context.equal(peer.recover(2).code, Types.Code.TERMINATED, "exhausted peer remains terminal")
	# The ordinary wrapper still accepts unavailable input and recovery while capacity remains.
	var fixture: RefCounted = Fixture.new()
	var mesh: Dictionary = fixture._build(context, 2)
	mesh.peers[0]._core._batch_id = 9223372036854775806
	var empty: Array[Driver.LocalInput] = []
	context.equal(mesh.peers[0].step(1, empty).code, Types.Code.MISSING_LOCAL_INPUT, "nonexhausted missing-input control")
	context.equal(mesh.peers[0].recover(1).code, Types.Code.OK, "nonexhausted idle recovery control")
	context.equal(mesh.peers[0].step(1, fixture._inputs(mesh, 0)).code, Types.Code.OK, "nonexhausted complete-input control")
	context.equal(mesh.peers[0].step(2, empty).code, Types.Code.FRAME_EXHAUSTED, "last permitted batch then reaches exhaustion")
	for recovery: bool in [false, true]:
		mesh = fixture._build(context, 2, 0, false, 128, true, false, 8, L.Options.new())
		mesh.peers[0]._core._batch_id = 9223372036854775807
		var result: Driver.StepResult = mesh.peers[0].recover(1) if recovery else mesh.peers[0].step(1, empty)
		context.equal(result.code, Types.Code.FRAME_EXHAUSTED, "network-enabled terminal limit")
		var packets: Array[Dictionary] = fixture._drain(mesh)
		context.equal(packets.is_empty(), false, "exhaustion still sends its final goodbye")
		for packet: Dictionary in packets:
			context.equal(packet.bytes.decode_u16(6), T.Kind.GOODBYE, "terminal limit sends only goodbye")
			var delivered: int = mesh.peers[packet.to].receive(packet.bytes, fixture._id(packet.from), 1)
			context.equal(delivered in [I.Code.OK, I.Code.TERMINATED], true, "goodbye duplication remains terminal")
		context.equal(mesh.peers[1].status().lifecycle, Types.Lifecycle.TERMINATED, "remote peer receives exhaustion goodbye")


func _callbacks(context: RefCounted) -> void:
	for failure: bool in [false, true]:
		var fixture: RefCounted = Fixture.new()
		var game: RecoveryGame = RecoveryGame.new(2)
		var mesh: Dictionary = fixture._build(context, 2, 0, false, 128, true, false, 8, null, 60, 0, game)
		for frame: int in range(3):
			mesh.now += 1000
			fixture._tick(context, mesh)
		fixture._deliver(context, mesh, fixture._drain(mesh))
		fixture._deliver(context, mesh, fixture._drain(mesh))
		var peer: RefCounted = mesh.peers[0]
		game.peer_ref = weakref(peer)
		game.fail_simulation = failure
		var notices: Array[int] = []
		var owner_ref: WeakRef = weakref(peer)
		peer.step_completed.connect(func(code: int, before: int, after: int) -> void: notices.append_array([code, before, after, owner_ref.get_ref().recover(4000).code]))
		var expected: int = Types.Code.CALLBACK_FAILED if failure else Types.Code.OK
		context.equal(peer.recover(4000).code, expected, "network recovery reports callback outcome")
		context.equal(notices, [expected, 3, 3, Types.Code.BUSY], "one final guarded network notification")
		context.equal(game.reentry_codes.is_empty(), false, "recovery executed actual game callbacks")
		for code: int in game.reentry_codes:
			context.equal(code, Types.Code.BUSY, "peer recovery refuses callback reentry")
		if failure:
			context.equal(peer.status().lifecycle, Types.Lifecycle.TERMINATED, "failed network callback terminates")
			context.equal(peer.recover(4001).code, Types.Code.TERMINATED, "failed network recovery cannot resume")


func _timeout(context: RefCounted) -> void:
	var fixture: RefCounted = Fixture.new()
	var mesh: Dictionary = fixture._build(context, 2, 0, false, 128, true, false, 8, L.Options.new())
	var peer: RefCounted = mesh.peers[0]
	context.equal(peer.recover(2000001).code, Types.Code.PROTOCOL_FAILED, "recovery independently services host deadlines")
	context.equal(peer.status().lifecycle, Types.Lifecycle.TERMINATED, "timeout halts recovery without new input")
	context.equal(mesh.games[0].requests.is_empty(), true, "expired peer runs no game callbacks")


# Value: protects=final receipt convergence below prediction limit; fails_when=confirmed peers stop gossiping to a lagging peer; why_new=mesh tests keep sampling; seam=none
func _idle_confirmation(context: RefCounted) -> void:
	for count: int in [3, 8]:
		for lose_packet: bool in [false, true]:
			var fixture: RefCounted = Fixture.new()
			var mesh: Dictionary = fixture._build(context, count)
			for frame: int in range(3):
				mesh.now += 1000
				fixture._tick(context, mesh)
			fixture._deliver(context, mesh, fixture._drain(mesh))
			fixture._deliver(context, mesh, fixture._drain(mesh))
			for peer: RefCounted in mesh.peers:
				context.equal(peer.status().confirmed_frame, -1, "input-idle tail remains below prediction exhaustion")
				for state: Dictionary in peer.network_status().peers.values():
					context.equal(state.pending_frames, 0, "all ordinary input ACKs drained")
				context.equal(peer.recover(203000).code, Types.Code.OK, "recover at strict input resend equality")
			context.equal(fixture._drain(mesh).is_empty(), true, "equality sends no gossip carrier")
			for peer: RefCounted in mesh.peers:
				context.equal(peer.recover(203001).code, Types.Code.OK, "recover services final receipt gossip")
			var packets: Array[Dictionary] = fixture._drain(mesh)
			context.equal(packets.size(), count * (count - 1), "one bounded historical carrier per link")
			if packets.is_empty():
				continue
			if lose_packet:
				packets.remove_at(0)
			mesh.now = 203001
			fixture._deliver(context, mesh, packets)
			fixture._deliver(context, mesh, fixture._drain(mesh))
			if lose_packet:
				var waiting: bool = false
				var completed: bool = false
				for peer: RefCounted in mesh.peers:
					waiting = waiting or peer.status().confirmed_frame < 2
					completed = completed or peer.status().confirmed_frame == 2
				context.equal(waiting and completed, true, "one missing packet leaves asymmetric confirmation")
				for peer: RefCounted in mesh.peers:
					context.equal(peer.recover(403001).code, Types.Code.OK, "retry equality remains idle")
				context.equal(fixture._drain(mesh).is_empty(), true, "gossip interval equality is strict")
				for peer: RefCounted in mesh.peers:
					context.equal(peer.recover(403002).code, Types.Code.OK, "confirmed senders still help the waiting recipient")
				mesh.now = 403002
				fixture._deliver(context, mesh, fixture._drain(mesh))
				fixture._deliver(context, mesh, fixture._drain(mesh))
			for peer: RefCounted in mesh.peers:
				context.equal(peer.status().confirmed_frame, 2, "entire final simulated prefix confirms without another sample")
				context.equal(peer.status().current_frame, 3, "receipt recovery adds no simulation frame")
				for state: Dictionary in peer.network_status().peers.values():
					context.equal(state.last_submitted_frame, 2, "gossip repeats historical input without a new sample")
