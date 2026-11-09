extends RefCounted

# Value: protects=playable lag changes, stalls, reset and bounded effects; fails_when=inputs resample or phantom shots play; why_new=controller owns scheduling; seam=none
const Scene = preload("res://examples/integration/integration.gd")
const Demo = preload("res://examples/integration/demo.gd")
const Game = preload("res://examples/integration/game.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


class StopReplayGame:
	extends Game
	var on_save: Callable
	var on_advance: Callable

	func save_state(saved_frame: int, writer: Game.Writer) -> Game.Driver.SaveResult:
		if on_save.is_valid():
			on_save.call()
		return super.save_state(saved_frame, writer)

	func simulate_frame(input_frame: int, inputs: Types.FrameInputs) -> bool:
		if on_advance.is_valid():
			on_advance.call()
		return super.simulate_frame(input_frame, inputs)


func cases() -> PackedStringArray:
	return PackedStringArray(
		["delayed_matches", "reset_and_validation", "replays_corrected_match", "restart_lifetimes", "pointer_controls", "restart_presentation", "pause_and_step"]
	)


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"pause_and_step":
			_pause_and_step(context)
		"restart_presentation":
			_restart_presentation(context)
		"pointer_controls":
			_pointer_controls(context)
		"delayed_matches":
			_delayed_matches(context)
		"reset_and_validation":
			_reset_and_validation(context)
		"restart_lifetimes":
			_restart_lifetimes(context)
		"replays_corrected_match":
			_replays_corrected_match(context)
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


## The P key's replay must end on the live corrected state, including frames repaired by rollback.
func _replays_corrected_match(context: RefCounted) -> void:
	var demo: Demo = Demo.new()
	context.equal(demo.replay_tick(), Types.Code.NOT_CONFIGURED, "no replay before a match")
	context.equal(demo.start(3), Types.Code.OK, "starts with late remote input")
	for tick: int in range(150):
		demo.tick(Game.RIGHT | Game.FIRE if tick % 9 < 5 else Game.LEFT)
	context.equal(demo.set_lag(0), Types.Code.OK, "removes lag")
	for tick: int in range(8):
		demo.tick(0)
	context.equal(demo.load_count() > 0, true, "the match rolled back")
	context.equal(demo.pending_input_count(), 0, "all remote input arrived")
	var live: PackedByteArray = demo.loop.game.canonical_bytes()
	context.equal(demo.start_replay(), Types.Code.OK, "starts the replay")
	context.equal(demo.replay_frames, demo.loop.game.frame, "records every simulated frame")
	var code: int = Types.Code.OK
	var steps: int = 0
	while code == Types.Code.OK:
		code = demo.replay_tick()
		steps += 1
	context.equal(code, Types.Code.FRAME_EXHAUSTED, "validates every recorded checksum")
	context.equal(steps, demo.replay_frames + 1, "plays each frame once")
	context.bytes_equal(demo.shown_game().canonical_bytes(), live, demo.replay_frames, "ends on the corrected live state")
	context.equal(demo.loop.game.canonical_bytes(), live, "the live match stays paused")
	demo.stop_replay()
	context.equal(demo.shown_game(), demo.loop.game, "returns to the live match")


# Value: protects=example restart retires old match and replay capabilities; fails_when=retained handles keep advancing;
# why_new=reset assertions inspect only fresh state; seam=none
func _restart_lifetimes(context: RefCounted) -> void:
	var demo: Demo = Demo.new()
	context.equal(demo.start(0), Types.Code.OK, "start retirement fixture")
	for tick: int in range(10):
		demo.tick(Game.RIGHT)
	context.equal(demo.start_replay(), Types.Code.OK, "retain active replay before restart")
	var old_loop: RefCounted = demo.loop
	var old_player: RefCounted = demo.replay_player
	context.equal(demo.reset(), Types.Code.OK, "reset retires owned sessions")
	context.equal(old_loop.session.status().reason, Types.Code.TERMINATED, "old live session terminates")
	context.equal(old_loop.tick(10 * Demo.TICK_US, Game.LEFT), Types.Code.TERMINATED, "old loop cannot advance after restart")
	context.equal(old_player.step(), Types.Code.TERMINATED, "old replay cannot continue")
	context.equal(demo.replay_player, null, "fresh live match clears replay mode")
	var next_loop: RefCounted = demo.loop
	var outcomes: PackedInt32Array = PackedInt32Array()
	var owner: WeakRef = weakref(demo)
	var restart: Callable = func(_code: int, _before: int, _after: int) -> void:
		var target: RefCounted = owner.get_ref()
		outcomes.append(target.reset())
		context.equal(target.loop == next_loop, true, "callback cannot replace its live match")
	next_loop.driver.step_completed.connect(restart)
	context.equal(demo.tick(Game.LEFT), Types.Code.OK, "live completion callback runs")
	next_loop.driver.step_completed.disconnect(restart)
	context.equal(outcomes, PackedInt32Array([Types.Code.BUSY]), "reset rejects active completion owner")
	context.equal(demo.reset(), Types.Code.OK, "reset works after callback releases")
	for tick: int in range(10):
		demo.tick(Game.RIGHT)
	context.equal(demo.start_replay(), Types.Code.OK, "configure replay replacement fixture")
	var previous: RefCounted = demo.replay_player
	context.equal(demo.start_replay(), Types.Code.OK, "replace prior replay")
	context.equal(previous.step(), Types.Code.TERMINATED, "replay replacement retires previous player")
	previous = demo.replay_player
	var batch: Types.Result = previous.begin_advance()
	context.equal(batch.code, Types.Code.READY, "open replay expert batch")
	context.equal(demo.start(), Types.Code.BUSY, "active replay batch blocks new match")
	context.equal(demo.reset(), Types.Code.BUSY, "active replay batch blocks reset")
	context.equal(demo.start_replay(), Types.Code.BUSY, "active replay batch blocks replay replacement")
	context.equal(demo.replay_player == previous, true, "busy replacements preserve player identity")
	demo.stop_replay()
	context.equal(previous.step(), Types.Code.TERMINATED, "stopping replay retires retained player")

	context.equal(demo.reset(), Types.Code.OK, "cancelled expert batch releases replacement ownership")
	_stopped_replay_callbacks(context)


# Value: protects=stopped replay callbacks retain match ownership; fails_when=clearing public player hides callback;
# why_new=expert cancellation has no executing callback; seam=none
func _stopped_replay_callbacks(context: RefCounted) -> void:
	for callback: String in ["save", "advance", "validate"]:
		var demo: Demo = Demo.new()
		context.equal(demo.start(0), Types.Code.OK, "start callback retirement fixture")
		for tick: int in range(10):
			demo.tick(Game.RIGHT)
		context.equal(demo.start_replay(), Types.Code.OK, "start callback replay")
		var previous: RefCounted = demo.replay_player
		var old_loop: RefCounted = demo.loop
		var game: StopReplayGame = StopReplayGame.new()
		context.equal(previous.configure(demo.loop.session.replay(), game, Game.SNAPSHOT_BYTES), Types.Code.OK, "configure real replay callback")
		var owner: WeakRef = weakref(demo)
		var attempts: PackedInt32Array = PackedInt32Array()
		var stop: Callable = func() -> void:
			var target: RefCounted = owner.get_ref()
			target.stop_replay()
			target.stop_replay()
			context.equal(target.replay_player, null, "stop immediately leaves replay mode")
			attempts.append(target.reset())
			attempts.append(target.start(0))
			attempts.append(target.start_replay())
			context.equal(target.loop == old_loop, true, "stopped callback retains live match identity")
		if callback == "advance":
			game.on_advance = stop
		else:
			game.on_save = stop
		var result: int = previous.validate_current_frame() if callback == "validate" else previous.step()
		game.on_advance = Callable()
		game.on_save = Callable()
		context.equal(result, Types.Code.TERMINATED, "callback stop preserves termination as first cause")
		context.equal(attempts, PackedInt32Array([Types.Code.BUSY, Types.Code.BUSY, Types.Code.BUSY]), "all replacement entries retain stopped callback ownership")
		context.equal(previous.step(), Types.Code.TERMINATED, "stopped replay stays retired")
		context.equal(demo.start_replay(), Types.Code.OK, "replacement replay works after stopped callback returns")
		context.equal(demo.reset(), Types.Code.OK, "new match works after stopped callback returns")


# Value: protects=pointer controls share keyboard ownership and preserve refused restart effects;
# fails_when=buttons are absent or a BUSY reset clears pulses; why_new=controller tests omit scene state; seam=none
func _pointer_controls(context: RefCounted) -> void:
	var scene: Node2D = Scene.new()
	scene._ready()
	for action: String in ["NoLag", "ShortLag", "LongLag", "Replay", "Restart"]:
		context.equal(scene.get_node_or_null("MatchControls/" + action) != null, true, "pointer match action exists")
		if scene.get_node_or_null("MatchControls/" + action) == null:
			scene._exit_tree()
			scene.free()
			return
	for index: int in range(3):
		var button: Button = scene.get_node("MatchControls/" + ["NoLag", "ShortLag", "LongLag"][index])
		var frame: int = scene._demo.loop.game.frame
		button.pressed.emit()
		context.equal(scene._demo.lag_ticks, [0, 3, 12][index], "pointer changes future sample delay")
		context.equal(scene._demo.loop.game.frame, frame, "lag action never advances the game")
		context.equal(button.focus_mode, Control.FOCUS_NONE, "click preserves movement focus")
	for tick: int in range(40):
		scene._demo.tick(Game.RIGHT | Game.FIRE)
	var replay: Button = scene.get_node("MatchControls/Replay")
	replay.pressed.emit()
	context.equal(scene._demo.replay_player != null, true, "pointer starts corrected replay")
	context.equal(replay.text, "Back to match (P)", "pointer action describes returning to match")
	var lag: int = scene._demo.lag_ticks
	var lag_button: Button = scene.get_node("MatchControls/NoLag")
	context.equal(lag_button.disabled, true, "replay holds live delay settings")
	lag_button.pressed.emit()
	context.equal(scene._demo.lag_ticks, lag, "direct signal preserves paused live match policy")
	replay.pressed.emit()
	context.equal(scene._demo.replay_player, null, "pointer returns to retained match")
	scene._demo.reset()
	scene._pulses.append(Vector2i(7, 9))
	scene._last_effect = 7
	context.equal(scene._demo.loop.session.begin_capture_replay_boundary().code, Types.Code.READY, "manual work owns live match")
	scene._update_label()
	var restart: Button = scene.get_node("MatchControls/Restart")
	context.equal(restart.disabled, true, "owned match disables restart")
	var old_session: RefCounted = scene._demo.loop.session
	var key: InputEventKey = InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_R
	scene._unhandled_key_input(key)
	restart.pressed.emit()
	context.equal(scene._demo.loop.session, old_session, "refused restarts preserve active match")
	context.equal(scene._pulses, [Vector2i(7, 9)], "refused restarts preserve confirmed presentation history")
	context.equal(scene._last_effect, 7, "refused restarts preserve effect deduplication frontier")
	old_session.terminate()
	scene._update_label()
	restart.pressed.emit()
	context.equal(scene._demo.loop.game.frame, 0, "idle restart creates initial state")
	context.equal(scene._pulses.is_empty(), true, "successful restart clears old pulses")
	context.equal(scene._last_effect, 0, "successful restart clears old effect frontier")
	context.state(0, scene._demo.loop.game.canonical_bytes())
	scene._exit_tree()
	scene.free()


# Value: protects=refused keyboard restart retains confirmed effect presentation;
# fails_when=reset clears scene history before its controller succeeds; why_new=controller tests cannot see scene pulses; seam=none
func _restart_presentation(context: RefCounted) -> void:
	var scene: Node2D = Scene.new()
	scene._ready()
	scene._pulses.append(Vector2i(7, 9))
	scene._last_effect = 7
	context.equal(scene._demo.loop.session.begin_capture_replay_boundary().code, Types.Code.READY, "manual snapshot owns initial boundary")
	var key: InputEventKey = InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_R
	scene._unhandled_key_input(key)
	context.equal(scene._pulses, [Vector2i(7, 9)], "BUSY restart retains pulses")
	context.equal(scene._last_effect, 7, "BUSY restart retains confirmed effect frontier")
	scene._demo.loop.session.terminate()
	scene._unhandled_key_input(key)
	context.equal(scene._pulses.is_empty(), true, "successful restart clears pulses")
	context.equal(scene._last_effect, 0, "successful restart clears effect frontier")
	context.state(0, scene._demo.loop.game.canonical_bytes())
	scene._exit_tree()
	scene.free()


# Value: protects=paused match inspection and explicit one-tick delivery; fails_when=pause samples or advances;
# why_new=existing controls cannot stop live service; seam=none
func _pause_and_step(context: RefCounted) -> void:
	var scene: Node2D = Scene.new()
	scene._ready()
	var pause: Button = scene.get_node_or_null("InspectionControls/Pause")
	var step: Button = scene.get_node_or_null("InspectionControls/Step")
	context.equal(pause != null and step != null, true, "live inspection controls exist")
	if pause == null or step == null:
		scene._exit_tree()
		scene.free()
		return
	context.equal(step.disabled, true, "step requires a paused live match")
	pause.pressed.emit()
	context.equal(scene._is_paused, true, "pointer pauses match")
	context.equal(step.disabled, false, "paused match enables one service tick")
	var reference: Demo = Demo.new()
	reference.start()
	for tick: int in range(40):
		var before: PackedByteArray = scene._demo.loop.game.canonical_bytes()
		var queued: int = scene._demo.pending_input_count()
		var effects: int = scene._demo.effects.total_count
		for waiting: int in range(3):
			scene._physics_process(1.0 / 60.0)
		context.equal(scene._demo.tick_count, tick, "paused physics preserves delivery clock")
		context.equal(scene._demo.pending_input_count(), queued, "paused physics preserves queued deliveries")
		context.equal(scene._demo.effects.total_count, effects, "paused physics preserves confirmed effects")
		context.bytes_equal(scene._demo.loop.game.canonical_bytes(), before, scene._demo.loop.game.frame, "paused physics preserves exact state")
		step.pressed.emit()
		reference.tick(0)
		context.equal(scene._demo.tick_count, tick + 1, "step services exactly one controller tick")
		context.equal(scene._is_paused, true, "step keeps automatic service paused")
		context.equal(scene._demo.effects.recent_ids, reference.effects.recent_ids, "step preserves exact confirmed effects")
		context.bytes_equal(scene._demo.loop.game.canonical_bytes(), reference.loop.game.canonical_bytes(), reference.loop.game.frame, "step matches ordinary driver history")
	context.equal(scene._demo.load_count() > 0, true, "inspection crosses real rollback")
	context.equal(scene._demo.loop.session.submit_local_input(0, scene._demo.loop.game.frame, PackedByteArray([0])).code, Types.Code.OK, "expert stages next local input")
	context.equal(scene._demo.loop.session.begin_advance().code, Types.Code.READY, "expert request owns paused match")
	scene._update_label()
	context.equal(pause.disabled and step.disabled, true, "active work disables inspection controls")
	pause.pressed.emit()
	step.pressed.emit()
	context.equal(scene._is_paused, true, "BUSY pause preserves inspection mode")
	context.equal(scene._demo.tick_count, 40, "BUSY step preserves delivery clock")
	scene._demo.loop.session.terminate()
	scene._restart()
	context.equal(scene._is_paused, false, "accepted restart resumes automatic live service")
	var key: InputEventKey = InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_O
	scene._unhandled_key_input(key)
	context.equal(scene._is_paused, true, "keyboard shares pause action")
	key.echo = true
	scene._unhandled_key_input(key)
	context.equal(scene._is_paused, true, "repeated key cannot toggle pause")
	key.echo = false
	key.keycode = KEY_N
	scene._unhandled_key_input(key)
	context.equal(scene._demo.tick_count, 1, "keyboard shares single step")
	scene._toggle_replay()
	context.equal(scene._demo.replay_player != null, true, "paused match opens its recorded prefix")
	var live_tick: int = scene._demo.tick_count
	pause.pressed.emit()
	step.pressed.emit()
	context.equal(scene._is_paused, true, "replay preserves live pause policy")
	context.equal(scene._demo.tick_count, live_tick, "replay refuses live stepping")
	scene._toggle_replay()
	pause.pressed.emit()
	var on_completed: Callable = func(_code: int, _before: int, _after: int) -> void:
		pause.pressed.emit()
		step.pressed.emit()
		context.equal(scene._is_paused, false, "completion callback cannot change pause policy")
		context.equal(scene._demo.tick_count, live_tick, "completion callback cannot service another tick")
	scene._demo.loop.driver.step_completed.connect(on_completed)
	scene._physics_process(1.0 / 60.0)
	scene._demo.loop.driver.step_completed.disconnect(on_completed)
	context.equal(scene._demo.tick_count, live_tick + 1, "resume restores ordinary live service")
	_paused_manual_work(context, scene)
	_stalled_inspection(context, scene)
	_inspection_lifetimes(context, scene)
	context.state(scene._demo.loop.game.frame, scene._demo.loop.game.canonical_bytes())
	scene._exit_tree()
	scene.free()


# Value: protects=paused pointer controls recover after manual ownership; fails_when=paused physics skips refresh;
# why_new=initial inspection coverage terminates the blocked session; seam=none
func _paused_manual_work(context: RefCounted, scene: Node2D) -> void:
	scene._restart()
	scene._toggle_pause()
	var session: RefCounted = scene._demo.loop.session
	var opened: Types.Result = session.begin_capture_replay_boundary()
	context.equal(opened.code, Types.Code.READY, "manual save owns paused initial boundary")
	scene._physics_process(1.0 / 60.0)
	context.equal(scene._code, Types.Code.BUSY, "paused physics reports temporary expert ownership")
	context.equal(scene._label.text.contains("STOPPED"), false, "temporary ownership does not claim a stopped match")
	scene._toggle_pause()
	context.equal(scene._pause_button.disabled and scene._step_button.disabled, true, "stale click refreshes BUSY controls")
	var request: Types.Request = opened.batch.next_request()
	context.equal(request.kind, Types.Kind.SAVE, "manual boundary supplies one save")
	var saved: RefCounted = scene._demo.loop.game.save_state(request.frame, request.writer)
	context.equal(session.complete_request(request.batch_id, request.request_id, saved.ok, saved.checksum).code, Types.Code.OK, "expert finishes original save")
	context.equal(opened.batch.next_request(), null, "manual save completes its batch")
	scene._physics_process(1.0 / 60.0)
	context.equal(scene._pause_button.disabled, false, "paused physics restores pointer resume after manual work")
	context.equal(scene._step_button.disabled, false, "paused physics restores pointer step after manual work")
	context.equal(scene._demo.tick_count, 0, "ownership refresh never services the paused match")
	context.equal(scene._is_paused, true, "ownership refresh retains pause")
	context.equal(scene._label.text.contains("PAUSED"), true, "released expert work retains paused presentation")
	context.equal(scene._label.text.contains("STOPPED"), false, "released temporary ownership is not a terminal failure")


func _stalled_inspection(context: RefCounted, scene: Node2D) -> void:
	scene._restart()
	scene._set_lag(12)
	scene._toggle_pause()
	var reference: Demo = Demo.new()
	reference.start(12)
	var stalled_steps: int = 0
	for tick: int in range(50):
		var frame: int = scene._demo.loop.game.frame
		scene._step_button.pressed.emit()
		var code: int = reference.tick(0)
		context.equal(scene._code, code, "long-delay inspection preserves actual step result")
		context.equal(scene._demo.tick_count, tick + 1, "long-delay step services exactly one delivery tick")
		context.equal(scene._is_paused, true, "long-delay step retains pause")
		if code == Types.Code.PREDICTION_STALL:
			stalled_steps += 1
			context.equal(scene._demo.loop.game.frame, frame, "stalled step does not invent a forward frame")
		context.bytes_equal(
			scene._demo.loop.game.canonical_bytes(), reference.loop.game.canonical_bytes(), reference.loop.game.frame, "stalled inspection matches ordinary canonical history"
		)
		context.equal(scene._demo.effects.recent_ids, reference.effects.recent_ids, "stalled inspection preserves confirmed effects")
		scene._physics_process(1.0 / 60.0)
		context.equal(scene._demo.tick_count, tick + 1, "paused physics never services an extra stalled tick")
	context.equal(stalled_steps > 0, true, "long-delay inspection exercises prediction stalls")
	context.equal(scene._demo.load_count() > 0, true, "long-delay inspection repairs original history")


# Value: protects=temporary playback ownership and terminal live-state presentation; fails_when=BUSY looks stopped or dead match looks paused;
# why_new=live manual-batch coverage does not exercise replay batches or external termination; seam=none
func _inspection_lifetimes(context: RefCounted, scene: Node2D) -> void:
	scene._restart()
	scene._set_lag(0)
	for tick: int in range(6):
		context.equal(scene._demo.tick(Game.RIGHT), Types.Code.OK, "healthy live fixture records original inputs")
	scene._toggle_replay()
	var player: RefCounted = scene._demo.replay_player
	var opened: Types.Result = player.begin_advance()
	context.equal(opened.code, Types.Code.READY, "expert owns actual replay batch")
	var live_tick: int = scene._demo.tick_count
	for attempt: int in range(2):
		scene._physics_process(1.0 / 60.0)
		context.equal(scene._replay_code, Types.Code.BUSY, "playback reports temporary expert ownership")
		context.equal(scene._label.text.contains("WAITING FOR ACTIVE REPLAY WORK"), true, "owned playback describes waiting")
		context.equal(scene._label.text.contains("REPLAY STOPPED"), false, "owned playback does not claim terminal failure")
		context.equal(player.current_frame(), 0, "busy playback preserves original exposed frame")
	while true:
		var request: Types.Request = opened.batch.next_request()
		if request == null:
			break
		var ok: bool = false
		var checksum: PackedByteArray = PackedByteArray()
		if request.kind == Types.Kind.SAVE:
			var saved: RefCounted = scene._demo.replay_game.save_state(request.frame, request.writer)
			ok = saved.ok
			checksum = saved.checksum
		elif request.kind == Types.Kind.ADVANCE:
			ok = scene._demo.replay_game.simulate_frame(request.frame, request.inputs)
		context.equal(player.complete_request(request.batch_id, request.request_id, ok, checksum).code, Types.Code.OK, "expert completes original replay request")
	scene._physics_process(1.0 / 60.0)
	context.equal(scene._replay_code, Types.Code.OK, "playback resumes after original expert work")
	context.equal(player.current_frame(), 2, "automatic playback follows the expert's original frame")
	context.equal(scene._demo.tick_count, live_tick, "replay ownership never services live input")
	var reference: Game = Game.new()
	for frame: int in range(2):
		var remote: int = (Game.FIRE if frame % 8 < 4 else 0) | (Game.LEFT if frame % 7 < 3 else Game.RIGHT)
		var original: Types.FrameInputs = Types.FrameInputs.new([PackedByteArray([Game.RIGHT]), PackedByteArray([remote])], PackedInt32Array([0, 0]))
		context.equal(reference.simulate_frame(frame, original), true, "reference executes original recorded inputs")
	context.bytes_equal(scene._demo.replay_game.canonical_bytes(), reference.canonical_bytes(), 2, "released replay preserves original canonical history")
	scene._toggle_replay()
	scene._toggle_pause()
	context.equal(scene._label.text.contains("PAUSED"), true, "healthy live control remains paused")
	var frame: int = scene._demo.loop.game.frame
	scene._demo.loop.session.terminate(Types.Code.DESYNC, frame)
	scene._physics_process(1.0 / 60.0)
	context.equal(scene._code, Types.Code.DESYNC, "paused physics observes the first terminal cause")
	context.equal(
		scene._label.text.contains("STOPPED: %s (code %d, failure frame %d)" % [Types.reason_text(Types.Code.DESYNC), Types.Code.DESYNC, frame]),
		true, "externally stopped match identifies its exact cause"
	)
	context.equal(scene._label.text.contains("state checksum mismatch"), true, "stopped match names its cause in plain language")
	context.equal(scene._label.text.contains("PAUSED"), false, "terminated match does not claim resumable pause")
	context.equal(scene._demo.tick_count, live_tick, "terminal status refresh never services the live match")
