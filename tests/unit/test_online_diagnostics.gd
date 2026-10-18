extends RefCounted

# Value: protects=explicit local trace consent and owned exports; fails_when=Ready ignores consent or disabled rooms retain payloads; seam=production freeze and report
const Fixture = preload("res://tests/unit/test_online_example.gd")
const Match = preload("res://examples/online/match.gd")
const Scene = preload("res://examples/online/online.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["consent", "capture", "replay", "replay_stall"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "consent":
		var node: Node2D = Scene.new()
		Engine.get_main_loop().root.add_child(node)
		if not node.is_node_ready():
			node._ready()
		var toggle: CheckBox = node.get("trace_checkbox")
		var replay_toggle: CheckBox = node.get("replay_checkbox")
		context.equal(replay_toggle != null, true, "online example offers separate replay consent")
		if replay_toggle != null:
			context.equal(replay_toggle.button_pressed, false, "recording defaults off")
			context.equal(node.replay_button.disabled, true, "no recording before gameplay")
			replay_toggle.button_pressed = true
			node._ready_player()
			context.equal(node.controller.game_match.record_replay, true, "Ready forwards recording choice")
			context.equal(node.controller.game_match.capture_trace, false, "recording does not enable diagnostic payloads")
		context.equal(toggle != null, true, "online example offers explicit trace consent")
		if toggle != null:
			context.equal(toggle.button_pressed, false, "payload capture defaults off")
			toggle.button_pressed = true
			node._ready_player()
			context.equal(node.controller.game_match.capture_trace, true, "Ready forwards user choice before freezing")
			node.controller.has_readied = true
			node._update_status()
			context.equal(toggle.disabled, true, "capture choice freezes at Ready")
			if replay_toggle != null:
				context.equal(replay_toggle.disabled, true, "recording choice freezes at Ready")
			node.controller.has_readied = false
			node._update_status()
			context.equal(toggle.disabled, false, "fresh room permits a new choice")
		node.free()
	elif name in ["replay", "replay_stall"]:
		_replay(context, name == "replay_stall")
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
			context.equal(game.peer.replay(), null, "trace choice alone never records gameplay")
			context.equal(report.has("trace"), enabled, "disabled capture retains no game payload")
			if enabled:
				context.equal(report.trace.max_frames, 120, "bounded two-second canonical window")
				context.equal(report.trace.seed, "1701", "actual application seed")
				context.equal(report.trace.application_version, "fortress-online-integer-v1", "game version matches session domain")
				context.equal(
					report.trace.replay_command,
					"godot --headless --path . --script scripts/diagnose_trace.gd -- fortress-diagnostics.json",
					"capture supplies the actual offline reproduction command"
				)
				report.trace.seed = "caller edit"
				context.equal(game.peer.diagnostics().trace.seed, "1701", "export owns metadata")
			game.detach()
			client.free()
			mesh.free()
	context.finish()


# Value: protects=confirmed recording without diagnostic consent; fails_when=recording is empty, predicted, or lost on failure; seam=real two-peer game.
func _replay(context: RefCounted, stalled_start: bool = false) -> void:
	var helper: RefCounted = Fixture.new()
	var fixtures: Array[Dictionary] = []
	for uuid: String in [Fixture.U, Fixture.V]:
		var client: Fixture.Client = Fixture.Client.new()
		client.local = uuid
		var mesh: Fixture.DirectFixture.FakeMesh = Fixture.DirectFixture.FakeMesh.new()
		var transport: Fixture.MeshFixture.Transport = Fixture.MeshFixture.Transport.new()
		transport.local = uuid
		mesh.transport = transport
		var game: Match = Match.new()
		context.equal("record_replay" in game, true, "recording configuration is available")
		if not "record_replay" in game:
			client.free()
			mesh.free()
			return
		game.set("record_replay", true)
		context.equal(game.freeze(client, mesh, PackedStringArray([Fixture.U, Fixture.V]), PackedByteArray([1, 2, 3, 4, 5, 6, 7, 8])), OK, "freeze replay without trace")
		context.equal(game.peer.diagnostics().has("trace"), false, "recording retains no diagnostic payload window")
		context.equal(game.peer.replay().game_seed(), "1701", "replay seed remains available without trace")
		context.equal(game.peer.replay().game_version(), "fortress-online-integer-v1", "replay identifies game revision")
		var plan: Fixture.MembershipFixture.Plan = Fixture.MembershipFixture.Plan.new()
		plan.data.peers = [{"player_id": Fixture.V if uuid == Fixture.U else Fixture.U, "initiate": uuid == Fixture.U}]
		client.session_plan.emit(plan)
		var config: Fixture.RelayFixture.SDKConfig = Fixture.RelayFixture.SDKConfig.new()
		config.max_buffered_bytes = 4096
		config.max_outbound_frame_bytes = 4096
		var info: Fixture.RelayFixture.Info = Fixture.RelayFixture.Info.new()
		context.equal(game.start_transport(client, mesh, config, info, 0), OK, "start recorded match")
		fixtures.append({"driver": game, "client": client, "mesh": mesh, "transport": transport, "config": config, "info": info})
	if stalled_start:
		_stalled_start(context, fixtures, helper)
		return
	for frame: int in 100:
		for fixture: Dictionary in fixtures:
			fixture.driver.tick(frame * 16667, Fixture.Simulation.RIGHT)
		helper._deliver(fixtures)
	var node: Node2D = Scene.new()
	Engine.get_main_loop().root.add_child(node)
	if not node.is_node_ready():
		node._ready()
	for fixture: Dictionary in fixtures:
		node.controller.game_match = fixture.driver
		context.equal(fixture.driver.failure, "", "recorded match remains healthy")
		context.equal(fixture.driver.has_recorded_replay, true, "download enabled after confirmed gameplay")
		var bytes: PackedByteArray = node.replay_bytes()
		var recording: Replay = Replay.new()
		context.equal(recording.decode(bytes), Replay.DecodeCode.OK, "exported bytes decode as replay")
		context.equal(recording.frame_count() > 50, true, "actual confirmed gameplay is recorded")
		context.equal(recording.frame_count() <= fixture.driver.peer.status().current_frame, true, "recording excludes unsimulated inputs")
		if recording.frame_count() > 20:
			context.equal(recording.inputs(20).read(0).bytes, PackedByteArray([Fixture.Simulation.RIGHT]), "recorded original keyboard input")
		fixture.driver.detach()
		context.equal(node.replay_bytes(), bytes, "ended match remains downloadable until Leave")
		node._update_status()
		context.equal(node.replay_button.disabled, false, "ended recording button remains enabled")
		fixture.mesh.free()
		fixture.client.free()
	var before_leave: PackedByteArray = node.replay_bytes()
	node._leave()
	context.equal(node.replay_bytes(), before_leave, "Leave retains the last recording alongside diagnostics")
	node.free()


# Value: protects=late recording availability; fails_when=repair-only stalls hide confirmed replay rows; seam=actual delayed first input packets.
func _stalled_start(context: RefCounted, fixtures: Array[Dictionary], helper: RefCounted) -> void:
	for round: int in 20:
		for fixture: Dictionary in fixtures:
			fixture.driver._service(round)
		helper._deliver(fixtures)
	var initial: Array[Array] = []
	for fixture: Dictionary in fixtures:
		context.equal(fixture.driver.peer.network_status().state, "running", "handshake completes before gameplay")
		fixture.driver.tick(100, Fixture.Simulation.RIGHT)
		initial.append(fixture.transport.routed.duplicate(true))
		fixture.transport.routed.clear()
	for round: int in 30:
		for fixture: Dictionary in fixtures:
			fixture.driver.tick(101 + round, Fixture.Simulation.LEFT)
			fixture.transport.routed.clear()
	for index: int in 2:
		context.equal(fixtures[index].driver.stalls > 0, true, "initial remote input is withheld past prediction stall")
		context.equal(fixtures[index].driver.has_recorded_replay, false, "no replay available before any remote input")
		fixtures[index].transport.routed.append_array(initial[index])
	helper._deliver(fixtures)
	for fixture: Dictionary in fixtures:
		var before: int = fixture.driver.peer.status().current_frame
		fixture.driver.tick(200, Fixture.Simulation.LEFT)
		var recording: Replay = fixture.driver.peer.replay()
		context.equal(fixture.driver.peer.status().current_frame > before, true, "first remote input permits a completed advance")
		context.equal(recording.frame_count() > 0, true, "late first actual input records a repaired prefix")
		context.equal(fixture.driver.has_recorded_replay, true, "download becomes available after the initial prediction stall")
		fixture.driver.detach()
		fixture.mesh.free()
		fixture.client.free()
