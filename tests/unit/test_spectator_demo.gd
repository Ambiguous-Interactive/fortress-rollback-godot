extends RefCounted

# Value: protects=delayed viewer follows corrected original game; fails_when=predictions stream or spectator stalls host; why_new=playable host/export composition; seam=none
const Scene = preload("res://examples/spectator/spectator.gd")
const Spectator = preload("res://addons/fortress_rollback/core/spectator_session.gd")
const Demo = preload("res://examples/spectator/demo.gd")
const Game = preload("res://examples/integration/game.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")


class RestartGame:
	extends Game
	var on_advance: Callable

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		on_advance.call()
		return super.simulate_frame(frame, inputs)


func cases() -> PackedStringArray:
	return PackedStringArray(
		[
			"corrected_viewing",
			"pause_and_catchup",
			"catchup_speed",
			"catchup_control",
			"lost_history",
			"idle_host_liveness",
			"clean_host_end",
			"paused_final_tail",
			"single_frame",
			"single_frame_end",
			"single_frame_control",
			"host_loss",
			"host_loss_control",
			"restart_lifetimes",
			"restart_busy",
			"service_busy",
			"playback_feedback",
			"terminal_feedback"
		]
	)


func run_case(name: String, context: RefCounted) -> void:
	if name == "corrected_viewing":
		_corrected_viewing(context)
	elif name == "pause_and_catchup":
		_pause_and_catchup(context)
	elif name in ["catchup_speed", "catchup_control"]:
		call("_" + name, context)
	elif name == "lost_history":
		_lost_history(context)
	elif name == "paused_final_tail":
		_paused_final_tail(context)
	elif (
		name
		in [
			"single_frame",
			"single_frame_end",
			"single_frame_control",
			"host_loss",
			"host_loss_control",
			"restart_lifetimes",
			"restart_busy",
			"service_busy",
			"playback_feedback",
			"terminal_feedback"
		]
	):
		call("_" + name, context)
	elif name == "clean_host_end":
		_clean_host_end(context)
	else:
		_idle_host_liveness(context)
	context.finish()


func _corrected_viewing(context: RefCounted) -> void:
	var demo: Demo = Demo.new()
	context.equal(demo.start(), Types.Code.OK, "start delayed viewer")
	var reference: Game = Game.new()
	var history: Array[PackedByteArray] = [reference.canonical_bytes()]
	for tick: int in range(260):
		var frame: int = demo.host.loop.session.status().current_frame
		var buttons: int = Game.RIGHT | (Game.FIRE if frame % 5 < 3 else Game.LEFT)
		var code: int = demo.tick(buttons)
		context.equal(code in [Types.Code.OK, Types.Code.PREDICTION_STALL], true, "host advances or waits")
		if demo.host.loop.session.status().current_frame > frame:
			var row: Array[PackedByteArray] = [PackedByteArray([buttons]), PackedByteArray([Demo.Host.remote_buttons(frame)])]
			var statuses: PackedInt32Array = PackedInt32Array([Queue.Status.CONFIRMED, Queue.Status.CONFIRMED])
			context.equal(reference.simulate_frame(frame, Types.FrameInputs.new(row, statuses)), true, "independent actual inputs")
			history.append(reference.canonical_bytes())
		context.bytes_equal(demo.game.canonical_bytes(), history[demo.game.frame], demo.game.frame, "viewer equals original corrected prefix")
		context.equal(demo.viewer.status().current_frame <= maxi(0, demo.host.loop.session.status().confirmed_frame - 11), true, "delay boundary")
	context.equal(demo.host.load_count() > 0, true, "host actually corrected prediction")
	context.equal(demo.game.frame > 100, true, "viewer makes sustained progress past ring wrap")
	context.equal(demo.viewer.statistics().rollback_count, 0, "viewer never predicts")


func _pause_and_catchup(context: RefCounted) -> void:
	_viewing_delay(context)
	var demo: Demo = Demo.new()
	demo.start()
	for tick: int in range(80):
		demo.tick(0)
	demo.is_paused = true
	var paused: int = demo.game.frame
	for tick: int in range(30):
		demo.tick(Game.RIGHT)
	context.equal(demo.game.frame, paused, "viewer pause")
	context.equal(demo.host.loop.game.frame > paused + 25, true, "host unaffected by viewer pause")
	demo.is_paused = false
	for tick: int in range(30):
		var before: int = demo.game.frame
		demo.tick(0)
		context.equal(demo.game.frame - before <= 4, true, "bounded catchup")
	context.equal(demo.viewer.recommended_steps() <= 1, true, "viewer returns to delayed live edge")


func _lost_history(context: RefCounted) -> void:
	var demo: Demo = Demo.new()
	demo.start()
	demo.is_paused = true
	for tick: int in range(300):
		demo.tick(0)
	context.equal(demo.viewer_code, Types.Code.HISTORY_UNAVAILABLE, "long pause cannot invent missing initial history")
	context.equal(demo.viewer.status().lifecycle, Types.Lifecycle.TERMINATED, "viewer stops explicitly")
	var frame: int = demo.host.loop.game.frame
	context.equal(demo.tick(Game.RIGHT), Types.Code.OK, "host continues after viewer failure")
	context.equal(demo.host.loop.game.frame, frame + 1, "no spectator effect on host")
	context.equal(demo.start(), Types.Code.OK, "explicit fresh game restart")
	context.equal(demo.game.frame, 0, "fresh viewer state")


# Value: protects=example forwards liveness without confirmed inputs; fails_when=startup idle sends no keepalive; why_new=normal ticks stay below timeout; seam=none
func _idle_host_liveness(context: RefCounted) -> void:
	var demo: Demo = Demo.new()
	context.equal(demo.start(), Types.Code.OK, "start host and viewer")
	context.equal(demo.tick(0), Types.Code.OK, "host begins predicting before remote input")
	context.equal(demo.next_host_frame, 0, "no confirmed row was delivered")
	context.equal(demo.stream.poll(10000000), Types.Code.OK, "host's rowless tick refreshed viewer liveness")
	context.equal(demo.viewer.status().reason, Types.Code.OK, "live idle host preserves viewer")


