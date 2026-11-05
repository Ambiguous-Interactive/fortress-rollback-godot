extends RefCounted

const Scene = preload("res://examples/spectator/spectator.gd")
const Demo = preload("res://examples/spectator/demo.gd")
const Game = preload("res://examples/integration/game.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Writer = preload("res://addons/fortress_rollback/core/snapshot_writer.gd")
const Reader = preload("res://addons/fortress_rollback/core/snapshot_reader.gd")


class FailedAdvance:
	extends Game

	func simulate_frame(_frame: int, _inputs: Types.FrameInputs) -> bool:
		return false


class StoppingGame:
	extends Game
	var owner: WeakRef
	var failure_kind: int
	var stopped: bool = false

	func _stop(kind: int) -> bool:
		if kind != failure_kind:
			return false
		stopped = true
		owner.get_ref().terminate(Types.Code.PROTOCOL_FAILED)
		return true

	func save_state(frame: int, writer: Writer) -> Driver.SaveResult:
		return Driver.SaveResult.new(false) if _stop(Types.Kind.SAVE) else super.save_state(frame, writer)

	func load_state(frame: int, reader: Reader) -> bool:
		return false if _stop(Types.Kind.LOAD) else super.load_state(frame, reader)

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		return false if _stop(Types.Kind.ADVANCE) else super.simulate_frame(frame, inputs)


const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["host_step", "host_step_ownership", "host_failure_feedback", "focus_pause"])


func run_case(name: String, context: RefCounted) -> void:
	var demo: Demo = Demo.new()
	context.equal(demo.has_method("step_host"), true, "spectator supports one host tick while paused")
	if demo.has_method("step_host"):
		call("_" + name, context)
	context.finish()


