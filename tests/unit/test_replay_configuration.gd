extends RefCounted

# Value: protects=malformed recording objects cannot replace working playback or cause unchecked indexing;
# fails_when=configuration checks only dimensions; why_new=file decoding does not validate caller-owned recording edits; seam=none
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const Fixture = preload("res://tests/unit/test_replay_viewer.gd")
const Validation = preload("res://tests/unit/test_replay_validation.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Viewer = preload("res://examples/online/replay_viewer.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["malformed_storage", "malformed_metadata", "valid_recording_ownership"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "valid_recording_ownership":
		_ownership(context)
	else:
		var fields: PackedStringArray = PackedStringArray(["_inputs", "_statuses", "_flags", "_checksums", "_digests", "_neutral"])
		if name == "malformed_metadata":
			fields = PackedStringArray([
				"version", "metadata count", "metadata encoding", "metadata size", "delay", "prediction", "skipped count", "flag", "status",
				"terminal", "historical terminal", "skipped input", "skipped status", "legacy status",
			])
		for expert: bool in [false, true]:
			for field: String in fields:
				for length_delta: int in ([-1, 1] if name == "malformed_storage" else [0]):
					if field == "_digests" and length_delta < 0:
						continue
					_rejection(context, expert, field, length_delta)
	context.finish()


func _rejection(context: RefCounted, expert: bool, field: String, length_delta: int) -> void:
	var valid: Replay = Fixture.recording(4)
	var malformed: Replay = valid.owned_copy()
	if length_delta != 0:
		var bytes: PackedByteArray = malformed.get(field)
		bytes.resize(bytes.size() + length_delta)
		malformed.set(field, bytes)
	else:
		match field:
			"version":
				malformed._format_version = 7
			"metadata count":
				malformed._text.resize(4)
			"metadata encoding":
				malformed._text[0] = "not\nprintable"
			"metadata size":
				malformed._text[0] = "x".repeat(Replay.MAX_TEXT_BYTES + 1)
			"delay":
				malformed._input_delay = 65536
			"prediction":
				malformed._max_prediction_frames = 129
			"skipped count":
				malformed._skipped = 1
			"flag":
				malformed._flags[0] = 3
			"status":
				malformed._statuses[0] = Queue.Status.PREDICTED
			"terminal":
				malformed._format_version = Replay.TERMINAL_VERSION
				malformed._terminal_checksum.resize(15)
			"historical terminal":
				malformed._terminal_checksum.resize(16)
			"skipped input", "skipped status":
				malformed._flags[0] = Replay.FLAG_SKIPPED
				malformed._skipped = 1
				if field == "skipped status":
					malformed._inputs[0] = 0
					malformed._inputs[1] = 0
					malformed._statuses[0] = Queue.Status.DISCONNECTED
			"legacy status":
				malformed._format_version = 4
				malformed._statuses[0] = Queue.Status.DISCONNECTED
	var game: Simulation = Simulation.new()
	var player: Player = Player.new()
	context.equal(_configure(player, valid, game, expert), Types.Code.OK, "valid control configures")
	if expert:
		Validation.new()._advance(context, player, game)
	else:
		context.equal(player.step(), Types.Code.OK, "valid control advances")
	var code: int = _configure(player, malformed, Simulation.new(), expert)
	context.equal(code, Types.Code.INVALID_CONFIGURATION, field + " refuses before replacing playback")
	if code != Types.Code.INVALID_CONFIGURATION:
		return
	context.equal(player.current_frame(), 1, "rejected recording preserves selected boundary")
	context.equal(player.checked_checksum_count(), 1, "rejected recording preserves verified coverage")
	if expert:
		Validation.new()._advance(context, player, game)
	else:
		context.equal(player.step(), Types.Code.OK, "original playback remains usable")
	context.equal(player.current_frame(), 2, "rejected recording cannot consume old inputs")
	context.state(game.frame, game.canonical_bytes())


func _configure(player: Player, replay: Replay, game: Simulation, expert: bool) -> int:
	var config: Config = Config.new()
	config.diagnostic_seed = "1701"
	config.diagnostic_version = Viewer.GAME_VERSION
	if expert:
		return player.configure_expert(replay, Simulation.SNAPSHOT_BYTES, config)
	return player.configure(replay, game, Simulation.SNAPSHOT_BYTES, 0, 0, config)


func _ownership(context: RefCounted) -> void:
	for expert: bool in [false, true]:
		for version: int in [4, 5, 6]:
			var source: Replay = Fixture.recording(4)
			source._format_version = version
			if version == 4:
				for frame: int in 4:
					var digest: PackedByteArray = source.computed_input_digest(frame)
					for index: int in Replay.DIGEST_BYTES:
						source._digests[frame * Replay.DIGEST_BYTES + index] = digest[index]
			if version == 6:
				var terminal_game: Simulation = Simulation.new()
				for frame: int in 4:
					terminal_game.simulate_frame(frame, source.inputs(frame))
				source._terminal_checksum = Simulation.checksum(terminal_game.canonical_bytes())
			var replay: Replay = Replay.new()
			context.equal(replay.decode(source.to_bytes()), Replay.DecodeCode.OK, "historical and terminal control files decode")
			var player: Player = Player.new()
			var game: Simulation = Simulation.new()
			context.equal(_configure(player, replay, game, expert), Types.Code.OK, "supported recording configures")
			replay._inputs.clear()
			replay._statuses.clear()
			replay._text.clear()
			for frame: int in (5 if version == 6 else 4):
				if expert:
					Validation.new()._advance(context, player, game)
				else:
					context.equal(player.step(), Types.Code.OK, "owned playback survives caller edits")
			context.equal(player.is_complete(), true, "supported playback completes with original owned rows")
			context.state(game.frame, game.canonical_bytes())
