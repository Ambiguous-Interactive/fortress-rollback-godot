extends RefCounted

# Value: protects=match recording, playback and the replay file format; fails_when=recorded inputs follow predictions, frames drop at discard,
# corrupt or unsupported files load, or the layout drifts from the independent golden; why_new=no replay support; seam=none
const Game = preload("res://examples/integration/game.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const FRAMES: int = 90


## Diverges from frame 40, as a game build with different rules would.
class ChangedRules:
	extends Game

	func simulate_frame(input_frame: int, inputs: Types.FrameInputs) -> bool:
		var ok: bool = super.simulate_frame(input_frame, inputs)
		if input_frame == 40:
			x[0] += 1
		return ok


class FailingGame:
	extends Game

	func simulate_frame(input_frame: int, inputs: Types.FrameInputs) -> bool:
		return input_frame != 5 and super.simulate_frame(input_frame, inputs)


func cases() -> PackedStringArray:
	return PackedStringArray(
		["records_corrected_match", "records_metadata", "detects_changed_rules", "golden", "rejects_malformed_files",
			"bounds_recording", "lockstep_confirmation_limit", "refuses_foreign_recording", "protects_input_rows"]
	)


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"records_corrected_match":
			_records_corrected_match(context)
		"records_metadata":
			_records_metadata(context)
		"detects_changed_rules":
			_detects_changed_rules(context)
		"golden":
			_golden(context)
		"rejects_malformed_files":
			_rejects_malformed_files(context)
		"bounds_recording":
			_bounds_recording(context)
		"lockstep_confirmation_limit":
			_lockstep_confirmation_limit(context)
		"refuses_foreign_recording":
			_refuses_foreign_recording(context)
		"protects_input_rows":
			_protects_input_rows(context)
	context.finish()


static func _local(frame: int) -> int:
	return (Game.RIGHT | Game.FIRE) if frame % 11 < 8 else Game.LEFT


## Local samples take effect `delay` frames later; earlier frames use neutral input.
static func _applied_local(frame: int, delay: int) -> int:
	return 0 if frame < delay else _local(frame - delay)


static func _remote(frame: int) -> int:
	return (Game.FIRE if frame % 8 < 4 else 0) | (Game.LEFT if frame % 7 < 3 else Game.RIGHT)


static func _config(sync_test: bool, max_frames: int, delay: int = 0) -> Config:
	var config: Config = Config.new()
	config.input_delay = delay
	config.sync_test = sync_test
	config.local_players = PackedInt32Array([0, 1] if sync_test else [0])
	config.check_distance = 4 if sync_test else 0
	config.max_snapshot_bytes = Game.SNAPSHOT_BYTES
	config.replay_max_frames = max_frames
	config.diagnostic_seed = "1701"
	config.diagnostic_version = "replay-test v1"
	config.storage_budget_bytes = config.required_storage_bytes()
	return config


## Plays one match where remote input arrives `lag` ticks late in bursts, then delivers the rest.
## Returns the session after a final tick that confirms every simulated frame.
func _match(context: RefCounted, row: Dictionary, max_frames: int) -> Session:
	var session: Session = Session.new()
	var sync_test: bool = row.get("sync_test", false)
	context.equal(session.configure(_config(sync_test, max_frames, row.get("delay", 0))), Types.Code.OK, "configures")
	var driver: Driver = Driver.new(session, Game.new())
	var delivered: int = 0
	var tick: int = 0
	var sample_frame: int = -1
	var sample: PackedByteArray = PackedByteArray()
	while session.status().current_frame < FRAMES and tick < FRAMES * 4:
		if not sync_test and tick % row.burst == 0:
			while delivered <= tick - row.lag:
				session.receive_input(1, delivered, PackedByteArray([_remote(delivered)]))
				delivered += 1
		var frame: int = session.status().current_frame
		if sample_frame != frame:
			sample_frame = frame
			sample = PackedByteArray([_local(frame)])
		var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, frame, sample)]
		if sync_test:
			samples.append(Driver.LocalInput.new(1, frame, PackedByteArray([_remote(frame)])))
		var code: int = driver.step(tick, samples).code
		if code != Types.Code.OK and code != Types.Code.PREDICTION_STALL:
			context.equal(code, Types.Code.OK, "match keeps running")
			return session
		tick += 1
	if not sync_test:
		while delivered <= session.status().current_frame:
			session.receive_input(1, delivered, PackedByteArray([_remote(delivered)]))
			delivered += 1
		var frame: int = session.status().current_frame
		context.equal(driver.step(tick, [Driver.LocalInput.new(0, frame, PackedByteArray([_local(frame)]))]).code, Types.Code.OK, "final tick")
	return session