# Value: protects=host single-step preserves canonical delayed history and independent viewer policy;
# fails_when=step runs continuously or skips retained stalled input; why_new=host pause cannot sample one frame; seam=none
func _host_step(context: RefCounted) -> void:
	var scene: Node2D = Scene.new()
	scene._ready()
	var button: Button = scene.get_node_or_null("SpectatorControls/Content/HostDelay/StepHost")
	context.equal(button != null, true, "pointer can step host")
	if button == null:
		scene._exit_tree()
		scene.free()
		return
	context.equal(scene.demo.host.set_lag(12), Types.Code.OK, "long delivery exposes real stalls")
	context.equal(scene.demo.set_viewing_delay(0), Types.Code.OK, "viewer follows confirmed input")
	var policy: PackedInt64Array = scene.demo.viewer.playback_policy()
	var reference: Game = Game.new()
	var key: InputEventKey = InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_T
	button.pressed.emit()
	context.equal(scene.demo.is_host_paused, true, "pointer step pauses continuous host sampling")
	context.equal(scene.demo.host.loop.game.frame, 1, "pointer advances at most one host frame")
	var first: Array[PackedByteArray] = [PackedByteArray([0]), PackedByteArray([Demo.Host.remote_buttons(0)])]
	var statuses: PackedInt32Array = PackedInt32Array([Queue.Status.CONFIRMED, Queue.Status.CONFIRMED])
	reference.simulate_frame(0, Types.FrameInputs.new(first, statuses))
	var original_samples: Dictionary = {}
	for tick: int in range(35):
		var before: int = scene.demo.host.loop.game.frame
		var buttons: int = Game.RIGHT | Game.FIRE if tick % 2 == 0 else Game.LEFT
		if not original_samples.has(before):
			original_samples[before] = buttons
		context.equal(scene.demo.step_host(buttons) in [Types.Code.OK, Types.Code.PREDICTION_STALL], true, "single-step retains ordinary prediction behavior")
		context.equal(scene.demo.host.loop.game.frame <= before + 1, true, "step never skips a forward frame")
		if scene.demo.host.loop.game.frame > before:
			var row: Array[PackedByteArray] = [PackedByteArray([original_samples[before]]), PackedByteArray([Demo.Host.remote_buttons(before)])]
			reference.simulate_frame(before, Types.FrameInputs.new(row, statuses))
		context.equal(scene.demo.is_host_paused, true, "step preserves host pause")
		context.equal(scene.demo.is_paused, false, "step preserves independent viewer pause")
		context.equal(scene.demo.viewer.playback_policy(), policy, "step preserves viewer delay and catch-up policy")
	context.equal(scene.demo.host.stall_count > 0, true, "ordinary host prediction stall was exercised")
	var frame: int = scene.demo.host.loop.game.frame
	for tick: int in range(20):
		context.equal(scene.demo.tick(Game.LEFT) in [Types.Code.OK, Types.Code.PREDICTION_STALL], true, "paused service drains outstanding input")
	context.equal(scene.demo.host.loop.game.frame, frame, "later physics ticks cannot continue host sampling")
	context.equal(scene.demo.host.pending_input_count(), 0, "paused service delivers pending original inputs")
	context.equal(scene.demo.host.load_count() > 0, true, "delayed original inputs caused actual rollback")
	context.bytes_equal(scene.demo.host.loop.game.canonical_bytes(), reference.canonical_bytes(), frame, "single-stepped host repairs to original canonical history")
	context.equal(scene.demo.game.frame, frame, "independent viewer catches up to paused host")
	context.bytes_equal(scene.demo.game.canonical_bytes(), reference.canonical_bytes(), frame, "viewer consumes the same corrected history")
	for modifier: String in ["ctrl_pressed", "alt_pressed", "meta_pressed", "shift_pressed", "echo"]:
		key.set(modifier, true)
		scene._unhandled_key_input(key)
		context.equal(scene.demo.host.loop.game.frame, frame, "modified/repeated T cannot sample")
		key.set(modifier, false)
	scene._unhandled_key_input(key)
	context.equal(scene.demo.host.loop.game.frame, frame + 1, "ordinary T steps exactly one host frame")
	context.equal(scene.demo.finish_host(), Types.Code.OK, "clean ending can follow host inspection")
	context.equal(scene.demo.step_host(Game.RIGHT), Types.Code.TERMINATED, "single-step cannot extend declared final boundary")
	scene._unhandled_key_input(key)
	context.equal(scene._code, Types.Code.OK, "refused T cannot stop clean tail service")
	for tick: int in range(20):
		scene._physics_process(0.0)
	context.equal(scene.demo.viewer.is_complete(), true, "single-stepped match drains a complete clean tail")
	scene._update_label()
	context.equal(button.disabled, true, "finished host disables step control")
	context.state(frame, reference.canonical_bytes())
	scene._exit_tree()
	scene.free()


