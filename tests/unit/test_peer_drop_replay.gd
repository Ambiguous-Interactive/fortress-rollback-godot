extends "res://tests/unit/test_peer_drop_backfill.gd"

# Value: protects=decoded drop recordings preserve repaired original history and statuses; fails_when=donor recovery records speculative or status-free rows;
# why_new=barrier tests compare live state but never decode and replay its recording; seam=none
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const FRAMES: int = 12
const CUT: int = 8
const STATUS_BONUS: int = 100003


class RecordingGame:
	extends WideGame

	func save_state(at: int, writer: RefCounted) -> Driver.SaveResult:
		var hash: HashingContext = HashingContext.new()
		hash.start(HashingContext.HASH_MD5)
		hash.update(bytes())
		return Driver.SaveResult.new(at == frame and writer.write_bytes(bytes()) == 0, hash.finish())

	func simulate_frame(at: int, inputs: Types.FrameInputs) -> bool:
		if not super.simulate_frame(at, inputs):
			return false
		for slot: int in values.size():
			if inputs.read(slot).status == Queue.Status.DISCONNECTED:
				values[slot] += STATUS_BONUS * (slot + 1)
		states[at] = bytes()
		return true


func cases() -> PackedStringArray:
	return PackedStringArray(["remote_donor_recording", "lost_reordered_history_recording"])


func run_case(name: String, context: RefCounted) -> void:
	_mode = "remote_donor" if name == "remote_donor_recording" else "loss_reorder"
	_slots = 1 if _mode == "remote_donor" else 2
	_missing_peer = 0 if _mode == "remote_donor" else 1
	_seen = 0
	_dropped_chunk = false
	_reordered = false
	_held.clear()
	_donor_sources.clear()
	var mesh: Dictionary = _recording_mesh(context, FRAMES, func(players: int) -> RefCounted: return RecordingGame.new(players))
	_play(context, mesh, 6, true)
	_leave(context, mesh, 2)
	for slot: int in range(2 * _slots, 3 * _slots):
		context.equal(mesh.peers[_missing_peer]._core.received_frames()[slot], CUT - 1, "real recipient lacks the final original target row")
		context.equal(mesh.peers[1 - _missing_peer]._core.received_frames()[slot], CUT, "real donor retains the original missing row")
	_detect(context, mesh, [0, 1], 800000, true, [], [], true)
	context.equal(_seen > 0, true, "actual encoded historical chunks were delivered")
	context.equal(_donor_sources.keys(), [1 - _missing_peer], "only the selected survivor supplies original history")
	context.equal(mesh.cuts, {0: CUT, 1: CUT}, "all survivors commit the receipt-raised cut")
	if _mode == "remote_donor":
		context.equal(mesh.peers[0]._drops.barrier(_id(2).hex_encode()).history.donor, 1, "the donor differs from the coordinator")
	else:
		context.equal(_dropped_chunk, true, "first history chunk was lost")
		context.equal(_reordered, true, "retry was delivered after its successor")
	_play(context, mesh, 6, true, [0, 1], 2)
	for _round: int in 4:
		for survivor: int in [0, 1]:
			context.equal(mesh.peers[survivor].recover(mesh.now).code, Types.Code.OK, "finalize late receipts without another input sample")
		_deliver(context, mesh, _without_peer(_drain(mesh), 2))
	for survivor: int in [0, 1]:
		var peer: Peer = mesh.peers[survivor]
		context.equal(peer.status().current_frame, FRAMES, "recovery preserves the exact final boundary")
		context.equal(mesh.games[survivor].bytes(), _original_state(FRAMES), "live state includes original inputs and disconnect effects")
		context.equal(peer._core.statistics().resimulated_frames > 0, true, "each survivor actually corrects predicted history")
		context.equal(peer.capture_replay_boundary().code, Types.Code.OK, "capture the finalized drop recording without advancement")
		context.equal(peer.status().current_frame, FRAMES, "capture adds no forward frame")
		var decoded: Replay = Replay.new()
		context.equal(decoded.decode(peer.replay().to_bytes()), Replay.DecodeCode.OK, "decode actual survivor recording")
		context.equal(decoded.frame_count(), FRAMES, "all original and continued rows are finalized")
		context.equal(decoded.skipped_frames(), 0, "donor repair does not substitute neutral rows")
		for frame: int in FRAMES:
			for slot: int in 3 * _slots:
				var input: Types.InputResult = decoded.inputs(frame).read(slot)
				var disconnected: bool = slot >= 2 * _slots and frame > CUT
				context.equal(input.bytes, _sample(slot, CUT if disconnected else frame), "decoded recording preserves every original and frozen sample")
				context.equal(input.status, Queue.Status.DISCONNECTED if disconnected else Queue.Status.CONFIRMED, "decoded status changes strictly after the certified cut")
		for expert: bool in [false, true]:
			for fault: String in ["none", "last_input", "disconnect_status", "terminal"]:
				_play_recording(context, decoded, expert, fault)
	context.finish()


