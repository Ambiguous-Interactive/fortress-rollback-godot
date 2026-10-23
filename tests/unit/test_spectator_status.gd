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
	return PackedStringArray(["rows", "wire_status", "host_drop"])


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
			session.receive_host_frame(12, Fixture.new()._row(12), PackedByteArray([1, 3])).code,
			Code.INPUT_ALREADY_SUBMITTED, "same bytes with conflicting status are refused"
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
		"465247530201020001000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1fd2deccf9f3deb3d06e7cc546fabec43b04030201731411334fcded23e53b538704c81eba0001"
	).hex_decode()
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
