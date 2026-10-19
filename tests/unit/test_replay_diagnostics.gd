extends RefCounted

# Value: protects=checksum failures expose owned bounded evidence across playback and seeking; fails_when=diagnostics vanish or callback failures claim divergence;
# why_new=existing replay tests assert only failure frame and code; seam=none
const Fixture = preload("res://tests/unit/test_replay_viewer.gd")
const Checkpoints = preload("res://tests/unit/test_replay_checkpoints.gd")
const Viewer = preload("res://examples/online/replay_viewer.gd")
const Scene = preload("res://examples/online/replay.tscn")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["playback_evidence", "restore_evidence", "viewer_evidence", "boundary_validation", "stepped_boundaries", "paused_boundaries"])


func run_case(name: String, context: RefCounted) -> void:
	var player: Player = Player.new()
	match name:
		"playback_evidence":
			_playback_evidence(context, player)
		"restore_evidence":
			_restore_evidence(context)
		"paused_boundaries":
			_paused_boundaries(context)
		"stepped_boundaries":
			_stepped_boundaries(context)
		"boundary_validation":
			_boundary_validation(context)
		_:
			_viewer_evidence(context)
	context.finish()


func _playback_evidence(context: RefCounted, player: Player) -> void:
	context.equal(player.failure_expected_checksum().is_empty(), true, "new player has no failed checksum")
	for boundary: int in [0, 8]:
		var replay: Replay = Fixture.recording()
		replay._checksums[boundary * Replay.CHECKSUM_BYTES] ^= 1
		var game: Simulation = Simulation.new()
		context.equal(player.configure(replay, game, Simulation.SNAPSHOT_BYTES), Types.Code.OK, "configure corrupt checksum")
		for frame: int in range(boundary):
			context.equal(player.step(), Types.Code.OK, "healthy prefix")
			context.equal(player.failure_actual_checksum().is_empty(), true, "healthy playback has no failure evidence")
		var expected: PackedByteArray = replay.checksum(boundary)
		var actual: PackedByteArray = Simulation.checksum(game.canonical_bytes())
		context.equal(player.step(), Types.Code.DESYNC, "checksum mismatch stops playback")
		context.equal(player.failure_frame(), boundary, "evidence identifies exact failing boundary")
		context.bytes_equal(player.failure_expected_checksum(), expected, boundary, "recorded checksum retained")
		context.bytes_equal(player.failure_actual_checksum(), actual, boundary, "computed checksum retained")
		var returned: PackedByteArray = player.failure_expected_checksum()
		returned.fill(0)
		returned = player.failure_actual_checksum()
		returned.fill(0)
		replay._checksums.fill(0)
		context.equal(player.step(), Types.Code.DESYNC, "terminal refusal preserves evidence")
		context.bytes_equal(player.failure_expected_checksum(), expected, boundary, "caller mutation cannot change recorded evidence")
		context.bytes_equal(player.failure_actual_checksum(), actual, boundary, "caller mutation cannot change computed evidence")
		context.equal(player.configure(null, game), Types.Code.INVALID_CONFIGURATION, "invalid reconfiguration refused")
		context.bytes_equal(player.failure_actual_checksum(), actual, boundary, "refused reconfiguration retains evidence")
		context.equal(player.configure(Fixture.recording(), Simulation.new()), Types.Code.OK, "new playback configures")
		context.equal(player.failure_expected_checksum().is_empty(), true, "successful configuration clears recorded evidence")
		context.equal(player.failure_actual_checksum().is_empty(), true, "successful configuration clears computed evidence")
		context.state(boundary, game.canonical_bytes())