static func _decode(bytes: PackedByteArray, max_bytes: int = Replay.MAX_BYTES) -> Replay:
	var replay: Replay = Replay.new()
	return replay if replay.decode(bytes, max_bytes) == Replay.DecodeCode.OK else null


## Golden bytes and fields from scripts/reference/replay_golden.py.
static func _fixture() -> Dictionary:
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/replay/golden.json"))
	for version: String in ["v1", "v2", "v3", "v4"]:
		fixture[version] = "".join(fixture[version]).hex_decode()
	return fixture


## Straight simulation of the actual inputs: canonical state before each frame.
func _reference(frames: int, delay: int) -> Array[PackedByteArray]:
	var game: Game = Game.new()
	var states: Array[PackedByteArray] = [game.canonical_bytes()]
	for frame: int in range(frames):
		var inputs: Array[PackedByteArray] = [PackedByteArray([_applied_local(frame, delay)]), PackedByteArray([_remote(frame)])]
		game.simulate_frame(frame, Types.FrameInputs.new(inputs, PackedInt32Array([1, 1])))
		states.append(game.canonical_bytes())
	return states


func _records_corrected_match(context: RefCounted) -> void:
	var rows: Array[Dictionary] = [
		{"label": "on time", "lag": 0, "burst": 1},
		{"label": "late corrections", "lag": 3, "burst": 1},
		{"label": "bursts and stalls", "lag": 3, "burst": 6},
		{"label": "beyond the prediction window", "lag": 12, "burst": 1},
		{"label": "local input delay", "lag": 3, "burst": 2, "delay": 2},
		{"label": "sync-test", "sync_test": true},
	]
	for row: Dictionary in rows:
		var label: String = row.label
		var session: Session = _match(context, row, FRAMES * 2)
		var replay: Replay = session.replay()
		var frames: int = session.status().current_frame
		context.equal(replay.frame_count(), frames, label + " records every simulated confirmed frame")
		context.equal(replay.skipped_frames(), 0, label + " skips nothing")
		var wrong_inputs: int = 0
		var checksums: int = 0
		for frame: int in range(replay.frame_count()):
			var inputs: Types.FrameInputs = replay.inputs(frame)
			if inputs.read(0).bytes != PackedByteArray([_applied_local(frame, row.get("delay", 0))]) or inputs.read(1).bytes != PackedByteArray([_remote(frame)]):
				wrong_inputs += 1
			checksums += int(not replay.checksum(frame).is_empty())
		context.equal(wrong_inputs, 0, label + " records actual inputs, never predictions")
		context.equal(checksums > frames / 2, true, label + " records state checksums")
		var decoded: Replay = _decode(replay.to_bytes())
		context.equal(decoded != null and decoded.to_bytes() == replay.to_bytes(), true, label + " round-trips bytes")
		var expected: Array[PackedByteArray] = _reference(frames, row.get("delay", 0))
		var game: Game = Game.new()
		var player: Player = Player.new()
		context.equal(player.configure(decoded, game, Game.SNAPSHOT_BYTES), Types.Code.OK, label + " player configures")
		var code: int = Types.Code.OK
		while code == Types.Code.OK:
			code = player.step()
		context.equal(code, Types.Code.FRAME_EXHAUSTED, label + " validates every checksum and finishes")
		context.equal(player.is_complete(), true, label + " is complete")
		context.bytes_equal(game.canonical_bytes(), expected[frames], frames, label + " replays the corrected final state")
		context.state(frames, game.canonical_bytes())


