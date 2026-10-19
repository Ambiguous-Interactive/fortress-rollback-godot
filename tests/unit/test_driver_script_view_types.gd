extends RefCounted

# Value: protects=typed callback views fail before guard acquisition; fails_when=reflected script classes are ignored; why_new=signature tests cover builtins; seam=none
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Writer = preload("res://addons/fortress_rollback/core/snapshot_writer.gd")
const Reader = preload("res://addons/fortress_rollback/core/snapshot_reader.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Fixture = preload("res://tests/unit/test_driver.gd")
const Diagnostic = preload("res://addons/fortress_rollback/core/diagnostic_player.gd")
const DiagnosticFixture = preload("res://tests/unit/test_diagnostic_player.gd")
const ReplayPlayer = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")


class TypedViews:
	extends RefCounted
	var game: RefCounted = Fixture.Game.new()

	func save_state(frame: int, writer: Writer) -> Driver.SaveResult:
		return game.save_state(frame, writer)

	func load_state(frame: int, reader: Reader) -> bool:
		return game.load_state(frame, reader)

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		return game.simulate_frame(frame, inputs)


class SwappedSaveView:
	extends RefCounted

	func save_state(_frame: int, _writer: Reader) -> Driver.SaveResult:
		return Driver.SaveResult.new(false)

	func load_state(_frame: int, _reader: Reader) -> bool:
		return false

	func simulate_frame(_frame: int, _inputs: Types.FrameInputs) -> bool:
		return false


class SwappedLoadView:
	extends RefCounted

	func save_state(_frame: int, _writer: Writer) -> Driver.SaveResult:
		return Driver.SaveResult.new(false)

	func load_state(_frame: int, _reader: Writer) -> bool:
		return false

	func simulate_frame(_frame: int, _inputs: Types.FrameInputs) -> bool:
		return false


class SwappedInputView:
	extends RefCounted

	func save_state(_frame: int, _writer: Writer) -> Driver.SaveResult:
		return Driver.SaveResult.new(false)

	func load_state(_frame: int, _reader: Reader) -> bool:
		return false

	func simulate_frame(_frame: int, _inputs: Writer) -> bool:
		return false


func cases() -> PackedStringArray:
	return PackedStringArray(["driver", "diagnostic", "replay"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"driver":
			_driver(context)
		"diagnostic":
			_diagnostic(context)
		"replay":
			_replay(context)
	context.finish()


func _invalid() -> Array[RefCounted]:
	return [SwappedSaveView.new(), SwappedLoadView.new(), SwappedInputView.new()]


func _expected(game: RefCounted) -> int:
	var name: String = "save_state" if game is SwappedSaveView else ("load_state" if game is SwappedLoadView else "simulate_frame")
	for method: Dictionary in game.get_method_list():
		if method.name == name:
			# Older Godot releases erase script-specific types to RefCounted.
			return Types.Code.OK if method.args[1].class_name in [&"", &"RefCounted"] else Types.Code.INVALID_CONFIGURATION
	return Types.Code.INVALID_CONFIGURATION


func _driver(context: RefCounted) -> void:
	var fixture: RefCounted = Fixture.new()
	for game: RefCounted in _invalid():
		var original: TypedViews = TypedViews.new()
		var session: RefCounted = fixture._session()
		var driver: Driver = Driver.new(session, original)
		var installed: int = driver.configure(session, game)
		context.equal(installed, _expected(game), "reflected incompatible script view rejected")
		if installed == Types.Code.OK:
			driver.configure(session, original)
		for frame: int in range(5):
			context.equal(driver.step(frame, fixture._samples(frame)).code, Types.Code.OK, "original exact typed callbacks remain callable")
		context.equal("load:1" in original.game.trace, true, "typed reader dispatch exercised through rollback")
		context.equal(session.poll(5).code, Types.Code.OK, "callback guard remains released")
	var typed: TypedViews = TypedViews.new()
	var driver: Driver = Driver.new(fixture._session(), typed)
	for frame: int in range(5):
		context.equal(driver.step(frame, fixture._samples(frame)).code, Types.Code.OK, "valid typed control dispatches on every engine")


func _diagnostic(context: RefCounted) -> void:
	var fixture: RefCounted = DiagnosticFixture.new()
	var trace: Dictionary = fixture._capture()
	for game: RefCounted in _invalid():
		var original: RefCounted = DiagnosticFixture.Game.new()
		var player: Diagnostic = Diagnostic.new()
		context.equal(player.configure(trace, original, original.SNAPSHOT_BYTES), Types.Code.OK, "diagnostic valid control")
		var installed: int = player.configure(trace, game, original.SNAPSHOT_BYTES)
		context.equal(installed, _expected(game), "diagnostic rejects known view mismatch")
		if installed == Types.Code.OK:
			player.configure(trace, original, original.SNAPSHOT_BYTES)
		context.equal(player.step(), Types.Code.OK, "diagnostic preserves installed callbacks")
		context.equal(original.frame, 3, "diagnostic restores and advances original game")


func _replay(context: RefCounted) -> void:
	var replay: Replay = Replay.new()
	replay._start(Config.new())
	replay._append(PackedByteArray([1, 2]), PackedByteArray(), false)
	for game: RefCounted in _invalid():
		var original: TypedViews = TypedViews.new()
		var player: ReplayPlayer = ReplayPlayer.new()
		context.equal(player.configure(replay, original, 8, 1, 2), Types.Code.OK, "replay valid typed control")
		var installed: int = player.configure(replay, game, 8, 1, 2)
		context.equal(installed, _expected(game), "replay rejects known view mismatch")
		if installed == Types.Code.OK:
			player.configure(replay, original, 8, 1, 2)
		context.equal(player.step(), Types.Code.OK, "replay preserves installed callbacks")
		context.equal(original.game.value, 5, "original replay game receives inputs")