# Value: protects=host single-step honors callback/expert/replay ownership and rejects malformed input before pause/time;
# fails_when=controls mutate a held match or rejected sample; why_new=step owns a separate sampling entry point; seam=none
func _host_step_ownership(context: RefCounted) -> void:
	var demo: Demo = Demo.new()
	context.equal(demo.step_host(0), Types.Code.NOT_CONFIGURED, "unconfigured host cannot step")
	context.equal(demo.start(), Types.Code.OK, "fresh spectator match")
	for buttons: int in [-1, 8, 256]:
		context.equal(demo.step_host(buttons), Types.Code.INVALID_CONFIGURATION, "malformed buttons cannot narrow into input")
		context.equal(demo.is_host_paused, false, "rejected input cannot pause host")
		context.equal(demo.host.tick_count, 0, "rejected input cannot consume delivery clock")
		context.equal(demo._tick_count, 0, "rejected input cannot consume stream clock")
	for owner: String in ["host", "viewer", "replay"]:
		context.equal(demo.start(), Types.Code.OK, "fresh ownership fixture")
		if owner == "host":
			demo.host.loop.session.submit_local_input(0, 0, PackedByteArray([Game.RIGHT]))
			context.equal(demo.host.loop.session.begin_advance().code, Types.Code.READY, "expert host owns batch")
		elif owner == "viewer":
			demo.viewer.set_playback(0, 0, 1)
			var rows: Array[PackedByteArray] = [PackedByteArray([0]), PackedByteArray([0])]
			demo.viewer.receive_host_frame(0, rows)
			context.equal(demo.viewer.begin_advance().code, Types.Code.READY, "expert viewer owns batch")
		else:
			context.equal(demo.host.start_replay(), Types.Code.OK, "embedded replay holds live host")
		context.equal(demo.step_host(Game.RIGHT), Types.Code.BUSY, "held composition refuses host step")
		context.equal(demo.is_host_paused, false, "BUSY preserves host pause")
		context.equal(demo._tick_count, 0, "BUSY preserves stream delivery clock")
		context.equal(demo.host.tick_count, 0, "BUSY preserves host delivery clock")
		demo.viewer.terminate()
		demo.host.loop.session.terminate()
		demo.host.stop_replay()
	context.equal(demo.start(), Types.Code.OK, "fresh idle staged-input fixture")
	context.equal(demo.host.loop.session.submit_local_input(0, 0, PackedByteArray([Game.RIGHT])).code, Types.Code.OK, "expert owns idle sample")
	context.equal(demo.step_host(Game.LEFT), Types.Code.INPUT_ALREADY_SUBMITTED, "conflicting staged sample refuses before pause")
	context.equal(demo.is_host_paused, false, "conflicting staged sample cannot pause host")
	context.equal(demo._tick_count, 0, "conflicting staged sample preserves stream time")
	context.equal(demo.host.tick_count, 0, "conflicting staged sample preserves host time")
	context.equal(demo.step_host(Game.RIGHT), Types.Code.OK, "corrected sample retries at original clock")
	context.equal(demo.host.loop.game.frame, 1, "corrected retry consumes one original frame")
	for owner: String in ["host", "viewer"]:
		context.equal(demo.start(), Types.Code.OK, "fresh completion-handler fixture")
		var observations: Array[int] = []
		var demo_ref: WeakRef = weakref(demo)
		var controlled_driver: RefCounted = demo.host.loop.driver if owner == "host" else demo.driver
		controlled_driver.step_completed.connect(
			func(_code: int, _before: int, _after: int) -> void:
				var active: Demo = demo_ref.get_ref()
				observations.append(active.step_host(Game.LEFT))
				observations.append(1 if active.is_host_paused else 0)
		)
		for tick: int in range(20):
			demo.tick(Game.RIGHT)
		context.equal(observations.is_empty(), false, "completion callback actually ran")
		for index: int in range(0, observations.size(), 2):
			context.equal(observations[index], Types.Code.BUSY, "nested host step refuses completion handler")
			context.equal(observations[index + 1], 0, "nested host step preserves running host through callback")
	demo.viewer.terminate()
	demo.host.loop.session.terminate()


