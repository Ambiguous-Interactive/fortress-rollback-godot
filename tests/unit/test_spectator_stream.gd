extends RefCounted

# Value: protects=bounded confirmed spectator bytes; fails_when=wire reorder predicts or host loss plays buffered rows; why_new=row tests bypass bytes/time; seam=none
const Stream = preload("res://addons/fortress_rollback/core/spectator_stream.gd")
const Fixture = preload("res://tests/unit/test_spectator_session.gd")
const GameFixture = preload("res://tests/unit/test_driver.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const CODE = Types.Code


class ReentrantGame:
	extends GameFixture.Game
	var stream_ref: WeakRef
	var stream_codes: PackedInt32Array = PackedInt32Array()

	func _reenter() -> void:
		super._reenter()
		var stream: RefCounted = stream_ref.get_ref()
		stream_codes.append(stream.poll(1000))
		stream_codes.append(stream.receive_packet(stream.encode_end(1), 1000))
		stream_codes.append(stream.configure(Fixture.new()._config(), stream._identity, 1000, 100, 50))


func cases() -> PackedStringArray:
	return PackedStringArray(["wire_golden", "byte_delivery", "malformed", "lifetime_and_timeout", "clean_tail", "bounds", "busy"])


func run_case(name: String, context: RefCounted) -> void:
	call("_" + name, context)
	context.finish()


func _identity() -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray()
	for value: int in range(32):
		bytes.append(value)
	return bytes


func _stream(context: RefCounted) -> RefCounted:
	var stream: RefCounted = Stream.new()
	context.equal(stream.configure(Fixture.new()._config(), _identity(), 0, 100, 50), CODE.OK, "bounded stream configured")
	return stream


func _row(frame: int) -> Array[PackedByteArray]:
	return Fixture.new()._row(frame)


func _empty() -> Array[Driver.LocalInput]:
	return []


func _wire_golden(context: RefCounted) -> void:
	var stream: RefCounted = _stream(context)
	context.equal(
		stream.encode_row(16909060, _row(0)).hex_encode(),
		"465247530101020001000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f040302010001",
		"independent little-endian frame, dimensions and identity golden"
	)
	context.equal(stream.encode_end(0).size(), 48, "empty stream has fixed header only")
	var identity: PackedByteArray = _identity()
	context.equal(stream.configure(Fixture.new()._config(), identity, 0, 100, 50), CODE.OK, "own caller identity")
	identity.fill(255)
	context.equal(stream.encode_end(0).slice(12, 44), _identity(), "identity mutation does not change lifetime")


func _byte_delivery(context: RefCounted) -> void:
	var stream: RefCounted = _stream(context)
	var viewer: RefCounted = stream.playback_session()
	var game: RefCounted = GameFixture.Game.new()
	var driver: RefCounted = Driver.new(viewer, game)
	var expected: int = 0
	for base: int in range(0, 30, 3):
		# A fake transport deliberately duplicates and reorders owned byte packets.
		var wire: Array[PackedByteArray] = [stream.encode_row(base + 2, _row(base + 2)), stream.encode_row(base, _row(base)), stream.encode_row(base + 1, _row(base + 1))]
		context.equal(stream.receive_packet(wire[0], base), CODE.OK, "future packet accepted")
		context.equal(viewer.recommended_steps(), 0, "wire gap cannot predict")
		context.equal(stream.receive_packet(wire[0], base), CODE.OK, "byte-identical duplicate")
		context.equal(stream.receive_packet(wire[1], base), CODE.OK, "first packet fills prefix")
		context.equal(stream.receive_packet(wire[2], base), CODE.OK, "remaining gap closes")
		wire[2].fill(255)
		for frame: int in range(base, base + 3):
			context.equal(driver.step(frame, _empty()).code, CODE.OK, "shared driver advances received row")
			for player: int in range(2):
				expected = expected * 3 + _row(frame)[player][0] + frame
			context.equal(game.value, expected, "state equals original host inputs")
	context.equal(viewer.statistics().rollback_count, 0, "bytes never cause spectator prediction")
	context.equal(viewer.host_frontier(), 29, "contiguous receipt crosses ring wraps")


func _malformed(context: RefCounted) -> void:
	for offset: int in [0, 4, 5, 6, 7, 8, 12, 28, 36]:
		var stream: RefCounted = _stream(context)
		var packet: PackedByteArray = stream.encode_row(0, _row(0))
		packet[offset] = 255
		context.equal(stream.receive_packet(packet, 90), CODE.PROTOCOL_FAILED, "bad field refused at %d" % offset)
		context.equal(stream.playback_session().host_frontier(), -1, "bad bytes preserve host history")
		context.equal(stream.receive_packet(stream.encode_row(0, _row(0)), 1), CODE.OK, "rejection cannot consume stream clock")
	for length: int in [0, 47, 48, 49, 51, 65536]:
		var stream: RefCounted = _stream(context)
		var packet: PackedByteArray = stream.encode_row(0, _row(0))
		packet.resize(length)
		context.equal(stream.receive_packet(packet, 0), CODE.PROTOCOL_FAILED, "exact row length required")
		context.equal(stream.playback_session().host_frontier(), -1, "length error is atomic")
	var invalid_frame: RefCounted = _stream(context)
	var exhausted: PackedByteArray = invalid_frame.encode_row(0, _row(0))
	exhausted.encode_u32(44, 4294967295)
	context.equal(invalid_frame.receive_packet(exhausted, 90), CODE.INVALID_FRAME, "exhausted wire frame")
	context.equal(invalid_frame.poll(1), CODE.OK, "invalid frame consumes no clock")
	var stream: RefCounted = _stream(context)
	context.equal(stream.receive_packet(stream.encode_row(0, _row(0)), 0), CODE.OK, "original packet")
	context.equal(stream.receive_packet(stream.encode_row(0, _row(1)), 1), CODE.PROTOCOL_FAILED, "conflicting history fails stream")
	context.equal(stream.playback_session().status().reason, CODE.PROTOCOL_FAILED, "conflict retains terminal cause")
	context.equal(Driver.new(stream.playback_session(), GameFixture.Game.new()).step(1, _empty()).code, CODE.TERMINATED, "conflict stops buffered playback")


func _lifetime_and_timeout(context: RefCounted) -> void:
	var stream: RefCounted = _stream(context)
	var stale: PackedByteArray = stream.encode_row(0, _row(0))
	var fresh: PackedByteArray = _identity()
	fresh[31] += 1
	context.equal(stream.configure(Fixture.new()._config(), fresh, 10, 100, 50), CODE.OK, "new connection lifetime")
	context.equal(stream.receive_packet(stale, 109), CODE.PROTOCOL_FAILED, "old lifetime cannot inject input")
	context.equal(stream.playback_session().host_frontier(), -1, "stale packet preserves fresh viewer")
	context.equal(stream.poll(109), CODE.OK, "strictly before deadline")
	context.equal(stream.receive_packet(stream.encode_row(0, _row(0)), 110), CODE.PROTOCOL_FAILED, "expiry wins over queued valid bytes")
	context.equal(stream.playback_session().status().reason, CODE.PROTOCOL_FAILED, "host loss terminates")
	var extreme: RefCounted = _stream(context)
	context.equal(extreme.poll(9223372036854775807), CODE.PROTOCOL_FAILED, "maximum clock cannot overflow timeout")
	var invalid: RefCounted = _stream(context)
	context.equal(invalid.poll(-1), CODE.INVALID_TIME, "negative time refused")
	context.equal(invalid.poll(2), CODE.OK, "monotonic time")
	context.equal(invalid.receive_packet(invalid.encode_row(0, _row(0)), 1), CODE.INVALID_TIME, "rewinding packet clock refused")
	context.equal(invalid.playback_session().host_frontier(), -1, "time error retains no row")
	var buffered: RefCounted = _stream(context)
	buffered.receive_packet(buffered.encode_row(0, _row(0)), 0)
	context.equal(buffered.poll(100), CODE.PROTOCOL_FAILED, "host loss with buffered input")
	var game: RefCounted = GameFixture.Game.new()
	context.equal(Driver.new(buffered.playback_session(), game).step(100, _empty()).code, CODE.TERMINATED, "host loss stops buffered playback")
	context.equal(game.trace.size(), 0, "host loss runs no callbacks")


func _clean_tail(context: RefCounted) -> void:
	var stream: RefCounted = _stream(context)
	var viewer: RefCounted = stream.playback_session()
	context.equal(viewer.set_playback(2, 1, 3), CODE.OK, "delayed viewer")
	context.equal(stream.receive_packet(stream.encode_end(3), 0), CODE.OK, "END may overtake all rows")
	context.equal(stream.receive_packet(stream.encode_row(2, _row(2)), 1), CODE.OK, "tail precedes gap")
	context.equal(viewer.recommended_steps(), 0, "END does not finish incomplete prefix")
	context.equal(stream.receive_packet(stream.encode_row(0, _row(0)), 2), CODE.OK, "prefix arrives")
	context.equal(stream.receive_packet(stream.encode_row(1, _row(1)), 3), CODE.OK, "last gap releases delay")
	context.equal(stream.poll(1000), CODE.OK, "complete clean tail needs no host liveness")
	var driver: RefCounted = Driver.new(viewer, GameFixture.Game.new())
	for frame: int in range(3):
		context.equal(driver.step(frame, _empty()).code, CODE.OK, "drain delayed clean tail")
	context.equal(driver.step(3, _empty()).code, CODE.TERMINATED, "clean tail finishes shared lifecycle")
	var gap: RefCounted = _stream(context)
	gap.receive_packet(gap.encode_end(2), 0)
	gap.receive_packet(gap.encode_row(1, _row(1)), 1)
	context.equal(gap.poll(101), CODE.PROTOCOL_FAILED, "END cannot hide missing-row host loss")
	for contradict: bool in [false, true]:
		var bad: RefCounted = _stream(context)
		bad.receive_packet(bad.encode_row(2, _row(2)), 0)
		context.equal(bad.receive_packet(bad.encode_end(3 if contradict else 2), 1), CODE.OK if contradict else CODE.PROTOCOL_FAILED, "end must contain accepted future rows")
		if contradict:
			context.equal(bad.receive_packet(bad.encode_end(4), 2), CODE.PROTOCOL_FAILED, "contradictory end fails")


func _bounds(context: RefCounted) -> void:
	var stream: RefCounted = Stream.new()
	context.equal(stream.configure(Fixture.new()._config(), _identity(), 0, 100, 49), CODE.INVALID_CONFIGURATION, "row cannot exceed physical packet cap")
	context.equal(stream.poll(0), CODE.NOT_CONFIGURED, "failed configure does not install viewer")
	stream = _stream(context)
	context.equal(stream.receive_packet(stream.encode_row(5, _row(5)), 0), CODE.NETWORK_BACKPRESSURE, "bounded future refused")
	context.equal(stream.playback_session().host_frontier(), -1, "refused future not retained")
	context.equal(stream.receive_packet(stream.encode_row(0, _row(0)), 1), CODE.OK, "head receives")
	var driver: RefCounted = Driver.new(stream.playback_session(), GameFixture.Game.new())
	context.equal(driver.step(1, _empty()).code, CODE.OK, "free one ring slot")
	context.equal(stream.receive_packet(stream.encode_row(5, _row(5)), 2), CODE.OK, "caller retries exact refused packet")
	context.equal(stream.encode_row(2147483647, _row(0)).is_empty(), true, "exhausted row cannot encode")
	context.equal(stream.encode_end(2147483647).size(), 48, "exclusive end accepts exhausted next frame")


# Value: protects=callback and request ownership; fails_when=stream polls expire an active game callback; why_new=byte flows service completed batches; seam=none
func _busy(context: RefCounted) -> void:
	var stream: RefCounted = _stream(context)
	stream.receive_packet(stream.encode_row(0, _row(0)), 0)
	var viewer: RefCounted = stream.playback_session()
	var advance: Types.Result = viewer.begin_advance()
	context.equal(advance.code, CODE.READY, "open expert batch")
	context.equal(stream.poll(1000), CODE.BUSY, "active batch cannot expire host")
	context.equal(stream.receive_packet(stream.encode_end(1), 1000), CODE.BUSY, "receive cannot consume clock during batch")
	context.equal(viewer.status().reason, CODE.OK, "busy stream preserves lifecycle")
	var request: Types.Request = advance.batch.next_request()
	viewer.complete_request(request.batch_id, request.request_id, true)
	context.equal(stream.poll(1), CODE.OK, "busy calls do not consume time")

	var callbacks: RefCounted = _stream(context)
	callbacks.receive_packet(callbacks.encode_row(0, _row(0)), 0)
	var game: ReentrantGame = ReentrantGame.new()
	game.stream_ref = weakref(callbacks)
	context.equal(Driver.new(callbacks.playback_session(), game).step(1, _empty()).code, CODE.OK, "guarded callback completes")
	context.equal(game.stream_codes, PackedInt32Array([CODE.BUSY, CODE.BUSY, CODE.BUSY]), "every stream mutation refuses callback reentry")
	context.equal(callbacks.poll(2), CODE.OK, "callback reentry consumes no clock")
