extends RefCounted

# Value: protects=playable lag changes, stalls, reset and bounded effects; fails_when=inputs resample or phantom shots play; why_new=controller owns scheduling; seam=none
const Demo = preload("res://examples/integration/demo.gd")
const Game = preload("res://examples/integration/game.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["delayed_matches", "reset_and_validation"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"delayed_matches":
			_delayed_matches(context)
		"reset_and_validation":
			_reset_and_validation(context)
	context.finish()


func _delayed_matches(context: RefCounted) -> void:
	for initial_lag: int in [0, 3, 12]:
		for transitions: bool in [false, true]:
			_match_history(context, initial_lag, transitions)


func _match_history(context: RefCounted, initial_lag: int, transitions: bool) -> void:
	var label: String = "lag %d transitions %s" % [initial_lag, transitions]
	var demo: Demo = Demo.new()
	context.equal(demo.start(initial_lag), Types.Code.OK, label + " starts")
	var reference: Game = Game.new()
	var actual_shots: PackedInt64Array = PackedInt64Array()
	var sample_frame: int = -1
	var held_buttons: int = 0
	var phantom_count: int = 0
	var corrected_comparisons: int = 0
	var expected_lag: int = initial_lag
	var deliveries: Array[PackedInt64Array] = []
	var delivered_frame: int = -1
	for tick: int in range(460):
		if transitions and tick in [90, 180, 270, 360]:
			var lag: int = 12 if tick in [90, 270] else 3
			if expected_lag > 0:
				context.equal(deliveries.is_empty(), false, label + " switches before older inputs arrive")
			context.equal(demo.set_lag(lag), Types.Code.OK, label + " changes lag")
			expected_lag = lag
		if tick == 420:
			context.equal(demo.set_lag(0), Types.Code.OK, label + " drains lag")
			expected_lag = 0
		var frame: int = demo.loop.session.status().current_frame
		var buttons: int = (Game.RIGHT if tick % 11 < 8 else Game.LEFT) | (Game.FIRE if tick % 5 < 4 else 0)
		while not deliveries.is_empty() and deliveries[0][1] <= tick:
			delivered_frame = deliveries.pop_front()[0]
		if frame != sample_frame:
			sample_frame = frame
			held_buttons = buttons
			var due: int = tick + expected_lag
			if not deliveries.is_empty():
				due = maxi(due, deliveries.back()[1])
			deliveries.append(PackedInt64Array([frame, due]))
		while not deliveries.is_empty() and deliveries[0][1] <= tick:
			delivered_frame = deliveries.pop_front()[0]
		var code: int = demo.tick(buttons)
		context.equal(code in [Types.Code.OK, Types.Code.PREDICTION_STALL], true, label + " keeps running")
		if code == Types.Code.OK:
			var before: int = reference.shot_total
			# Independent input history, with no queue, session, prediction or controller helpers.
			var remote: int = (Game.FIRE if frame % 8 < 4 else 0) | (Game.LEFT if frame % 7 < 3 else Game.RIGHT)
			var inputs: Array[PackedByteArray] = [PackedByteArray([held_buttons]), PackedByteArray([remote])]
			context.equal(reference.simulate_frame(frame, Types.FrameInputs.new(inputs, PackedInt32Array([0, 0]))), true, label + " advances reference")
			for index: int in range(before, reference.shot_total):
				actual_shots.append(reference.shot_ids[index % Game.SHOT_SLOTS])
		context.equal(demo.tick_count, tick + 1, label + " clock advances through stalls")
		context.equal(demo.loop.game.frame, reference.frame, label + " retains the simulation frame")
		context.equal(demo.pending_input_count() <= Demo.MAX_PENDING_INPUTS, true, label + " bounds queued input")
		context.equal(demo.pending_input_count(), deliveries.size(), label + " samples remote input once per simulation frame")
		context.equal(demo.effects.recent_ids.size() <= Demo.RECENT_EFFECT_LIMIT, true, label + " bounds effect history")
		var status: Types.Status = demo.loop.session.status()
		context.equal(status.confirmed_frame, delivered_frame, label + " delivers only due input across lag changes")
		var final_frame: int = mini(status.confirmed_frame, reference.frame - 1)
		if status.pending_rollback_frame != -1:
			final_frame = mini(final_frame, status.pending_rollback_frame - 1)
		var expected_ids: PackedInt64Array = PackedInt64Array()
		for id: int in actual_shots:
			if Game.shot_frame(id) <= final_frame:
				expected_ids.append(id)
		context.equal(demo.effects.total_count, expected_ids.size(), label + " emits each confirmed actual shot once")
		context.equal(demo.effects.recent_ids, expected_ids.slice(maxi(0, expected_ids.size() - Demo.RECENT_EFFECT_LIMIT)), label + " emits exact ordered IDs")
		for id: int in demo.predicted_shot_ids():
			context.equal(Game.shot_frame(id) > final_frame, true, label + " predicted shots stay reversible")
			if not actual_shots.has(id):
				phantom_count += 1
		if status.confirmed_frame >= reference.frame - 1 and status.pending_rollback_frame == -1:
			context.bytes_equal(demo.loop.game.canonical_bytes(), reference.canonical_bytes(), reference.frame, label + " corrected prefix")
			corrected_comparisons += 1
	context.equal(demo.pending_input_count(), 0, label + " drains every queued input")
	context.equal(demo.loop.session.status().confirmed_frame, reference.frame - 1, label + " confirms complete history")
	context.bytes_equal(demo.loop.game.canonical_bytes(), reference.canonical_bytes(), reference.frame, label + " final actual-input state")
	context.equal(demo.effects.total_count, actual_shots.size(), label + " confirms every actual effect")
	context.equal(demo.effects.total_count > Demo.RECENT_EFFECT_LIMIT, true, label + " exercises effect eviction")
	context.equal(corrected_comparisons > 20, true, label + " compares corrected prefixes")
	context.equal(demo.load_count() > 0, initial_lag > 0 or transitions, label + " performs real rollback")
	context.equal(demo.stall_count > 0, initial_lag == 12 or transitions, label + " performs real prediction stalls")
	context.equal(phantom_count > 0, initial_lag > 0 or transitions, label + " displays phantom predictions")


func _reset_and_validation(context: RefCounted) -> void:
	var demo: Demo = Demo.new()
	context.equal(demo.tick(0), Types.Code.INVALID_CONFIGURATION, "tick before start rejects")
	context.equal(demo.start(7), Types.Code.INVALID_CONFIGURATION, "unsupported initial lag rejects")
	context.equal(demo.loop == null, true, "invalid initial lag creates no match")
	context.equal(demo.start(12), Types.Code.OK, "slow match starts")
	for tick: int in range(180):
		demo.tick(Game.FIRE | Game.RIGHT)
	context.equal(demo.stall_count > 0 and demo.load_count() > 0, true, "reset fixture exercised stalls and rollback")
	context.equal(demo.effects.total_count > 0 and demo.pending_input_count() > 0, true, "reset fixture has effects and queued input")
	var bytes: PackedByteArray = demo.loop.game.canonical_bytes()
	var tick_count: int = demo.tick_count
	context.equal(demo.set_lag(-1), Types.Code.INVALID_CONFIGURATION, "negative lag rejects")
	context.equal(demo.start(4), Types.Code.INVALID_CONFIGURATION, "invalid restart rejects")
	context.equal(demo.lag_ticks, 12, "rejected lag keeps previous setting")
	context.equal(demo.tick_count, tick_count, "invalid restart preserves time")
	context.bytes_equal(demo.loop.game.canonical_bytes(), bytes, demo.loop.game.frame, "invalid restart preserves match")
	context.equal(demo.reset(), Types.Code.OK, "reset starts a fresh match")
	context.equal(demo.lag_ticks, 12, "reset preserves selected lag")
	context.equal(demo.tick_count, 0, "reset clears injected clock")
	context.equal(demo.stall_count, 0, "reset clears stalls")
	context.equal(demo.load_count(), 0, "reset clears rollback count")
	context.equal(demo.pending_input_count(), 0, "reset drops previous deliveries")
	context.equal(demo.effects.total_count, 0, "reset clears effect count")
	context.equal(demo.effects.last_played_id, 0, "reset clears effect deduplication")
	context.equal(demo.effects.recent_ids.is_empty(), true, "reset clears recent effects")
	context.equal(demo.predicted_shot_ids().is_empty(), true, "reset clears predicted shots")
	context.bytes_equal(demo.loop.game.canonical_bytes(), Game.new().canonical_bytes(), 0, "reset restores initial simulation")
	var fresh: Demo = Demo.new()
	fresh.start(12)
	for tick: int in range(50):
		var buttons: int = Game.FIRE if tick % 2 == 0 else Game.LEFT
		context.equal(demo.tick(buttons), fresh.tick(buttons), "reset has fresh match behavior")
		context.bytes_equal(demo.loop.game.canonical_bytes(), fresh.loop.game.canonical_bytes(), demo.loop.game.frame, "reset does not deliver stale input")
		context.equal(demo.effects.recent_ids, fresh.effects.recent_ids, "reset does not replay stale effects")