# Value: protects=playable final tail without a phantom host tick; fails_when=ending skips correction or paused tail; why_new=demo only runs indefinitely; seam=none
func _clean_host_end(context: RefCounted) -> void:
	var demo: Demo = Demo.new()
	context.equal(demo.has_method("finish_host"), true, "example exposes clean ending")
	if not demo.has_method("finish_host"):
		return
	for pause: bool in [false, true]:
		context.equal(demo.start(), Types.Code.OK, "fresh ending example")
		var reference: Game = Game.new()
		for tick: int in range(40):
			var frame: int = demo.host.loop.game.frame
			var buttons: int = Game.RIGHT | (Game.FIRE if frame % 5 < 3 else 0)
			context.equal(demo.tick(buttons), Types.Code.OK, "original host input")
			var rows: Array[PackedByteArray] = [PackedByteArray([buttons]), PackedByteArray([Demo.Host.remote_buttons(frame)])]
			var statuses: PackedInt32Array = PackedInt32Array([Queue.Status.CONFIRMED, Queue.Status.CONFIRMED])
			context.equal(reference.simulate_frame(frame, Types.FrameInputs.new(rows, statuses)), true, "independent final history")
		var final_frame: int = demo.host.loop.game.frame
		context.equal(demo.host.loop.session.status().confirmed_frame < final_frame - 1, true, "ending begins with outstanding actual input")
		demo.is_paused = pause
		context.equal(demo.finish_host(), Types.Code.OK, "request final host boundary")
		context.equal(demo.finish_host(), Types.Code.OK, "repeated end request is idempotent")
		for tick: int in range(20):
			context.equal(demo.tick(Game.LEFT) in [Types.Code.OK, Types.Code.PREDICTION_STALL], true, "drain without new host samples")
		context.equal(demo.host.loop.game.frame, final_frame, "host never adds a phantom final frame")
		context.bytes_equal(demo.host.loop.game.canonical_bytes(), reference.canonical_bytes(), final_frame, "final host corrected to original inputs")
		if pause:
			context.equal(demo.game.frame < final_frame, true, "pause holds clean tail")
			demo.is_paused = false
		for tick: int in range(20):
			context.equal(demo.tick(Game.LEFT), Types.Code.OK, "viewer catches up after host stops")
		context.equal(demo.viewer.status().lifecycle, Types.Lifecycle.TERMINATED, "clean tail visibly completes")
		context.equal(demo.viewer_code, Types.Code.TERMINATED, "clean end reason")
		context.bytes_equal(demo.game.canonical_bytes(), reference.canonical_bytes(), final_frame, "viewer displays exact final canonical host state")
		context.equal(demo.start(), Types.Code.OK, "restart creates a fresh host and viewer")
		context.equal(demo.tick(Game.RIGHT), Types.Code.OK, "fresh host accepts input after ending")
		context.equal(demo.host.loop.game.frame, 1, "new host advances normally")


# Value: protects=stopped host liveness while final rows wait; fails_when=freeze suppresses heartbeat before END acceptance; why_new=short pauses never fill ring; seam=none
func _paused_final_tail(context: RefCounted) -> void:
	var demo: Demo = Demo.new()
	context.equal(demo.start(), Types.Code.OK, "fresh paused viewer")
	demo.is_paused = true
	for tick: int in range(130):
		context.equal(demo.tick(0), Types.Code.OK, "host advances with full paused viewer ring")
	context.equal(demo.finish_host(), Types.Code.OK, "stop host before retained history is lost")
	for tick: int in range(620):
		context.equal(demo.tick(0) in [Types.Code.OK, Types.Code.PREDICTION_STALL], true, "final packets wait with live host")
	context.equal(demo.is_host_finished, true, "host boundary settled")
	context.equal(demo.viewer.status().lifecycle, Types.Lifecycle.RUNNING, "backpressured final tail survives original ten-second deadline")
	context.equal(demo.game.frame, 0, "long pause simulates no viewer input")
	demo.is_paused = false
	for tick: int in range(150):
		demo.tick(0)
	context.equal(demo.viewer_code, Types.Code.TERMINATED, "resumed final tail ends cleanly")
	context.bytes_equal(demo.game.canonical_bytes(), demo.host.loop.game.canonical_bytes(), 130, "full stopped-host history survives pause")


# Value: protects=paused single-frame inspection; fails_when=step runs catchup or advances host; why_new=pause tests only resume continuous playback; seam=none
func _single_frame(context: RefCounted) -> void:
	var demo: Demo = Demo.new()
	context.equal(demo.has_method("step_viewer"), true, "viewer exposes single-frame playback")
	if not demo.has_method("step_viewer"):
		return
	context.equal(demo.call("step_viewer"), Types.Code.NOT_CONFIGURED, "cannot step before startup")
	context.equal(demo.start(), Types.Code.OK, "start frame inspection")
	context.equal(demo.call("step_viewer"), Types.Code.PREDICTION_STALL, "empty viewer cannot invent inputs")
	context.equal(demo.is_paused, true, "single step pauses continuous playback")
	var reference: Game = Game.new()
	var history: Array[PackedByteArray] = [reference.canonical_bytes()]
	for tick: int in range(60):
		var frame: int = demo.host.loop.game.frame
		var buttons: int = Game.RIGHT | (Game.FIRE if frame % 5 < 3 else 0)
		context.equal(demo.tick(buttons), Types.Code.OK, "host advances while viewer remains paused")
		var rows: Array[PackedByteArray] = [PackedByteArray([buttons]), PackedByteArray([Demo.Host.remote_buttons(frame)])]
		var statuses: PackedInt32Array = PackedInt32Array([Queue.Status.CONFIRMED, Queue.Status.CONFIRMED])
		context.equal(reference.simulate_frame(frame, Types.FrameInputs.new(rows, statuses)), true, "independent original-input history")
		history.append(reference.canonical_bytes())
	context.equal(demo.game.frame, 0, "host ticking does not resume paused viewer")
	var host_frame: int = demo.host.loop.game.frame
	var confirmed: int = demo.host.loop.session.status().confirmed_frame
	var playable: int = demo.viewer.host_frontier() - 11
	for frame: int in range(playable):
		context.equal(demo.call("step_viewer"), Types.Code.OK, "inspect exactly one confirmed frame")
		context.equal(demo.game.frame, frame + 1, "single step ignores multi-frame catchup advice")
		context.equal(demo.is_paused, true, "inspection preserves pause")
		context.bytes_equal(demo.game.canonical_bytes(), history[frame + 1], frame + 1, "inspected state matches original input prefix")
	context.equal(demo.call("step_viewer"), Types.Code.PREDICTION_STALL, "single step cannot bypass stream delay")
	context.equal(demo.game.frame, playable, "delay stall leaves game unchanged")
	context.equal(demo.host.loop.game.frame, host_frame, "inspection never advances host")
	context.equal(demo.host.loop.session.status().confirmed_frame, confirmed, "inspection never changes player confirmation")
	demo.is_paused = false
	context.equal(demo.tick(Game.LEFT), Types.Code.OK, "resume host and viewer")
	context.equal(demo.is_paused, false, "regular playback resumes explicitly")
	context.equal(demo.game.frame > playable, true, "resumed viewer follows new confirmed history")


