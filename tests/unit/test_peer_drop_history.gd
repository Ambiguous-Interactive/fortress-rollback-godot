extends "res://tests/unit/test_peer_drop_barrier.gd"

# Value: protects=exposed confirmation survives drop; fails_when=freeze rewrites finalized history or timeout freezes without agreement;
# why_new=equal-frontier drop tests cannot expose a lower cut; seam=none
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const Basic = preload("res://tests/unit/test_peer_drop.gd")

var _hold_a_inputs: bool = false


func cases() -> PackedStringArray:
	return PackedStringArray(["retained_below_confirmation", "certified_below_confirmation", "unequal_exposed_frontiers"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "unequal_exposed_frontiers":
		_unequal_frontiers(context)
	else:
		_rejected_freeze(context, name.begins_with("certified"))
	context.finish()


func _rejected_freeze(context: RefCounted, certified: bool) -> void:
	var config: Config = Config.new()
	config.sync_test = false
	config.check_distance = 0
	config.local_players = PackedInt32Array([0])
	config.input_width = 1
	config.neutral_input = PackedByteArray([0])
	config.max_snapshot_bytes = 16
	config.storage_budget_bytes = 65536
	var session: Session = Session.new()
	context.equal(session.configure(config), Types.Code.OK, "configure remote-input core")
	var fixture: RefCounted = Basic.new()
	for frame: int in range(3):
		fixture._advance(context, session, frame, PackedByteArray([frame + 1]))
	var before: Types.FrameInputs = session.confirmed_inputs(2)
	context.equal(before != null, true, "expose a finalized confirmed row")
	context.equal(session.status().confirmed_frame, 2, "expose confirmed high-water")
	var code: int = session.freeze_player_with_value(1, 1, PackedByteArray([9])) if certified else session.freeze_player(1, 1)
	context.equal(code, Types.Code.INVALID_FRAME, "reject a cut below exposed confirmation")
	context.equal(session.frozen_frame(1), -1, "rejection cannot freeze the slot")
	context.equal(session.status().pending_rollback_frame, -1, "rejection cannot invalidate confirmed simulation")
	var after: Types.FrameInputs = session.confirmed_inputs(2)
	context.equal(after != null, true, "rejection preserves finalized export")
	if after != null:
		context.equal(after.read(1).bytes, before.read(1).bytes, "rejection preserves confirmed bytes")
		context.equal(after.read(1).status, Queue.Status.CONFIRMED, "rejection preserves confirmed status")
	context.equal(session.freeze_player(1, 2), Types.Code.OK, "a cut at the confirmed boundary still succeeds")


func _unequal_frontiers(context: RefCounted) -> void:
	_hold_a_inputs = false
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE, 8, 3, [], 250000, 0)
	_play(context, mesh, 6, true)
	_leave(context, mesh, 2)
	mesh.now += 1000
	mesh.peers[1].step(mesh.now, _inputs(mesh, 1))
	var one_way: Array[Dictionary] = []
	for packet: Dictionary in _drain(mesh):
		if packet.from == 1 and packet.to == 0:
			one_way.append(packet)
	_deliver(context, mesh, one_way)
	mesh.now += 1000
	context.equal(mesh.peers[0].recover(mesh.now).code, Types.Code.OK, "finalize the exposed prefix before dropping")
	_drain(mesh)
	var exposed: int = mesh.peers[0].status().confirmed_frame
	context.equal(exposed, 5, "the first survivor exposes frame five")
	context.equal(mesh.peers[1].status().confirmed_frame, 4, "the second survivor exposes a lower frontier")
	var before: Types.FrameInputs = mesh.peers[0]._core.confirmed_inputs(exposed)
	context.equal(before != null, true, "the higher frontier has a finalized row")
	var state_before: String = _state_at(mesh.games[0], exposed)
	_hold_a_inputs = true
	_detect(context, mesh, [0, 1], 800000, true, [], [], true)
	for survivor: int in [0, 1]:
		context.equal(mesh.peers[survivor].status().lifecycle, Types.Lifecycle.TERMINATED, "unbackfilled unequal frontiers fail closed")
		context.equal(mesh.peers[survivor]._core.frozen_frame(2), -1, "failed agreement never freezes the departed slot")
	context.equal(mesh.cuts.is_empty(), true, "failed agreement cannot publish an irreversible drop")
	context.equal(_state_at(mesh.games[0], exposed), state_before, "failed agreement preserves canonical confirmed state")
	var after: Types.FrameInputs = mesh.peers[0]._core.confirmed_inputs(exposed)
	context.equal(after != null, true, "failed agreement preserves finalized export")
	if after != null:
		context.equal(after.read(2).bytes, before.read(2).bytes, "failed agreement preserves confirmed bytes")
		context.equal(after.read(2).status, Queue.Status.CONFIRMED, "failed agreement preserves confirmed status")


func _state_at(game: RefCounted, frame: int) -> String:
	var result: String = ""
	for request: Dictionary in game.requests:
		if request.kind == "advance" and request.frame == frame:
			result = request.state_bytes
	return result


func _deliver(context: RefCounted, mesh: Dictionary, packets: Array[Dictionary], terminated: bool = false) -> void:
	var accepted: Array[Dictionary] = []
	for packet: Dictionary in packets:
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
		if _hold_a_inputs and packet.from == 0 and packet.to == 1 and decoded.code == T.Code.OK and decoded.message.kind == T.Kind.INPUT:
			continue
		accepted.append(packet)
	super._deliver(context, mesh, accepted, terminated)
