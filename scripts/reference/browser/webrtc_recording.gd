extends RefCounted

const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const S = preload("res://addons/fortress_rollback/core/session_types.gd")
const Game = preload("res://webrtc_game.gd")
const FRAMES: int = 40
const MAX_BYTES: int = 65536


func run(host: Node, count: int) -> Dictionary:
	host.stage = "recording_confirmation"
	var peer: Peer = host.peers[0]
	var before: int = peer.status().current_frame
	if before != FRAMES:
		host.errors.append("recording_initial_frame_%d" % before)
		return {}
	# Recovery publishes bounded historical carriers when the last original input needs receipt gossip.
	# A recovery failure ends the wait immediately; the health check below refuses its latched error.
	if not await host._wait(func() -> bool: return not _recover(host, peer) or peer.status().confirmed_frame == FRAMES - 1, true):
		return {}
	if not host._healthy(true):
		return {}
	host._update_transport_clock()
	var recovered: Driver.StepResult = peer.recover(host.transport_us)
	var after: int = peer.status().current_frame
	if recovered.code != S.Code.OK or before != FRAMES or after != FRAMES or host.games[0].bytes() != host._expected(FRAMES, count):
		host.errors.append("recording_recovery_%d_%d_%d" % [recovered.code, before, after])
		return {}
	if not host._service_batch() or not host._healthy(true):
		return {}
	host.stage = "recording_capture"
	var captured: Driver.StepResult = peer.capture_replay_boundary()
	if captured.code != S.Code.OK or peer.status().current_frame != FRAMES:
		host.errors.append("recording_capture_%d" % captured.code)
		return {}
	var recording: Replay = peer.replay()
	var bytes: PackedByteArray = recording.to_bytes() if recording != null else PackedByteArray()
	if bytes.is_empty() or bytes.size() > MAX_BYTES:
		host.errors.append("recording_size_%d" % bytes.size())
		return {}
	var decoded: Replay = Replay.new()
	var decode_code: int = decoded.decode(bytes, MAX_BYTES)
	if decode_code != Replay.DecodeCode.OK or not _matches_inputs(host, decoded, count):
		host.errors.append("recording_decode_%d" % decode_code)
		return {}
	var game: Game = Game.new(count)
	var player: Player = Player.new()
	var code: int = player.configure(decoded, game, 4 + 4 * count)
	if code == S.Code.OK:
		for attempt: int in FRAMES + 2:
			code = player.step()
			if code != S.Code.OK:
				break
	if code != S.Code.FRAME_EXHAUSTED or player.current_frame() != FRAMES or player.failure_frame() != -1 \
		or player.checked_checksum_count() != FRAMES + 1 or not player.is_final_state_validated() or game.bytes() != host._expected(FRAMES, count):
		host.errors.append("recording_playback_%d_%d_%d" % [code, player.current_frame(), player.checked_checksum_count()])
		return {}
	if not host._healthy(true):
		return {}
	return {"hex": bytes.hex_encode(), "before_frame": before, "after_frame": after, "recover_code": recovered.code,
		"capture_code": captured.code, "decode_code": decode_code, "playback_code": code, "playback_frame": player.current_frame(),
		"failure_frame": player.failure_frame(), "canonical": game.bytes().hex_encode(), "checked_checksums": player.checked_checksum_count()}


func _recover(host: Node, peer: Peer) -> bool:
	host._update_transport_clock()
	var result: Driver.StepResult = peer.recover(host.transport_us)
	if result.code != S.Code.OK or peer.status().current_frame != FRAMES:
		host.errors.append("recording_confirmation_recover_%d" % result.code)
		return false
	return host._healthy(true)


func _matches_inputs(host: Node, recording: Replay, count: int) -> bool:
	if recording.frame_count() != FRAMES or recording.player_count() != count or recording.input_width() != 1 or recording.skipped_frames() != 0 \
		or recording.game_version() != "fortress-webrtc-integer-v1" or recording.game_seed() != "0":
		return false
	for frame: int in FRAMES:
		var inputs: S.FrameInputs = recording.inputs(frame)
		if inputs == null or recording.checksum(frame).size() != Replay.CHECKSUM_BYTES:
			return false
		for slot: int in count:
			var sample: S.InputResult = inputs.read(slot)
			if sample.bytes != PackedByteArray([host._sample(frame, slot)]) or sample.status != Queue.Status.CONFIRMED:
				return false
	return recording.checksum(FRAMES).size() == Replay.CHECKSUM_BYTES
