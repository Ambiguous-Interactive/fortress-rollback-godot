extends "res://tests/unit/test_peer_drop_barrier.gd"

# Value: protects=exposed confirmation survives drop; fails_when=freeze rewrites finalized history or timeout freezes without agreement;
# why_new=equal-frontier drop tests cannot expose a lower cut; seam=none
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const Basic = preload("res://tests/unit/test_peer_drop.gd")

var _hold_a_inputs: bool = false
var _drop_target_after: int = -1


func cases() -> PackedStringArray:
	return PackedStringArray(["retained_below_confirmation", "certified_below_confirmation", "unequal_exposed_frontiers", "missing_actual_rows", "pending_repair_raised_cut"])


func run_case(name: String, context: RefCounted) -> void:
	if name in ["unequal_exposed_frontiers", "missing_actual_rows", "pending_repair_raised_cut"]:
		_unequal_frontiers(context, name == "missing_actual_rows", name == "pending_repair_raised_cut")
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


func _unequal_frontiers(context: RefCounted, missing: bool, pending: bool = false) -> void:
	_hold_a_inputs = false
	_drop_target_after = 7 if missing else -1
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE, 8, 3, [], 250000, 0)
	_play(context, mesh, 6, true)
	_leave(context, mesh, 2)
	if pending:
		mesh.now += 1000
		context.equal(mesh.peers[0].recover(mesh.now).code, Types.Code.OK, "finalize frame five before predicting the next live input")
		_drain(mesh)
		mesh.now += 1000
		context.equal(mesh.peers[0].step(mesh.now, _inputs(mesh, 0)).code, Types.Code.OK, "predict live peer frame six before its changing actual arrives")
		_drain(mesh)
	mesh.now += 1000
	mesh.peers[1].step(mesh.now, _inputs(mesh, 1))
	var one_way: Array[Dictionary] = []
	for packet: Dictionary in _drain(mesh):
		if packet.from == 1 and packet.to == 0:
			one_way.append(packet)
	_deliver(context, mesh, one_way)
	mesh.now += 1000
	if not pending:
		context.equal(mesh.peers[0].recover(mesh.now).code, Types.Code.OK, "finalize the exposed prefix before dropping")
	_drain(mesh)
	if pending:
		context.equal(mesh.peers[0].status().pending_rollback_frame, 6, "a real misprediction before the raised cut remains pending")
	var exposed: int = mesh.peers[0].status().confirmed_frame
	context.equal(exposed, 5, "the first survivor exposes frame five")
	context.equal(mesh.peers[1].status().confirmed_frame, 4, "the second survivor exposes a lower frontier")
	var before: Types.FrameInputs = mesh.peers[0]._core.confirmed_inputs(exposed)
	context.equal(before != null, true, "the higher frontier has a finalized row")
	var state_before: String = _state_at(mesh.games[0], exposed)
	_hold_a_inputs = true
	_detect(context, mesh, [0, 1], 800000, true, [], [], true)
	for survivor: int in [0, 1]:
		context.equal(mesh.peers[survivor].status().lifecycle, Types.Lifecycle.TERMINATED if missing else Types.Lifecycle.RUNNING, "only missing actual history fails closed")
		context.equal(mesh.peers[survivor]._core.frozen_frame(2), -1 if missing else 8, "the cut includes the highest target receipt")
	context.equal(mesh.cuts.is_empty(), missing, "complete retained actual history permits an irreversible drop")
	context.equal(_state_at(mesh.games[0], exposed), state_before, "failed agreement preserves canonical confirmed state")
	var after: Types.FrameInputs = mesh.peers[0]._core.confirmed_inputs(exposed)
	context.equal(after != null, true, "failed agreement preserves finalized export")
	if after != null:
		context.equal(after.read(2).bytes, before.read(2).bytes, "failed agreement preserves confirmed bytes")
		context.equal(after.read(2).status, Queue.Status.CONFIRMED, "agreement preserves confirmed status")
	if not missing:
		if pending:
			context.equal(mesh.peers[0].status().pending_rollback_frame, 6, "commit preserves the earlier actual-input correction")
		_hold_a_inputs = false
		_play(context, mesh, 6, true, [0, 1], 2)
		var shared: int = mini(mesh.peers[0].status().confirmed_frame, mesh.peers[1].status().confirmed_frame) - 1
		context.equal(shared > 8, true, "the continuing canonical history reaches past the raised cut")
		context.equal(_state_at(mesh.games[0], shared), _state_at(mesh.games[1], shared), "survivors preserve one canonical confirmed history")
		for frame: int in range(exposed + 1, 9):
			var retained: Types.FrameInputs = mesh.peers[0]._core.confirmed_inputs(frame)
			context.equal(retained != null, true, "actual rows below raised cut remain available")
			if retained != null:
				context.equal(retained.read(2).bytes, _sample(2, frame), "raised cut preserves every target input before freezing")
				context.equal(retained.read(2).status, Queue.Status.CONFIRMED, "raised cut does not disconnect earlier receipt history")


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
		if _drop_target_after >= 0 and packet.from == 2 and packet.to == 1 and decoded.code == T.Code.OK and decoded.message.kind == T.Kind.INPUT:
			if decoded.message.start_frame + decoded.message.frame_count - 1 > _drop_target_after:
				continue
		if _hold_a_inputs and packet.from == 0 and packet.to == 1 and decoded.code == T.Code.OK and decoded.message.kind == T.Kind.INPUT:
			continue
		accepted.append(packet)
	super._deliver(context, mesh, accepted, terminated)