func _detects_changed_rules(context: RefCounted) -> void:
	var replay: Replay = _match(context, {"lag": 3, "burst": 1}, FRAMES * 2).replay()
	# Validation stops at the first saved checksum after the divergence; frame 41's state differs.
	var rows: Array[Dictionary] = [
		{"label": "validated", "game": ChangedRules.new(), "bytes": Game.SNAPSHOT_BYTES, "code": Types.Code.DESYNC, "frame": 41},
		{"label": "inputs only", "game": ChangedRules.new(), "bytes": 0, "code": Types.Code.FRAME_EXHAUSTED, "frame": -1},
		{"label": "callback failure", "game": FailingGame.new(), "bytes": Game.SNAPSHOT_BYTES, "code": Types.Code.CALLBACK_FAILED, "frame": 5},
	]
	for row: Dictionary in rows:
		var player: Player = Player.new()
		context.equal(player.configure(replay, row.game, row.bytes), Types.Code.OK, row.label + " configures")
		var code: int = Types.Code.OK
		while code == Types.Code.OK:
			code = player.step()
		context.equal(code, row.code, row.label + " result")
		context.equal(player.failure_frame(), row.frame, row.label + " failure frame")
		context.equal(player.step(), row.code, row.label + " stays stopped")
		context.state(row.game.frame, row.game.canonical_bytes())
	context.equal(Player.new().configure(replay, RefCounted.new()), Types.Code.INVALID_CONFIGURATION, "rejects a game without callbacks")
	context.equal(Player.new().step(), Types.Code.NOT_CONFIGURED, "unconfigured player refuses to step")


func _records_metadata(context: RefCounted) -> void:
	var session: Session = _match(context, {"lag": 2, "burst": 1, "delay": 2}, 6)
	var replay: Replay = _decode(session.replay().to_bytes())
	var info: Dictionary = Engine.get_version_info()
	context.equal(replay.engine_version(), "%d.%d.%d.%s %s" % [info.major, info.minor, info.patch, info.status, info.hash], "records the engine build")
	context.equal(replay.addon_version(), ProjectSettings.get_setting("application/config/version"), "addon version matches the project version")
	context.equal(replay.upstream_revision(), "fortress-rollback f13cd5c0f2815926785a395947e18da0dbea0dd8", "records the pinned upstream")
	context.equal([replay.game_seed(), replay.game_version()], ["1701", "replay-test v1"], "records the game seed and version")
	context.equal([replay.input_delay(), replay.max_prediction_frames(), replay.sync_test()], [2, 8, false], "records the session configuration")
	context.equal(replay.neutral_input(), PackedByteArray([0]), "records the neutral input")