# Value: protects=spectator reports the originating host callback and frame; fails_when=forwarded viewer failure loses host evidence;
# why_new=viewer callback reports do not cover host failure forwarding; seam=real driver callback
func _host_failure_feedback(context: RefCounted) -> void:
	for failed: bool in [false, true]:
		var scene: Node = Scene.new()
		scene._ready()
		if failed:
			context.equal(scene.demo.host.loop.driver.configure(scene.demo.host.loop.session, FailedAdvance.new()), Types.Code.OK, "install failing host game")
		scene._step_host_button.pressed.emit()
		if failed:
			context.equal(scene._code, Types.Code.CALLBACK_FAILED, "single host step retains its actual failure code")
			context.equal(scene.demo.host.loop.session.status().failure_kind, Types.Kind.ADVANCE, "real host ADVANCE failed")
			context.equal(scene._label.text.contains("Host stopped: failed while simulating input at frame 0"), true, "host callback evidence remains visible after viewer forwarding")
			context.equal(scene._step_host_button.disabled, true, "failed host cannot step again")
			scene._restart_button.pressed.emit()
			context.equal(scene._code, Types.Code.OK, "restart clears host failure")
			context.equal(scene._label.text.contains("Host stopped:"), false, "fresh match clears failure notice")
		else:
			context.equal(scene._code, Types.Code.OK, "healthy host step remains successful")
			context.equal(scene._label.text.contains("Host stopped:"), false, "healthy host has no failure report")
		scene._exit_tree()
		scene.free()
	for limit: String in ["frame", "batch"]:
		for entry: String in ["pointer", "controller"]:
			var scene: Node = Scene.new()
			scene._ready()
			scene.demo.set_paused(true)
			for tick: int in 20:
				scene.demo.tick(Game.RIGHT)
			context.equal(scene.demo.viewer.playback_status().buffered_frames > 0, true, "preflight fixture retains real confirmed viewer rows")
			var bytes: PackedByteArray = scene.demo.game.canonical_bytes()
			var host: RefCounted = scene.demo.host.loop.session
			if limit == "frame":
				host._current = Queue.FRAME_MAX
			else:
				host._batch_id = 9223372036854775807
			if entry == "pointer":
				scene._step_host_button.pressed.emit()
				context.equal(scene._code, Types.Code.FRAME_EXHAUSTED, "pointer retains preflight exhaustion")
			else:
				context.equal(scene.demo.step_host(Game.RIGHT), Types.Code.FRAME_EXHAUSTED, "controller reports preflight exhaustion")
			context.equal(host.status().reason, Types.Code.FRAME_EXHAUSTED, "host really terminates during preflight")
			context.equal(scene.demo.viewer.status().lifecycle, Types.Lifecycle.TERMINATED, "preflight host termination also retires buffered viewer")
			context.equal(scene.demo.viewer_code, Types.Code.FRAME_EXHAUSTED, "forwarding preserves terminal cause")
			context.equal(scene.demo.step_viewer(), Types.Code.FRAME_EXHAUSTED, "manual viewer cannot consume buffered rows after host exhaustion")
			context.bytes_equal(scene.demo.game.canonical_bytes(), bytes, scene.demo.game.frame, "terminal preflight preserves displayed viewer history")
			scene._exit_tree()
			scene.free()
	for entry: String in ["tick", "step"]:
		var demo: Demo = Demo.new()
		context.equal(demo.start(), Types.Code.OK, "fresh externally stopped host")
		demo.host.loop.session.terminate(Types.Code.FRAME_EXHAUSTED)
		var code: int = demo.tick(0) if entry == "tick" else demo.step_host(0)
		context.equal(code, Types.Code.FRAME_EXHAUSTED, "already stopped host preserves its first cause through " + entry)
		context.equal(demo.viewer.status().reason, Types.Code.FRAME_EXHAUSTED, "already stopped host immediately retires viewer through " + entry)
		context.equal(demo.viewer_code, Types.Code.FRAME_EXHAUSTED, "already stopped host updates viewer result through " + entry)
		demo.viewer.terminate()
		demo.host.loop.session.terminate()

	for entry: String in ["tick", "step"]:
		for kind: int in [Types.Kind.SAVE, Types.Kind.LOAD, Types.Kind.ADVANCE]:
			for prior_viewer_failure: bool in [false, true]:
				var scene: Node = Scene.new()
				scene._ready()
				scene.demo.set_paused(true)
				var game: StoppingGame = StoppingGame.new()
				game.owner = weakref(scene.demo.host.loop.session)
				game.failure_kind = kind
				scene.demo.host.loop.game = game
				context.equal(scene.demo.host.loop.driver.configure(scene.demo.host.loop.session, game), Types.Code.OK, "install callback termination fixture")
				if prior_viewer_failure:
					scene.demo.viewer.terminate(Types.Code.DESYNC)
				for tick: int in 24:
					if entry == "tick":
						scene._physics_process(0.0)
					else:
						scene._step_host_button.pressed.emit()
					if game.stopped:
						break
				context.equal(game.stopped, true, "actual selected host callback terminates its session")
				context.equal(scene.demo.host.loop.session.status().reason, Types.Code.PROTOCOL_FAILED, "host retains callback termination cause")
				context.equal(scene._code, Types.Code.PROTOCOL_FAILED, "scene receives original callback termination cause")
				var viewer_reason: int = Types.Code.DESYNC if prior_viewer_failure else Types.Code.PROTOCOL_FAILED
				context.equal(scene.demo.viewer.status().reason, viewer_reason, "forwarded callback termination preserves viewer's first cause")
				context.equal(scene.demo.viewer_code, viewer_reason, "viewer result preserves its first cause after callback termination")
				scene._exit_tree()
				scene.free()


