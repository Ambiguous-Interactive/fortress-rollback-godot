extends RefCounted

# Value: protects=explicit local trace consent and owned exports; fails_when=Ready ignores consent or disabled rooms retain payloads; seam=production freeze and report
const Fixture = preload("res://tests/unit/test_online_example.gd")
const Match = preload("res://examples/online/match.gd")
const Scene = preload("res://examples/online/online.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["consent", "capture"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "consent":
		var node: Node2D = Scene.new()
		Engine.get_main_loop().root.add_child(node)
		if not node.is_node_ready():
			node._ready()
		var toggle: CheckBox = node.get("trace_checkbox")
		context.equal(toggle != null, true, "online example offers explicit trace consent")
		if toggle != null:
			context.equal(toggle.button_pressed, false, "payload capture defaults off")
			toggle.button_pressed = true
			node._ready_player()
			context.equal(node.controller.game_match.capture_trace, true, "Ready forwards user choice before freezing")
			node.controller.has_readied = true
			node._update_status()
			context.equal(toggle.disabled, true, "capture choice freezes at Ready")
			node.controller.has_readied = false
			node._update_status()
			context.equal(toggle.disabled, false, "fresh room permits a new choice")
		node.free()
	else:
		for enabled: bool in [false, true]:
			var client: Fixture.Client = Fixture.Client.new()
			client.local = Fixture.U
			var mesh: Fixture.DirectFixture.FakeMesh = Fixture.DirectFixture.FakeMesh.new()
			var game: Match = Match.new()
			context.equal("capture_trace" in game, true, "local opt-in is available")
			if not "capture_trace" in game:
				client.free()
				mesh.free()
				continue
			game.capture_trace = enabled
			context.equal(game.freeze(client, mesh, PackedStringArray([Fixture.U, Fixture.V]), PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8])), OK, "freeze trace configuration")
			var report: Dictionary = game.peer.diagnostics()
			context.equal(report.has("trace"), enabled, "disabled capture retains no game payload")
			if enabled:
				context.equal(report.trace.max_frames, 120, "bounded two-second canonical window")
				context.equal(report.trace.seed, "1701", "actual application seed")
				context.equal(report.trace.application_version, "fortress-online-integer-v1", "game version matches session domain")
				context.equal(report.trace.replay_command, "", "no invented replay command")
				report.trace.seed = "caller edit"
				context.equal(game.peer.diagnostics().trace.seed, "1701", "export owns metadata")
			game.detach()
			client.free()
			mesh.free()
	context.finish()