func _restore_evidence(context: RefCounted) -> void:
	for fault: String in ["none", "wrong state", "false", "underflow", "large checksum", "checksum collision"]:
		var replay: Replay = Fixture.recording(12)
		var game: Checkpoints.FaultGame = Checkpoints.FaultGame.new()
		var player: Player = Player.new()
		context.equal(player.configure(replay, game, Simulation.SNAPSHOT_BYTES, 3, 3), Types.Code.OK, fault + " configure cache")
		for frame: int in range(12):
			context.equal(player.step(), Types.Code.OK, "healthy cached prefix")
		game.fault = fault
		game.cached_checksum = replay.checksum(6)
		var code: int = player.restore_before(8)
		if fault == "wrong state":
			context.equal(code, Types.Code.DESYNC, "restored state checksum mismatch")
			context.equal(player.failure_frame(), 6, "diagnostics identify restored checkpoint")
			context.bytes_equal(player.failure_expected_checksum(), replay.checksum(6), 6, "checkpoint expected checksum")
			context.bytes_equal(player.failure_actual_checksum(), Simulation.checksum(game.game.canonical_bytes()), 6, "checkpoint actual checksum")
		else:
			var codes: Dictionary = {"none": Types.Code.OK, "false": Types.Code.CALLBACK_FAILED, "underflow": Types.Code.SNAPSHOT_FAILED}
			context.equal(code, codes.get(fault, Types.Code.DESYNC), "callback result")
			context.equal(player.failure_expected_checksum().is_empty(), true, fault + " has no checksum pair")
			context.equal(player.failure_actual_checksum().is_empty(), true, fault + " has no misleading computed checksum")
		context.state(game.game.frame, game.game.canonical_bytes())


func _viewer_evidence(context: RefCounted) -> void:
	for navigation: bool in [false, true]:
		var replay: Replay = Fixture.recording()
		replay._checksums[8 * Replay.CHECKSUM_BYTES] ^= 1
		var viewer: Viewer = Viewer.new()
		viewer.open_bytes(replay.to_bytes())
		if navigation:
			viewer.seek(8)
			viewer.tick()
		else:
			viewer.toggle_play()
			for tick: int in range(9):
				viewer.tick()
		context.equal(viewer.current_frame(), 8, "viewer stops at mismatching boundary")
		context.equal(viewer.message.contains("Expected: " + replay.checksum(8).hex_encode()), true, "viewer shows recorded checksum")
		context.equal(viewer.message.contains("Actual: " + Simulation.checksum(viewer.game.canonical_bytes()).hex_encode()), true, "viewer shows computed checksum")
		context.equal(viewer.can_step(), false, "evidence remains terminal")
		context.state(8, viewer.game.canonical_bytes())


