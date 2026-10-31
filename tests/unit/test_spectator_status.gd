extends RefCounted

# Value: protects=status-sensitive spectator history; fails_when=disconnected becomes confirmed; why_new=old spectators ignore status; seam=none
const Fixture = preload("res://tests/unit/test_spectator_session.gd")
const WireFixture = preload("res://tests/unit/test_spectator_stream.gd")
const GameFixture = preload("res://tests/unit/test_driver.gd")
const Spectator = preload("res://addons/fortress_rollback/core/spectator_session.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Stream = preload("res://addons/fortress_rollback/core/spectator_stream.gd")
const Publisher = preload("res://addons/fortress_rollback/core/spectator_publisher.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Code = Types.Code


class Game:
	extends GameFixture.Game

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		trace.append("advance:%d" % frame)
		for player: int in range(inputs.size().value):
			var input: Types.InputResult = inputs.read(player)
			value = (value * 17 + input.bytes[0] + input.status * 31 + frame) % 1000000007
		return true


func cases() -> PackedStringArray:
	return PackedStringArray(["rows", "wire_status", "host_drop", "playback_observation"])


func run_case(name: String, context: RefCounted) -> void:
	call("_" + name, context)
	context.finish()


func _rows(context: RefCounted) -> void:
	for expert: bool in [false, true]:
		var config: RefCounted = Fixture.new()._config()
		config.replay_max_frames = 12
		var session: RefCounted = Spectator.new()
		context.equal(session.configure(config), Code.OK, "status viewer")
		var game: Game = Game.new()
		var driver: RefCounted = Driver.new(session, game)
		var expected: int = 0
		for frame: int in range(12):
			var row: Array[PackedByteArray] = Fixture.new()._row(frame)
			var statuses: PackedByteArray = PackedByteArray([Queue.Status.CONFIRMED, Queue.Status.DISCONNECTED if frame > 0 else Queue.Status.CONFIRMED])
			context.equal(session.receive_host_frame(frame, row, statuses).code, Code.OK, "atomic status row")
			statuses[1] = Queue.Status.PREDICTED
			if expert:
				var advance: Types.Result = session.begin_advance()
				context.equal(advance.code, Code.READY, "expert ready")
				var request: Types.Request = advance.batch.next_request()
				context.equal(request.kind, Types.Kind.ADVANCE, "expert advance")
				context.equal(session.complete_request(request.batch_id, request.request_id, game.simulate_frame(frame, request.inputs)).code, Code.OK, "expert applies status")
			else:
				context.equal(driver.step(frame, _empty()).code, Code.OK, "driver applies status")
			for player: int in range(2):
				var status: int = Queue.Status.DISCONNECTED if player == 1 and frame > 0 else Queue.Status.CONFIRMED
				expected = (expected * 17 + row[player][0] + status * 31 + frame) % 1000000007
			context.equal(game.value, expected, "independent canonical status state")
			context.equal(session.confirmed_inputs(frame).read(1).status, Queue.Status.DISCONNECTED if frame > 0 else Queue.Status.CONFIRMED, "re-export host status")
			context.equal(session.replay().inputs(frame).read(1).status, 3 if frame > 0 else 1, "record the same statuses")
		context.equal(session.receive_host_frame(12, Fixture.new()._row(12), PackedByteArray([1, 2])).code, Code.INVALID_CONFIGURATION, "prediction is not a final host status")
		context.equal(session.receive_host_frame(12, Fixture.new()._row(12), PackedByteArray([1])).code, Code.INVALID_CONFIGURATION, "partial statuses cannot imply defaults")
		context.equal(session.host_frontier(), 11, "invalid status is atomic")
		context.equal(session.receive_host_frame(12, Fixture.new()._row(12)).code, Code.OK, "byte-only call defaults to confirmed")
		context.equal(
			session.receive_host_frame(12, Fixture.new()._row(12), PackedByteArray([1, 3])).code, Code.INPUT_ALREADY_SUBMITTED, "same bytes with conflicting status are refused"
		)
		context.equal(driver.step(12, _empty()).code, Code.OK, "default row still playable")
		context.equal(session.confirmed_inputs(12).read(1).status, Queue.Status.CONFIRMED, "old API keeps confirmed default")
		context.equal(session.confirmed_inputs(0), null, "wrapped status tags cannot decorate stale input")


func _wire_status(context: RefCounted) -> void:
	var wire: RefCounted = WireFixture.new()
	var stream: RefCounted = wire._stream(context)
	var row: Array[PackedByteArray] = Fixture.new()._row(0)
	var packet: PackedByteArray = stream.encode_row(0, row, PackedByteArray([1, 3]))
	context.equal(
		stream.encode_row(16909060, row, PackedByteArray([1, 3])).hex_encode(),
		"465247530301020001000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1fd2deccf9f3deb3d06e7cc546fabec43b040302019d9c42b084659941b3c44ddf035e381300010103",
		"independent Python struct and HMAC v3 status golden"
	)
	var legacy: PackedByteArray = (
		("465247530201020001000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1fd2deccf9f3deb3d06e7cc546fabec43b04030201731411334fcded23e53b538704c81eba0001")
		. hex_decode()
	)
	context.equal(stream.receive_packet(legacy, 0), Code.PROTOCOL_FAILED, "frozen v2 byte-only packet is incompatible")
	var old: RefCounted = Stream.new()
	context.equal(old.configure(Fixture.new()._config(), wire._identity(), wire._key(), wire._digest(), 0, 100, 128), Code.OK, "fresh viewer for v2 startup")
	context.equal(old.receive_packet(wire._legacy_offer(2), 0), Code.UNSUPPORTED, "v2 offer fails before first row")
	context.equal(wire._publisher(context).receive_accept(wire._legacy_accept(2)), Code.UNSUPPORTED, "v2 answer cannot downgrade publisher")
	context.equal(packet.size(), 84, "v3 rows add exactly one status byte per player")
	context.equal(packet.slice(80), PackedByteArray([0, 1, 1, 3]), "row bytes then statuses")
	for invalid: int in [0, 2, 4, 255]:
		context.equal(stream.encode_row(0, row, PackedByteArray([1, invalid])).is_empty(), true, "writer refuses non-final statuses")
		var malformed: PackedByteArray = packet.duplicate()
		malformed[83] = invalid
		malformed = Stream.authenticate(wire._unsigned(malformed), wire._key())
		context.equal(stream.receive_packet(malformed, 90), Code.INVALID_CONFIGURATION, "authenticated invalid status refused")
		context.equal(stream.playback_session().host_frontier(), -1, "malformed status changes no input")
	var forged: PackedByteArray = packet.duplicate()
	forged[83] = 1
	context.equal(stream.receive_packet(forged, 90), Code.PROTOCOL_FAILED, "statuses share the packet tag")
	context.equal(stream.receive_packet(packet, 1), Code.OK, "refused status consumes no liveness clock")
	context.equal(stream.receive_packet(stream.encode_row(0, row, PackedByteArray([1, 1])), 2), Code.PROTOCOL_FAILED, "conflicting duplicate status terminates stream")
	var narrow: RefCounted = Fixture.new()._config()
	narrow.input_width = 5
	narrow.neutral_input.resize(5)
	context.equal(Stream.new().configure(narrow, wire._identity(), wire._key(), wire._digest(narrow), 0, 100, 91), Code.INVALID_CONFIGURATION, "packet cap includes statuses")


func _host_drop(context: RefCounted) -> void:
	var config: RefCounted = Fixture.new().host_config()
	config.local_players = PackedInt32Array([0])
	config.max_prediction_frames = 3
	config.history_slots = 4
	var host: RefCounted = Session.new()
	context.equal(host.configure(config), Code.OK, "predicting player host")
	var host_game: Game = Game.new()
	var host_driver: RefCounted = Driver.new(host, host_game)
	var wire: RefCounted = WireFixture.new()
	var stream: RefCounted = wire._stream(context)
	var viewer: RefCounted = stream.playback_session()
	context.equal(viewer.set_playback(1, 1, 3), Code.OK, "delayed catchup viewer")
	var viewer_game: Game = Game.new()
	var viewer_driver: RefCounted = Driver.new(viewer, viewer_game)
	var publisher: RefCounted = Publisher.new()
	context.equal(publisher.configure(host, wire._identity(), wire._key(), wire._digest(), 128), Code.OK, "host publisher")
	context.equal(publisher.receive_accept(stream.encode_accept()), Code.OK, "v3 publisher agreement")
	context.equal(host.receive_input(1, 0, PackedByteArray([7])).code, Code.OK, "one actual remote input")
	for frame: int in range(3):
		var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, frame, PackedByteArray([frame + 1]))]
		context.equal(host_driver.step(frame, samples).code, Code.OK, "host predicts remote tail")
	context.equal(host.freeze_player(1, 0), Code.OK, "drop repairs predicted status tail")
	context.equal(host_driver.recover(3).code, Code.OK, "recover exact host boundary")
	context.equal(host.confirmed_inputs(1).read(1).status, Queue.Status.DISCONNECTED, "corrected host exports status")
	var held: Array[PackedByteArray] = []
	for frame: int in range(3):
		var packet: PackedByteArray = publisher.prepare_packet().bytes
		held.append(packet)
		context.equal(publisher.prepare_packet().bytes, packet, "pressure retains exact status packet")
		context.equal(publisher.acknowledge_packet(packet), Code.OK, "transport accepts status row")
	for index: int in [2, 0, 1]:
		context.equal(stream.receive_packet(held[index], 4), Code.OK, "reordered dropped host rows")
	context.equal(publisher.finish_host(), Code.OK, "host final boundary")
	context.equal(stream.receive_packet(publisher.prepare_packet().bytes, 5), Code.OK, "END releases delayed tail")
	var expected: int = 0
	for frame: int in range(3):
		context.equal(viewer_driver.step(frame, _empty()).code, Code.OK, "catchup through dropped match")
		expected = (expected * 17 + frame + 1 + 31 + frame) % 1000000007
		expected = (expected * 17 + 7 + (1 if frame == 0 else 3) * 31 + frame) % 1000000007
		context.equal(viewer_game.value, expected, "original status-sensitive history")
	context.equal(host_game.value, expected, "host repair and spectator share canonical state")


