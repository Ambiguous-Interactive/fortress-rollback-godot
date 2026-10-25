extends RefCounted

# Value: protects=replay validates callback signatures and bounded snapshots before advancing; fails_when=uncallable callbacks reset playback or failed writes pass;
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


class WrongSimulate:
	extends RefCounted

	func simulate_frame() -> bool:
		return false


class WrongSave:
	extends RefCounted

	func simulate_frame(_frame: int, _inputs: Types.FrameInputs) -> bool:
		return true

	func save_state() -> Driver.SaveResult:
		return null


class WrongLoad:
	extends RefCounted

	func simulate_frame(_frame: int, _inputs: Types.FrameInputs) -> bool:
		return true

	func save_state(frame: int, writer: Writer) -> Driver.SaveResult:
		return Game.new().save_state(frame, writer)

	func load_state() -> bool:
		return false


class FailureGame:
	extends RefCounted
	var game: Game = Game.new()
	var fail_kind: int = -1
	var owner: WeakRef
	var terminate_callback: bool = false

	func _accept(kind: int) -> bool:
		if kind == fail_kind and terminate_callback:
			owner.get_ref().terminate()
		return kind != fail_kind

	func save_state(frame: int, writer: Writer) -> Driver.SaveResult:
		var result: Driver.SaveResult = game.save_state(frame, writer)
		result.ok = _accept(Types.Kind.SAVE)
		return result

	func load_state(frame: int, reader: RefCounted) -> bool:
		return game.load_state(frame, reader) and _accept(Types.Kind.LOAD)

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		return game.simulate_frame(frame, inputs) and _accept(Types.Kind.ADVANCE)


func cases() -> PackedStringArray:
	return PackedStringArray(["snapshot_failures", "uninitialized_replay", "callback_arguments", "failure_kinds"])


func run_case(name: String, context: RefCounted) -> void:
	var replay: Replay = _record(context)
	if name == "failure_kinds":
		_failure_kinds(context, replay)
	elif name == "callback_arguments":
		_callback_arguments(context, replay)
	elif name == "snapshot_failures":
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


# Value: protects=callback and expert replay failures name the failing request without losing first cause;
# fails_when=all callback errors expose only a shared code/frame; why_new=driver diagnostics do not cover replay; seam=none
func _failure_kinds(context: RefCounted, replay: Replay) -> void:
	var probe: Player = Player.new()
	context.equal(probe.has_method("failure_kind"), true, "replay failures identify the game operation")
	if not probe.has_method("failure_kind"):
		return
	context.equal(probe.call("failure_kind"), -1, "healthy player has no failed request")
	for expert: bool in [false, true]:
		for operation: String in ["advance", "save", "validate", "load", "restore save"]:
			for terminal: bool in [false, true]:
				var player: Player = Player.new()
				var game: FailureGame = FailureGame.new()
				game.owner = weakref(player)
				if expert:
					player.configure_expert(replay, Game.SNAPSHOT_BYTES, null, 2, 4)
				else:
					player.configure(replay, game, Game.SNAPSHOT_BYTES, 2, 4)
				for frame: int in 6:
					context.equal(_dispatch(player, game, player.begin_advance()) if expert else player.step(), Types.Code.OK, "healthy prefix")
				game.fail_kind = Types.Kind.LOAD if operation == "load" else (Types.Kind.ADVANCE if operation == "advance" else Types.Kind.SAVE)
				game.terminate_callback = terminal
				var code: int
				if expert:
					var result: Types.Result
					if operation in ["load", "restore save"]:
						result = player.begin_restore_before(3)
					elif operation == "validate":
						result = player.begin_validate_current_frame()
					else:
						result = player.begin_advance()
					code = _dispatch(player, game, result)
				elif operation in ["load", "restore save"]:
					code = player.restore_before(3)
				elif operation == "validate":
					code = player.validate_current_frame()
				else:
					code = player.step()
				context.equal(code, Types.Code.TERMINATED if terminal else Types.Code.CALLBACK_FAILED, operation + " first cause")
				var expected: int = -1 if terminal else game.fail_kind
				context.equal(player.call("failure_kind"), expected, operation + " request kind")
				context.equal(player.failure_comparison(), "", "callback failure is not a checksum mismatch")
				player.terminate()
				player.begin_validate_current_frame()
				context.equal(player.configure_expert(null), Types.Code.INVALID_CONFIGURATION, "invalid restart preserves failure")
				context.equal(player.call("failure_kind"), expected, "later calls preserve first cause")
				context.equal(player.configure_expert(replay), Types.Code.OK, "explicit restart")
				context.equal(player.call("failure_kind"), -1, "new lifetime clears failed request")
				context.state(game.game.frame, game.game.canonical_bytes())


func _dispatch(player: Player, game: FailureGame, result: Types.Result) -> int:
	if result.code != Types.Code.READY:
		return result.code
	while true:
		var request: Types.Request = result.batch.next_request()
		if request == null:
			return Types.Code.OK
		var checksum: PackedByteArray = PackedByteArray()
		var ok: bool
		if request.kind == Types.Kind.SAVE:
			var saved: Driver.SaveResult = game.save_state(request.frame, request.writer)
			ok = saved.ok
			checksum = saved.checksum
		elif request.kind == Types.Kind.LOAD:
			ok = game.load_state(request.frame, request.reader)
		else:
			ok = game.simulate_frame(request.frame, request.inputs)
		# Descriptive metadata cannot change which operation failed.
		request.kind = -1
		var code: int = player.complete_request(request.batch_id, request.request_id, ok, checksum).code
		if code != Types.Code.OK:
			return code
	return Types.Code.OK


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
			context.equal(player.failure_kind(), -1 if fault == "none" else Types.Kind.SAVE, fault + " identifies failed save")
			context.equal(player.step(), expected, fault + " remains stopped")
			context.equal(game.retained_writer.status(), Writer.Code.EXPIRED_VIEW, fault + " callback writer expires")
			context.equal(player.failure_expected_checksum().is_empty(), true, fault + " has no recorded mismatch evidence")
			context.equal(player.failure_actual_checksum().is_empty(), true, fault + " has no computed mismatch evidence")
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


func _callback_arguments(context: RefCounted, replay: Replay) -> void:
	var player: Player = Player.new()
	context.equal(player.configure(replay, Game.new()), Types.Code.OK, "healthy playback configured")
	context.equal(player.step(), Types.Code.OK, "healthy first frame")
	context.equal(player.configure(replay, WrongSimulate.new()), Types.Code.INVALID_CONFIGURATION, "simulate callback must accept two arguments")
	context.equal(player.configure(replay, WrongSave.new(), Game.SNAPSHOT_BYTES), Types.Code.INVALID_CONFIGURATION, "validation requires callable save")
	context.equal(player.configure(replay, WrongLoad.new(), Game.SNAPSHOT_BYTES, 2, 2), Types.Code.INVALID_CONFIGURATION, "checkpointing requires callable load")
	context.equal(player.current_frame(), 1, "rejected callbacks preserve prior position")
	context.equal(player.step(), Types.Code.OK, "prior recording still plays after refused configurations")
	context.equal(player.configure(replay, WrongSave.new()), Types.Code.OK, "input-only playback does not require save callback")
	context.equal(player.configure(replay, WrongLoad.new(), Game.SNAPSHOT_BYTES), Types.Code.OK, "uncached playback does not require load callback")