## Independent golden: decode every field, then re-encode the same bytes.
func _golden(context: RefCounted) -> void:
	var fixture: Dictionary = _fixture()
	var replay: Replay = Replay.new()
	context.equal(replay.decode(fixture.v4), Replay.DecodeCode.OK, "decodes the golden")
	var fields: Dictionary = fixture.fields
	for field: String in fields:
		var actual: Variant = replay.call(field)
		context.equal(actual.hex_encode() if actual is PackedByteArray else actual, fields[field], field)
	for frame: int in range(replay.frame_count()):
		var expected: String = fixture.checksums.get(str(frame), "")
		context.equal(replay.checksum(frame).hex_encode(), expected, "checksum %d" % frame)
		context.equal(replay.is_skipped_frame(frame), frame == 2, "skipped flag %d" % frame)
		context.equal(replay.input_digest(frame), replay.computed_input_digest(frame), "input digest %d" % frame)
	context.equal(replay.inputs(2).read(1).bytes, PackedByteArray([0x00, 0x80]), "a skipped frame holds neutral input")
	context.equal(replay.inputs(1).read(1).bytes, PackedByteArray([0x7f, 0x80]), "second player's input")
	context.bytes_equal(replay.to_bytes(), fixture.v4, 0, "re-encodes the golden")
	context.bytes_equal(replay.owned_copy().to_bytes(), fixture.v4, 0, "copies keep every field")
	context.state(replay.frame_count(), replay.to_bytes())
	context.equal(Replay.new().decode(fixture.v1), Replay.DecodeCode.UNSUPPORTED_VERSION, "rejects the unreleased v1 layout explicitly")
	context.equal(Replay.new().decode(fixture.v2), Replay.DecodeCode.UNSUPPORTED_VERSION, "rejects the released v2 layout explicitly")
	context.equal(Replay.new().decode(fixture.v3), Replay.DecodeCode.UNSUPPORTED_VERSION, "rejects the released v3 layout explicitly")


func _rejects_malformed_files(context: RefCounted) -> void:
	var golden: PackedByteArray = _fixture().v4
	var truncated: int = 0
	for size: int in range(golden.size()):
		truncated += int(Replay.new().decode(golden.slice(0, size)) != Replay.DecodeCode.MALFORMED)
	context.equal(truncated, 0, "every truncation is malformed")
	const MALFORMED: int = Replay.DecodeCode.MALFORMED
	const UNSUPPORTED: int = Replay.DecodeCode.UNSUPPORTED_VERSION
	# Golden frames: 4 input bytes, a flag and an input digest each; frames 0 and 3 add a checksum.
	var body: int = golden.size() - 4 * (4 + 1 + Replay.DIGEST_BYTES) - 2 * Replay.CHECKSUM_BYTES
	var engine_text: int = Replay.FIXED_BYTES + 2
	# Frame 1 starts after frame 0's row, flag, checksum and digest; frame 2 follows frame 1's digest.
	var frame1_flag: int = body + 4 + 1 + Replay.CHECKSUM_BYTES + Replay.DIGEST_BYTES + 4
	var frame2_row: int = frame1_flag + 1 + Replay.DIGEST_BYTES
	# Each row patches one field: [offset, encoder width, value].
	var rows: Array[Dictionary] = [
		{"label": "magic", "patch": [0, 1, 0x58], "code": MALFORMED},
		{"label": "v1", "patch": [4, 2, 1], "code": UNSUPPORTED},
		{"label": "version 0", "patch": [4, 2, 0], "code": UNSUPPORTED},
		{"label": "released v2", "patch": [4, 2, 2], "code": UNSUPPORTED},
		{"label": "released v3", "patch": [4, 2, 3], "code": UNSUPPORTED},
		{"label": "future version", "patch": [4, 2, 5], "code": UNSUPPORTED},
		{"label": "largest version", "patch": [4, 2, 0xffff], "code": UNSUPPORTED},
		{"label": "one player", "patch": [6, 1, 1], "code": MALFORMED},
		{"label": "nine players", "patch": [6, 1, 9], "code": MALFORMED},
		{"label": "zero width", "patch": [7, 4, 0], "code": MALFORMED},
		{"label": "width bomb", "patch": [7, 4, 0xffffffff], "code": MALFORMED},
		{"label": "extra frame", "patch": [11, 4, 5], "code": MALFORMED},
		{"label": "frame-count bomb", "patch": [11, 4, Replay.MAX_FRAMES], "code": MALFORMED},
		{"label": "skipped beyond frames", "patch": [15, 4, 5], "code": MALFORMED},
		{"label": "skipped count disagrees with flags", "patch": [15, 4, 0], "code": MALFORMED},
		{"label": "prediction window", "patch": [21, 1, 129], "code": MALFORMED},
		{"label": "sync-test flag", "patch": [22, 1, 2], "code": MALFORMED},
		{"label": "text length", "patch": [engine_text, 1, Replay.MAX_TEXT_BYTES + 1], "code": MALFORMED},
		{"label": "text past the end", "patch": [engine_text, 1, Replay.MAX_TEXT_BYTES], "code": MALFORMED},
		{"label": "control character", "patch": [engine_text + 1, 1, 0x0a], "code": MALFORMED},
		{"label": "delete character", "patch": [engine_text + 1, 1, 0x7f], "code": MALFORMED},
		{"label": "non-ASCII text", "patch": [engine_text + 1, 1, 0xc3], "code": MALFORMED},
		{"label": "unknown frame flag", "patch": [body + 4, 1, 4], "code": MALFORMED},
		{"label": "checksum and skipped together", "patch": [body + 4, 1, 3], "code": MALFORMED},
		{"label": "skipped frame with real input", "patch": [frame1_flag, 1, 2], "code": MALFORMED},
		{"label": "non-neutral skipped row", "patch": [frame2_row, 1, 1], "code": MALFORMED},
	]
	for row: Dictionary in rows:
		var bytes: PackedByteArray = golden.duplicate()
		match int(row.patch[1]):
			1:
				bytes.encode_u8(row.patch[0], row.patch[2])
			2:
				bytes.encode_u16(row.patch[0], row.patch[2])
			4:
				bytes.encode_u32(row.patch[0], row.patch[2])
		context.equal(Replay.new().decode(bytes), row.code, row.label)
	var trailing: PackedByteArray = golden.duplicate()
	trailing.append(0)
	context.equal(Replay.new().decode(trailing), MALFORMED, "rejects trailing bytes")
	context.equal(Replay.new().decode(golden, golden.size() - 1), Replay.DecodeCode.TOO_LARGE, "honors the caller's size limit")
	var kept: Replay = _decode(golden)
	context.equal(kept.decode(trailing), MALFORMED, "a failed decode reports its reason")
	context.equal(kept.to_bytes(), golden, "a failed decode keeps the previous replay")


