extends RefCounted

# Value: protects=runnable example snapshots and cosmetic effects; fails_when=PRNG/events are omitted or callbacks emit effects; why_new=shared user scene was absent; seam=none
const Simulation = preload("res://examples/offline/simulation.gd")
const Presentation = preload("res://examples/offline/presentation.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Reader = preload("res://addons/fortress_rollback/core/snapshot_reader.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


class MissingRandom:
	extends Simulation

	func canonical_bytes() -> PackedByteArray:
		var bytes: PackedByteArray = super.canonical_bytes()
		bytes.encode_s64(16, 0)
		return bytes


class MissingPending:
	extends Simulation

	func canonical_bytes() -> PackedByteArray:
		var bytes: PackedByteArray = super.canonical_bytes()
		for player: int in range(2):
			bytes.encode_s64(24 + player * 56 + 16, -1)
			bytes.encode_s64(24 + player * 56 + 24, 0)
		return bytes


func cases() -> PackedStringArray:
	return PackedStringArray(["continuation", "controls", "omissions", "malformed_snapshots", "scene"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"continuation":
			_continuation(context)
		"controls":
			_controls(context)
		"omissions":
			_omissions(context)
		"malformed_snapshots":
			_malformed_snapshots(context)
		"scene":
			_scene(context)
	context.finish()


func _session(distance: int) -> Session:
	var config: Config = Config.new()
	config.check_distance = distance
	config.max_prediction_frames = 8
	config.history_slots = 9
	config.max_snapshot_bytes = Simulation.SNAPSHOT_BYTES
	config.storage_budget_bytes = config.required_storage_bytes()
	var session: Session = Session.new()
	if session.configure(config) != Types.Code.OK:
		push_error("Offline test configuration failed")
	return session


func _samples(frame: int) -> Array[Driver.LocalInput]:
	var result: Array[Driver.LocalInput] = []
	for player: int in range(2):
		result.append(Driver.LocalInput.new(player, frame, PackedByteArray([(frame * 7 + player * 3) % 16])))
	return result


func _continuation(context: RefCounted) -> void:
	var expected: Simulation = Simulation.new()
	var corrected: Simulation = Simulation.new()
	var reference_driver: Driver = Driver.new(_session(0), expected)
	var rollback_driver: Driver = Driver.new(_session(8), corrected)
	var presentation: Presentation = Presentation.new()
	for frame: int in range(160):
		context.equal(reference_driver.step(frame, _samples(frame)).code, Types.Code.OK, "reference advance")
		context.equal(rollback_driver.step(frame, _samples(frame)).code, Types.Code.OK, "rollback advance")
		context.bytes_equal(corrected.canonical_bytes(), expected.canonical_bytes(), frame, "seed=1701 corrected snapshot with pending events")
		presentation.reconcile(corrected)
		var before: int = presentation.pulse_count
		presentation.reconcile(corrected)
		context.equal(presentation.pulse_count, before, "same final state emits no second pulse")
	context.equal(presentation.pulse_count, 16, "eight scheduled pulses per player despite repeated rewinds")
	context.equal(corrected.event_id, expected.event_id, "stable event IDs survive rewinds")
	context.equal(corrected.frame, 160, "continued beyond many history wraps")


func _omissions(context: RefCounted) -> void:
	var mutations: Array[Simulation] = [MissingRandom.new(), MissingPending.new()]
	var first_visible_frames: PackedInt32Array = PackedInt32Array([21, 4])
	for index: int in range(mutations.size()):
		var game: Simulation = mutations[index]
		var session: Session = _session(8)
		var driver: Driver = Driver.new(session, game)
		var result: Driver.StepResult
		for frame: int in range(100):
			result = driver.step(frame, _samples(frame))
			if result.code != Types.Code.OK:
				break
		context.equal(result.code, Types.Code.DESYNC, "production sync-test catches omitted random or pending state")
		context.equal(session.status().failure_frame, first_visible_frames[index], "omission localizes the first differing resimulated snapshot")
		context.equal(session.status().lifecycle, Types.Lifecycle.TERMINATED, "omission stops before publishing divergent state")


func _scene(context: RefCounted) -> void:
	var scene: PackedScene = load("res://examples/offline/offline.tscn")
	var instance: Node = scene.instantiate()
	context.equal(instance is Node2D, true, "runnable scene loads with production-only dependencies")
	instance.free()


# Value: protects=atomic snapshot rejection; fails_when=corrupt fields truncate or index colors; why_new=continuation only restores valid bytes; seam=none
func _malformed_snapshots(context: RefCounted) -> void:
	var game: Simulation = Simulation.new()
	var before: PackedByteArray = game.canonical_bytes()
	var malformed: Array[PackedByteArray] = [before.slice(0, before.size() - 1)]
	var oversized: PackedByteArray = before.duplicate()
	oversized.encode_s64(24, 200)
	oversized.append(0)
	malformed.append(oversized)
	var mutations: Array[PackedInt64Array] = [
		PackedInt64Array([0, 2]),
		PackedInt64Array([8, 1]),
		PackedInt64Array([16, -1]),
		PackedInt64Array([16, 2147483648]),
		PackedInt64Array([24, 9223372036854775807]),
		PackedInt64Array([32, 281]),
		PackedInt64Array([40, -2]),
		PackedInt64Array([40, 3]),
		PackedInt64Array([48, 4]),
		PackedInt64Array([56, 7]),
		PackedInt64Array([64, 0]),
		PackedInt64Array([72, -1]),
		PackedInt64Array([80, 19]),
		PackedInt64Array([128, 4]),
	]
	for mutation: PackedInt64Array in mutations:
		var bytes: PackedByteArray = before.duplicate()
		bytes.encode_s64(mutation[0], mutation[1])
		malformed.append(bytes)
	for bytes: PackedByteArray in malformed:
		context.equal(game.load_state(0, Reader.new(bytes, true)), false, "corrupt snapshot rejected")
		context.bytes_equal(game.canonical_bytes(), before, 0, "rejection preserves every field")
	context.equal(game.load_state(0, Reader.new(before, true)), true, "valid initial snapshot accepted")
	# Snapshot frame validation also covers the production session frame ceiling.
	var final_snapshot: PackedByteArray = before.duplicate()
	final_snapshot.encode_s64(8, Simulation.MAX_FRAME)
	final_snapshot.encode_s64(40, Simulation.MAX_FRAME + 2)
	context.equal(game.load_state(Simulation.MAX_FRAME, Reader.new(final_snapshot, true)), false, "incoherent pending frame rejected")

	final_snapshot.encode_s64(40, -1)
	context.equal(game.load_state(Simulation.MAX_FRAME, Reader.new(final_snapshot, true)), true, "final session frame restores")
	context.equal(game.simulate_frame(Simulation.MAX_FRAME, Types.FrameInputs.new()), false, "simulation rejects frame exhaustion")
	context.bytes_equal(game.canonical_bytes(), final_snapshot, Simulation.MAX_FRAME, "exhaustion preserves state")


# Value: protects=movement controls and input validation; fails_when=button mapping/clamps regress; why_new=run-twice can agree on broken controls; seam=none
func _controls(context: RefCounted) -> void:
	for buttons: int in range(16):
		var game: Simulation = Simulation.new()
		var driver: Driver = Driver.new(_session(0), game)
		var inputs: Array[Driver.LocalInput] = [
			Driver.LocalInput.new(0, 0, PackedByteArray([buttons])),
			Driver.LocalInput.new(1, 0, PackedByteArray([0])),
		]
		context.equal(driver.step(0, inputs).code, Types.Code.OK, "button combination accepted")
		var horizontal: int = int(bool(buttons & 2)) - int(bool(buttons & 1))
		var vertical: int = int(bool(buttons & 8)) - int(bool(buttons & 4))
		context.equal(game.x[0], 120 + horizontal * 2, "left/right controls")
		context.equal(game.y[0], 160 + vertical * 2, "up/down controls")
		context.equal(game.x[1], 360, "neutral second player")
	var bounded: Simulation = Simulation.new()
	bounded.x = PackedInt32Array([20, 460])
	bounded.y = PackedInt32Array([20, 280])
	var driver: Driver = Driver.new(_session(0), bounded)
	var samples: Array[Driver.LocalInput] = [
		Driver.LocalInput.new(0, 0, PackedByteArray([5])),
		Driver.LocalInput.new(1, 0, PackedByteArray([10])),
	]
	context.equal(driver.step(0, samples).code, Types.Code.OK, "boundary controls accepted")
	context.equal(bounded.x, PackedInt32Array([20, 460]), "horizontal arena clamps")
	context.equal(bounded.y, PackedInt32Array([20, 280]), "vertical arena clamps")
	var before: PackedByteArray = bounded.canonical_bytes()
	samples = [Driver.LocalInput.new(0, 1, PackedByteArray([1])), Driver.LocalInput.new(1, 1, PackedByteArray([16]))]
	context.equal(driver.step(1, samples).code, Types.Code.CALLBACK_FAILED, "unsupported buttons fail callback")
	context.bytes_equal(bounded.canonical_bytes(), before, 1, "invalid second input preserves both players")
