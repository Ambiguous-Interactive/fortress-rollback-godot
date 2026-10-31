extends RefCounted

# Value: protects=finalized recordings during sustained SDK send refusal; fails_when=retry drops input or records predictions;
# why_new=recording witnesses inject input below the transport; seam=SDK public send result
const Fixture = preload("res://tests/unit/test_signalfish_fallback_mesh.gd")
const Envelope = preload("res://addons/fortress_rollback/transport/signalfish_relay_envelope.gd")
const Relay = preload("res://addons/fortress_rollback/transport/signalfish_relay.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const Reference = preload("res://tests/oracle/reference_game.gd")
const Game = preload("res://tests/oracle/p2p_game.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Cleanup = preload("res://tests/unit/test_signalfish_fallback.gd")
const FRAMES: int = 257


class Client:
	extends Fixture.Client
	var refused: int = 0
	var retried: int = 0
	var blocked_head: PackedByteArray = PackedByteArray()
	var changed_head: bool = false

	func send_game_data_binary(bytes: PackedByteArray) -> Error:
		if not blocked_head.is_empty() and bytes != blocked_head:
			changed_head = true
		if busy:
			refused += 1
			blocked_head = bytes.duplicate()
			return ERR_BUSY
		if not blocked_head.is_empty():
			retried += 1
			blocked_head.clear()
		return super.send_game_data_binary(bytes)


func cases() -> PackedStringArray:
	return PackedStringArray(["changing", "neutral"])


func run_case(name: String, context: RefCounted) -> void:
	var neutral: bool = name == "neutral"
	var helper: RefCounted = Fixture.new()
	var fixtures: Array[Dictionary] = []
	for index: int in 3:
		fixtures.append(helper._build(context, index, FRAMES, Client.new()))
	for tick: int in 20:
		_service(context, fixtures, tick, false)
	for fixture: Dictionary in fixtures:
		context.equal(fixture.peer.network_status().state, "running", "relay handshake completed")
	var prefixes: Array[PackedByteArray] = _prefixes(context, neutral)
	var stalls: PackedInt32Array = PackedInt32Array([0, 0, 0])
	var loads: PackedInt32Array = PackedInt32Array([0, 0, 0])
	var pressured_comparisons: PackedInt32Array = PackedInt32Array([0, 0, 0])
	var saved: Array[Dictionary] = [{}, {}, {}]
	var now: int = 20
	for turn: int in 1000:
		now += 1000
		var finished: bool = true
		for index: int in 3:
			var peer: Peer = fixtures[index].peer
			var frame: int = peer.status().current_frame
			if frame == FRAMES:
				continue
			finished = false
			var retained: Types.InputResult = peer.scheduled_local_input(index)
			var inputs: Array[Driver.LocalInput] = []
			if retained.code == Types.Code.MISSING_LOCAL_INPUT:
				inputs.append(Driver.LocalInput.new(index, frame, _sample(index, frame, neutral)))
			var result: Driver.StepResult = peer.step(now, inputs)
			context.equal(result.code in [Types.Code.OK, Types.Code.PREDICTION_STALL, Types.Code.NETWORK_BACKPRESSURE], true, "send refusal remains recoverable")
			if result.frame_after == frame:
				stalls[index] += 1
			pressured_comparisons[index] += _observe(context, fixtures[index], prefixes, saved[index], loads, index)
		_service(context, fixtures, now, true, turn)
		if finished:
			break
	for fixture: Dictionary in fixtures:
		context.equal(fixture.peer.status().current_frame, FRAMES, "service bound reaches all original frames")
	for index: int in 3:
		context.equal(pressured_comparisons[index] > 0, true, "post-wrap canonical comparisons happened before pressure release")
		context.equal(loads[index] > 0, not neutral, "changing originals were repaired before pressure release")
	# Release transport pressure and converge receipts without another local sample or forward step.
	for _round: int in 256:
		now += 1000
		for index: int in 3:
			context.equal(fixtures[index].peer.recover(now).code, Types.Code.OK, "recovery only after delayed final receipts")
			pressured_comparisons[index] += _observe(context, fixtures[index], prefixes, saved[index], loads, index)
		_service(context, fixtures, now, false)
	for index: int in 3:
		var fixture: Dictionary = fixtures[index]
		var client: Client = fixture.client
		var peer: Peer = fixture.peer
		context.equal(client.refused > 0, true, "SDK actually refused sends")
		context.equal(client.retried > 0, true, "refused bytes later accepted")
		context.equal(client.changed_head, false, "every refused head retries identical envelope bytes")
		context.equal(client.blocked_head.is_empty(), true, "every final refused head drained")
		context.equal(stalls[index] > 0, true, "each endpoint stalled under sustained asymmetric pressure")
		context.equal(loads[index] > 0, not neutral, "only changing originals require correction")
		context.equal(peer.status().current_frame, FRAMES, "final recovery never advances gameplay")
		context.bytes_equal(fixture.game.game.bytes(), prefixes[FRAMES], FRAMES, "final corrected state matches original history")
		context.equal(peer.capture_replay_boundary().code, Types.Code.OK, "capture recovered final checksum")
		var recording: Replay = Replay.new()
		context.equal(recording.decode(peer.replay().to_bytes()), Replay.DecodeCode.OK, "decode actual transport recording")
		context.equal(recording.frame_count(), FRAMES, "every original row is finalized")
		context.equal(recording.skipped_frames(), 0, "transport refusal omits no history")
		if recording.frame_count() != FRAMES:
			Cleanup.new().destroy(fixture)
			continue
		for frame: int in FRAMES:
			for slot: int in 3:
				var input: Types.InputResult = recording.inputs(frame).read(slot)
				context.equal(input.status, Queue.Status.CONFIRMED, "exported row is finalized")
				context.bytes_equal(input.bytes, _sample(slot, frame, neutral), frame, "exported input is original")
			var original: Reference = Reference.new(3, 2)
			context.equal(original.restore(prefixes[frame]), "", "restore independently calculated boundary")
			context.bytes_equal(recording.checksum(frame), original.checksum().hex_decode(), frame, "recorded checksum binds original history")
		var playback: Game = Game.new(3)
		var player: Player = Player.new()
		context.equal(player.configure(recording, playback, 24), Types.Code.OK, "play transport-owned recording")
		for frame: int in FRAMES:
			context.equal(player.step(), Types.Code.OK, "decoded playback accepts original input")
			context.bytes_equal(playback.game.bytes(), prefixes[frame + 1], frame + 1, "every decoded canonical boundary matches")
		context.equal(player.step(), Types.Code.OK, "decoded final checksum validates")
		context.equal(player.is_final_state_validated(), true, "transport replay proves final state")
		context.state(FRAMES, playback.game.bytes())
		Cleanup.new().destroy(fixture)
	context.finish()


func _service(context: RefCounted, fixtures: Array[Dictionary], now: int, pressure: bool, turn: int = 0) -> void:
	for index: int in 3:
		var fixture: Dictionary = fixtures[index]
		fixture.client.busy = pressure and turn % (index + 4) != index + 3
		context.equal(fixture.peer.poll(now), 0, "poll actual byte session")
		var packets: Array[Peer.Packet] = fixture.peer.drain_outbox()
		context.equal(fixture.relay.enqueue_batch(packets), Relay.Code.OK, "transport owns complete peer batch")
		var result: Relay.Result = fixture.relay.poll(now)
		context.equal(result.code in [Relay.Code.OK, Relay.Code.BACKPRESSURE], true, "bounded relay send/receive work")
	for fixture: Dictionary in fixtures:
		for envelope: PackedByteArray in fixture.client.sent:
			var decoded: Envelope.Decoded = Envelope.decode(envelope, 512)
			context.equal(decoded.code, Relay.Code.OK, "decode actual accepted relay envelope")
			for target: Dictionary in fixtures:
				if target.client.local == decoded.recipient:
					target.client.game_data_binary_received.emit(fixture.client.local, 1, envelope)
		fixture.client.sent.clear()


func _observe(context: RefCounted, fixture: Dictionary, prefixes: Array[PackedByteArray], saved: Dictionary, loads: PackedInt32Array, index: int) -> int:
	var post_wrap_comparisons: int = 0
	for request: Dictionary in fixture.game.requests:
		if request.kind == "load":
			loads[index] += 1
		if request.kind == "save":
			saved[request.frame] = request.state_bytes.hex_decode()
	fixture.game.requests.clear()
	var confirmed: int = fixture.peer.status().confirmed_frame
	for frame: int in saved.keys():
		if frame <= confirmed and frame < fixture.peer.status().current_frame:
			context.bytes_equal(saved[frame], prefixes[frame], frame, "corrected original prefix while refusal is active")
			saved.erase(frame)
			if frame > 128:
				post_wrap_comparisons += 1
	return post_wrap_comparisons


func _sample(slot: int, frame: int, neutral: bool) -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray([0, 0, 0, 0])
	bytes.encode_u32(0, 0 if neutral else (0xffffffff + frame * 1234567 + slot * 0x1020304) & 0xffffffff)
	return bytes


func _prefixes(context: RefCounted, neutral: bool) -> Array[PackedByteArray]:
	var game: Reference = Reference.new(3, 2)
	var prefixes: Array[PackedByteArray] = [game.bytes()]
	for frame: int in FRAMES:
		var inputs: Array[Dictionary] = []
		for slot: int in 3:
			inputs.append({"player": slot, "bytes": _sample(slot, frame, neutral).hex_encode(), "status": "confirmed"})
		context.equal(game.advance(inputs), "", "independent original canonical history")
		prefixes.append(game.bytes())
	return prefixes