## Every frame carries the digest of its own input row, so a corrupted row is refused at the
## frame that owns it - including a row in front of a frame that carries no state checksum.
func _protects_input_rows(context: RefCounted) -> void:
	var replay: Replay = _match(context, {"lag": 3, "burst": 1}, FRAMES * 2).replay()
	var frames: int = replay.frame_count()
	var bytes: PackedByteArray = replay.to_bytes()
	var last: int = frames - 1
	var row_size: int = replay.player_count() * replay.input_width()
	var tail: int = Replay.DIGEST_BYTES + 1 + (Replay.CHECKSUM_BYTES if not replay.checksum(last).is_empty() else 0)
	var corrupted: PackedByteArray = bytes.duplicate()
	corrupted[bytes.size() - tail - row_size] ^= 0xff
	var decoded: Replay = _decode(corrupted)
	context.equal(decoded != null, true, "a corrupted final row still decodes")
	context.bytes_equal(decoded.to_bytes(), corrupted, last, "a decoded recording keeps its recorded digests")
	var player: Player = Player.new()
	context.equal(player.configure(decoded, Game.new(), Game.SNAPSHOT_BYTES), Types.Code.OK, "player configures")
	var code: int = Types.Code.OK
	while code == Types.Code.OK:
		code = player.step()
	context.equal(code, Types.Code.DESYNC, "a corrupted final input stops playback")
	context.equal(player.failure_frame(), last, "the corrupted frame is reported")
	context.equal(player.failure_expected_checksum() != player.failure_actual_checksum(), true, "the digest evidence is reported")
	context.equal(player.is_complete(), false, "playback does not complete")
	var middle: Replay = _decode(bytes)
	middle._inputs[row_size * 7] = (middle._inputs[row_size * 7] + 1) % 8
	var middle_player: Player = Player.new()
	context.equal(middle_player.configure(middle, Game.new(), Game.SNAPSHOT_BYTES), Types.Code.OK, "middle player configures")
	code = Types.Code.OK
	while code == Types.Code.OK:
		code = middle_player.step()
	context.equal(code, Types.Code.DESYNC, "a corrupted middle input stops playback")
	context.equal(middle_player.failure_frame(), 7, "the owning frame reports the failure")
	# A recording whose last frames carry no state checksum leaves the rows in front of them
	# uncovered by any state checksum: only the per-frame digest can refuse them.
	var sparse: Replay = Replay.new()
	sparse._start(_config(false, 8))
	sparse._append(PackedByteArray([1, 2]), PackedByteArray(), false)
	sparse._append(PackedByteArray([3, 4]), PackedByteArray(), false)
	sparse._append(PackedByteArray([5, 6]), PackedByteArray(), false)
	var sparse_bytes: PackedByteArray = sparse.to_bytes()
	context.equal(_decode(sparse_bytes) != null, true, "a sparse recording decodes")
	var sparse_decoded: Replay = _decode(sparse_bytes)
	sparse_decoded._inputs[2] = (sparse_decoded._inputs[2] + 1) % 8
	var sparse_player: Player = Player.new()
	context.equal(sparse_player.configure(sparse_decoded, Game.new(), 0), Types.Code.OK, "sparse player configures")
	code = Types.Code.OK
	while code == Types.Code.OK:
		code = sparse_player.step()
	context.equal(code, Types.Code.DESYNC, "a corrupted row without a later state checksum stops playback")
	context.equal(sparse_player.failure_frame(), 1, "the owning frame reports the failure")
	# A recording without its recorded digests cannot be verified and is refused.
	var stripped: Replay = _decode(bytes)
	stripped._digests = PackedByteArray()
	var stripped_player: Player = Player.new()
	context.equal(stripped_player.configure(stripped, Game.new(), Game.SNAPSHOT_BYTES), Types.Code.OK, "stripped player configures")
	code = Types.Code.OK
	while code == Types.Code.OK:
		code = stripped_player.step()
	context.equal(code, Types.Code.DESYNC, "a recording without its input digests is refused")
	context.equal(stripped_player.failure_frame(), 0, "the refusal names the first unverified frame")