# Value: protects=single-step final tail and failure diagnostics; fails_when=terminal action invents frame or erases failure; why_new=tail tests use continuous playback; seam=none
func _single_frame_end(context: RefCounted) -> void:
	var demo: Demo = Demo.new()
	context.equal(demo.has_method("step_viewer"), true, "viewer exposes single-frame playback")
	if not demo.has_method("step_viewer"):
		return
	for count: int in [0, 40]:
		context.equal(demo.start(), Types.Code.OK, "fresh ending inspection")
		demo.is_paused = true
		for tick: int in range(count):
			context.equal(demo.tick(Game.RIGHT | Game.FIRE), Types.Code.OK, "host input before ending")
		context.equal(demo.finish_host(), Types.Code.OK, "freeze host")
		for tick: int in range(20):
			context.equal(demo.tick(0) in [Types.Code.OK, Types.Code.PREDICTION_STALL], true, "confirm and publish final rows")
		for frame: int in range(count):
			context.equal(demo.call("step_viewer"), Types.Code.OK, "step through final tail")
			context.equal(demo.game.frame, frame + 1, "exact final-tail step")
		context.bytes_equal(demo.game.canonical_bytes(), demo.host.loop.game.canonical_bytes(), count, "inspected tail reaches exact final host state")
		context.equal(demo.call("step_viewer"), Types.Code.TERMINATED, "final control call reports clean completion")
		context.equal(demo.call("step_viewer"), Types.Code.TERMINATED, "repeated completion is stable")
		context.equal(demo.game.frame, count, "terminal step creates no phantom frame")
	context.equal(demo.start(), Types.Code.OK, "restart after single-step completion")
	demo.is_paused = true
	for tick: int in range(300):
		demo.tick(0)
	context.equal(demo.call("step_viewer"), Types.Code.HISTORY_UNAVAILABLE, "step preserves lost-history cause")
	context.equal(demo.viewer_code, Types.Code.HISTORY_UNAVAILABLE, "failure remains visible")
	context.equal(demo.start(), Types.Code.OK, "restart after failed inspection")
	context.equal(demo.is_paused, false, "restart restores continuous playback")


# Value: protects=scene keyboard frame-step control; fails_when=N is unbound or repeats on held key; why_new=demo API tests bypass scene input; seam=none
func _single_frame_control(context: RefCounted) -> void:
	var scene: Node2D = Scene.new()
	scene._ready()
	for tick: int in range(50):
		scene.demo.tick(Game.RIGHT)
	var key: InputEventKey = InputEventKey.new()
	key.keycode = KEY_P
	key.pressed = true
	scene._unhandled_key_input(key)
	context.equal(scene.demo.is_paused, true, "existing pause control prepares inspection")
	for tick: int in range(10):
		scene.demo.tick(Game.RIGHT)
	var frame: int = scene.demo.game.frame
	key.keycode = KEY_N
	key.pressed = false
	scene._unhandled_key_input(key)
	context.equal(scene.demo.game.frame, frame, "key release never advances viewer")
	key.pressed = true
	key.echo = true
	scene._unhandled_key_input(key)
	context.equal(scene.demo.game.frame, frame, "held key never repeats viewer advance")
	key.echo = false
	scene._unhandled_key_input(key)
	context.equal(scene.demo.is_paused, true, "N key enters paused inspection")
	context.equal(scene.demo.game.frame, frame + 1, "N key advances one eligible frame")
	context.equal(scene._label.text.contains("N: step viewer"), true, "help exposes frame-step key")
	key.keycode = KEY_P
	scene._unhandled_key_input(key)
	context.equal(scene.demo.is_paused, false, "P resumes playback after inspection")
	var host_frame: int = scene.demo.host.loop.game.frame
	frame = scene.demo.game.frame
	key.keycode = KEY_BRACKETRIGHT
	scene._unhandled_key_input(key)
	context.equal(scene.demo.viewer.playback_policy()[0], 13, "right bracket raises cushion one confirmed frame")
	context.equal(scene._label.text.contains("Viewer holds 13 confirmed frames"), true, "delay feedback reflects selected policy")
	context.equal(scene._label.text.contains("[: less delay | ]: more delay"), true, "help exposes delay controls")
	key.keycode = KEY_BRACKETLEFT
	for press: int in range(15):
		scene._unhandled_key_input(key)
	context.equal(scene.demo.viewer.playback_policy()[0], 0, "left bracket reaches zero without going negative")
	context.equal(scene.demo.game.frame, frame, "delay keys never step viewer")
	context.equal(scene.demo.host.loop.game.frame, host_frame, "delay keys never step host")
	context.equal(scene.demo.is_paused, false, "delay keys preserve continuous viewing")
	key.keycode = KEY_BRACKETRIGHT
	for press: int in range(140):
		scene._unhandled_key_input(key)
	var maximum_delay: int = Demo.Config.new().queue_capacity - 1
	context.equal(scene.demo.viewer.playback_policy()[0], maximum_delay, "delay key cannot exceed retained ring")
	context.equal(scene._label.text.contains("Viewer holds %d confirmed frames" % maximum_delay), true, "upper-bound display retains accepted delay")
	scene.demo.lose_host_connection()
	key.keycode = KEY_BRACKETLEFT
	scene._unhandled_key_input(key)
	context.equal(scene.demo.viewer.playback_policy()[0], maximum_delay, "terminal delay key leaves policy unchanged")
	context.equal(scene._label.text.contains("HOST CONNECTION LOST"), true, "terminal refusal preserves visible cause")
	scene.free()