func _empty() -> Array[Driver.LocalInput]:
	return []


# Value: protects=owned viewer buffering and final-tail observations; fails_when=gaps look playable or stopped tails complete;
# why_new=policy tests inspect pacing without a structured client observation; seam=none
func _playback_observation(context: RefCounted) -> void:
	_gap_observation(context)
	for terminal: int in [Code.TERMINATED, Code.PROTOCOL_FAILED]:
		var viewer: Spectator = Spectator.new()
		context.equal(viewer.playback_status().code, Code.NOT_CONFIGURED, "unconfigured observation reports readiness")
		context.equal(viewer.playback_status().state, Spectator.PlaybackState.STOPPED, "unconfigured viewer cannot play")
		viewer.configure(Fixture.new()._config())
		context.equal(viewer.set_playback(2, 1, 3), Code.OK, "delay separates received and playable prefixes")
		_check_observation(context, viewer, Spectator.PlaybackState.WAITING_FOR_INPUT, 0, 0, 0)
		viewer.receive_host_frame(1, Fixture.new()._row(1))
		_check_observation(context, viewer, Spectator.PlaybackState.WAITING_FOR_INPUT, 0, 0, 0)
		viewer.receive_host_frame(0, Fixture.new()._row(0))
		_check_observation(context, viewer, Spectator.PlaybackState.DELAYED, 2, 0, 0)
		viewer.receive_host_frame(2, Fixture.new()._row(2))
		_check_observation(context, viewer, Spectator.PlaybackState.PLAYABLE, 3, 1, 1)
		var initial: Dictionary = viewer.playback_status()
		initial.state = Spectator.PlaybackState.COMPLETE
		initial.buffered_frames = 999
		context.equal(viewer.playback_status().buffered_frames, 3, "caller mutations cannot change retained rows")
		var driver: Driver = Driver.new(viewer, GameFixture.Game.new())
		context.equal(driver.step(0, _empty()).code, Code.OK, "play exactly the delay-eligible row")
		_check_observation(context, viewer, Spectator.PlaybackState.DELAYED, 2, 0, 0)
		context.equal(initial.current_frame, 0, "prior observation remains a snapshot after playback")
		context.equal(viewer.finish_host(), Code.OK, "closed input releases the paused tail")
		_check_observation(context, viewer, Spectator.PlaybackState.FINAL_TAIL, 2, 2, 2)
		context.equal(viewer.playback_status().input_closed, true, "closure is independent of playback completion")
		context.equal(viewer.is_complete(), false, "a paused closed tail is not complete")
		for frame: int in [1, 2]:
			context.equal(driver.step(frame, _empty()).code, Code.OK, "consume original final row")
		_check_observation(context, viewer, Spectator.PlaybackState.FINAL_TAIL, 0, 0, 1)
		viewer.terminate(terminal)
		_check_observation(context, viewer, Spectator.PlaybackState.STOPPED, 0, 0, 0)
		context.equal(viewer.playback_status().reason, terminal, "cancellation retains its exact cause")
		context.equal(viewer.playback_status().code, Code.TERMINATED, "terminal readiness is distinct from terminal cause")
		context.equal(viewer.configure(Fixture.new()._config()), Code.OK, "replace stopped lifetime")
		_check_observation(context, viewer, Spectator.PlaybackState.WAITING_FOR_INPUT, 0, 0, 0)
		context.equal(viewer.playback_status().input_closed, false, "replacement clears prior closure")
		context.equal(viewer.playback_status().reason, Code.OK, "replacement clears prior failure")
		viewer.finish_host()
		context.equal(driver.step(3, _empty()).code, Code.TERMINATED, "empty clean stream completes by ordinary service")
		_check_observation(context, viewer, Spectator.PlaybackState.COMPLETE, 0, 0, 0)
		context.equal(viewer.playback_status().reason, Code.TERMINATED, "completion preserves ordinary terminal reason")
		var invalid: RefCounted = Fixture.new()._config()
		invalid.queue_capacity = 0
		context.equal(viewer.configure(invalid), Code.INVALID_CONFIGURATION, "invalid replacement rejected")
		_check_observation(context, viewer, Spectator.PlaybackState.COMPLETE, 0, 0, 0)
	var stopped: Spectator = Spectator.new()
	stopped.configure(Fixture.new()._config())
	stopped.receive_host_frame(0, Fixture.new()._row(0))
	stopped.terminate(Code.PROTOCOL_FAILED)
	_check_observation(context, stopped, Spectator.PlaybackState.STOPPED, 1, 0, 0)
	var busy: Spectator = Spectator.new()
	busy.configure(Fixture.new()._config())
	busy.receive_host_frame(0, Fixture.new()._row(0))
	var batch: Types.Result = busy.begin_advance()
	context.equal(batch.code, Code.READY, "expert request owns current playback")
	context.equal(busy.playback_status().code, Code.BUSY, "observation exposes active request readiness")
	_check_observation(context, busy, Spectator.PlaybackState.PLAYABLE, 1, 1, 1)
	context.equal(busy.drain_events().size(), 0, "observation cannot release the active batch or its events")
	busy.terminate(Code.CALLBACK_FAILED)
	context.equal(busy.drain_events().size(), 3, "observation did not consume lifecycle events")


