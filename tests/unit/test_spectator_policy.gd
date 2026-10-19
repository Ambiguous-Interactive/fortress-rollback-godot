extends RefCounted

const Spectator = preload("res://addons/fortress_rollback/core/spectator_session.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Fixture = preload("res://tests/unit/test_spectator_session.gd")
const GameFixture = preload("res://tests/unit/test_driver.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["confirmation_policy"])


func run_case(name: String, context: RefCounted) -> void:
	call("_" + name, context)
	context.finish()


# Value: protects=viewer exports host-confirmed rows; fails_when=player confirmation gates freeze viewer state; why_new=viewer tests skip mesh controls; seam=none
func _confirmation_policy(context: RefCounted) -> void:
	for use_player_control: bool in [false, true]:
		var viewer: Session = Spectator.new()
		context.equal(viewer.configure(Fixture.new()._config()), Types.Code.OK, "configure confirmed-only viewer")
		if use_player_control:
			context.equal(viewer.set_confirmation_limit(-1).code, Types.Code.UNSUPPORTED, "player confirmation policy unavailable before playback")
		var game: RefCounted = GameFixture.Game.new()
		var driver: RefCounted = Driver.new(viewer, game)
		var empty: Array[Driver.LocalInput] = []
		for frame: int in range(8):
			context.equal(viewer.receive_host_frame(frame, Fixture.new()._row(frame)).code, Types.Code.OK, "host confirms complete row")
			context.equal(driver.step(frame, empty).code, Types.Code.OK, "viewer plays host row")
			context.equal(viewer.status().confirmed_frame, frame, "viewer confirmation follows played host input")
			var exported: Types.FrameInputs = viewer.confirmed_inputs(frame)
			context.equal(exported != null, true, "played host input remains exportable")
			if exported != null:
				for player: int in range(2):
					context.equal(exported.read(player).bytes, Fixture.new()._row(frame)[player], "export preserves host bytes")
			if use_player_control:
				context.equal(viewer.set_confirmation_limit(frame).code, Types.Code.UNSUPPORTED, "player confirmation policy unavailable after playback")
		context.equal(viewer.host_frontier(), 7, "refused control preserves host frontier")
		context.equal(game.trace.size(), 8, "every host row simulated once")

	var config: RefCounted = Fixture.new()._config()
	config.spectator = false
	config.local_players = PackedInt32Array([0, 1])
	var player_session: Session = Session.new()
	context.equal(player_session.configure(config), Types.Code.OK, "ordinary player control configuration")
	context.equal(player_session.set_confirmation_limit(-1).code, Types.Code.OK, "player mesh may establish confirmation policy")
	for player: int in range(2):
		context.equal(player_session.submit_local_input(player, 0, Fixture.new()._row(0)[player]).code, Types.Code.OK, "player input receipt")
	context.equal(player_session.status().confirmed_frame, -1, "player policy waits for remote evidence")
	context.equal(player_session.set_confirmation_limit(0).code, Types.Code.OK, "player mesh may advance confirmation")
	context.equal(player_session.status().confirmed_frame, 0, "ordinary player confirmation remains controllable")
