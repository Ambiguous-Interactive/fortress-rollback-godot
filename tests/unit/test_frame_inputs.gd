extends RefCounted

# Value: protects=reusable fixed-width input reads and lifetime; fails_when=copy aliases or ignores expiry; why_new=read allocates owned result wrappers; seam=none
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Fixture = preload("res://tests/unit/test_driver.gd")


class ReusingGame:
	extends Fixture.Game
	var sample: PackedByteArray = PackedByteArray([0])

	func simulate_frame(frame: int, inputs: RefCounted) -> bool:
		trace.append("advance:%d" % frame)
		retained_inputs = inputs
		for player: int in range(inputs.player_count()):
			if inputs.read_into(player, sample) != Types.Code.OK:
				return false
			value = value * 3 + sample[0] + frame
		return true


func cases() -> PackedStringArray:
	return PackedStringArray(["copy", "validation", "driver_parity"])


func run_case(name: String, context: RefCounted) -> void:
	var view: RefCounted = Types.FrameInputs.new()
	var available: bool = view.has_method("player_count") and view.has_method("read_into")
	context.equal(available, true, "reusable input access exists")
	if available:
		call("_" + name, context)
	context.finish()


func _view(width: int = 2) -> RefCounted:
	var first: PackedByteArray = PackedByteArray()
	first.resize(width)
	first.fill(3)
	var second: PackedByteArray = first.duplicate()
	second.fill(7)
	return Types.FrameInputs.new([first, second], PackedInt32Array([0, 1]))


func _copy(context: RefCounted) -> void:
	for width: int in [1, 2, 65536]:
		var view: RefCounted = _view(width)
		var destination: PackedByteArray = PackedByteArray()
		destination.resize(width)
		context.equal(view.player_count(), 2, "live view exposes player count")
		for player: int in range(2):
			context.equal(view.read_into(player, destination), Types.Code.OK, "copy into existing destination")
			context.bytes_equal(destination, view.read(player).bytes, player, "reusable copy equals owned read")
			destination.fill(99)
			context.equal(view.read(player).bytes[0], 3 if player == 0 else 7, "destination never edits authoritative inputs")
		context.equal(view.read(1).status, 1, "owned read retains input status")


func _validation(context: RefCounted) -> void:
	var view: RefCounted = _view()
	for player: int in [-1, 2, 2147483647]:
		var destination: PackedByteArray = PackedByteArray([8, 9])
		context.equal(view.read_into(player, destination), Types.Code.INVALID_PLAYER, "invalid player rejected")
		context.bytes_equal(destination, PackedByteArray([8, 9]), 0, "invalid player preserves destination")
	for width: int in [0, 1, 3]:
		var destination: PackedByteArray = PackedByteArray()
		destination.resize(width)
		destination.fill(8)
		var before: PackedByteArray = destination.duplicate()
		context.equal(view.read_into(0, destination), Types.Code.INPUT_WIDTH, "exact destination width required")
		context.bytes_equal(destination, before, 0, "wrong width preserves destination")
	view._expire()
	context.equal(view.player_count(), -1, "expired player count cannot resemble a live view")
	var destination: PackedByteArray = PackedByteArray([8, 9])
	context.equal(view.read_into(0, destination), Types.Code.EXPIRED_VIEW, "expired read fails")
	context.equal(view.read_into(-1, PackedByteArray()), Types.Code.EXPIRED_VIEW, "expiry precedes other validation")
	context.bytes_equal(destination, PackedByteArray([8, 9]), 0, "expired read preserves destination")


func _driver_parity(context: RefCounted) -> void:
	var fixture: RefCounted = Fixture.new()
	var original: RefCounted = Fixture.Game.new()
	var reused: ReusingGame = ReusingGame.new()
	var original_driver: Driver = Driver.new(fixture._session(), original)
	var reused_driver: Driver = Driver.new(fixture._session(), reused)
	for frame: int in range(14):
		context.equal(original_driver.step(frame, fixture._samples(frame)).code, Types.Code.OK, "owned-read control advances")
		context.equal(reused_driver.step(frame, fixture._samples(frame)).code, Types.Code.OK, "reusable-read driver advances")
		context.equal(reused.value, original.value, "same state through rollback bursts")
		context.equal(reused.trace, original.trace, "same ordered callbacks")
		context.equal(reused.retained_inputs.player_count(), -1, "driver expires reusable view")
		context.equal(reused.retained_inputs.read_into(0, reused.sample), Types.Code.EXPIRED_VIEW, "retained reusable view fails after callback")
