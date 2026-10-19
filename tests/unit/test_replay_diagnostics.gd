extends RefCounted

# Value: protects=checksum failures expose owned bounded evidence across playback and seeking; fails_when=diagnostics vanish or callback failures claim divergence;
# why_new=existing replay tests assert only failure frame and code; seam=none
const Fixture = preload("res://tests/unit/test_replay_viewer.gd")
const Checkpoints = preload("res://tests/unit/test_replay_checkpoints.gd")
const Viewer = preload("res://examples/online/replay_viewer.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["playback_evidence", "restore_evidence", "viewer_evidence", "boundary_validation"])


func run_case(name: String, context: RefCounted) -> void:
	var player: Player = Player.new()
	match name:
		"playback_evidence":
			_playback_evidence(context, player)
		"restore_evidence":
			_restore_evidence(context)
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