# Value: protects=known host loss stops buffered viewing while host remains playable;
# fails_when=disconnect drains stale input or blocks restart; why_new=demo covers clean end only; seam=none
func _host_loss(context: RefCounted) -> void:
	var demo: Demo = Demo.new()
	context.equal(demo.has_method("lose_host_connection"), true, "example exposes unexpected host loss")
	if not demo.has_method("lose_host_connection"):
		return
	context.equal(demo.call("lose_host_connection"), Types.Code.NOT_CONFIGURED, "no host connection before startup")
	for pause: bool in [false, true]:
		context.equal(demo.start(), Types.Code.OK, "start host-loss scenario")
		for tick: int in range(40):
			context.equal(demo.tick(Game.RIGHT), Types.Code.OK, "play before host loss")
		demo.is_paused = pause
		for tick: int in range(10):
			context.equal(demo.tick(Game.LEFT), Types.Code.OK, "retain host rows before loss")
		context.equal(demo.viewer.host_frontier() >= demo.game.frame, true, "loss occurs with buffered confirmed input")
		var frame: int = demo.game.frame
		var canonical: PackedByteArray = demo.game.canonical_bytes()
		var host_frame: int = demo.host.loop.game.frame
		demo.viewer.drain_events()
		context.equal(demo.call("lose_host_connection"), Types.Code.PROTOCOL_FAILED, "known loss terminates playback immediately")
		context.equal(demo.viewer.status().lifecycle, Types.Lifecycle.TERMINATED, "host loss is terminal")
		context.equal(demo.viewer.status().reason, Types.Code.PROTOCOL_FAILED, "loss cause remains visible")
		context.equal(demo.viewer_code, Types.Code.PROTOCOL_FAILED, "demo retains loss cause")
		context.equal(demo.call("lose_host_connection"), Types.Code.PROTOCOL_FAILED, "repeated loss retains first cause")
		var events: Array[RefCounted] = demo.viewer.drain_events()
		context.equal(events.size(), 1, "host loss publishes one terminal event")
		if events.size() == 1:
			context.equal(events[0].kind, Demo.Spectator.EventKind.TERMINATED, "host loss lifecycle event")
			context.equal(events[0].frame, frame, "loss identifies stopped viewer boundary")
			context.equal(events[0].reason, Types.Code.PROTOCOL_FAILED, "event carries loss reason")
		context.equal(demo.step_viewer(), Types.Code.PROTOCOL_FAILED, "inspection cannot consume buffered rows after loss")
		demo.is_paused = false
		for tick: int in range(15):
			context.equal(demo.tick(Game.RIGHT | Game.FIRE), Types.Code.OK, "host continues without its viewer")
		context.equal(demo.host.loop.game.frame, host_frame + 15, "viewer loss never stalls the host")
		context.equal(demo.game.frame, frame, "no buffered row advances after loss")
		context.bytes_equal(demo.game.canonical_bytes(), canonical, frame, "host loss preserves last displayed state")
		context.equal(demo.viewer.drain_events().is_empty(), true, "later service does not duplicate termination")
		context.equal(demo.start(), Types.Code.OK, "restart after unexpected loss")
		context.equal(demo.tick(Game.RIGHT), Types.Code.OK, "fresh host and viewer are usable")
		context.equal(demo.viewer.status().reason, Types.Code.OK, "restart clears prior failure")
	context.equal(demo.start(), Types.Code.OK, "empty clean ending control")
	context.equal(demo.finish_host(), Types.Code.OK, "request clean ending")
	context.equal(demo.tick(0), Types.Code.OK, "complete empty host")
	context.equal(demo.viewer_code, Types.Code.TERMINATED, "control completes cleanly")
	context.equal(demo.call("lose_host_connection"), Types.Code.TERMINATED, "later disconnect preserves clean first cause")
	context.equal(demo.viewer_code, Types.Code.TERMINATED, "clean completion remains visible")
	context.equal(demo.start(), Types.Code.OK, "external terminal control")
	demo.viewer.terminate(Types.Code.HISTORY_UNAVAILABLE)
	context.equal(demo.call("lose_host_connection"), Types.Code.HISTORY_UNAVAILABLE, "external first cause takes precedence")
	context.equal(demo.viewer_code, Types.Code.HISTORY_UNAVAILABLE, "synchronize displayed external cause")
	context.equal(demo.is_host_connection_lost, false, "later disconnect does not relabel an earlier failure")


# Value: protects=playable host-loss and restart controls; fails_when=L is unbound or held repeats;
# why_new=API tests bypass keyboard dispatch; seam=none
func _host_loss_control(context: RefCounted) -> void:
	var scene: Node2D = Scene.new()
	scene._ready()
	for tick: int in range(40):
		scene.demo.tick(Game.RIGHT)
	var key: InputEventKey = InputEventKey.new()
	key.keycode = KEY_L
	key.pressed = false
	scene._unhandled_key_input(key)
	context.equal(scene.demo.viewer.status().lifecycle, Types.Lifecycle.RUNNING, "release does not disconnect")
	key.pressed = true
	key.echo = true
	scene._unhandled_key_input(key)
	context.equal(scene.demo.viewer.status().lifecycle, Types.Lifecycle.RUNNING, "held key does not disconnect")
	key.echo = false
	scene._unhandled_key_input(key)
	context.equal(scene.demo.viewer.status().reason, Types.Code.PROTOCOL_FAILED, "L reports host connection loss")
	context.equal(scene._label.text.contains("HOST CONNECTION LOST"), true, "loss has a readable explanation")
	context.equal(scene._label.text.contains("L: lose host link"), true, "help exposes loss control")
	key.keycode = KEY_R
	scene._unhandled_key_input(key)
	context.equal(scene.demo.viewer.status().lifecycle, Types.Lifecycle.RUNNING, "R starts a fresh viewer")
	context.equal(scene.demo.viewer_code, Types.Code.OK, "restart clears displayed failure")
	scene.free()


# Value: protects=restart retires retained match handles; fails_when=old drivers consume buffered rows;
# why_new=keyboard restart checks only the replacement viewer; seam=none
func _restart_lifetimes(context: RefCounted) -> void:
	for scenario: String in ["control", "restart", "failed"]:
		var demo: Demo = Demo.new()
		context.equal(demo.start(), Types.Code.OK, "start retained-handle scenario")
		demo.is_paused = true
		for tick: int in range(35):
			context.equal(demo.tick(Game.RIGHT), Types.Code.OK, "buffer old confirmed rows")
		context.equal(demo.host.start_replay(), Types.Code.OK, "retain host's public replay capability")
		var old_replay: RefCounted = demo.host.replay_player
		var old_host: RefCounted = demo.host
		var old_viewer: RefCounted = demo.viewer
		var old_driver: RefCounted = demo.driver
		var old_stream: RefCounted = demo.stream
		var old_game: Game = demo.game
		context.equal(old_viewer.recommended_steps() > 0, true, "retained old viewer can consume history")
		if scenario == "failed":
			old_viewer.terminate(Types.Code.PROTOCOL_FAILED)
		if scenario != "control":
			context.equal(demo.start(), Types.Code.OK, "replace match after buffering")
			context.equal(old_host.loop.session.status().reason, Types.Code.TERMINATED, "old player match is retired")
			context.equal(old_viewer.status().reason, Types.Code.PROTOCOL_FAILED if scenario == "failed" else Types.Code.TERMINATED, "viewer retirement preserves first cause")
		var frame: int = old_game.frame
		var bytes: PackedByteArray = old_game.canonical_bytes()
		var samples: Array[Demo.Driver.LocalInput] = []
		context.equal(
			old_driver.step(35 * Demo.Host.TICK_US, samples).code,
			Types.Code.OK if scenario == "control" else Types.Code.TERMINATED,
			"old driver cannot consume history after replacement"
		)
		context.equal(old_replay.step(), Types.Code.OK if scenario == "control" else Types.Code.TERMINATED, "host replay retires with its match")
		context.equal(old_stream.poll(35 * Demo.Host.TICK_US), Types.Code.OK if scenario == "control" else Types.Code.TERMINATED, "old stream cannot service retired playback")
		if scenario != "control":
			context.bytes_equal(old_game.canonical_bytes(), bytes, frame, "retained retired game stays frozen")
			context.equal(demo.tick(Game.LEFT), Types.Code.OK, "new host remains playable")
			context.equal(demo.viewer.status().reason, Types.Code.OK, "new viewer remains live")


