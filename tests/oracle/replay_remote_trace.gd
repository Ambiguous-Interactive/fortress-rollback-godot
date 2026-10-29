extends "res://tests/oracle/replay_session_trace.gd"


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() != 1 or args[0] not in ["--remote-recording", "--remote-recording-withhold", "--remote-recording-neutral"]:
		_fail("expected remote recording mode")
		return
	var sessions: Array[Session] = []
	var games: Array[Game] = []
	var drivers: Array[Driver] = []
	var services: Array[Array] = [[], []]
	var deliveries: Array[Dictionary] = []
	var neutral: bool = args[0] == "--remote-recording-neutral"
	for peer: int in 2:
		var config: Config = Config.new()
		config.input_width = 4
		config.neutral_input = PackedByteArray([0, 0, 0, 0])
		config.sync_test = false
		config.check_distance = 0
		config.max_prediction_frames = 4
		config.max_snapshot_bytes = 16
		config.replay_max_frames = 16
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
	for round: int in 9:
		for peer: int in 2:
			var first: int = games[peer].records.size()
			var before: int = games[peer].state[0]
			var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(peer, round, _sample(peer, round, neutral))]
			var step_code: int = drivers[peer].step(round, samples).code
			if step_code != Types.Code.OK:
				if step_code == Types.Code.PREDICTION_STALL and round == 4 and games[peer].state[0] == 4:
					_fail("remote prediction-window stall: round=4 code=PREDICTION_STALL(3) frame=4")
				else:
					_fail("unexpected remote advance failure: %d" % step_code)
				return
			var requests: Array[String] = []
			for index: int in range(first, games[peer].records.size()):
				requests.append(games[peer].records[index].kind)
			services[peer].append({"round": round, "before": before, "after": int(games[peer].state[0]), "requests": requests})
		if round % 2 == 1 and args[0] != "--remote-recording-withhold":
			for peer: int in 2:
				for frame: int in range(round - 1, round + 1):
					if sessions[peer].receive_input(1 - peer, frame, _sample(1 - peer, frame, neutral)).code != Types.Code.OK:
						_fail("remote receipt failed")
						return
			deliveries.append({"round": round, "rows": 4})
	var peers: Array[Dictionary] = []
	for peer: int in 2:
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
	print("FORTRESS_REPLAY_RESULT " + JSON.stringify({"format": 1, "peers": peers, "deliveries": deliveries}))
	quit(0)


func _sample(slot: int, frame: int, neutral: bool) -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray([0, 0, 0, 0])
	bytes.encode_u32(0, 0 if neutral else (0xffffffff + frame * 1234567 + slot * 0x1020304) & 0xffffffff)
	return bytes
