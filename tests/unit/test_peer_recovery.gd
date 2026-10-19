extends RefCounted

# Value: protects=network final history without another outgoing input; fails_when=peer recovery samples or skips controls; why_new=driver seam bypasses byte mesh; seam=none
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Fixture = preload("res://tests/unit/test_peer_session.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const L = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")
const Game = preload("res://tests/oracle/p2p_game.gd")
const Reference = preload("res://tests/oracle/reference_game.gd")


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
	return PackedStringArray(["final_mesh", "guards", "callbacks", "timeout"])


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
	context.equal(Peer.new().recover(0).code, Types.Code.NOT_CONFIGURED, "unconfigured peer recovery")
	var fixture: RefCounted = Fixture.new()
	var mesh: Dictionary = fixture._build(context, 2, 0, false, 128, false)
	context.equal(mesh.peers[0].recover(0).code, Types.Code.NOT_SYNCHRONIZED, "recovery cannot bypass handshake")
	mesh = fixture._build(context, 2, 0, false, 128, true, false, 8, L.Options.new())
	var peer: RefCounted = mesh.peers[0]
	peer._busy = true
	context.equal(peer.recover(0).code, Types.Code.BUSY, "outer peer ownership guard")
	peer._busy = false
	context.equal(peer.close(1), I.Code.OK, "explicit peer close")
	context.equal(peer.recover(2).code, Types.Code.TERMINATED, "recovery cannot resume terminal peer")


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
