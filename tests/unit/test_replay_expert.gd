extends RefCounted

# Value: protects=expert and callback replay share ordered validation and canonical history; fails_when=requests skip, mutate or bypass failed saves;
# why_new=replay tests dispatch only game callbacks; seam=none
const Player = preload("res://addons/fortress_rollback/core/replay_player.gd")
const Fixture = preload("res://tests/unit/test_replay_viewer.gd")
const Replay = preload("res://addons/fortress_rollback/core/replay.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Reader = preload("res://addons/fortress_rollback/core/snapshot_reader.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Writer = preload("res://addons/fortress_rollback/core/snapshot_writer.gd")


class ReentryGame:
	extends Simulation
	var player: WeakRef
	var terminate_in: String = ""
	var observed: Array[int] = []
	var expired_views: Array[bool] = []
	var corrupt_terminal_result: bool = false

	func _probe(kind: String, view: RefCounted) -> void:
		var owner: RefCounted = player.get_ref()
		if terminate_in == kind:
			owner.terminate()
			expired_views.append(view.player_count() == -1 if kind == "advance" else view.status() == Writer.Code.EXPIRED_VIEW)
		observed.append(owner.begin_advance().code)
		observed.append(owner.complete_request(0, 0, true).code)
		observed.append(owner.configure_expert(Fixture.recording(), 0))
		observed.append(owner.step())
		observed.append(owner.validate_current_frame())

	func save_state(frame: int, writer: Writer) -> Driver.SaveResult:
		var saved: Driver.SaveResult = super.save_state(frame, writer)
		_probe("save", writer)
		if corrupt_terminal_result and terminate_in == "save":
			saved.checksum.resize(15)
		return saved

	func load_state(frame: int, reader: Reader) -> bool:
		var loaded: bool = super.load_state(frame, reader)
		_probe("load", reader)
		return false if corrupt_terminal_result and terminate_in == "load" else loaded

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		_probe("advance", inputs)
		return super.simulate_frame(frame, inputs)


func cases() -> PackedStringArray:
	return PackedStringArray(["canonical_parity", "request_lifetime", "save_failures", "callback_guards", "paused_termination", "paused_termination_bad_result"])


func run_case(name: String, context: RefCounted) -> void:
	var player: Player = Player.new()
	context.equal(player.has_method("configure_expert"), true, "expert replay uses the shared player")
	if player.has_method("configure_expert"):
		match name:
			"canonical_parity":
				_canonical_parity(context)
			"request_lifetime":
				_request_lifetime(context)
			"save_failures":
				_save_failures(context)
			"callback_guards":
				_callback_guards(context)
			"paused_termination", "paused_termination_bad_result":
				_paused_termination(context, name == "paused_termination_bad_result")
	context.finish()


func _canonical_parity(context: RefCounted) -> void:
	for frames: int in [0, 1, 13]:
		for coverage: String in ["full", "sparse", "none", "input only"]:
			var replay: Replay = Fixture.recording(frames)
			for frame: int in frames:
				if coverage == "none" or (coverage == "sparse" and frame % 3 != 0):
					replay._flags[frame] = 0
			var limit: int = 0 if coverage == "input only" else Simulation.SNAPSHOT_BYTES
			var expert: Player = Player.new()
			var callback: Player = Player.new()
			var game: Simulation = Simulation.new()
			var control: Simulation = Simulation.new()
			context.equal(expert.call("configure_expert", replay, limit), Types.Code.OK, "expert configures")
			context.equal(callback.configure(replay, control, limit), Types.Code.OK, "callback control configures")
			context.equal(expert.step(), Types.Code.UNSUPPORTED, "expert mode requires explicit dispatch")
			context.equal(expert.validate_current_frame(), Types.Code.UNSUPPORTED, "expert mode refuses callback validation")
			for frame: int in frames:
				var result: Types.Result = expert.call("begin_advance")
				context.equal(result.code, Types.Code.READY, "opens one ordered batch")
				var kinds: Array[int] = []
				while true:
					var request: Types.Request = result.batch.next_request()
					if request == null:
						break
					kinds.append(request.kind)
					context.equal(request.frame, frame, "pre-input frame convention")
					var checksum: PackedByteArray = PackedByteArray()
					if request.kind == Types.Kind.SAVE:
						checksum = game.save_state(frame, request.writer).checksum
					else:
						for slot: int in 2:
							context.equal(request.inputs.read(slot).status, 1, "replay inputs are confirmed")
						context.equal(game.simulate_frame(frame, request.inputs), true, "expert simulates")
					context.equal(expert.call("complete_request", request.batch_id, request.request_id, true, checksum).code, Types.Code.OK, "ordered acknowledgement")
				context.equal(
					kinds, [Types.Kind.SAVE, Types.Kind.ADVANCE] if limit > 0 and not replay.checksum(frame).is_empty() else [Types.Kind.ADVANCE], "same sparse validation policy"
				)
				context.equal(callback.step(), Types.Code.OK, "callback follows identical path")
				context.bytes_equal(game.canonical_bytes(), control.canonical_bytes(), frame + 1, "expert and callback canonical boundary")
			context.equal(expert.checked_checksum_count(), callback.checked_checksum_count(), "same checksum coverage")
			context.equal(expert.is_complete(), true, "empty and final histories complete")
			context.equal(expert.call("begin_advance").code, Types.Code.FRAME_EXHAUSTED, "no extra terminal input")
			context.state(frames, game.canonical_bytes())


func _request_lifetime(context: RefCounted) -> void:
	var player: Player = Player.new()
	context.equal(player.call("begin_advance").code, Types.Code.NOT_CONFIGURED, "unconfigured expert refuses")
	player.call("configure_expert", Fixture.recording(2), Simulation.SNAPSHOT_BYTES)
	var result: Types.Result = player.call("begin_advance")
	var request: Types.Request = result.batch.next_request()
	var batch_id: int = request.batch_id
	var request_id: int = request.request_id
	var writer: Writer = request.writer
	context.equal(result.batch.next_request(), request, "unacknowledged request remains active")
	context.equal(player.call("begin_advance").code, Types.Code.BUSY, "incomplete batch owns playback")
	context.equal(player.call("configure_expert", Fixture.recording(1), 0), Types.Code.BUSY, "cannot replace active expert batch")
	context.equal(player.configure(Fixture.recording(1), Simulation.new()), Types.Code.BUSY, "cannot replace batch with callback playback")
	context.equal(player.call("complete_request", batch_id, request_id + 1, true).code, Types.Code.STALE_REQUEST, "out-of-order completion refused")
	context.equal(writer.status(), Writer.Code.OK, "misuse preserves live writer")
	var game: Simulation = Simulation.new()
	var checksum: PackedByteArray = game.save_state(0, writer).checksum
	request.kind = Types.Kind.ADVANCE
	request.frame = 100
	context.equal(player.call("complete_request", batch_id, request_id, true, checksum).code, Types.Code.OK, "public metadata cannot change authoritative SAVE")
	context.equal(writer.status(), Writer.Code.EXPIRED_VIEW, "completed writer expires")
	request = result.batch.next_request()
	var inputs: Types.FrameInputs = request.inputs
	context.equal(player.call("complete_request", batch_id, request_id, true).code, Types.Code.STALE_REQUEST, "duplicate save acknowledgement refused")
	context.equal(inputs.player_count(), 2, "stale completion preserves advance view")
	context.equal(player.current_frame(), 0, "SAVE does not commit a frame")
	game.simulate_frame(0, inputs)
	context.equal(player.call("complete_request", request.batch_id, request.request_id, true).code, Types.Code.OK, "advance completes")
	context.equal(inputs.player_count(), -1, "completed inputs expire")
	context.equal(player.current_frame(), 1, "only completed advance commits")
	context.equal(result.batch.next_request(), null, "completed batch cannot publish more")
	context.equal(player.call("configure_expert", Fixture.recording(1), -1), Types.Code.INVALID_CONFIGURATION, "invalid new configuration preserves position")
	context.equal(player.current_frame(), 1, "invalid configuration preserves playback")
	context.equal(player.call("configure_expert", Fixture.recording(1), 0), Types.Code.OK, "new lifetime")
	var newer: Types.Result = player.call("begin_advance")
	request = newer.batch.next_request()
	context.equal(request.batch_id > batch_id, true, "batch identities survive reconfiguration")
	context.equal(result.batch.next_request(), null, "stale batch cannot borrow new request")
	context.equal(player.call("complete_request", batch_id, request_id, true).code, Types.Code.STALE_REQUEST, "old identity rejected")
	context.equal(player.call("complete_request", request.batch_id, request.request_id, false).code, Types.Code.CALLBACK_FAILED, "failed advance terminates")
	context.equal(request.inputs.player_count(), -1, "failed advance expires its view")
	context.equal(player.failure_frame(), 0, "failure identifies uncommitted input")
	context.equal(player.call("begin_advance").code, Types.Code.CALLBACK_FAILED, "failure is latched")
	context.equal(player.call("configure_expert", Fixture.recording(1), 0), Types.Code.OK, "restart after failure")
	var abandoned: Types.Result = player.call("begin_advance")
	var retained: Types.FrameInputs = abandoned.batch.next_request().inputs
	player.call("terminate")
	context.equal(retained.player_count(), -1, "explicit termination releases abandoned inputs")
	context.equal(abandoned.batch.next_request(), null, "terminated batch cannot publish requests")
	context.equal(player.call("begin_advance").code, Types.Code.TERMINATED, "explicit termination is latched")
	context.equal(player.call("configure_expert", Fixture.recording(1), 0), Types.Code.OK, "abandoned batch can be replaced after termination")

	context.state(game.frame, game.canonical_bytes())


func _save_failures(context: RefCounted) -> void:
	for fault: String in ["none", "first mismatch", "final mismatch", "overflow", "expired", "short checksum", "callback"]:
		var replay: Replay = Fixture.recording(3)
		if fault in ["first mismatch", "final mismatch"]:
			replay._checksums[(2 if fault == "final mismatch" else 0) * Replay.CHECKSUM_BYTES] ^= 1
		var player: Player = Player.new()
		player.call("configure_expert", replay, Simulation.SNAPSHOT_BYTES)
		var game: Simulation = Simulation.new()
		var code: int = Types.Code.OK
		for frame: int in 3:
			var batch: Types.Result = player.call("begin_advance")
			while true:
				var request: Types.Request = batch.batch.next_request()
				if request == null:
					break
				var checksum: PackedByteArray = PackedByteArray()
				if request.kind == Types.Kind.SAVE:
					checksum = game.save_state(frame, request.writer).checksum
					if fault == "overflow":
						request.writer.write_bytes(PackedByteArray([0]))
					elif fault == "expired":
						request.writer._expire()
					elif fault == "short checksum":
						checksum.resize(15)
				else:
					game.simulate_frame(frame, request.inputs)
				code = player.call("complete_request", request.batch_id, request.request_id, fault != "callback", checksum).code
				if code != Types.Code.OK:
					break
			if code != Types.Code.OK:
				break
		var expected: int = Types.Code.OK
		if fault.contains("mismatch") or fault == "short checksum":
			expected = Types.Code.DESYNC
		elif fault in ["overflow", "expired"]:
			expected = Types.Code.SNAPSHOT_FAILED
		elif fault == "callback":
			expected = Types.Code.CALLBACK_FAILED
		context.equal(code, expected, fault + " enforces shared validation")
		context.equal(player.current_frame(), 3 if fault == "none" else (2 if fault == "final mismatch" else 0), "failure stops before mismatching input")
		context.equal(player.failure_expected_checksum().is_empty(), not fault.contains("mismatch"), "only comparison mismatch publishes checksum evidence")
		context.equal(player.is_complete(), fault == "none", "failed final checksum cannot appear complete")
		context.state(game.frame, game.canonical_bytes())


func _callback_guards(context: RefCounted) -> void:
	for terminal: String in ["", "save", "advance"]:
		var player: Player = Player.new()
		var game: ReentryGame = ReentryGame.new()
		game.player = weakref(player)
		game.terminate_in = terminal
		context.equal(player.configure(Fixture.recording(1), game, Simulation.SNAPSHOT_BYTES), Types.Code.OK, "callback control configures")
		context.equal(player.step(), Types.Code.OK if terminal.is_empty() else Types.Code.TERMINATED, "callback termination remains authoritative")
		context.equal(player.current_frame(), 1 if terminal.is_empty() else 0, "termination never commits an input")
		for code: int in game.observed:
			context.equal(code, Types.Code.BUSY, "callback guard survives batch teardown")
		context.equal(game.observed.size(), 5 if terminal == "save" else 10, "guard exercised in every dispatched callback")
		context.equal(player.configure(Fixture.recording(1), Simulation.new()), Types.Code.OK, "callback returns release guard")
		context.state(game.frame, game.canonical_bytes())


# Value: protects=paused termination expires live views and preserves its first failure; fails_when=callback output overrides teardown; why_new=step owns batch views; seam=none
func _paused_termination(context: RefCounted, corrupt_result: bool = false) -> void:
	for operation: String in ["validate", "restore load", "restore save"]:
		var player: Player = Player.new()
		var game: ReentryGame = ReentryGame.new()
		game.player = weakref(player)
		context.equal(player.configure(Fixture.recording(12), game, Simulation.SNAPSHOT_BYTES, 3, 3), Types.Code.OK, "cached callback playback configures")
		for frame: int in 8:
			context.equal(player.step(), Types.Code.OK, "healthy cached prefix")
		game.observed.clear()
		game.corrupt_terminal_result = corrupt_result
		game.terminate_in = "load" if operation == "restore load" else "save"
		var checked: int = player.checked_checksum_count()
		var code: int = player.validate_current_frame() if operation == "validate" else player.restore_before(7)
		context.equal(code, Types.Code.TERMINATED, operation + " cannot report success after callback termination")
		context.equal(player.current_frame(), 8, "terminal restore cannot commit a checkpoint frame")
		context.equal(player.failure_frame(), 8, "terminal cause retains its original frame")
		context.equal(game.expired_views, [true], "termination expires callback view before returning to game")
		for observed: int in game.observed:
			context.equal(observed, Types.Code.BUSY, "paused callback retains reentry guard after termination")
		context.equal(player.failure_expected_checksum().is_empty(), true, "terminal callback output cannot publish mismatch evidence")
		context.equal(player.checked_checksum_count(), checked, "termination cannot publish additional checksum coverage")
		context.equal(player.step(), Types.Code.TERMINATED, "terminal cause survives paused operation")
		context.equal(game.observed.size(), 5 if operation in ["validate", "restore load"] else 10, "termination prevents subsequent callbacks")
		context.state(game.frame, game.canonical_bytes())
