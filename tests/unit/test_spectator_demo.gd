extends RefCounted

# Value: protects=delayed viewer follows corrected original game; fails_when=predictions stream or spectator stalls host; why_new=playable host/export composition; seam=none
const Scene = preload("res://examples/spectator/spectator.gd")
const Demo = preload("res://examples/spectator/demo.gd")
const Game = preload("res://examples/integration/game.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(
		[
			"corrected_viewing",
			"pause_and_catchup",
			"lost_history",
			"idle_host_liveness",
			"clean_host_end",
			"paused_final_tail",
			"single_frame",
			"single_frame_end",
			"single_frame_control",
			"host_loss",
			"host_loss_control"
		]
	)


func run_case(name: String, context: RefCounted) -> void:
	if name == "corrected_viewing":
		_corrected_viewing(context)
	elif name == "pause_and_catchup":
		_pause_and_catchup(context)
	elif name == "lost_history":
		_lost_history(context)
	elif name == "paused_final_tail":
		_paused_final_tail(context)
	elif name in ["single_frame", "single_frame_end", "single_frame_control", "host_loss", "host_loss_control"]:
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
