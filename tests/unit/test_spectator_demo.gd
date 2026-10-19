extends RefCounted

# Value: protects=delayed viewer follows corrected original game; fails_when=predictions stream or spectator stalls host; why_new=playable host/export composition; seam=none
const Demo = preload("res://examples/spectator/demo.gd")
const Game = preload("res://examples/integration/game.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["corrected_viewing", "pause_and_catchup", "lost_history", "idle_host_liveness", "clean_host_end", "paused_final_tail"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "corrected_viewing":
		_corrected_viewing(context)
	elif name == "pause_and_catchup":
		_pause_and_catchup(context)
	elif name == "lost_history":
		_lost_history(context)
	elif name == "paused_final_tail":
		_paused_final_tail(context)
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
