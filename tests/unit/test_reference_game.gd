extends RefCounted

# Value: protects=shared oracle PRNG/pending snapshots and byte-first sync checks; fails_when=restore omits a field; why_new=local toy game differs from Rust oracle; seam=none
const ReferenceGame = preload("res://tests/oracle/reference_game.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const SnapshotStatus = preload("res://addons/fortress_rollback/core/snapshot_status.gd")


class Client:
	extends RefCounted
	var game: RefCounted = ReferenceGame.new(2, 2)
	var omitted: String = ""

	func save_state(_frame: int, writer: RefCounted) -> Driver.SaveResult:
		var checksum: PackedByteArray = PackedByteArray()
		checksum.resize(16)
		# A deliberate collision proves that exact snapshot bytes guard sync-test.
		return Driver.SaveResult.new(writer.write_bytes(game.bytes()) == SnapshotStatus.Code.OK, checksum)

	func load_state(_frame: int, reader: RefCounted) -> bool:
		var old_rng: int = game.rng
		var old_pending: int = game.pending
		var result: RefCounted = reader.read_bytes(game.bytes().size())
		if result.code != SnapshotStatus.Code.OK or not reader.is_complete() or not game.restore(result.bytes).is_empty():
			return false
		if omitted == "rng":
			game.rng = old_rng
		if omitted == "pending":
			game.pending = old_pending
		return true

	func simulate_frame(_frame: int, inputs: Types.FrameInputs) -> bool:
		var slots: Array[Dictionary] = []
		for player: int in range(inputs.size().value):
			var input: Types.InputResult = inputs.read(player)
			slots.append({"player": player, "bytes": input.bytes.hex_encode(), "status": "confirmed"})
		return game.advance(slots).is_empty()


func cases() -> PackedStringArray:
	return PackedStringArray(["snapshot_omissions", "restore_validation"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"snapshot_omissions":
			for omitted: String in ["", "rng", "pending"]:
				_run(context, omitted)
		"restore_validation":
			var game: RefCounted = ReferenceGame.new(2, 2)
			var original: PackedByteArray = game.bytes()
			context.equal(game.restore(PackedByteArray()).is_empty(), false, "truncated state rejected")
			context.bytes_equal(game.bytes(), original, 0, "rejection preserves state")
			var invalid: PackedByteArray = original.duplicate()
			invalid.encode_s32(0, -1)
			context.equal(game.restore(invalid).is_empty(), false, "negative frame rejected")
			context.bytes_equal(game.bytes(), original, 0, "invalid frame preserves state")
	context.finish()


func _run(context: RefCounted, omitted: String) -> void:
	var config: RefCounted = Config.new()
	config.input_width = 4
	config.neutral_input = PackedByteArray([0, 0, 0, 0])
	config.check_distance = 2
	config.max_prediction_frames = 2
	config.history_slots = 3
	config.max_snapshot_bytes = 20
	config.storage_budget_bytes = 65536
	var session: RefCounted = Session.new()
	context.equal(session.configure(config), Types.Code.OK, "stateful config")
	var client: Client = Client.new()
	client.omitted = omitted
	var baseline: RefCounted = ReferenceGame.new(2, 2)
	var driver: RefCounted = Driver.new(session, client)
	var failed: bool = false
	for frame: int in range(20):
		var samples: Array[Driver.LocalInput] = []
		var slots: Array[Dictionary] = []
		for player: int in range(2):
			var bytes: PackedByteArray = PackedByteArray()
			bytes.resize(4)
			bytes.encode_u32(0, (frame + 1) * (player + 3))
			samples.append(Driver.LocalInput.new(player, frame, bytes))
			slots.append({"player": player, "bytes": bytes.hex_encode(), "status": "confirmed"})
		var result: RefCounted = driver.step(frame, samples)
		if result.code == Types.Code.DESYNC:
			failed = true
			context.equal(omitted.is_empty(), false, "only broken clients diverge")
			context.equal(session.status().failure_frame, 2, "first differing snapshot localized")
			break
		context.equal(result.code, Types.Code.OK, "shared game advances")
		context.equal(baseline.advance(slots), "", "offline continuation")
		if omitted.is_empty():
			context.bytes_equal(client.game.bytes(), baseline.bytes(), frame + 1, "full state after rewind")
	context.equal(failed, not omitted.is_empty(), "colliding checksum cannot hide omitted state")