# Value: protects=restart preserves active callback ownership; fails_when=old completion replaces the match;
# why_new=restart controls run between completed steps; seam=none
func _restart_busy(context: RefCounted) -> void:
	for actor: String in ["host", "viewer", "batch", "game_callback", "host_replay_batch", "stopped_host_replay_callback"]:
		var demo: Demo = Demo.new()
		context.equal(demo.start(), Types.Code.OK, "start guarded restart scenario")
		demo.is_paused = true
		for tick: int in range(35):
			demo.tick(Game.RIGHT)
		var host: RefCounted = demo.host
		var viewer: RefCounted = demo.viewer
		var attempts: PackedInt32Array = PackedInt32Array()
		var restart: Callable = func(_code: int, _before: int, _after: int) -> void:
			attempts.append(demo.start())
			context.equal(demo.host == host and demo.viewer == viewer, true, "busy restart preserves match identity")
		if actor == "stopped_host_replay_callback":
			context.equal(host.start_replay(), Types.Code.OK, "start cancellable host replay")
			var player: RefCounted = host.replay_player
			var game: RestartGame = RestartGame.new()
			var owner: WeakRef = weakref(demo)
			game.on_advance = func() -> void:
				var target: RefCounted = owner.get_ref()
				target.host.stop_replay()
				target.host.stop_replay()
				context.equal(target.host.replay_player, null, "callback cancellation exits host replay mode")
				attempts.append(target.start())
				context.equal(target.host == host and target.viewer == viewer, true, "stopped replay callback preserves spectator match identity")
			context.equal(player.configure(host.loop.session.replay(), game, Game.SNAPSHOT_BYTES), Types.Code.OK, "configure callback host replay")
			context.equal(player.step(), Types.Code.TERMINATED, "host replay cancellation preserves first cause")
			game.on_advance = Callable()
			context.equal(attempts, PackedInt32Array([Types.Code.BUSY]), "stopped host replay callback blocks spectator replacement")
		elif actor == "host_replay_batch":
			context.equal(host.start_replay(), Types.Code.OK, "start public host replay")
			context.equal(host.replay_player.begin_advance().code, Types.Code.READY, "open host replay expert batch")
			context.equal(demo.start(), Types.Code.BUSY, "host replay batch blocks spectator match replacement")
			context.equal(demo.host == host and demo.viewer == viewer, true, "host replay batch preserves match identity")
			host.stop_replay()
		elif actor == "game_callback":
			var owner: WeakRef = weakref(demo)
			var game: RestartGame = RestartGame.new()
			game.on_advance = func() -> void:
				var target: RefCounted = owner.get_ref()
				context.equal(target.start(), Types.Code.BUSY, "active game callback blocks replacement")
				context.equal(target.host == host and target.viewer == viewer, true, "game callback preserves match identity")
			demo.game = game
			demo.driver = Demo.Driver.new(viewer, game)
			context.equal(demo.step_viewer(), Types.Code.OK, "original game callback completes")
			game.on_advance = Callable()
		elif actor == "batch":
			var advance: Types.Result = viewer.begin_advance()
			context.equal(advance.code, Types.Code.READY, "open real expert batch")
			context.equal(demo.start(), Types.Code.BUSY, "active batch blocks match replacement")
			context.equal(demo.host == host and demo.viewer == viewer, true, "active batch preserves match identity")
			viewer.terminate()
		else:
			var driver: RefCounted = host.loop.driver if actor == "host" else demo.driver
			driver.step_completed.connect(restart)
			if actor == "host":
				context.equal(demo.tick(Game.LEFT), Types.Code.OK, "host completes guarded step")
			else:
				context.equal(demo.step_viewer(), Types.Code.OK, "viewer completes guarded step")
			driver.step_completed.disconnect(restart)
			context.equal(attempts, PackedInt32Array([Types.Code.BUSY]), "completion callback cannot replace its match")
		context.equal(demo.start(), Types.Code.OK, "replacement works after ownership releases")


# Value: protects=active callbacks and expert batches own spectator service; fails_when=recursive controls consume time or stop viewing;
# why_new=restart guards do not cover playback and service actions; seam=none
func _service_busy(context: RefCounted) -> void:
	for actor: String in ["host", "viewer", "batch", "game_callback"]:
		for action: String in ["tick", "step_viewer", "finish_host", "set_viewing_delay", "set_catchup_speed"]:
			var demo: Demo = Demo.new()
			context.equal(demo.start(), Types.Code.OK, "start guarded service")
			demo.is_paused = true
			for tick: int in range(35):
				demo.tick(Game.RIGHT)
			var owner: WeakRef = weakref(demo)
			var attempts: PackedInt32Array = PackedInt32Array()
			var attempt: Callable = func(_code: int = 0, _before: int = 0, _after: int = 0) -> void:
				var target: RefCounted = owner.get_ref()
				var before: Array = _service_observation(target)
				var code: int
				if action in ["set_viewing_delay", "set_catchup_speed"]:
					if not target.has_method(action):
						context.equal(false, true, "viewing delay exposes guarded adjustment")
						return
					code = target.call(action, 1)
				else:
					code = target.tick(Game.LEFT) if action == "tick" else target.call(action)
				attempts.append(code)
				context.equal(code, Types.Code.BUSY, "active " + actor + " refuses " + action)
				context.equal(_service_observation(target), before, "refused service preserves clocks, playback and host state")
			if actor == "batch":
				context.equal(demo.viewer.begin_advance().code, Types.Code.READY, "retain ordinary viewer expert batch")
				attempt.call()
				demo.viewer.terminate()
			elif actor == "game_callback":
				var callback_game: RestartGame = RestartGame.new()
				callback_game.on_advance = attempt
				demo.game = callback_game
				demo.driver = Demo.Driver.new(demo.viewer, callback_game)
				context.equal(demo.step_viewer(), Types.Code.OK, "viewer callback completes after guarded adjustment")
				callback_game.on_advance = Callable()
			else:
				var driver: RefCounted = demo.host.loop.driver if actor == "host" else demo.driver
				driver.step_completed.connect(attempt)
				context.equal(demo.tick(Game.RIGHT) if actor == "host" else demo.step_viewer(), Types.Code.OK, "outer service completes")
				driver.step_completed.disconnect(attempt)
				context.equal(demo.viewer.status().reason, Types.Code.OK, "refusal does not terminate viewing")
				context.equal(demo.tick(Game.RIGHT), Types.Code.OK, "service resumes after completion handler")
			context.equal(attempts.size(), 1, "one guarded service attempt")