func _bounds_recording(context: RefCounted) -> void:
	var session: Session = _match(context, {"lag": 3, "burst": 6}, 10)
	var replay: Replay = session.replay()
	context.equal(replay.frame_count(), 10, "keeps only the first configured frames")
	replay._append(PackedByteArray([0, 0]), PackedByteArray(), false)
	context.equal(session.replay().frame_count(), 10, "returns caller-owned copies")
	var disabled: Session = Session.new()
	context.equal(disabled.configure(_config(true, 0)), Types.Code.OK, "recording is optional")
	context.equal(disabled.replay(), null, "no replay when disabled")
	for max_frames: int in [-1, Replay.MAX_FRAMES + 1]:
		context.equal(_config(true, max_frames).validate(), Types.Code.INVALID_CONFIGURATION, "rejects replay limit %d" % max_frames)
	for text: String in ["sé", "line\n", "x".repeat(Replay.MAX_TEXT_BYTES + 1)]:
		var config: Config = _config(true, 10)
		config.diagnostic_version = text
		context.equal(config.validate(), Types.Code.INVALID_CONFIGURATION, "rejects replay text %s" % text.c_escape().left(12))
	var wide: Config = _config(true, Replay.MAX_FRAMES)
	wide.input_width = 65536
	wide.neutral_input.resize(65536)
	context.equal(wide.validate(), Types.Code.INVALID_CONFIGURATION, "rejects recordings larger than the byte limit")


