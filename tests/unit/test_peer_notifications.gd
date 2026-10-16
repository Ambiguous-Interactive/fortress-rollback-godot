extends RefCounted

# Value: protects=peer completion after controls and guarded reentry; fails_when=notice is absent, early or recursive; why_new=driver signal precedes peer controls; seam=none
const Fixture = preload("res://tests/unit/test_peer_session.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const L = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["completion", "stall_and_repair", "failure", "callback_failure"])


func run_case(name: String, context: RefCounted) -> void:
	var fixture: RefCounted = Fixture.new()
	var mesh: Dictionary = fixture._build(context, 2, 0, false, 128, true, false, 2, L.Options.new())
	var peer: Peer = mesh.peers[0]
	context.equal(peer.has_signal("step_completed"), true, "peer offers a completed outer-step notice")
	if not peer.has_signal("step_completed"):
		context.finish()
		return
	var notices: Array[PackedInt32Array] = []
	var reference: WeakRef = weakref(peer)
	var game: RefCounted = mesh.games[0]
	peer.connect(
		"step_completed",
		func(code: int, before: int, after: int) -> void:
			var target: Peer = reference.get_ref()
			notices.append(PackedInt32Array([code, before, after]))
			context.equal(target.status().current_frame, after, "final corrected frame visible")
			context.equal(game.game.frame, after, "all game callbacks completed")
			context.equal(target.poll(999), I.Code.BUSY, "signal cannot poll")
			context.equal(target.close(999), I.Code.BUSY, "signal cannot close")
			context.equal(target.begin(999, []), I.Code.BUSY, "signal cannot begin")
			context.equal(target.configure(null, null, null, null, null), I.Code.BUSY, "signal cannot configure")
			context.equal(target.step(999, []).code, Types.Code.BUSY, "signal cannot recursively step")
			context.equal(target.receive(PackedByteArray(), target.peer_ids()[0], 999), I.Code.BUSY, "signal cannot receive")
			context.equal(target.drain_outbox().size(), 0, "signal cannot drain unpublished work")
	)
	if name == "completion":
		for round_index: int in 7:
			mesh.now += 1000
			var before: int = peer.status().current_frame
			var result: RefCounted = peer.step(mesh.now, fixture._inputs(mesh, 0))
			context.equal(notices[-1], PackedInt32Array([result.code, before, result.frame_after]), "notice matches returned outcome")
			context.equal(notices.size(), round_index + 1, "one notice per outer step")
			context.equal(mesh.peers[1].step(mesh.now, fixture._inputs(mesh, 1)).code, Types.Code.OK, "remote step")
			fixture._deliver(context, mesh, fixture._drain(mesh))
			fixture._deliver(context, mesh, fixture._drain(mesh))
	elif name == "stall_and_repair":
		for frame: int in 2:
			context.equal(peer.step(frame, fixture._inputs(mesh, 0)).code, Types.Code.OK, "predict remote")
		context.equal(peer.step(2, fixture._inputs(mesh, 0)).code, Types.Code.PREDICTION_STALL, "window stalls")
		context.equal(mesh.peers[1].step(2, fixture._inputs(mesh, 1)).code, Types.Code.OK, "actual remote correction")
		mesh.now = 2
		fixture._deliver(context, mesh, fixture._drain(mesh))
		fixture._deliver(context, mesh, fixture._drain(mesh))
		var result: RefCounted = peer.step(3, fixture._inputs(mesh, 0))
		context.equal(result.code, Types.Code.PREDICTION_STALL, "repair completes while new frame still stalls")
		context.equal(peer.statistics().rollback_count, 1, "notice follows actual rollback")
		context.equal(notices[-1], PackedInt32Array([result.code, 2, 2]), "repair-only final outcome")
		context.equal(notices.size(), 4, "reentry never emits another notice")
	elif name == "callback_failure":
		game.game.accumulators.resize(0)
		var result: RefCounted = peer.step(1, fixture._inputs(mesh, 0))
		context.equal(result.code, Types.Code.CALLBACK_FAILED, "invalid application state fails simulation callback")
		context.equal(notices[-1], PackedInt32Array([Types.Code.CALLBACK_FAILED, 0, 0]), "final peer notification retains callback failure")
		context.equal(peer.network_status().state, "terminated", "peer controls finish terminal cleanup before return")
		context.equal(notices.size(), 1, "one failed-batch notice")
	else:
		context.equal(peer.close(0), I.Code.OK, "explicit terminal outcome")
		var result: RefCounted = peer.step(1, fixture._inputs(mesh, 0))
		context.equal(notices[-1], PackedInt32Array([result.code, 0, 0]), "terminal result is visible")
		context.equal(notices.size(), 1, "one terminal notice")
	context.finish()