func _service_observation(demo: RefCounted) -> Array:
	return [
		demo._tick_count,
		demo.host.tick_count,
		demo.host.pending_input_count(),
		demo.host.loop.game.frame,
		demo.game.frame,
		demo.next_host_frame,
		demo.viewer_code,
		demo.is_paused,
		demo.is_finishing,
		demo.viewer.status().reason,
		demo.viewer.playback_policy()
	]


# Value: protects=viewer explains buffering, paused final tail and lost history; fails_when=idle viewing claims active playback;
# why_new=demo lifecycle tests inspect codes without user guidance; seam=scene labels
func _playback_feedback(context: RefCounted) -> void:
	_gap_feedback(context)
	var scene: Node2D = Scene.new()
	scene._ready()
	context.equal(scene._label.text.contains("BUFFERING"), true, "startup explains why viewer has not advanced")
	context.equal(scene._label.text.contains("confirmed input"), true, "startup identifies the input wait")
	for tick: int in range(60):
		scene.demo.tick(Game.RIGHT)
	scene._update_label()
	context.equal(scene.demo.game.frame > 0, true, "control reaches actual viewing")
	context.equal(scene._label.text.contains("WATCHING"), true, "eligible live input shows normal watching")
	context.equal(scene.demo.viewer.playback_status().state, Spectator.PlaybackState.DELAYED, "unpaused viewer retains deliberate delay")
	context.equal(scene.demo.viewer.playback_status().buffered_frames, 12, "the ordinary viewing policy holds twelve confirmed rows")
	context.equal(
		scene._label.text.get_slice("\n", 0),
		"Delayed spectator | WATCHING | viewing delay (12 confirmed frames buffered)",
		"delayed feedback names its reason and exact buffered count"
	)
	context.equal(scene.demo.viewer.set_playback(0, 4, 4), Types.Code.OK, "release viewing delay for input-gap observation")
	while scene.demo.viewer.recommended_steps() > 0:
		context.equal(scene.demo.step_viewer(), Types.Code.OK, "consume existing contiguous host prefix")
	scene.demo.is_paused = false
	scene._update_label()
	context.equal(scene._label.text.contains("BUFFERING"), true, "mid-match host gap must not claim active watching")
	context.equal(scene._label.text.contains("confirmed input"), true, "mid-match wait identifies missing host input")
	context.equal(scene.demo.viewer.set_playback(12, 4, 4), Types.Code.OK, "restore ordinary viewing policy")
	scene.demo.is_paused = true
	for tick: int in range(20):
		scene.demo.tick(Game.LEFT)
	scene._update_label()
	context.equal(scene._label.text.contains("PAUSED"), true, "ordinary pause stays visible")
	context.equal(scene.demo.finish_host(), Types.Code.OK, "stop host while viewer is paused")
	for tick: int in range(20):
		scene.demo.tick(0)
	scene._update_label()
	context.equal(scene.demo.is_host_finished, true, "host has published clean ending")
	context.equal(scene._label.text.contains("FINAL TAIL PAUSED"), true, "paused tail does not claim to drain")
	context.equal(scene._label.text.contains("P: resume or N: step"), true, "paused final tail gives recovery controls")
	scene.demo.is_paused = false
	scene.demo.tick(0)
	scene._update_label()
	context.equal(scene._label.text.contains("DRAINING FINAL TAIL"), true, "resumed tail shows actual draining")
	for tick: int in range(40):
		scene.demo.tick(0)
	scene._update_label()
	context.equal(scene._label.text.contains("COMPLETE"), true, "clean ending takes precedence over draining")
	context.equal(scene.demo.start(), Types.Code.OK, "fresh lost-history scenario")
	scene.demo.is_paused = true
	for tick: int in range(300):
		scene.demo.tick(0)
	scene._update_label()
	context.equal(scene.demo.viewer_code, Types.Code.HISTORY_UNAVAILABLE, "long pause actually loses bounded host history")
	context.equal(scene._label.text.contains("HISTORY UNAVAILABLE"), true, "lost history has a readable reason")
	context.equal(scene._label.text.contains("R: start again"), true, "lost history explains how to recover")
	scene.free()


# Value: protects=failed viewers retain their first cause in controls and labels; fails_when=generic stop reports COMPLETE;
# why_new=existing loss cases terminate through the demo itself; seam=none
func _terminal_feedback(context: RefCounted) -> void:
	for actor: String in ["external", "completion", "host", "clean", "cancel", "cancel_tail", "cancel_boundary"]:
		for service: String in ["tick", "step"]:
			var scene: Node2D = Scene.new()
			scene._ready()
			for tick: int in range(40):
				scene.demo.tick(Game.RIGHT)
			scene.demo.is_paused = true
			context.equal(scene.demo.viewer.is_complete(), false, "buffered viewer has not completed")
			var expected: int = Types.Code.TERMINATED if actor in ["clean", "cancel", "cancel_tail", "cancel_boundary"] else Types.Code.HISTORY_UNAVAILABLE
			if actor in ["clean", "cancel_tail", "cancel_boundary"]:
				context.equal(scene.demo.finish_host(), Types.Code.OK, "clean input ending")
				for tick: int in 30:
					scene.demo.tick(0)
				if actor == "cancel_boundary":
					for tick: int in 40:
						if scene.demo.game.frame == scene.demo.next_host_frame:
							break
						scene.demo.step_viewer()
					context.equal(scene.demo.game.frame, scene.demo.next_host_frame, "cancellation at exact clean final input boundary")
					context.equal(scene.demo.viewer.status().reason, Types.Code.OK, "ordinary terminal notification remains unserviced")
				if actor == "clean":
					scene.demo.is_paused = false
					for tick: int in 30:
						scene.demo.tick(0)
					scene.demo.is_paused = true
			if actor == "completion":
				var viewer: WeakRef = weakref(scene.demo.viewer)
				scene.demo.driver.step_completed.connect(func(_code: int, _before: int, _after: int) -> void: viewer.get_ref().terminate(expected), CONNECT_ONE_SHOT)
			else:
				scene.demo.viewer.terminate(expected)
				scene._update_label()
				context.equal(scene._label.text.contains("COMPLETE"), actor == "clean", "label reads committed cause before another service")
			if actor == "host":
				scene.demo.host.loop.session.terminate(Types.Code.CALLBACK_FAILED)
			if service == "tick":
				scene.demo.is_paused = false
				scene.demo.tick(Game.LEFT)
			else:
				scene.demo.step_viewer()
			var frame: int = scene.demo.game.frame
			var canonical: PackedByteArray = scene.demo.game.canonical_bytes()
			context.equal(scene.demo.viewer_code, expected, "service reports committed first cause")
			context.equal(scene.demo.viewer.status().reason, expected, "service cannot replace first cause")
			context.equal(scene.demo.viewer.is_complete(), actor == "clean", "ordinary clean end alone completes playback")
			context.equal(scene.demo.step_viewer(), expected, "inspection preserves committed cause")
			scene.demo.tick(Game.LEFT)
			scene._update_label()
			context.equal(scene.demo.viewer_code, expected, "later host service cannot overwrite viewer cause")
			context.equal(scene._label.text.contains("COMPLETE"), actor == "clean", "only clean termination displays completion")
			context.equal(scene._label.text.contains("HISTORY UNAVAILABLE"), expected == Types.Code.HISTORY_UNAVAILABLE, "failure displays its specific cause")
			context.equal(scene.demo.game.frame, frame, "later service consumes no buffered frame")
			context.bytes_equal(scene.demo.game.canonical_bytes(), canonical, frame, "stopped viewer preserves displayed state")
			context.equal(scene.demo.start(), Types.Code.OK, "restart clears failed lifetime")
			context.equal(scene.demo.viewer_code, Types.Code.OK, "new viewer reports a fresh lifetime")
			scene.free()


