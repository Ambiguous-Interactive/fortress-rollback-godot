extends RefCounted

# Value: protects=malformed recording objects cannot replace playback or export invalid files;
# fails_when=configuration or export checks only dimensions; why_new=file decoding does not validate caller-owned recording edits; seam=none
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const Fixture = preload("res://tests/unit/test_replay_viewer.gd")
const Validation = preload("res://tests/unit/test_replay_validation.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Viewer = preload("res://examples/online/replay_viewer.gd")


class SimilarConfig:
	extends RefCounted
	var getter_calls: int = 0
	var player_count: int:
		get:
			getter_calls += 1
			return 2
	var input_width: int = 1
	var neutral_input: PackedByteArray = PackedByteArray([0])
	var diagnostic_seed: String = "1701"
	var diagnostic_version: String = Viewer.GAME_VERSION


class DerivedConfig:
	extends Config


func cases() -> PackedStringArray:
	return PackedStringArray(["malformed_storage", "malformed_metadata", "valid_recording_ownership", "invalid_config_type", "recording_accessors"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "recording_accessors":
		_recording_accessors(context)
	elif name == "invalid_config_type":
		_invalid_config_type(context)
	elif name == "valid_recording_ownership":
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


# Value: protects=wrong configuration objects return incompatibility without replacing playback;
# fails_when=matching property names substitute for FortressConfig or absent properties raise; why_new=shape tests mutate recordings only; seam=none
func _invalid_config_type(context: RefCounted) -> void:
	var recording: Replay = Fixture.recording(4)
	var similar: RefCounted = SimilarConfig.new()
	context.equal(recording.matches_config(similar), false, "matching property names do not establish a session configuration")
	context.equal(similar.getter_calls, 0, "foreign property getters cannot run during compatibility validation")
	for expert: bool in [false, true]:
		var player: Player = Player.new()
		var game: Simulation = Simulation.new()
		context.equal(_configure(player, recording, game, expert), Types.Code.OK, "real config control configures")
		if expert:
			Validation.new()._advance(context, player, game)
		else:
			context.equal(player.step(), Types.Code.OK, "real config control advances")
		for foreign: RefCounted in [similar, RefCounted.new()]:
			var code: int = player.configure_expert(recording, Simulation.SNAPSHOT_BYTES, foreign) if expert else player.configure(
				recording, Simulation.new(), Simulation.SNAPSHOT_BYTES, 0, 0, foreign
			)
			context.equal(code, Types.Code.INCOMPATIBLE_RECORDING, "wrong config type refuses both public playback modes")
		context.equal(recording.matches_config(RefCounted.new()), false, "an unrelated object refuses without property access")
		context.equal(player.current_frame(), 1, "refused config preserves selected frame")
		context.equal(player.checked_checksum_count(), 1, "refused config preserves verified coverage")
		if expert:
			Validation.new()._advance(context, player, game)
		else:
			context.equal(player.step(), Types.Code.OK, "prior game still receives ordered callbacks")
		context.equal(player.current_frame(), 2, "prior recording continues after refusal")
		context.state(game.frame, game.canonical_bytes())
	context.equal(similar.getter_calls, 0, "refused configurations cannot execute foreign getters or replace playback reentrantly")
	var derived: Config = DerivedConfig.new()
	derived.diagnostic_seed = "1701"
	derived.diagnostic_version = Viewer.GAME_VERSION
	context.equal(recording.matches_config(derived), true, "FortressConfig subclasses remain compatible")
	context.equal(Replay.new().matches_config(derived), false, "uninitialized recording cannot match a config")
	var invalid: Replay = recording.owned_copy()
	invalid._text.clear()
	context.equal(invalid.matches_config(derived), false, "malformed recording metadata refuses before indexing")


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
	context.equal(malformed.to_bytes().is_empty(), true, field + " cannot export malformed replay bytes")
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
	var incomplete: Replay = Fixture.recording(4)
	incomplete._digests.resize(incomplete._digests.size() - 1)
	context.equal(incomplete.is_valid(), true, "missing digest remains a playback-owned failure")
	context.equal(incomplete.to_bytes().is_empty(), true, "missing digest cannot produce a truncated portable file")
	context.equal(Replay.new().to_bytes().is_empty(), true, "unconfigured replay has no portable export")
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


# Value: protects=public replay reads refuse incomplete rows without publishing short samples or crashing;
# fails_when=accessors trust declared frames over retained bytes; why_new=configuration rejects malformed storage before reads; seam=none
func _recording_accessors(context: RefCounted) -> void:
	var source: Replay = Fixture.recording(3)
	for players: int in [2, 8]:
		for width: int in [1, 3]:
			var control: Replay = source.owned_copy()
			control._players = players
			control._width = width
			control._inputs.resize(3 * players * width)
			control._statuses.resize(3 * players)
			control._statuses.fill(Queue.Status.CONFIRMED)
			_row_bounds(context, control)
	for dimension: String in ["_players", "_width", "_frames"]:
		for value: int in [-1, 0, 9223372036854775807]:
			var replay: Replay = source.owned_copy()
			replay.set(dimension, value)
			context.equal(replay.inputs(0), null, "invalid dimensions refuse before indexing or multiplication")
			context.equal(replay.computed_input_digest(0), PackedByteArray(), "invalid dimensions cannot publish a row digest")
	for version: int in [3, 4, 5, 6, 7]:
		for status: int in [-1, Queue.Status.CONFIRMED, Queue.Status.PREDICTED, Queue.Status.DISCONNECTED, 255]:
			var replay: Replay = source.owned_copy()
			replay._format_version = version
			replay._statuses[2] = status
			var valid: bool = version in [4, 5, 6] and status in [Queue.Status.CONFIRMED, Queue.Status.DISCONNECTED] and not (version == 4 and status == Queue.Status.DISCONNECTED)
			context.equal(replay.inputs(1) != null, valid, "requested row exposes only format-compatible finalized statuses")
			context.equal(not replay.computed_input_digest(1).is_empty(), valid, "invalid statuses cannot publish a row digest")
			context.equal(replay.inputs(0) != null, version in [4, 5, 6], "a later invalid status preserves complete earlier rows")
	for size: int in [0, 1, 15, 16, 17, 32, 47, 48]:
		var replay: Replay = source.owned_copy()
		replay._digests.resize(size)
		for frame: int in [-1, 0, 1, 2, 3, 9223372036854775806]:
			var complete: bool = frame >= 0 and frame < 3 and (frame + 1) * Replay.DIGEST_BYTES <= size
			context.equal(replay.input_digest(frame), source.input_digest(frame) if complete else PackedByteArray(), "input digest reads require complete stored evidence")
			replay._frames = 9223372036854775807
		context.equal(replay.input_digest(9223372036854775806), PackedByteArray(), "hostile frame metadata cannot overflow digest indexing")
	var flags: Replay = source.owned_copy()
	flags._flags.clear()
	context.equal(flags.is_skipped_frame(0), false, "missing frame flags cannot claim substitution or index absent bytes")
	for size: int in range(Replay.TEXT_FIELDS + 1):
		var replay: Replay = source.owned_copy()
		replay._text.resize(size)
		var names: PackedStringArray = PackedStringArray(["engine_version", "addon_version", "upstream_revision", "game_seed", "game_version"])
		for index: int in names.size():
			context.equal(replay.call(names[index]), source.call(names[index]) if index < size else "", "missing metadata is unavailable without indexing absent fields")
	context.state(0, source.to_bytes())


func _row_bounds(context: RefCounted, source: Replay) -> void:
	for field: String in ["_inputs", "_statuses"]:
		var unit: int = source.player_count() * (source.input_width() if field == "_inputs" else 1)
		for size: int in [0, unit - 1, unit, unit + 1, 2 * unit, 3 * unit - 1, 3 * unit]:
			var replay: Replay = source.owned_copy()
			var retained: PackedByteArray = replay.get(field)
			retained.resize(size)
			replay.set(field, retained)
			for frame: int in [-1, 0, 1, 2, 3, 9223372036854775807]:
				var complete: bool = frame >= 0 and frame < 3 and (frame + 1) * unit <= size
				var inputs: Types.FrameInputs = replay.inputs(frame)
				context.equal(inputs != null, complete, field + " reads require a complete requested row")
				context.equal(replay.computed_input_digest(frame), source.computed_input_digest(frame) if complete else PackedByteArray(), "partial rows cannot publish a digest")
				if complete and inputs != null:
					for player: int in source.player_count():
						context.equal(inputs.read(player).bytes, source.inputs(frame).read(player).bytes, "complete prefix inputs survive later truncation")
						context.equal(inputs.read(player).status, source.inputs(frame).read(player).status, "complete prefix statuses survive later truncation")
			context.equal(replay.get(field), retained, "reads preserve incomplete source bytes")
