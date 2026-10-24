extends RefCounted

# Value: protects=repeated replay navigation restores validated state with bounded work; fails_when=seek starts over or crosses imports/failures;
# why_new=viewer navigation tests cover sequential seeking only; seam=none
const Fixture = preload("res://tests/unit/test_replay_viewer.gd")
const Viewer = preload("res://examples/online/replay_viewer.gd")
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Reader = preload("res://addons/fortress_rollback/core/snapshot_reader.gd")
const Writer = preload("res://addons/fortress_rollback/core/snapshot_writer.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Simulation = preload("res://examples/offline/simulation.gd")


class FaultGame:
	extends RefCounted
	var game: Simulation = Simulation.new()
	var fault: String = "none"
	var owner: WeakRef
	var reentry_codes: Array[int] = []
	var retained_reader: Reader
	var save_calls: int = 0
	var cached_checksum: PackedByteArray = PackedByteArray()

	func save_state(frame: int, writer: Writer) -> Driver.SaveResult:
		save_calls += 1
		if fault == "save reentry":
			reentry_codes.append(owner.get_ref().restore_before(0))
			reentry_codes.append(owner.get_ref().step())
			reentry_codes.append(owner.get_ref().validate_current_frame())
			reentry_codes.append(owner.get_ref().configure(Fixture.recording(), self))
		var result: Driver.SaveResult = game.save_state(frame, writer)
		if fault == "overflow":
			writer.write_bytes(PackedByteArray([0]))
		if fault == "false":
			result.ok = false
		if fault == "checksum collision":
			result.checksum = cached_checksum.duplicate()
		if fault == "large checksum":
			result.checksum.resize(1048576)
		return result

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		return game.simulate_frame(frame, inputs)

	# Variant intentionally exercises malformed application callback results.
	func load_state(frame: int, reader: Reader) -> Variant:
		retained_reader = reader
		if fault == "wrong type":
			return 1
		if fault == "null":
			return null
		if fault == "unread":
			return true
		if fault == "underflow":
			reader.read_bytes(Simulation.SNAPSHOT_BYTES + 1)
			return true
		var loaded: bool = game.load_state(frame, reader)
		if fault == "expired":
			reader._expire()
		if fault in ["wrong state", "checksum collision"]:
			game.rng_state ^= 1
		if fault == "false":
			return false
		if fault == "reentry":
			reentry_codes.append(owner.get_ref().restore_before(0))
			reentry_codes.append(owner.get_ref().step())
			reentry_codes.append(owner.get_ref().validate_current_frame())
			reentry_codes.append(owner.get_ref().configure(Fixture.recording(), self))
		return loaded


func cases() -> PackedStringArray:
	return PackedStringArray(["cached_navigation", "bounded_cache", "restore_failures", "checkpoint_callbacks"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "cached_navigation":
		_cached_navigation(context)
	elif name == "bounded_cache":
		_bounded_cache(context)
	elif name == "restore_failures":
		_restore_failures(context)
	else:
		_checkpoint_callbacks(context)
	context.finish()


func _cached_navigation(context: RefCounted) -> void:
	var probe: RefCounted = Player.new()
	context.equal(probe.has_method("checkpoint_frames"), true, "validated checkpoints can be listed for navigation")
	if not probe.has_method("checkpoint_frames"):
		return
	_checkpoint_controls(context)
	var replay: RefCounted = Fixture.recording(900)
	var viewer: Viewer = Viewer.new()
	context.equal(viewer.open_bytes(replay.to_bytes()), true, "open recording")
	viewer.seek(900)
	while viewer.is_seeking():
		viewer.tick()
	var expected: Simulation = Simulation.new()
	for frame: int in range(450):
		expected.simulate_frame(frame, replay.inputs(frame))
	viewer.seek(450)
	context.equal(viewer.current_frame(), 300, "backward navigation restores nearest validated checkpoint")
	viewer.tick()
	context.equal(viewer.current_frame(), 420, "restored seek retains per-tick work bound")
	viewer.tick()
	context.equal(viewer.current_frame(), 450, "restored seek reaches target exactly")
	context.bytes_equal(viewer.game.canonical_bytes(), expected.canonical_bytes(), 450, "restores RNG and pending effects")
	viewer.seek(750)
	context.equal(viewer.current_frame(), 600, "forward navigation can reuse a previously validated checkpoint")
	while viewer.is_seeking():
		viewer.tick()
	viewer.seek(0)
	context.equal(viewer.current_frame(), 0, "initial checkpoint remains available")
	context.bytes_equal(viewer.game.canonical_bytes(), Simulation.new().canonical_bytes(), 0, "initial state restored")
	replay._inputs[14] = 1
	context.equal(viewer.open_bytes(replay.to_bytes()), true, "load different recording with identical dimensions")
	viewer.seek(750)
	context.equal(viewer.current_frame(), 0, "new import discards all old checkpoints")
	viewer.tick()
	context.equal(viewer.current_frame(), 7, "corruption cannot reuse a healthy recording checkpoint")
	context.equal(viewer.can_step(), false, "checksum failure remains terminal")
	viewer.seek(750)
	viewer.tick()
	context.equal(viewer.current_frame(), 7, "retry cannot skip the failed prefix")
	context.state(viewer.current_frame(), viewer.game.canonical_bytes())


func _bounded_cache(context: RefCounted) -> void:
	var probe: RefCounted = Player.new()
	context.equal(probe.has_method("checkpoint_frames"), true, "bounded cache exposes its actual inventory")
	if not probe.has_method("checkpoint_frames"):
		return
	var replay: RefCounted = Fixture.recording(12)
	var player: Player = Player.new()
	context.equal(player.checkpoint_frames(), PackedInt64Array(), "unconfigured inventory is empty")
	var game: Simulation = Simulation.new()
	for dimensions: Array in [[0, 2], [1, 0], [-1, 2], [1, 1], [1, 1025], [1, 1024]]:
		var capacity: int = 16777216 if dimensions == [1, 1024] else Simulation.SNAPSHOT_BYTES
		context.equal(player.configure(replay, game, capacity, dimensions[0], dimensions[1]), Types.Code.INVALID_CONFIGURATION, "invalid cache budget rejected")
	context.equal(player.configure(replay, game, Simulation.SNAPSHOT_BYTES, 3, 2), Types.Code.OK, "minimum cache budget")
	context.equal(player.restore_before(0), Types.Code.HISTORY_UNAVAILABLE, "no snapshot before first save")
	context.equal(player.call("checkpoint_frames"), PackedInt64Array(), "unvalidated boundaries are absent")
	for frame: int in range(12):
		context.equal(player.step(), Types.Code.OK, "recorded playback")
	context.equal(player.call("checkpoint_frames"), PackedInt64Array([0, 9]), "inventory excludes evicted checkpoints")
	var frames: PackedInt64Array = player.call("checkpoint_frames")
	frames[0] = 8
	context.equal(player.call("checkpoint_frames"), PackedInt64Array([0, 9]), "inventory is caller-owned")
	for target: int in [-1, 13, 9223372036854775807]:
		context.equal(player.restore_before(target), Types.Code.INVALID_FRAME, "invalid target rejected")
		context.equal(player.current_frame(), 12, "invalid target leaves playback intact")
	context.equal(player.restore_before(8), Types.Code.OK, "evicted checkpoint falls back to initial state")
	context.equal(player.current_frame(), 0, "initial state survives bounded eviction")
	context.equal(player.restore_before(11), Types.Code.OK, "retained newest checkpoint reused")
	context.equal(player.current_frame(), 9, "restores closest retained checkpoint")
	context.equal(player.step(), Types.Code.OK, "continues after checkpoint restore")
	context.equal(player.current_frame(), 10, "continuation uses restored input frame")
	context.state(10, game.canonical_bytes())
	context.equal(player.configure(replay, Simulation.new(), Simulation.SNAPSHOT_BYTES), Types.Code.OK, "ordinary playback remains compatible")
	context.equal(player.restore_before(0), Types.Code.HISTORY_UNAVAILABLE, "reconfiguration releases previous cache")
	context.equal(player.call("checkpoint_frames"), PackedInt64Array(), "new lifetime has no inherited inventory")


func _restore_failures(context: RefCounted) -> void:
	var replay: RefCounted = Fixture.recording(12)
	for fault: String in ["none", "false", "wrong type", "null", "unread", "underflow", "expired", "wrong state", "reentry"]:
		var game: FaultGame = FaultGame.new()
		var player: Player = Player.new()
		game.owner = weakref(player)
		context.equal(player.configure(replay, game, Simulation.SNAPSHOT_BYTES, 3, 3), Types.Code.OK, fault + " configured")
		for frame: int in range(12):
			context.equal(player.step(), Types.Code.OK, fault + " healthy control before restore")
		game.fault = fault
		var expected: int = Types.Code.OK
		if fault in ["false", "wrong type", "null"]:
			expected = Types.Code.CALLBACK_FAILED
		elif fault in ["unread", "underflow", "expired"]:
			expected = Types.Code.SNAPSHOT_FAILED
		elif fault == "wrong state":
			expected = Types.Code.DESYNC
		context.equal(player.restore_before(8), expected, fault + " restore validates callback and exact snapshot")
		context.equal(game.retained_reader.status(), Reader.Code.EXPIRED_VIEW, fault + " reader expired after callback")
		if expected != Types.Code.OK:
			context.equal(player.failure_frame(), 6, fault + " reports attempted checkpoint frame")
			context.equal(player.step(), expected, fault + " failure stops playback")
			context.equal(player.restore_before(0), expected, fault + " restore cannot erase failure")
		else:
			context.equal(player.current_frame(), 6, fault + " restored nearest checkpoint")
			context.equal(player.step(), Types.Code.OK, fault + " restored frame continues normally")
		if fault == "reentry":
			context.equal(game.reentry_codes, [Types.Code.BUSY, Types.Code.BUSY, Types.Code.BUSY, Types.Code.BUSY], "restore guard covers callbacks")
		context.state(game.game.frame, game.game.canonical_bytes())


func _checkpoint_callbacks(context: RefCounted) -> void:
	var replay: RefCounted = Fixture.recording(12)
	replay._flags.fill(0)
	for cache: bool in [false, true]:
		for fault: String in ["none", "save reentry", "large checksum"]:
			var game: FaultGame = FaultGame.new()
			game.fault = fault
			var player: Player = Player.new()
			game.owner = weakref(player)
			context.equal(player.configure(replay, game, Simulation.SNAPSHOT_BYTES, 3 if cache else 0, 2 if cache else 0), Types.Code.OK, "configure missing checksums")
			context.equal(player.step(), Types.Code.DESYNC if cache and fault == "large checksum" else Types.Code.OK, "checkpoint callback result validated")
			context.equal(game.save_calls, 1 if cache else 0, "ordinary playback does not add snapshot callbacks")
			if cache and fault == "save reentry":
				context.equal(game.reentry_codes, [Types.Code.BUSY, Types.Code.BUSY, Types.Code.BUSY, Types.Code.BUSY], "checkpoint save guards all player mutations")
			if cache and fault == "large checksum":
				context.equal(player.failure_frame(), 0, "unbounded callback checksum stops before simulation")
				context.equal(player.current_frame(), 0, "invalid checksum does not advance")


# Value: protects=visible controls jump between retained verified boundaries; fails_when=controls seek fabricated or stale checkpoints; why_new=Go requires a typed frame; seam=none
func _checkpoint_controls(context: RefCounted) -> void:
	var node: Node2D = Fixture.Scene.instantiate()
	node._ready()
	context.equal(node.viewer.open_bytes(Fixture.recording(900).to_bytes()), true, "checkpoint recording imports")
	node._refresh()
	var previous: Button = Fixture._button(node, "Previous checkpoint")
	var following: Button = Fixture._button(node, "Next checkpoint")
	context.equal(previous != null and following != null, true, "scene supplies checkpoint controls")
	if previous == null or following == null:
		node._exit_tree()
		node.free()
		return
	context.equal([previous.disabled, following.disabled], [true, true], "no validated checkpoints before playback")
	node.viewer.seek(900)
	while node.viewer.is_seeking():
		node._physics_process(0.0)
	context.equal([previous.disabled, following.disabled], [false, true], "completed playback can revisit its preceding checkpoint")
	previous.pressed.emit()
	context.equal(node.viewer.current_frame(), 600, "previous selects the nearest earlier cached boundary")
	context.equal(node.viewer.is_seeking(), false, "cached navigation finishes immediately")
	context.equal(node.viewer.is_playing, false, "checkpoint inspection is paused")
	previous.pressed.emit()
	context.equal(node.viewer.current_frame(), 300, "previous moves to the next older retained boundary")
	context.equal(following.disabled, false, "backward inspection enables a retained forward checkpoint")
	following.pressed.emit()
	context.equal(node.viewer.current_frame(), 600, "next reuses a validated future checkpoint")
	var expected: Simulation = Simulation.new()
	var replay: RefCounted = Fixture.recording(900)
	for frame: int in 600:
		expected.simulate_frame(frame, replay.inputs(frame))
	context.bytes_equal(node.viewer.game.canonical_bytes(), expected.canonical_bytes(), 600, "checkpoint button restores canonical game state")
	context.equal(node.viewer.checked_checksum_count(), 900, "checkpoint navigation does not duplicate validation coverage")
	node.viewer.seek(750)
	node._refresh()
	context.equal([previous.disabled, following.disabled], [true, true], "checkpoint controls cannot interrupt a running seek")
	node.viewer.cancel_seek()
	node._restart()
	context.equal([previous.disabled, following.disabled], [true, true], "restart removes old checkpoint targets")
	var corrupt: RefCounted = Fixture.recording(900)
	corrupt._inputs[14] ^= 1
	node.viewer.open_bytes(corrupt.to_bytes())
	node.viewer.seek(900)
	node._physics_process(0.0)
	context.equal(node.viewer.current_frame(), 7, "failed recording preserves the divergence boundary")
	context.equal([previous.disabled, following.disabled], [true, true], "failed playback cannot jump past its failure")
	previous.pressed.emit()
	following.pressed.emit()
	context.equal(node.viewer.current_frame(), 7, "disabled actions preserve failure even when called directly")
	node._exit_tree()
	node.free()