# Value: protects=visible input-gap recovery guidance; fails_when=later received rows look like an idle host;
# why_new=ordinary demo publisher delivers rows in order; seam=public authenticated stream and scene label
func _gap_feedback(context: RefCounted) -> void:
	var scene: Node2D = Scene.new()
	scene._ready()
	context.equal(scene.demo.viewer.set_playback(0, 4, 4), Types.Code.OK, "release intentional delay for gap feedback")
	var row: Array[PackedByteArray] = [PackedByteArray([0]), PackedByteArray([0])]
	for frame: int in [1, 3]:
		context.equal(scene.demo.stream.receive_packet(scene.demo.stream.encode_row(frame, row), 0), Types.Code.OK, "accept authenticated reordered input")
	scene.demo.is_paused = false
	scene._update_label()
	context.equal(
		scene._label.text.get_slice("\n", 0),
		"Delayed spectator | BUFFERING | waiting for confirmed frame 0 (2 later frames received)",
		"gap feedback names the exact missing frame and retained later rows"
	)
	context.equal(scene.demo.stream.receive_packet(scene.demo.stream.encode_row(0, row), 0), Types.Code.OK, "first gap receives its original input")
	context.equal(scene.demo.viewer.set_playback(2, 4, 4), Types.Code.OK, "delay needs contiguous input beyond the next gap")
	scene._update_label()
	context.equal(
		scene._label.text.get_slice("\n", 0),
		"Delayed spectator | BUFFERING | waiting for confirmed frame 2 (1 later frame received)",
		"known missing input explains why viewing delay cannot release buffered rows"
	)
	scene.demo.is_paused = true
	scene._update_label()
	context.equal(scene._label.text.get_slice("\n", 0), "Delayed spectator | PAUSED", "caller pause remains distinct from a network input gap")
	scene.demo.is_paused = false
	context.equal(scene.demo.viewer.set_playback(0, 4, 4), Types.Code.OK, "release delay to consume recovered prefix")
	for frame: int in 2:
		context.equal(scene.demo.step_viewer(), Types.Code.OK, "play newly contiguous original prefix")
	scene.demo.is_paused = false
	scene._update_label()
	context.equal(
		scene._label.text.get_slice("\n", 0),
		"Delayed spectator | BUFFERING | waiting for confirmed frame 2 (1 later frame received)",
		"feedback follows the remaining gap after playback"
	)
	context.equal(scene.demo.stream.receive_packet(scene.demo.stream.encode_row(2, row), 0), Types.Code.OK, "last missing original row recovers viewing")
	scene.demo.is_paused = false
	scene._update_label()
	context.equal(scene._label.text.get_slice("\n", 0), "Delayed spectator | WATCHING", "contiguous recovery restores normal watching")
	for frame: int in 2:
		context.equal(scene.demo.step_viewer(), Types.Code.OK, "recovered rows remain playable")
	context.equal(scene.demo.game.frame, 4, "healthy continuation consumes every original row once")
	scene.demo.is_paused = false
	scene._update_label()
	context.equal(scene._label.text.get_slice("\n", 0), "Delayed spectator | BUFFERING | waiting for confirmed input", "drained healthy stream waits for host progress")
	scene.free()


# Value: protects=live viewing delay changes preserve canonical progress; fails_when=adjustment rewinds or resamples;
# why_new=policy API had no playable control; seam=none
func _viewing_delay(context: RefCounted) -> void:
	var demo: Demo = Demo.new()
	context.equal(demo.has_method("set_viewing_delay"), true, "demo exposes viewing delay adjustment")
	if not demo.has_method("set_viewing_delay"):
		return
	context.equal(demo.call("set_viewing_delay", 0), Types.Code.NOT_CONFIGURED, "delay needs a configured viewer")
	context.equal(demo.start(), Types.Code.OK, "start delay adjustment")
	for tick: int in range(60):
		context.equal(demo.tick(Game.RIGHT | Game.FIRE), Types.Code.OK, "original changing host history")
	var frame: int = demo.game.frame
	var host_frame: int = demo.host.loop.game.frame
	var canonical: PackedByteArray = demo.game.canonical_bytes()
	context.equal(demo.call("set_viewing_delay", 0), Types.Code.OK, "remove viewing delay")
	context.equal(demo.viewer.playback_policy(), PackedInt64Array([0, 4, 4]), "adjustment preserves catchup policy")
	context.equal(demo.game.frame, frame, "adjustment does not advance viewer immediately")
	context.equal(demo.host.loop.game.frame, host_frame, "adjustment never advances host")
	context.bytes_equal(demo.game.canonical_bytes(), canonical, frame, "adjustment preserves displayed state")
	context.equal(demo.tick(Game.LEFT), Types.Code.OK, "service reduced delay")
	context.equal(demo.game.frame - frame, 4, "reduced delay catches up within ordinary work budget")
	frame = demo.game.frame
	context.equal(demo.call("set_viewing_delay", 30), Types.Code.OK, "increase viewing delay")
	for tick: int in range(8):
		context.equal(demo.tick(Game.RIGHT), Types.Code.OK, "host keeps playing while new cushion fills")
	context.equal(demo.game.frame, frame, "larger delay waits without rewinding")
	demo.is_paused = true
	context.equal(demo.call("set_viewing_delay", 1), Types.Code.OK, "delay changes while paused")
	context.equal(demo.is_paused, true, "delay adjustment does not resume viewer")
	for invalid: int in [-1, Demo.Config.new().queue_capacity]:
		context.equal(demo.call("set_viewing_delay", invalid), Types.Code.INVALID_CONFIGURATION, "invalid viewing delay refused")
		context.equal(demo.viewer.playback_policy(), PackedInt64Array([1, 4, 4]), "invalid adjustment preserves policy")
	context.equal(demo.finish_host(), Types.Code.OK, "stop at original host boundary")
	for tick: int in range(20):
		demo.tick(0)
	context.equal(demo.call("set_viewing_delay", 30), Types.Code.OK, "closed tail accepts policy without reholding rows")
	demo.is_paused = false
	for tick: int in range(80):
		demo.tick(0)
	context.equal(demo.viewer.is_complete(), true, "clean ending releases adjusted delay")
	context.bytes_equal(demo.game.canonical_bytes(), demo.host.loop.game.canonical_bytes(), demo.game.frame, "adjusted playback equals original corrected host")
	context.equal(demo.call("set_viewing_delay", 0), Types.Code.TERMINATED, "completed viewing cannot be revived")
	context.equal(demo.start(), Types.Code.OK, "restart fresh viewing")
	context.equal(demo.viewer.playback_policy(), PackedInt64Array([12, 4, 4]), "restart restores default viewing delay")


