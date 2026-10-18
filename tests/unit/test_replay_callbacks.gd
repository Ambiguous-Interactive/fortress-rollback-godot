extends RefCounted

# Value: protects=replay validation honors bounded snapshot failures before advancing; fails_when=matching checksums hide failed writes;
# why_new=replay tests cover simulation failure and checksum mismatch only; seam=none
const Game = preload("res://examples/integration/game.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Writer = preload("res://addons/fortress_rollback/core/snapshot_writer.gd")


class SaveGame:
	extends RefCounted
	var game: Game = Game.new()
	var fault: String
	var fault_frame: int
	var retained_writer: Writer

	func _init(mode: String, frame: int) -> void:
		fault = mode
		fault_frame = frame

	# Variant exercises invalid results at the public callback boundary.
	func save_state(frame: int, writer: Writer) -> Variant:
		retained_writer = writer
		var saved: Driver.SaveResult = game.save_state(frame, writer)
		if frame == fault_frame:
			match fault:
				"overflow":
					writer.write_bytes(PackedByteArray([0]))
				"expired":
					writer._expire()
				"false":
					saved.ok = false
				"wrong type":
					return true
				"null":
					return null
				"short checksum":
					saved.checksum.resize(15)
		return saved

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		return game.simulate_frame(frame, inputs)


func cases() -> PackedStringArray:
	return PackedStringArray(["snapshot_failures", "uninitialized_replay"])


func run_case(name: String, context: RefCounted) -> void:
	var replay: Replay = _record(context)
	if name == "snapshot_failures":
		_snapshot_failures(context, replay)
	else:
		var player: Player = Player.new()
		context.equal(player.configure(replay, Game.new()), Types.Code.OK, "valid recording configures")
		context.equal(player.step(), Types.Code.OK, "plays first frame")
		context.equal(player.configure(Replay.new(), Game.new()), Types.Code.INVALID_CONFIGURATION, "rejects an uninitialized recording")
		context.equal(player.current_frame(), 1, "rejected configuration preserves playback")
		context.equal(player.step(), Types.Code.OK, "previous recording still plays")
		var config: Config = _config()
		var session: Session = Session.new()
		context.equal(session.configure(config), Types.Code.OK, "empty recording session configures")
		context.equal(player.configure(session.replay(), Game.new()), Types.Code.OK, "valid empty recording configures")
		context.equal(player.is_complete(), true, "valid zero-frame recording is complete")
		context.equal(player.step(), Types.Code.FRAME_EXHAUSTED, "empty recording has no frames")
	context.finish()


func _snapshot_failures(context: RefCounted, replay: Replay) -> void:
	for fault: String in ["none", "overflow", "expired", "false", "wrong type", "null", "short checksum"]:
		for frame: int in [0, 5]:
			var game: SaveGame = SaveGame.new(fault, frame)
			var player: Player = Player.new()
			context.equal(player.configure(replay, game, Game.SNAPSHOT_BYTES), Types.Code.OK, fault + " configures")
			var expected: int = Types.Code.CALLBACK_FAILED
			if fault == "none":
				expected = Types.Code.FRAME_EXHAUSTED
			elif fault in ["overflow", "expired"]:
				expected = Types.Code.SNAPSHOT_FAILED
			elif fault == "short checksum":
				expected = Types.Code.DESYNC
			var code: int = Types.Code.OK
			while code == Types.Code.OK:
				code = player.step()
			context.equal(code, expected, fault + " result")
			context.equal(player.current_frame(), replay.frame_count() if fault == "none" else frame, fault + " stops before simulation")
			context.equal(player.failure_frame(), -1 if fault == "none" else frame, fault + " identifies failed frame")
			context.equal(player.step(), expected, fault + " remains stopped")
			context.equal(game.retained_writer.status(), Writer.Code.EXPIRED_VIEW, fault + " callback writer expires")
			context.state(game.game.frame, game.game.canonical_bytes())


func _config() -> Config:
	var config: Config = Config.new()
	config.max_snapshot_bytes = Game.SNAPSHOT_BYTES
	config.replay_max_frames = 8
	config.storage_budget_bytes = config.required_storage_bytes()
	return config


func _record(context: RefCounted) -> Replay:
	var session: Session = Session.new()
	context.equal(session.configure(_config()), Types.Code.OK, "recording session configures")
	var driver: Driver = Driver.new(session, Game.new())
	for frame: int in range(8):
		var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, frame, PackedByteArray([5])), Driver.LocalInput.new(1, frame, PackedByteArray([2]))]
		context.equal(driver.step(frame, samples).code, Types.Code.OK, "records confirmed frame")
	return session.replay()
