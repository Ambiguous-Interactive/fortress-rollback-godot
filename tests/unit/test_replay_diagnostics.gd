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
	return PackedStringArray(
		["playback_evidence", "restore_evidence", "viewer_evidence", "boundary_validation", "stepped_boundaries", "paused_boundaries", "failure_download", "comparison_domains"]
	)


func run_case(name: String, context: RefCounted) -> void:
	var player: Player = Player.new()
	match name:
		"comparison_domains":
			_comparison_domains(context)
		"failure_download":
			_failure_download(context)
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
	context.equal(player.failure_code(), Types.Code.OK, "new player has no failure code")
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
		context.equal(player.failure_code(), Types.Code.DESYNC, "failure code identifies the latched cause")
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
		context.equal(player.failure_code(), Types.Code.OK, "new playback lifetime clears the failure code")
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
					context.equal(
						viewer.message.contains("Actual: " + Simulation.checksum(expected.canonical_bytes()).hex_encode()), true, "Step retains computed failure evidence"
					)
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


# Value: protects=players retain replay divergence evidence tied to the imported file; fails_when=export advances playback or loses original failure;
# why_new=visible hashes cannot be downloaded or correlated with a recording; seam=none
func _failure_download(context: RefCounted) -> void:
	var probe: Viewer = Viewer.new()
	context.equal(probe.has_method("failure_report_bytes"), true, "replay failures can be downloaded")
	if not probe.has_method("failure_report_bytes"):
		return
	context.equal(probe.call("failure_report_bytes"), PackedByteArray(), "unconfigured playback has no failure report")
	for fault: String in ["checksum", "digest"]:
		var replay: Replay = Fixture.recording(12)
		if fault == "checksum":
			replay._checksums[8 * Replay.CHECKSUM_BYTES] ^= 1
		else:
			replay._digests[8 * Replay.DIGEST_BYTES] ^= 1
		var source: PackedByteArray = replay.to_bytes()
		var node: Node2D = Scene.instantiate()
		node._ready()
		node.viewer.open_bytes(source)
		node._refresh()
		var button: Button = Fixture._button(node, "Download failure")
		context.equal(button != null, true, "replay scene offers the failure download")
		if button == null:
			node._exit_tree()
			node.free()
			return
		context.equal(button.disabled, true, "healthy playback cannot export a failure")
		context.equal(node.viewer.call("failure_report_bytes"), PackedByteArray(), "healthy playback has no failure report")
		node.viewer.seek(12)
		node._physics_process(0.0)
		context.equal(button.disabled, false, "divergence enables the visible download")
		var before: PackedByteArray = node.viewer.game.canonical_bytes()
		var bytes: PackedByteArray = node.viewer.call("failure_report_bytes")
		context.equal(bytes.size() > 0 and bytes.size() <= 16384, true, "download has a fixed small bound")
		var report: Dictionary = JSON.parse_string(bytes.get_string_from_utf8())
		var hash: HashingContext = HashingContext.new()
		hash.start(HashingContext.HASH_SHA256)
		hash.update(source)
		context.equal(report.schema, "fortress-replay-failure-v1", "failure report has its own versioned schema")
		context.equal(report.replay_sha256, hash.finish().hex_encode(), "report identifies the exact imported recording")
		context.equal(report.replay_bytes, source.size(), "report records imported file size")
		context.equal(report.failure.frame, 8, "report identifies the failed boundary")
		context.equal(report.failure.code, Types.Code.DESYNC, "report preserves the real failure code")
		context.equal(report.failure.comparison, "state_checksum" if fault == "checksum" else "input_digest", "report names the hash domain")
		context.equal(
			node.viewer.message.contains("state checksum mismatch" if fault == "checksum" else "input digest mismatch"), true, "visible evidence names the failed comparison"
		)
		context.equal(
			report.failure.expected, replay.checksum(8).hex_encode() if fault == "checksum" else replay.input_digest(8).hex_encode(), "report preserves expected comparison hash"
		)
		context.equal(
			report.failure.actual,
			Simulation.checksum(before).hex_encode() if fault == "checksum" else replay.computed_input_digest(8).hex_encode(),
			"report preserves computed comparison hash"
		)
		context.equal(report.observed_state.frame, 8, "state observation names the exposed frame")
		context.equal(report.observed_state.bytes, before.hex_encode(), "report keeps the actual displayed state without claiming validation")
		context.equal(report.recording.game_version, replay.game_version(), "report includes reproducible game metadata")
		context.equal(report.recording.frames, 12, "report preserves the recording extent")
		context.equal(report.coverage.checked, 8, "report never counts the failed comparison as verified")
		context.equal(report.coverage.recorded, 12, "report preserves sparse checksum context")
		context.equal(node.viewer.open_bytes(PackedByteArray([0])), false, "failed replacement leaves old failure evidence")
		context.equal(node.viewer.call("failure_report_bytes"), bytes, "failed import preserves exact downloadable evidence")
		bytes.fill(0)
		context.equal(node.viewer.call("failure_report_bytes").size() > 0, true, "caller cannot mutate retained report evidence")
		context.bytes_equal(node.viewer.game.canonical_bytes(), before, 8, "report construction does not advance or alter game state")
		context.equal(node.viewer.current_frame(), 8, "report preserves exposed playback frame")
		node.viewer.restart()
		node._refresh()
		context.equal(button.disabled, true, "restart clears the old downloadable failure")
		context.equal(node.viewer.call("failure_report_bytes"), PackedByteArray(), "new lifetime cannot export stale divergence")
		context.state(8, before)
		node._exit_tree()
		node.free()