func _check_observation(context: RefCounted, viewer: Spectator, state: int, buffered: int, playable: int, steps: int) -> void:
	var observed: Dictionary = viewer.playback_status()
	context.equal(observed.get("capacity_frames", -1), viewer._host_tags.size(), "observation names bounded row capacity")
	context.equal(observed.get("available_frames", -1), viewer._host_tags.size() - observed.pending_frames, "only unplayed rows occupy receive capacity")
	context.equal(observed.state, state, "playback state separates input wait, delay, tail and termination")
	context.equal(observed.buffered_frames, buffered, "only contiguous rows count as buffered playback")
	context.equal(observed.playable_frames, playable, "playable count applies delay until host closure")
	context.equal(observed.recommended_steps, steps, "observation preserves bounded service advice")
	context.equal(observed.current_frame, viewer.status().current_frame, "observed current boundary agrees with shared session")
	context.equal(observed.host_frontier, viewer.host_frontier(), "observation preserves original host frontier")


# Value: protects=received rows beyond a gap remain visible; fails_when=waiting hides retained future input;
# why_new=contiguous buffering observations deliberately exclude future rows; seam=none
func _gap_observation(context: RefCounted) -> void:
	for start: int in [0, 8]:
		var viewer: Spectator = Spectator.new()
		context.equal(viewer.playback_status().get("pending_frames", -1), 0, "unconfigured viewer retains no pending row")
		viewer.configure(Fixture.new()._config())
		var driver: Driver = Driver.new(viewer, GameFixture.Game.new())
		for frame: int in start:
			viewer.receive_host_frame(frame, Fixture.new()._row(frame))
			context.equal(driver.step(frame, _empty()).code, Code.OK, "play prefix through ring reuse")
		for offset: int in [1, 3]:
			context.equal(viewer.receive_host_frame(start + offset, Fixture.new()._row(start + offset)).code, Code.OK, "retain later host row")
		var observed: Dictionary = viewer.playback_status()
		context.equal(observed.get("pending_frames", -1), 2, "pending count includes accepted future rows")
		context.equal(observed.get("available_frames", -1), Fixture.new()._config().queue_capacity - 2, "future rows occupy capacity even before their gap fills")
		context.equal(observed.get("missing_frame", -2), start, "first missing row explains input wait")
		context.equal(observed.buffered_frames, 0, "future rows are not a contiguous playable prefix")
		context.equal(viewer.receive_host_frame(start + 1, Fixture.new()._row(start + 1)).code, Code.OK, "duplicate future receipt remains idempotent")
		context.equal(viewer.playback_status().get("pending_frames", -1), 2, "duplicates do not inflate pending count")
		var changed: Dictionary = viewer.playback_status()
		changed.pending_frames = 999
		changed.missing_frame = 999
		context.equal(viewer.playback_status().get("pending_frames", -1), 2, "caller mutation cannot alter pending observations")
		context.equal(viewer.playback_status().get("missing_frame", -2), start, "caller mutation cannot alter gap observations")
		context.equal(viewer.receive_host_frame(start + 5, Fixture.new()._row(start + 5)).code, Code.NETWORK_BACKPRESSURE, "out-of-window future row is refused")
		context.equal(viewer.playback_status().get("pending_frames", -1), 2, "refusal cannot fabricate pending history")
		viewer.receive_host_frame(start, Fixture.new()._row(start))
		context.equal(viewer.playback_status().get("missing_frame", -2), start + 2, "filling first gap reveals the next gap")
		context.equal(viewer.playback_status().get("pending_frames", -1), 3, "contiguous and future accepted rows both remain pending")
		for frame: int in range(start, start + 2):
			context.equal(driver.step(frame, _empty()).code, Code.OK, "play prefix up to next gap")
		context.equal(viewer.playback_status().get("pending_frames", -1), 1, "played rows leave pending count without losing future row")
		context.equal(observed.get("pending_frames", -1), 2, "prior gap observation remains owned")
		viewer.receive_host_frame(start + 2, Fixture.new()._row(start + 2))
		context.equal(viewer.playback_status().get("missing_frame", -2), -1, "complete prefix reports no known gap")
		context.equal(viewer.finish_host(), Code.OK, "complete tail closes")
		context.equal(viewer.playback_status().get("pending_frames", -1), 2, "clean closure preserves unplayed rows")
		viewer.terminate(Code.PROTOCOL_FAILED)
		context.equal(viewer.playback_status().get("pending_frames", -1), 2, "stopped observation preserves retained input evidence")
		viewer.configure(Fixture.new()._config())
		context.equal(viewer.playback_status().get("pending_frames", -1), 0, "replacement clears pending input")
		context.equal(viewer.playback_status().get("missing_frame", -2), -1, "replacement has no known gap")

	var stopped: Spectator = Spectator.new()
	stopped.configure(Fixture.new()._config())
	stopped.receive_host_frame(1, Fixture.new()._row(1))
	stopped.terminate(Code.PROTOCOL_FAILED)
	context.equal(stopped.playback_status().get("pending_frames", -1), 1, "stopped viewer retains future-row observation")
	context.equal(stopped.playback_status().get("missing_frame", -2), 0, "stopped gap evidence does not disappear")
	context.equal(stopped.playback_status().playable_frames, 0, "retained terminal gap never grants playback")
