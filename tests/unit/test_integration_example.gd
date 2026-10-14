extends RefCounted

# Value: protects=guide loop and one-time effects; fails_when=predicted shots play early, stalls resample or snapshots omit state; why_new=no input-driven effects; seam=none
const Game = preload("res://examples/integration/game.gd")
const Effects = preload("res://examples/integration/effects.gd")
const Loop = preload("res://examples/integration/loop.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Reader = preload("res://addons/fortress_rollback/core/snapshot_reader.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const FRAMES: int = 120


class RecordingEffects:
	extends Effects
	var ids: PackedInt64Array = PackedInt64Array()

	func play(id: int) -> void:
		ids.append(id)


## Plays shots as soon as they appear in predicted state. Used only to prove the
## scenarios really mispredict.
class EagerEffects:
	extends RefCounted
	var ids: PackedInt64Array = PackedInt64Array()
	var _last: int = 0

	func observe(game: Game) -> void:
		for index: int in range(maxi(0, game.shot_total - Game.SHOT_SLOTS), game.shot_total):
			var id: int = game.shot_ids[index % Game.SHOT_SLOTS]
			if id > _last:
				_last = id
				ids.append(id)


class CountingLoads:
	extends Game
	var loads: int = 0

	func load_state(saved_frame: int, reader: Reader) -> bool:
		loads += 1
		return super.load_state(saved_frame, reader)


class MissingCooldown:
	extends Game

	func canonical_bytes() -> PackedByteArray:
		var bytes: PackedByteArray = super.canonical_bytes()
		bytes.encode_s64(32, 0)
		bytes.encode_s64(40, 0)
		return bytes


func cases() -> PackedStringArray:
	return PackedStringArray(["confirmed_effects", "nondeterminism", "malformed_snapshots"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"confirmed_effects":
			_confirmed_effects(context)
		"nondeterminism":
			_nondeterminism(context)
		"malformed_snapshots":
			_malformed_snapshots(context)
	context.finish()


static func _local(frame: int) -> int:
	return (Game.RIGHT | Game.FIRE) if frame % 11 < 8 else Game.LEFT


static func _remote(frame: int) -> int:
	# Fire is released while the cooldown is ready, so a late release predicts a shot never fired.
	return (Game.FIRE if frame % 8 < 4 else 0) | (Game.LEFT if frame % 7 < 3 else Game.RIGHT)


## Independent reference: actual inputs simulated directly, without a session or rollback.
## Returns canonical bytes for frames 0..FRAMES + 1 and appends every shot ID.
func _reference(shot_ids: PackedInt64Array) -> Array[PackedByteArray]:
	var game: Game = Game.new()
	var states: Array[PackedByteArray] = [game.canonical_bytes()]
	for frame: int in range(FRAMES + 1):
		var inputs: Array[PackedByteArray] = [PackedByteArray([_local(frame)]), PackedByteArray([_remote(frame)])]
		var before: int = game.shot_total
		game.simulate_frame(frame, Types.FrameInputs.new(inputs, PackedInt32Array([0, 0])))
		for index: int in range(before, game.shot_total):
			shot_ids.append(game.shot_ids[index % Game.SHOT_SLOTS])
		states.append(game.canonical_bytes())
	return states


## Shots whose frames are final: confirmed, simulated and not awaiting rollback.
static func _final_shots(shot_ids: PackedInt64Array, game: Game, status: Types.Status) -> PackedInt64Array:
	var final_frame: int = status.confirmed_frame if status.pending_rollback_frame == -1 else mini(status.confirmed_frame, status.pending_rollback_frame - 1)
	var result: PackedInt64Array = PackedInt64Array()
	for id: int in shot_ids:
		if Game.shot_frame(id) <= final_frame and Game.shot_frame(id) < game.frame:
			result.append(id)
	return result


func _confirmed_effects(context: RefCounted) -> void:
	var expected_ids: PackedInt64Array = PackedInt64Array()
	var expected: Array[PackedByteArray] = _reference(expected_ids)
	context.equal(expected_ids.size() > 20, true, "scenario fires many shots")
	# lag: remote input arrives this many ticks late, in bursts every `burst` ticks.
	# 12 exceeds the 8-frame prediction window.
	var rows: Array[Dictionary] = [
		{"lag": 0, "burst": 1, "mispredicts": false, "stalls": false},
		{"lag": 3, "burst": 1, "mispredicts": true, "stalls": false},
		{"lag": 3, "burst": 6, "mispredicts": true, "stalls": true},
		{"lag": 7, "burst": 1, "mispredicts": true, "stalls": false},
		{"lag": 12, "burst": 1, "mispredicts": true, "stalls": true},
	]
	for row: Dictionary in rows:
		var lag: int = row["lag"]
		var burst: int = row["burst"]
		var label: String = "lag %d burst %d" % [lag, burst]
		var effects: RecordingEffects = RecordingEffects.new()
		var loop: Loop = Loop.new(0, effects)
		loop.game = CountingLoads.new()
		context.equal(loop.start(), Types.Code.OK, label + " configures")
		var eager: EagerEffects = EagerEffects.new()
		var delivered: int = 0
		var stalls: int = 0
		var stalled: bool = false
		var early_or_late: int = 0
		var tick: int = 0
		while loop.game.frame < FRAMES and tick < FRAMES * 3:
			if tick % burst == 0:
				while delivered <= tick - lag:
					context.equal(loop.session.receive_input(1, delivered, PackedByteArray([_remote(delivered)])).code, Types.Code.OK, label + " delivers")
					delivered += 1
			# Delivery can raise confirmed_frame before rollback runs; reconciling here must not play wrong shots.
			effects.reconcile(loop.game, loop.session.status())
			# A real player keeps pressing keys while stalled; the loop must keep its first sample.
			var buttons: int = _local(loop.session.status().current_frame) ^ (Game.FIRE if stalled else 0)
			var code: int = loop.tick(tick, buttons)
			stalled = code == Types.Code.PREDICTION_STALL
			if stalled:
				stalls += 1
			elif code != Types.Code.OK:
				context.equal(code, Types.Code.OK, label + " keeps running")
				break
			if effects.ids != _final_shots(expected_ids, loop.game, loop.session.status()):
				early_or_late += 1
			eager.observe(loop.game)
			tick += 1
		context.equal(early_or_late, 0, label + " plays each shot on the first tick its frame is final")
		# Deliver the remaining remote input; one more tick corrects and confirms everything.
		while delivered <= loop.session.status().current_frame:
			context.equal(loop.session.receive_input(1, delivered, PackedByteArray([_remote(delivered)])).code, Types.Code.OK, label + " delivers rest")
			delivered += 1
		context.equal(loop.tick(tick, _local(loop.session.status().current_frame)), Types.Code.OK, label + " final tick")
		var final_frame: int = loop.game.frame
		context.equal(loop.session.status().confirmed_frame >= final_frame - 1, true, label + " fully confirmed")
		context.bytes_equal(loop.game.canonical_bytes(), expected[final_frame], final_frame, label + " corrected state")
		context.equal(effects.ids, _final_shots(expected_ids, loop.game, loop.session.status()), label + " plays every actual shot once, in order")
		var wrong_shots: int = 0
		for id: int in eager.ids:
			if not expected_ids.has(id):
				wrong_shots += 1
		context.equal(wrong_shots > 0, row["mispredicts"], label + " predicted state shows shots never fired")
		context.equal(loop.game.loads > 0, row["mispredicts"], label + " rolls back")
		context.equal(stalls > 0, row["stalls"], label + " stalls and retains its sample")


func _nondeterminism(context: RefCounted) -> void:
	for game: Game in [Game.new(), MissingCooldown.new()]:
		var config: Config = Config.new()
		config.check_distance = 4
		config.max_snapshot_bytes = Game.SNAPSHOT_BYTES
		config.storage_budget_bytes = config.required_storage_bytes()
		var session: Session = Session.new()
		context.equal(session.configure(config), Types.Code.OK, "sync-test configures")
		var driver: Driver = Driver.new(session, game)
		var code: int = Types.Code.OK
		for frame: int in range(FRAMES):
			var samples: Array[Driver.LocalInput] = [
				Driver.LocalInput.new(0, frame, PackedByteArray([_local(frame)])),
				Driver.LocalInput.new(1, frame, PackedByteArray([_remote(frame)])),
			]
			code = driver.step(frame, samples).code
			if code != Types.Code.OK:
				break
		var expected: int = Types.Code.DESYNC if game is MissingCooldown else Types.Code.OK
		context.equal(code, expected, "sync-test detects a snapshot that omits cooldown")


func _malformed_snapshots(context: RefCounted) -> void:
	# Shots 3 and 5 (frames 1 and 2) occupy the oldest ring slots 0 and 1.
	var game: Game = Game.new()
	game.frame = 10
	game.shot_total = 2
	game.shot_ids[0] = 3
	game.shot_ids[1] = 5
	var valid: PackedByteArray = game.canonical_bytes()
	context.equal(Game.new().load_state(10, Reader.new(valid, true)), true, "valid snapshot loads")
	var trailing: PackedByteArray = valid.duplicate()
	trailing.append(0)
	var cases: Array[PackedByteArray] = [valid.slice(0, valid.size() - 1), trailing]
	# [offset, value]: version, frame, position, cooldown, shot total, then ring IDs that are
	# negative, from the future, out of order, or in a slot beyond the total.
	var mutations: Array[PackedInt64Array] = [
		PackedInt64Array([0, 2]),
		PackedInt64Array([8, 11]),
		PackedInt64Array([16, -1]),
		PackedInt64Array([16, 401]),
		PackedInt64Array([32, -1]),
		PackedInt64Array([32, Game.COOLDOWN]),
		PackedInt64Array([48, -1]),
		PackedInt64Array([48, 21]),
		PackedInt64Array([48, 9223372036854775807]),
		PackedInt64Array([56, -1]),
		PackedInt64Array([56, 10 * 2 + 1]),
		PackedInt64Array([64, 3]),
		PackedInt64Array([72, 2]),
	]
	for mutation: PackedInt64Array in mutations:
		var bytes: PackedByteArray = valid.duplicate()
		bytes.encode_s64(mutation[0], mutation[1])
		cases.append(bytes)
	for bytes: PackedByteArray in cases:
		var target: Game = Game.new()
		target.x[0] = 7
		var before: PackedByteArray = target.canonical_bytes()
		context.equal(target.load_state(10, Reader.new(bytes, true)), false, "malformed snapshot rejected")
		context.bytes_equal(target.canonical_bytes(), before, 10, "rejected snapshot leaves state unchanged")