# Value: protects=caller-selected bounded catch-up preserves canonical playback; fails_when=rate is ignored; why_new=default-rate tests cannot vary service; seam=none
func _catchup_speed(context: RefCounted) -> void:
	var empty: Demo = Demo.new()
	context.equal(empty.has_method("set_catchup_speed"), true, "demo exposes bounded catch-up adjustment")
	if not empty.has_method("set_catchup_speed"):
		return
	context.equal(empty.call("set_catchup_speed", 1), Types.Code.NOT_CONFIGURED, "catch-up adjustment needs a viewer")
	for speed: int in [1, 4]:
		var demo: Demo = Demo.new()
		context.equal(demo.start(), Types.Code.OK, "start catch-up scenario")
		demo.is_paused = true
		for tick: int in range(50):
			context.equal(demo.tick(Game.RIGHT | Game.FIRE), Types.Code.OK, "host builds an original confirmed backlog")
		var before: Array = _service_observation(demo)
		context.equal(demo.call("set_catchup_speed", speed), Types.Code.OK, "select catch-up speed while paused")
		context.equal(demo.viewer.playback_policy(), PackedInt64Array([12, 4, speed]), "catch-up adjustment preserves delay and threshold")
		before[10] = demo.viewer.playback_policy()
		context.equal(_service_observation(demo), before, "rate selection does not service host or viewer or change pause")
		for invalid: int in [-1, 0, Demo.Config.new().queue_capacity + 1]:
			context.equal(demo.call("set_catchup_speed", invalid), Types.Code.INVALID_CONFIGURATION, "invalid catch-up speed refused")
			context.equal(_service_observation(demo), before, "invalid catch-up speed preserves policy and match")
		context.equal(demo.tick(Game.LEFT), Types.Code.OK, "paused host still plays after adjustment")
		context.equal(demo.game.frame, 0, "rate selection keeps viewer paused")
		demo.is_paused = false
		for tick: int in range(3):
			var frame: int = demo.game.frame
			context.equal(demo.tick(Game.RIGHT), Types.Code.OK, "service selected catch-up rate")
			context.equal(demo.game.frame - frame, speed, "each backlog tick obeys selected service bound")
		var expected: Game = Game.new()
		for frame: int in range(demo.game.frame):
			var rows: Array[PackedByteArray] = [PackedByteArray([Game.RIGHT | Game.FIRE]), PackedByteArray([Demo.Host.remote_buttons(frame)])]
			var statuses: PackedInt32Array = PackedInt32Array([Queue.Status.CONFIRMED, Queue.Status.CONFIRMED])
			context.equal(expected.simulate_frame(frame, Types.FrameInputs.new(rows, statuses)), true, "independent original-input prefix")
		context.bytes_equal(demo.game.canonical_bytes(), expected.canonical_bytes(), demo.game.frame, "rate does not change canonical viewed history")
		demo.viewer.terminate(Types.Code.PROTOCOL_FAILED)
		context.equal(demo.call("set_catchup_speed", 2), Types.Code.TERMINATED, "rate selection cannot revive failed viewing")
		context.equal(demo.start(), Types.Code.OK, "fresh restart after custom catch-up")
		context.equal(demo.viewer.playback_policy(), PackedInt64Array([12, 4, 4]), "restart restores default catch-up rate")


# Value: protects=playable catch-up rate keys respect bounds and pause; fails_when=keys are missing or repeat on held input; why_new=API controls bypass keyboard; seam=scene input
func _catchup_control(context: RefCounted) -> void:
	var scene: Node2D = Scene.new()
	scene._ready()
	scene.demo.is_paused = true
	var before: Array = _service_observation(scene.demo)
	var key: InputEventKey = InputEventKey.new()
	key.keycode = KEY_COMMA
	key.pressed = false
	scene._unhandled_key_input(key)
	key.pressed = true
	key.echo = true
	scene._unhandled_key_input(key)
	context.equal(_service_observation(scene.demo), before, "release and repeat do not change catch-up rate")
	key.echo = false
	scene._unhandled_key_input(key)
	context.equal(scene.demo.viewer.playback_policy(), PackedInt64Array([12, 4, 3]), "comma lowers catch-up speed")
	context.equal(scene._label.text.contains("at most 3 per tick"), true, "feedback shows selected rate")
	for press: int in range(5):
		scene._unhandled_key_input(key)
	context.equal(scene.demo.viewer.playback_policy()[2], 1, "slower key stops at one frame per tick")
	key.keycode = KEY_PERIOD
	for press: int in range(140):
		scene._unhandled_key_input(key)
	context.equal(scene.demo.viewer.playback_policy()[2], Demo.Config.new().queue_capacity, "faster key stops at bounded ring capacity")
	context.equal(scene._label.text.contains(",: slower catch-up | .: faster catch-up"), true, "help exposes catch-up controls")
	before[10] = scene.demo.viewer.playback_policy()
	context.equal(_service_observation(scene.demo), before, "catch-up keys do not service or resume viewing")
	scene.free()