# Value: protects=paused replay destinations validate without consuming their input; fails_when=only step detects corruption or snapshot failure;
# why_new=viewer used a game-specific checksum outside the player's bounded snapshot contract; seam=none
func _boundary_validation(context: RefCounted) -> void:
	var probe: Player = Player.new()
	context.equal(probe.has_method("validate_current_frame"), true, "paused boundary validation is available")
	if not probe.has_method("validate_current_frame"):
		return
	context.equal(probe.call("validate_current_frame"), Types.Code.NOT_CONFIGURED, "unconfigured boundary refused")
	for fault: String in ["none", "checksum", "overflow", "false", "save reentry"]:
		var replay: Replay = Fixture.recording(12)
		if fault == "checksum":
			replay._checksums[8 * Replay.CHECKSUM_BYTES] ^= 1
		var game: Checkpoints.FaultGame = Checkpoints.FaultGame.new()
		var player: Player = Player.new()
		context.equal(player.configure(replay, game, Simulation.SNAPSHOT_BYTES, 3, 3), Types.Code.OK, fault + " boundary configures")
		for frame: int in 8:
			context.equal(player.step(), Types.Code.OK, "healthy prefix reaches selected boundary")
		game.fault = fault
		game.owner = weakref(player)
		var before: PackedByteArray = game.game.canonical_bytes()
		var expected: int = {
			"none": Types.Code.OK, "checksum": Types.Code.DESYNC, "overflow": Types.Code.SNAPSHOT_FAILED, "false": Types.Code.CALLBACK_FAILED, "save reentry": Types.Code.OK
		}[fault]
		context.equal(player.call("validate_current_frame"), expected, fault + " paused validation uses bounded snapshot callback")
		context.equal(player.current_frame(), 8, "validation does not consume selected input")
		context.bytes_equal(game.game.canonical_bytes(), before, 8, "validation preserves canonical selected state")
		if fault in ["none", "save reentry"]:
			if fault == "save reentry":
				context.equal(game.reentry_codes, [Types.Code.BUSY, Types.Code.BUSY, Types.Code.BUSY, Types.Code.BUSY], "paused validation guards callback reentry")
			context.equal(player.step(), Types.Code.OK, "healthy validation permits continuation")
			context.equal(player.current_frame(), 9, "next step consumes selected input exactly once")
		else:
			context.equal(player.failure_frame(), 8, "paused failure identifies selected frame")
			context.equal(player.step(), expected, "paused failure stops simulation")
			context.equal(player.restore_before(0), expected, "restore cannot erase paused validation failure")
			context.equal(player.call("validate_current_frame"), expected, "failure remains latched")
		context.equal(player.failure_expected_checksum().is_empty(), fault != "checksum", "only checksum mismatch publishes evidence")
		context.state(player.current_frame(), game.game.canonical_bytes())

	for frames: int in [0, 1]:
		for snapshot_limit: int in [0, Simulation.SNAPSHOT_BYTES]:
			var replay: Replay = Fixture.recording(frames)
			replay._flags.fill(0)
			var game: Checkpoints.FaultGame = Checkpoints.FaultGame.new()
			var player: Player = Player.new()
			player.configure(replay, game, snapshot_limit)
			context.equal(player.call("validate_current_frame"), Types.Code.OK, "checksum-absent boundary is valid")
			if frames == 1:
				context.equal(player.step(), Types.Code.OK, "checksum-absent input advances")
			context.equal(player.call("validate_current_frame"), Types.Code.OK, "completion boundary has no recorded checksum")
			context.equal(game.save_calls, 0, "absent checksums do not invent snapshot requirements")
			context.equal(player.is_complete(), true, "validation preserves completion")


# Value: protects=single-step inspection validates the selected state before pausing; fails_when=only a later input discovers a corrupt boundary;
# why_new=paused seek validation does not cover the Step action; seam=none
func _stepped_boundaries(context: RefCounted) -> void:
	for boundary: int in [1, 8, 120]:
		for coverage: String in ["full", "sparse", "absent"]:
			for corrupt: bool in [false, true]:
				var replay: Replay = Fixture.recording(122)
				if coverage != "full":
					replay._flags.fill(0)
					if coverage == "sparse":
						replay._flags[boundary] = Replay.FLAG_CHECKSUM
				if corrupt:
					replay._checksums[boundary * Replay.CHECKSUM_BYTES] ^= 1
				var viewer: Viewer = Viewer.new()
				context.equal(viewer.open_bytes(replay.to_bytes()), true, "step recording imports")
				var expected: Simulation = Simulation.new()
				for frame: int in boundary:
					viewer.step()
					expected.simulate_frame(frame, replay.inputs(frame))
				var failed: bool = corrupt and coverage != "absent"
				context.equal(viewer.current_frame(), boundary, "Step reaches selected boundary without consuming its input")
				context.bytes_equal(viewer.game.canonical_bytes(), expected.canonical_bytes(), boundary, "Step shows canonical destination state")
				context.equal(viewer.can_step(), not failed, "Step immediately detects a selected checksum mismatch")
				context.equal(viewer.is_playing, false, "Step finishes paused")
				var checks: int = boundary + int(not failed) if coverage == "full" else int(coverage == "sparse" and not failed)
				context.equal(viewer.checked_checksum_count(), checks, "Step counts only distinct successful selected boundaries")
				if failed:
					context.equal(viewer.message.contains("stopped at frame %d" % boundary), true, "Step reports the selected failed frame")
					context.equal(viewer.message.contains("Expected: " + replay.checksum(boundary).hex_encode()), true, "Step retains recorded failure evidence")
					context.equal(viewer.message.contains("Actual: " + Simulation.checksum(expected.canonical_bytes()).hex_encode()), true, "Step retains computed failure evidence")
					var message: String = viewer.message
					viewer.step()
					viewer.tick()
					context.equal(viewer.current_frame(), boundary, "failed Step remains terminal")
					context.equal(viewer.message, message, "repeated Step preserves mismatch evidence")
				else:
					context.equal(viewer.message, "Paused.", "healthy Step reports paused inspection")
					viewer.toggle_play()
					viewer.tick()
					context.equal(viewer.current_frame(), boundary + 1, "healthy Step resumes with the selected input exactly once")
				context.state(viewer.current_frame(), viewer.game.canonical_bytes())

	for playing: bool in [false, true]:
		var replay: Replay = Fixture.recording()
		replay._checksums[8 * Replay.CHECKSUM_BYTES] ^= 1
		var node: Node2D = Scene.instantiate()
		node._ready()
		node.viewer.open_bytes(replay.to_bytes())
		node.viewer.seek(7)
		node.viewer.tick()
		if playing:
			node.viewer.toggle_play()
		node._refresh()
		Fixture._button(node, "Step").pressed.emit()
		context.equal(node.viewer.current_frame(), 8, "visible Step selects the failing boundary")
		context.equal(Fixture._button(node, "Step").disabled, true, "visible Step disables itself immediately at mismatch")
		context.equal(Fixture._button(node, "Play").disabled, true, "visible Step cannot resume a mismatching state")
		context.equal(node.viewer.message.contains("stopped at frame 8"), true, "visible Step shows mismatch before another tick")
		node._physics_process(0.0)
		context.equal(node.viewer.current_frame(), 8, "paused mismatch does not consume its input on a later tick")
		context.state(8, node.viewer.game.canonical_bytes())
		node._exit_tree()
		node.free()