func _original_state(boundary: int) -> PackedByteArray:
	var state: PackedByteArray = PackedByteArray()
	state.resize(8 * (3 * _slots + 1))
	state.encode_s64(0, boundary)
	for slot: int in 3 * _slots:
		var value: int = 0
		for frame: int in boundary:
			var disconnected: bool = slot >= 2 * _slots and frame > CUT
			for byte: int in _sample(slot, CUT if disconnected else frame):
				value += byte
			if disconnected:
				value += STATUS_BONUS * (slot + 1)
		state.encode_s64(8 * (slot + 1), value)
	return state


func _play_recording(context: RefCounted, source: Replay, expert: bool, fault: String) -> void:
	var changed: Replay = source.owned_copy()
	if fault == "last_input":
		changed._inputs[(FRAMES - 1) * changed.player_count() * _width] ^= 1
	elif fault == "disconnect_status":
		var frame: int = CUT + 1
		changed._statuses[frame * changed.player_count() + 2 * _slots] = Queue.Status.CONFIRMED
		# Keep a valid input digest to exercise the status-sensitive state comparison itself.
		var digest: PackedByteArray = changed.computed_input_digest(frame)
		for index: int in Replay.DIGEST_BYTES:
			changed._digests[frame * Replay.DIGEST_BYTES + index] = digest[index]
	elif fault == "terminal":
		changed._terminal_checksum[0] ^= 1
	var decoded: Replay = Replay.new()
	context.equal(decoded.decode(changed.to_bytes()), Replay.DecodeCode.OK, "serialized control reaches the installed decoder")
	var player: Player = Player.new()
	var game: RecordingGame = RecordingGame.new(decoded.player_count())
	var bound: int = 8 * (decoded.player_count() + 1)
	var configured: int = player.configure_expert(decoded, bound) if expert else player.configure(decoded, game, bound)
	context.equal(configured, Types.Code.OK, "configure decoded callback/expert playback")
	var stop: int = {"none": FRAMES + 1, "last_input": FRAMES - 1, "disconnect_status": CUT + 2, "terminal": FRAMES}[fault]
	for boundary: int in stop:
		context.equal(_dispatch(player, game) if expert else player.step(), Types.Code.OK, "play finalized rows and matching state checksums")
		if fault != "disconnect_status" or boundary < CUT + 1:
			context.equal(game.bytes(), _original_state(mini(boundary + 1, FRAMES)), "every replayed boundary matches independently reconstructed originals")
	if fault == "none":
		context.equal(player.is_final_state_validated(), true, "decoded survivor recording validates the captured terminal state")
		context.equal(player.is_complete(), true, "decoded survivor playback completes")
		context.equal(player.checked_checksum_count(), FRAMES + 1, "every recorded input boundary and terminal checksum actually matched")
		context.equal(_dispatch(player, game) if expert else player.step(), Types.Code.FRAME_EXHAUSTED, "terminal verification consumes no extra input")
	else:
		context.equal(_dispatch(player, game) if expert else player.step(), Types.Code.DESYNC, "serialized corruption fails at its owning comparison")
		context.equal(player.failure_frame(), stop, "failure names the first bad input or state boundary")
		var comparison: String = "input_digest" if fault == "last_input" else "state_checksum"
		context.equal(player.failure_comparison(), comparison, "status corruption is caught independently of its input digest")
		context.equal(player.is_complete(), false, "corrupted recordings cannot complete")
	context.state(player.current_frame(), game.bytes())


func _dispatch(player: Player, game: RecordingGame) -> int:
	var result: Types.Result = player.begin_advance()
	if result.code != Types.Code.READY:
		return result.code
	while true:
		var request: Types.Request = result.batch.next_request()
		if request == null:
			return Types.Code.OK
		var checksum: PackedByteArray = PackedByteArray()
		var ok: bool = false
		if request.kind == Types.Kind.SAVE:
			var saved: Driver.SaveResult = game.save_state(request.frame, request.writer)
			ok = saved.ok
			checksum = saved.checksum
		else:
			ok = game.simulate_frame(request.frame, request.inputs)
		var code: int = player.complete_request(request.batch_id, request.request_id, ok, checksum).code
		if code != Types.Code.OK:
			return code
	return Types.Code.OK
