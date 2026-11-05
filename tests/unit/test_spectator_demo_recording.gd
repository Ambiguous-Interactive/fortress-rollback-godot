extends RefCounted

# Value: protects=exported spectator history reproduces displayed state; fails_when=viewer records receipts or misses final boundary;
# why_new=host recordings do not cover delayed/paused viewer exports; seam=none
const Demo = preload("res://examples/spectator/demo.gd")
const Game = preload("res://examples/integration/game.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Scene = preload("res://examples/spectator/spectator.gd")


class SaveScene:
	extends Scene
	var exported_bytes: PackedByteArray = PackedByteArray()
	var export_calls: int = 0

	func _export_replay() -> void:
		export_calls += 1
		exported_bytes = demo.replay_bytes()
		_replay_notice = "Viewed replay captured."


class FailingSaveGame:
	extends Game
	var overflow: bool = false

	func save_state(frame: int, writer: RefCounted) -> Driver.SaveResult:
		var saved: Driver.SaveResult = super.save_state(frame, writer)
		if overflow:
			writer.write_bytes(PackedByteArray([0]))
		else:
			saved.ok = false
		return saved


func cases() -> PackedStringArray:
	return PackedStringArray(["prefix_capture", "clean_end_capture", "capture_guards", "save_pointer_control"])


func run_case(name: String, context: RefCounted) -> void:
	var demo: Demo = Demo.new()
	context.equal(demo.has_method("replay_bytes"), true, "spectator can export its viewed history")
	if demo.has_method("replay_bytes"):
		call("_" + name, context)
	context.finish()


func _prefix_capture(context: RefCounted) -> void:
	var demo: Demo = Demo.new()
	context.equal(demo.call("replay_bytes").is_empty(), true, "no recording before startup")
	context.equal(demo.start(), Types.Code.OK, "start recorded spectator")
	_check(context, demo.call("replay_bytes"), demo.game.canonical_bytes(), 0)
	for tick: int in 60:
		context.equal(demo.tick(Game.RIGHT | Game.FIRE), Types.Code.OK, "live host")
	demo.is_paused = true
	var frame: int = demo.game.frame
	var canonical: PackedByteArray = demo.game.canonical_bytes()
	var bytes: PackedByteArray = demo.call("replay_bytes")
	_check(context, bytes, canonical, frame)
	for tick: int in 20:
		context.equal(demo.tick(Game.LEFT), Types.Code.OK, "host continues during export")
	_check(context, demo.call("replay_bytes"), canonical, frame)
	context.equal(demo.step_viewer(), Types.Code.OK, "recording resumes after captured prefix")
	_check(context, demo.call("replay_bytes"), demo.game.canonical_bytes(), frame + 1)
	_check(context, bytes, canonical, frame)
	context.equal(demo.start(), Types.Code.OK, "restart resets recording")
	_check(context, demo.call("replay_bytes"), demo.game.canonical_bytes(), 0)


func _clean_end_capture(context: RefCounted) -> void:
	for count: int in [0, 1, 40]:
		for single_step: bool in [false, true]:
			var demo: Demo = Demo.new()
			context.equal(demo.start(), Types.Code.OK, "start ending capture")
			demo.is_paused = single_step
			for tick: int in count:
				context.equal(demo.tick(Game.RIGHT | Game.FIRE), Types.Code.OK, "host original history")
			context.equal(demo.finish_host(), Types.Code.OK, "request host end")
			for tick: int in 80:
				context.equal(demo.tick(0) in [Types.Code.OK, Types.Code.PREDICTION_STALL], true, "settle host and tail")
				if single_step:
					demo.step_viewer()
				if demo.viewer_code == Types.Code.TERMINATED:
					break
			context.equal(demo.viewer_code, Types.Code.TERMINATED, "viewer completes")
			context.bytes_equal(demo.game.canonical_bytes(), demo.host.loop.game.canonical_bytes(), count, "clean tail equals corrected original host")
			_check(context, demo.call("replay_bytes"), demo.host.loop.game.canonical_bytes(), count)


func _capture_guards(context: RefCounted) -> void:
	var demo: Demo = Demo.new()
	context.equal(demo.start(), Types.Code.OK, "start guarded capture")
	for tick: int in 60:
		demo.tick(Game.RIGHT)
	demo.is_paused = true
	var notices: Array[int] = []
	var owner: WeakRef = weakref(demo)
	demo.driver.step_completed.connect(
		func(_code: int, _before: int, _after: int) -> void:
			var target: RefCounted = owner.get_ref()
			notices.append(target.call("replay_bytes").size())
	)
	var frame: int = demo.game.frame
	_check(context, demo.call("replay_bytes"), demo.game.canonical_bytes(), frame)
	context.equal(notices, [0], "completion handler cannot recursively capture")
	for tick: int in 4:
		demo.tick(Game.LEFT)
	context.equal(demo.viewer.begin_advance().code, Types.Code.READY, "retained expert work")
	context.equal(demo.call("replay_bytes").is_empty(), true, "export cannot borrow active game state")
	demo.viewer.terminate(Types.Code.PROTOCOL_FAILED)
	var bytes: PackedByteArray = demo.call("replay_bytes")
	_check(context, bytes, demo.game.canonical_bytes(), frame)
	context.equal(demo.viewer.status().reason, Types.Code.PROTOCOL_FAILED, "export preserves original failure")
	context.equal(demo.start(), Types.Code.OK, "new recording lifetime")
	context.equal(demo.lose_host_connection(), Types.Code.PROTOCOL_FAILED, "failed empty viewer")
	context.equal(demo.call("replay_bytes").is_empty(), true, "empty failed viewing has no validated state")

	for overflow: bool in [false, true]:
		context.equal(demo.start(), Types.Code.OK, "start failed capture")
		var game: FailingSaveGame = FailingSaveGame.new()
		game.overflow = overflow
		context.equal(demo.driver.configure(demo.viewer, game), Types.Code.OK, "application save callback installed")
		context.equal(demo.call("replay_bytes").is_empty(), true, "failed capture invents no boundary evidence")
		var expected: int = Types.Code.SNAPSHOT_FAILED if overflow else Types.Code.CALLBACK_FAILED
		context.equal(demo.viewer.status().reason, expected, "shared driver preserves failed save cause")
		context.equal(demo.viewer_code, expected, "capture failure is visible to the spectator client")


# Value: protects=pointer users can save viewed recordings; fails_when=save is keyboard-only or bypasses owned playback;
# why_new=existing capture tests do not exercise scene pointer wiring; seam=existing export method override avoids shared user files
func _save_pointer_control(context: RefCounted) -> void:
	var scene: SaveScene = SaveScene.new()
	scene._ready()
	var button: Button = scene.get_node_or_null("SpectatorControls/Content/HostControls/SaveViewedReplay")
	context.equal(button != null, true, "pointer users can save their viewed replay")
	if button == null:
		scene.free()
		return
	context.equal(button.focus_mode, Control.FOCUS_NONE, "save preserves host keyboard focus")
	context.equal(button.disabled, false, "healthy initial state can be captured before input")
	_save_from_button(context, scene, button, 0)
	context.equal(scene.demo.lose_host_connection(), Types.Code.PROTOCOL_FAILED, "host loss preserves captured initial state")
	scene._update_label()
	context.equal(button.disabled, false, "captured initial-only recording remains saveable after stopping")
	_save_from_button(context, scene, button, 0)
	context.equal(scene.demo.start(), Types.Code.OK, "new host restores ordinary viewing")
	context.equal(scene.demo.set_paused(true), Types.Code.OK, "pause viewing while host supplies input")
	for tick: int in range(40):
		context.equal(scene.demo.tick(Game.RIGHT | Game.FIRE), Types.Code.OK, "host supplies original confirmed inputs")
	context.equal(scene.demo.step_viewer(), Types.Code.OK, "display one original confirmed frame")
	scene._update_label()
	_save_from_button(context, scene, button, 1)
	var before_notice: String = scene._replay_notice
	context.equal(scene.demo.viewer.begin_advance().code, Types.Code.READY, "expert retains playback ownership")
	scene._update_label()
	context.equal(button.disabled, true, "active request disables saving")
	var before_calls: int = scene.export_calls
	button.pressed.emit()
	context.equal(scene.export_calls, before_calls, "active work never invokes the export action")
	context.equal(scene._replay_notice, before_notice, "direct signal cannot export through owned game work")
	context.equal(scene.demo.lose_host_connection(), Types.Code.PROTOCOL_FAILED, "known host loss stops buffered viewing")
	scene._update_label()
	context.equal(button.disabled, false, "stopped viewing retains its completed recording")
	_save_from_button(context, scene, button, 1)
	context.equal(scene.demo.viewer.status().reason, Types.Code.PROTOCOL_FAILED, "saving never revives failed viewing")
	context.equal(scene.demo.start(), Types.Code.OK, "restart discards old recording lifetime")
	context.equal(scene.demo.lose_host_connection(), Types.Code.PROTOCOL_FAILED, "stop before any state capture")
	scene._update_label()
	context.equal(button.disabled, true, "empty failed viewing has no usable recording")
	before_notice = scene._replay_notice
	before_calls = scene.export_calls
	button.pressed.emit()
	context.equal(scene.export_calls, before_calls, "empty stopped viewer never invokes the export action")
	context.equal(scene._replay_notice, before_notice, "disabled empty export does not claim a saved replay")
	scene.free()


func _save_from_button(context: RefCounted, scene: SaveScene, button: Button, frames: int) -> void:
	var host_frame: int = scene.demo.host.loop.game.frame
	var canonical: PackedByteArray = scene.demo.game.canonical_bytes()
	var before_calls: int = scene.export_calls
	button.pressed.emit()
	context.equal(scene.export_calls, before_calls + 1, "each successful pointer save invokes a fresh export")
	context.equal(scene._label.text.contains("Viewed replay captured."), true, "pointer save immediately displays export feedback")
	var bytes: PackedByteArray = scene.exported_bytes
	_check(context, bytes, canonical, frames)
	context.equal(scene.demo.host.loop.game.frame, host_frame, "saving does not sample the player host")


func _check(context: RefCounted, bytes: PackedByteArray, canonical: PackedByteArray, frames: int) -> void:
	var recording: Replay = Replay.new()
	context.equal(recording.decode(bytes), Replay.DecodeCode.OK, "portable spectator replay")
	context.equal(recording.frame_count(), frames, "only displayed input history recorded")
	context.equal(recording.skipped_frames(), 0, "recording contains no substituted rows")
	context.equal(recording.checksum(frames).size(), 16, "displayed boundary has final checksum")
	for expert: bool in [false, true]:
		var game: Game = Game.new()
		var player: Player = Player.new()
		context.equal(
			player.configure_expert(recording, Game.SNAPSHOT_BYTES) if expert else player.configure(recording, game, Game.SNAPSHOT_BYTES), Types.Code.OK, "replay configures"
		)
		for _work: int in frames + 2:
			var code: int = _dispatch(player, game) if expert else player.step()
			context.equal(code in [Types.Code.OK, Types.Code.FRAME_EXHAUSTED], true, "validated playback")
			if player.is_complete():
				break
		context.equal(player.is_final_state_validated(), true, "replay final state validated")
		context.bytes_equal(game.canonical_bytes(), canonical, frames, "replay equals viewed original history")


func _dispatch(player: Player, game: Game) -> int:
	var opened: Types.Result = player.begin_advance()
	if opened.code != Types.Code.READY:
		return opened.code
	while true:
		var request: Types.Request = opened.batch.next_request()
		if request == null:
			return Types.Code.OK
		var checksum: PackedByteArray = PackedByteArray()
		var ok: bool
		if request.kind == Types.Kind.SAVE:
			var saved: Driver.SaveResult = game.save_state(request.frame, request.writer)
			ok = saved.ok
			checksum = saved.checksum
		else:
			ok = game.simulate_frame(request.frame, request.inputs)
		var completed: Types.Result = player.complete_request(request.batch_id, request.request_id, ok, checksum)
		if completed.code != Types.Code.OK:
			return completed.code
	return Types.Code.OK
