extends "res://tests/oracle/replay_session_trace.gd"


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if (
		args.size() != 1
		or (
			args[0]
			not in [
				"--remote-recording-pressure",
				"--remote-recording-pressure-neutral",
				"--remote-recording-pressure-withhold",
				"--remote-recording-asymmetric",
				"--remote-recording-asymmetric-terminal",
				"--remote-recording-asymmetric-terminal-neutral",
				"--remote-recording-asymmetric-neutral",
				"--remote-recording-asymmetric-withhold",
				"--remote-recording",
				"--remote-recording-withhold",
				"--remote-recording-neutral",
				"--remote-recording-long",
				"--remote-recording-neutral-long"
			]
		)
	):
		_fail("expected remote recording mode")
		return
	var sessions: Array[Session] = []
	var games: Array[Game] = []
	var drivers: Array[Driver] = []
	var services: Array[Array] = [[], []]
	var deliveries: Array[Dictionary] = []
	var neutral: bool = args[0].contains("neutral")
	var asymmetric: bool = args[0].contains("asymmetric") or args[0].contains("pressure")
	var pressure: bool = args[0].contains("pressure")
	var terminal: bool = args[0].contains("terminal")
	var received: Array[int] = [-1, -1]
	var rounds: int = 257 if args[0].ends_with("-long") or asymmetric else 9
	for peer: int in 2:
		var config: Config = Config.new()
		config.input_width = 4
		config.neutral_input = PackedByteArray([0, 0, 0, 0])
		config.sync_test = false
		config.check_distance = 0
		config.max_prediction_frames = 4
		config.max_snapshot_bytes = 16
		config.replay_max_frames = rounds
		config.local_players = PackedInt32Array([peer])
		config.storage_budget_bytes = config.required_storage_bytes()
		var session: Session = Session.new()
		if session.configure(config) != Types.Code.OK:
			_fail("remote recording configure failed")
			return
		var game: Game = Game.new()
		game.state[1] = 0xffffffff
		game.state[2] = 0xffffffff
		sessions.append(session)
		games.append(game)
		drivers.append(Driver.new(session, game))
	for turn: int in 400 if pressure else rounds:
		if pressure and games[0].state[0] == rounds and games[1].state[0] == rounds:
			break
		for peer: int in 2:
			if pressure and games[peer].state[0] == rounds:
				continue
			var round: int = games[peer].state[0] if pressure else turn
			var first: int = games[peer].records.size()
			var before: int = games[peer].state[0]
			var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(peer, round, _sample(peer, round, neutral))]
			var step_code: int = drivers[peer].step(round, samples).code
			if pressure and args[0].ends_with("-withhold") and step_code == Types.Code.PREDICTION_STALL:
				_fail("pressure prediction-window stall: peer=%d turn=%d frames=[%d,%d]" % [peer, turn, games[0].state[0], games[1].state[0]])
				return
			if step_code != Types.Code.OK and not (pressure and step_code == Types.Code.PREDICTION_STALL):
				if pressure:
					_fail("pressure retry failed: peer=%d turn=%d frame=%d code=%d" % [peer, turn, before, step_code])
					return
				if step_code == Types.Code.PREDICTION_STALL and round == 4 and games[peer].state[0] == 4:
					if asymmetric:
						_fail("asymmetric prediction-window stall: peer=%d round=4 frames=[%d,%d]" % [peer, games[0].state[0], games[1].state[0]])
					else:
						_fail("remote prediction-window stall: round=4 code=PREDICTION_STALL(3) frame=4")
				else:
					_fail("unexpected remote advance failure: %d" % step_code)
				return
			var requests: Array[String] = []
			for index: int in range(first, games[peer].records.size()):
				requests.append(games[peer].records[index].kind)
			services[peer].append({"round": turn, "before": before, "after": int(games[peer].state[0]), "requests": requests})
		if asymmetric:
			for peer: int in 2:
				var period: int = 5 if pressure and peer == 1 else peer + 2
				if turn % period != period - 1 or (peer == 1 and args[0].ends_with("-withhold")):
					continue
				var count: int = 0
				for frame: int in range(received[peer] + 1, int(games[1 - peer].state[0]) if pressure else turn + 1):
					if sessions[peer].receive_input(1 - peer, frame, _sample(1 - peer, frame, neutral)).code != Types.Code.OK:
						_fail("asymmetric receipt failed")
						return
					count += 1
				received[peer] = int(games[1 - peer].state[0]) - 1 if pressure else turn
				deliveries.append({"round": turn, "peer": peer, "rows": count})
			continue
		if turn % 2 == 1 and args[0] != "--remote-recording-withhold":
			var delivered_rows: int = 0
			for peer: int in 2:
				for frame: int in range(turn - 1, turn + 1):
					if sessions[peer].receive_input(1 - peer, frame, _sample(1 - peer, frame, neutral)).code != Types.Code.OK:
						_fail("remote receipt failed")
						return
					delivered_rows += 1
			deliveries.append({"round": turn, "rows": delivered_rows})
	if pressure and (games[0].state[0] != rounds or games[1].state[0] != rounds):
		_fail("pressure service bound exhausted")
		return
	var recovery: Array[Dictionary] = []
	if asymmetric:
		for peer: int in 2:
			var count: int = 0
			for frame: int in range(received[peer] + 1, rounds):
				if sessions[peer].receive_input(1 - peer, frame, _sample(1 - peer, frame, neutral)).code != Types.Code.OK:
					_fail("asymmetric final receipt failed")
					return
				count += 1
			var first: int = games[peer].records.size()
			var code: int = drivers[peer].recover(rounds).code
			if code != Types.Code.OK:
				_fail("asymmetric recovery failed: %d" % code)
				return
			var requests: Array[String] = []
			for index: int in range(first, games[peer].records.size()):
				requests.append(games[peer].records[index].kind)
			recovery.append({"peer": peer, "rows": count, "before": rounds, "after": int(games[peer].state[0]), "requests": requests})
	var peers: Array[Dictionary] = []
	for peer: int in 2:
		if terminal and drivers[peer].capture_replay_boundary().code != Types.Code.OK:
			_fail("asymmetric terminal capture failed")
			return
		var recording: Replay = sessions[peer].replay()
		var decoded: Replay = Replay.new()
		if decoded.decode(recording.to_bytes()) != Replay.DecodeCode.OK or decoded.to_bytes() != recording.to_bytes():
			_fail("remote recording roundtrip failed")
			return
		var rows: Array[Array] = []
		var checksums: Array = []  # Recorded checksum evidence is absent or hexadecimal bytes.
		for frame: int in decoded.frame_count():
			var row: Array[int] = []
			for slot: int in 2:
				var input: Types.InputResult = decoded.inputs(frame).read(slot)
				if input.status != Queue.Status.CONFIRMED:
					_fail("recording exported speculative input")
					return
				row.append(input.bytes.decode_u32(0))
			rows.append(row)
			var digest: PackedByteArray = decoded.checksum(frame)
			checksums.append(null if digest.is_empty() else digest.hex_encode())
		var playback: Dictionary = _play(decoded, 0xffffffff, true, false)
		playback.name = "remote-%d" % peer
		peers.append(
			{
				"peer": peer,
				"current_frame": int(games[peer].state[0]),
				"bytes": games[peer].bytes().hex_encode(),
				"records": games[peer].records,
				"services": services[peer],
				"frames": rows,
				"checksums": checksums,
				"skipped": decoded.skipped_frames(),
				"playback": playback
			}
		)
		if terminal:
			peers[-1].terminal_checksum = decoded.checksum(rounds).hex_encode()
	var result: Dictionary = {"format": 1, "peers": peers, "deliveries": deliveries}
	if asymmetric:
		result.recovery = recovery
	print("FORTRESS_REPLAY_RESULT " + JSON.stringify(result))
	quit(0)


func _sample(slot: int, frame: int, neutral: bool) -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray([0, 0, 0, 0])
	bytes.encode_u32(0, 0 if neutral else (0xffffffff + frame * 1234567 + slot * 0x1020304) & 0xffffffff)
	return bytes