# Value: protects=focus loss freezes complete local service; fails_when=unattended input delivery or playback advances;
# why_new=independent host/viewer pauses still service transport; seam=none
func _focus_pause(context: RefCounted) -> void:
	var scene: Node2D = Scene.new()
	scene._ready()
	for tick: int in 20:
		scene._physics_process(0.0)
	context.equal(scene.demo.host.pending_input_count() > 0, true, "focus witness retains real delayed input")
	var before: Array = _service_state(scene)
	scene.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	for tick: int in 150:
		scene._physics_process(0.0)
	context.equal(_service_state(scene), before, "focus loss preserves canonical games, delivery clocks and queued inputs")
	context.equal(scene._label.text.contains("DEMO PAUSED"), true, "focus pause names explicit resume action")
	scene.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	scene._physics_process(0.0)
	context.equal(_service_state(scene), before, "focus gain cannot resume local service")
	var button: Button = scene.get_node_or_null("SpectatorControls/Content/PauseDemo")
	context.equal(button != null, true, "demo has explicit pointer resume")
	if button != null:
		context.equal(button.text, "Resume demo (G)", "paused pointer names resume shortcut")
		context.equal(button.focus_mode, Control.FOCUS_NONE, "resume preserves host movement routing")
		button.pressed.emit()
		scene._physics_process(0.0)
		context.equal(scene.demo.host.tick_count, int(before[2]) + 1, "pointer resumes exactly one delivery tick")
		context.equal(scene.demo.is_host_paused, false, "global pause preserves host policy")
		context.equal(scene.demo.is_paused, false, "global pause preserves viewer policy")
		var key: InputEventKey = InputEventKey.new()
		key.pressed = true
		key.keycode = KEY_G
		scene._unhandled_key_input(key)
		before = _service_state(scene)
		for modifier: String in ["ctrl_pressed", "alt_pressed", "meta_pressed", "shift_pressed", "echo"]:
			key.set(modifier, true)
			scene._unhandled_key_input(key)
			scene._physics_process(0.0)
			context.equal(_service_state(scene), before, "modified or repeated G cannot resume service")
			key.set(modifier, false)
		scene.demo.set_host_paused(true)
		scene.demo.set_paused(true)
		scene._unhandled_key_input(key)
		context.equal(scene.demo.is_host_paused, true, "G preserves independent host pause")
		context.equal(scene.demo.is_paused, true, "G preserves independent viewer pause")
		scene.demo.set_viewing_delay(0)
		var batch: Types.Result = scene.demo.viewer.begin_advance()
		context.equal(batch.code, Types.Code.READY, "real expert batch owns service")
		scene.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
		button.pressed.emit()
		scene._unhandled_key_input(key)
		context.equal(button.disabled, true, "resume waits for active ownership")
		before = _service_state(scene)
		scene._physics_process(0.0)
		context.equal(_service_state(scene), before, "ownership cannot bypass global pause")
		scene.demo.viewer.terminate()
		scene._restart()
		context.equal(button.text, "Pause demo (G)", "successful restart clears focus pause")
		context.equal(scene.demo.host.tick_count, 0, "restart creates fresh delivery clock")
	scene._exit_tree()
	scene.free()


func _service_state(scene: Node2D) -> Array:
	return [scene.demo.host.loop.game.canonical_bytes(), scene.demo.game.canonical_bytes(), scene.demo.host.tick_count,
		scene.demo._tick_count, scene.demo.host.pending_input_count(), scene.demo.next_host_frame]