# Value: protects=replay diagnosis distinguishes changed input from game divergence; fails_when=all DESYNC hashes look alike;
# why_new=existing evidence checks compare hash bytes without identifying their domain; seam=none
func _comparison_domains(context: RefCounted) -> void:
	var probe: Player = Player.new()
	context.equal(probe.has_method("failure_comparison"), true, "replay evidence identifies the failed comparison")
	if not probe.has_method("failure_comparison"):
		return
	for expert: bool in [false, true]:
		for paused: bool in [false, true]:
			for fault: String in ["none", "input_digest", "state_checksum"]:
				var replay: Replay = Fixture.recording(2)
				if fault == "input_digest":
					replay._digests[0] ^= 1
				elif fault == "state_checksum":
					replay._checksums[0] ^= 1
				var player: Player = Player.new()
				var game: Simulation = Simulation.new()
				if expert:
					player.configure_expert(replay, Simulation.SNAPSHOT_BYTES)
					var result: Types.Result = player.begin_validate_current_frame() if paused else player.begin_advance()
					if result.code == Types.Code.READY:
						var request: Types.Request = result.batch.next_request()
						var saved: RefCounted = game.save_state(0, request.writer)
						player.complete_request(request.batch_id, request.request_id, saved.ok, saved.checksum)
				else:
					player.configure(replay, game, Simulation.SNAPSHOT_BYTES)
					if paused:
						player.validate_current_frame()
					else:
						player.step()
				context.equal(player.call("failure_comparison"), "" if fault == "none" else fault, "comparison identity survives every playback entry point")
				context.equal(player.failure_kind(), Types.Kind.SAVE if fault == "state_checksum" else -1, "only dispatched comparison failures name a request")
				player.terminate()
				context.equal(player.call("failure_comparison"), "" if fault == "none" else fault, "termination preserves the first comparison")
				context.equal(player.configure(null, game), Types.Code.INVALID_CONFIGURATION, "invalid configure preserves diagnosis")
				context.equal(player.call("failure_comparison"), "" if fault == "none" else fault, "refused configure preserves comparison")
				context.equal(player.configure(Fixture.recording(1), game), Types.Code.OK, "new playback clears diagnosis")
				context.equal(player.call("failure_comparison"), "", "successful configure clears comparison")
	for fault: String in ["none", "wrong state", "checksum collision", "false", "underflow", "large checksum"]:
		var player: Player = Player.new()
		var game: Checkpoints.FaultGame = Checkpoints.FaultGame.new()
		var replay: Replay = Fixture.recording(12)
		player.configure(replay, game, Simulation.SNAPSHOT_BYTES, 3, 3)
		for frame: int in 12:
			player.step()
		game.fault = fault
		game.cached_checksum = replay.checksum(6)
		player.restore_before(8)
		var expected: String = "checkpoint_checksum" if fault == "wrong state" else ("checkpoint_bytes" if fault == "checksum collision" else "")
		context.equal(player.call("failure_comparison"), expected, "restore comparison is distinct from callback or snapshot failure")
		context.state(game.game.frame, game.game.canonical_bytes())

	var viewer: Viewer = Viewer.new()
	viewer.open_bytes(Fixture.recording(2).to_bytes())
	viewer.game.frame = 1
	viewer.step()
	context.equal(viewer.has_failure(), true, "invalid initial game state rejects the real save callback")
	context.equal(viewer.message.contains("Failed while saving state."), true, "visible failure identifies the callback operation")
	var report: Dictionary = JSON.parse_string(viewer.failure_report_bytes().get_string_from_utf8())
	context.equal(report.failure.code, Types.Code.CALLBACK_FAILED, "download preserves the callback cause")
	context.equal(report.failure.request_kind, Types.Kind.SAVE, "download identifies the failed request")
	context.equal(report.failure.comparison, "", "callback diagnosis cannot claim a checksum comparison")
	context.state(viewer.current_frame(), viewer.game.canonical_bytes())
