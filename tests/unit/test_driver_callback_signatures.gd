extends RefCounted

# Value: protects=invalid callback arity fails before a step; fails_when=configure accepts uncallable methods; why_new=result tests assume callable signatures; seam=none
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Fixture = preload("res://tests/unit/test_driver.gd")
const Diagnostic = preload("res://addons/fortress_rollback/core/diagnostic_player.gd")
const DiagnosticFixture = preload("res://tests/unit/test_diagnostic_player.gd")


class ShortSave:
	extends RefCounted

	func save_state(_frame: int) -> Driver.SaveResult:
		return Driver.SaveResult.new(false)

	func load_state(_frame: int, _reader: RefCounted) -> bool:
		return false

	func simulate_frame(_frame: int, _inputs: RefCounted) -> bool:
		return false


class LongLoad:
	extends RefCounted

	func save_state(_frame: int, _writer: RefCounted) -> Driver.SaveResult:
		return Driver.SaveResult.new(false)

	func load_state(_frame: int, _reader: RefCounted, _required: int) -> bool:
		return false

	func simulate_frame(_frame: int, _inputs: RefCounted) -> bool:
		return false


class ShortSimulation:
	extends RefCounted

	func save_state(_frame: int, _writer: RefCounted) -> Driver.SaveResult:
		return Driver.SaveResult.new(false)

	func load_state(_frame: int, _reader: RefCounted) -> bool:
		return false

	func simulate_frame() -> bool:
		return false


class OptionalArguments:
	extends RefCounted
	var game: RefCounted = Fixture.Game.new()

	func save_state(frame: int, writer: RefCounted, _optional: int = 0) -> Driver.SaveResult:
		return game.save_state(frame, writer)

	func load_state(frame: int = 0, reader: RefCounted = null) -> bool:
		return game.load_state(frame, reader)

	func simulate_frame(frame: int, inputs: RefCounted, _optional: bool = false) -> bool:
		return game.simulate_frame(frame, inputs)


func cases() -> PackedStringArray:
	return PackedStringArray(["arity", "optional", "diagnostic"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"arity":
			_arity(context)
		"optional":
			_optional(context)
		"diagnostic":
			_diagnostic(context)
	context.finish()


func _arity(context: RefCounted) -> void:
	var fixture: RefCounted = Fixture.new()
	var session: RefCounted = fixture._session()
	var original: RefCounted = Fixture.Game.new()
	var driver: RefCounted = Driver.new(session, original)
	var invalid: Array[RefCounted] = [ShortSave.new(), LongLoad.new(), ShortSimulation.new()]
	for game: RefCounted in invalid:
		context.equal(driver.configure(session, game), Types.Code.INVALID_CONFIGURATION, "uncallable callback rejected at configuration")
	# Failed replacement must leave the original game usable.
	context.equal(driver.step(0, fixture._samples(0)).code, Types.Code.OK, "original game survives invalid replacement")
	context.equal(original.trace, PackedStringArray(["save:0", "advance:0"]), "rejected callback was never installed")


func _optional(context: RefCounted) -> void:
	var fixture: RefCounted = Fixture.new()
	var game: OptionalArguments = OptionalArguments.new()
	var driver: RefCounted = Driver.new()
	context.equal(driver.configure(fixture._session(), game), Types.Code.OK, "optional arguments accept two-argument invocation")
	for frame: int in range(5):
		context.equal(driver.step(frame, fixture._samples(frame)).code, Types.Code.OK, "optional callback arguments remain callable")
	context.equal("load:1" in game.game.trace, true, "all optional signatures exercised through rollback")


func _diagnostic(context: RefCounted) -> void:
	var fixture: RefCounted = DiagnosticFixture.new()
	var trace: Dictionary = fixture._capture()
	var original: RefCounted = DiagnosticFixture.Game.new()
	var player: RefCounted = Diagnostic.new()
	context.equal(player.configure(trace, original, original.SNAPSHOT_BYTES), Types.Code.OK, "valid diagnostic control")
	var invalid: Array[RefCounted] = [ShortSave.new(), LongLoad.new(), ShortSimulation.new()]
	for game: RefCounted in invalid:
		context.equal(player.configure(trace, game, original.SNAPSHOT_BYTES), Types.Code.INVALID_CONFIGURATION, "diagnostic rejects incompatible callback before replacing game")
	context.equal(player.step(), Types.Code.OK, "diagnostic original callback remains usable")
	context.equal(original.frame, 3, "diagnostic starts from captured canonical boundary")