## Peer lockstep advances on received input while the mesh confirmation limit trails by a round trip.
## Recording must not wait for that limit: the queues discard each frame once it is simulated.
func _lockstep_confirmation_limit(context: RefCounted) -> void:
	var config: Config = _config(false, FRAMES)
	config.max_prediction_frames = 0
	config.history_slots = 1
	config.capture_confirmed_snapshots = true
	config.storage_budget_bytes = config.required_storage_bytes()
	var session: Session = Session.new()
	context.equal(session.configure(config), Types.Code.OK, "lockstep configures")
	context.equal(session.set_confirmation_limit(-1).code, Types.Code.OK, "enables the mesh limit")
	var driver: Driver = Driver.new(session, Game.new())
	for frame: int in range(30):
		session.receive_input(1, frame, PackedByteArray([_remote(frame)]))
		context.equal(driver.step(frame, [Driver.LocalInput.new(0, frame, PackedByteArray([_local(frame)]))]).code, Types.Code.OK, "lockstep advances")
		if frame % 10 == 9:
			context.equal(session.set_confirmation_limit(frame - 5).code, Types.Code.OK, "limit trails receipts")
	var replay: Replay = session.replay()
	context.equal(replay.frame_count(), 30, "records every simulated frame")
	context.equal(replay.skipped_frames(), 0, "skips nothing while the limit trails")
	var checksums: int = 0
	for frame: int in range(replay.frame_count()):
		checksums += int(not replay.checksum(frame).is_empty())
	context.equal(checksums, 30, "records every lockstep checksum")
	var game: Game = Game.new()
	var player: Player = Player.new()
	context.equal(player.configure(replay, game, Game.SNAPSHOT_BYTES), Types.Code.OK, "player configures")
	var code: int = Types.Code.OK
	while code == Types.Code.OK:
		code = player.step()
	context.equal(code, Types.Code.FRAME_EXHAUSTED, "plays the whole lockstep match")
	context.bytes_equal(game.canonical_bytes(), _reference(30, 0)[30], 30, "reaches the lockstep final state")
	context.state(30, game.canonical_bytes())


## A configuration that differs from the recording in exactly one compared field.
static func _foreign_config(field: String) -> Config:
	var config: Config = _config(false, 12)
	match field:
		"player_count":
			config.player_count = 4
			config.local_players = PackedInt32Array([0])
		"input_width":
			config.input_width = 2
			config.neutral_input = PackedByteArray([0, 0])
		"neutral_input":
			config.neutral_input = PackedByteArray([9])
		"diagnostic_seed":
			config.diagnostic_seed = "other"
		"diagnostic_version":
			config.diagnostic_version = "other v2"
	config.storage_budget_bytes = config.required_storage_bytes()
	return config


# Value: protects=recorded inputs only drive the game that produced them; fails_when=a foreign roster, width, neutral
# input, seed or version is played; why_new=other cases decode a recording without a running configuration; seam=none
func _refuses_foreign_recording(context: RefCounted) -> void:
	var config: Config = _config(false, 12)
	var session: Session = _match(context, {"lag": 2, "burst": 1}, 12)
	var recording: Replay = session.replay()
	context.equal(recording.matches_config(config), true, "a recording matches its own configuration")
	context.equal(recording.matches_config(null), false, "no configuration matches nothing")
	var player: Player = Player.new()
	context.equal(player.configure(recording, Game.new(), 0, 0, 0, config), Types.Code.OK, "the matching configuration plays the recording")
	context.equal(player.skipped_frames(), 0, "a complete recording skips nothing")
	for field: String in ["player_count", "input_width", "neutral_input", "diagnostic_seed", "diagnostic_version"]:
		var foreign: Config = _foreign_config(field)
		context.equal(recording.matches_config(foreign), false, "a foreign " + field + " does not match")
		context.equal(Player.new().configure(recording, Game.new(), 0, 0, 0, foreign), Types.Code.INCOMPATIBLE_RECORDING, "the player refuses a foreign " + field)
		context.equal(Player.new().configure_expert(recording, 0, foreign), Types.Code.INCOMPATIBLE_RECORDING, "expert playback refuses a foreign " + field)
	context.equal(Player.new().configure_expert(recording, 0, config), Types.Code.OK, "expert playback accepts the matching configuration")