# Value: protects=Pause validates the displayed state immediately; fails_when=pause waits for a later resumed input to expose corruption;
# why_new=Step and seek paths do not exercise toggling active playback to paused; seam=none
func _paused_boundaries(context: RefCounted) -> void:
	for boundary: int in [0, 8, 120]:
		for coverage: String in ["full", "sparse", "absent"]:
			for corrupt: bool in [false, true]:
				var replay: Replay = Fixture.recording(122)
				if coverage != "full":
					replay._flags.fill(0)
					if coverage == "sparse":
						replay._flags[boundary] = Replay.FLAG_CHECKSUM
				if corrupt:
					replay._checksums[boundary * Replay.CHECKSUM_BYTES] ^= 1
				var viewer: Viewer = Viewer.new()
				viewer.open_bytes(replay.to_bytes())
				viewer.toggle_play()
				for tick: int in boundary:
					viewer.tick()
				viewer.toggle_play()
				var failed: bool = corrupt and coverage != "absent"
				context.equal(viewer.current_frame(), boundary, "Pause does not consume the displayed boundary input")
				context.equal(viewer.is_playing, false, "Pause finishes paused")
				context.equal(viewer.can_step(), not failed, "Pause immediately detects displayed checksum mismatch")
				var checks: int = boundary + int(not failed) if coverage == "full" else int(coverage == "sparse" and not failed)
				context.equal(viewer.checked_checksum_count(), checks, "Pause counts distinct successful displayed boundaries")
				if failed:
					context.equal(viewer.message.contains("stopped at frame %d" % boundary), true, "Pause identifies the displayed failed boundary")
					context.equal(viewer.message.contains("Expected: " + replay.checksum(boundary).hex_encode()), true, "Pause retains recorded mismatch evidence")
				else:
					context.equal(viewer.message, "Paused.", "healthy Pause remains visible")
				var before: PackedByteArray = viewer.game.canonical_bytes()
				viewer.tick()
				context.bytes_equal(viewer.game.canonical_bytes(), before, boundary, "paused state remains unchanged")
				context.state(boundary, before)
