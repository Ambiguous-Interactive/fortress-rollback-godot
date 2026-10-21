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
		stream_codes.append(stream.receive_packet(stream.encode_keepalive(), 1000))
		var key: PackedByteArray = PackedByteArray()
		key.resize(32)
		var digest: PackedByteArray = Stream.configuration_digest(Fixture.new()._config(), "seed-1", "rules-1")
		stream_codes.append(stream.configure(Fixture.new()._config(), stream._identity, key, digest, 1000, 100, 128))


func cases() -> PackedStringArray:
	return PackedStringArray(
		["wire_golden", "byte_delivery", "malformed", "authentication", "lifetime_and_timeout", "clean_tail", "bounds", "busy", "keepalive",
			"viewer_lifetime", "viewer_lifetime_control", "policy_preserved", "wide_shapes"]
	)


func run_case(name: String, context: RefCounted) -> void:
	call("_" + name, context)
	context.finish()




func _key() -> PackedByteArray:
	var key: PackedByteArray = PackedByteArray()
	key.resize(32)
	for value: int in range(32):
		key[value] = value + 1
	return key


func _digest(config: Variant = null) -> PackedByteArray:
	var agreed: Variant = config if config != null else Fixture.new()._config()
	return Stream.configuration_digest(agreed, "seed-1", "rules-1")

func _identity() -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray()
	for value: int in range(32):
		bytes.append(value)
	return bytes


func _stream(context: RefCounted) -> RefCounted:
	var stream: RefCounted = Stream.new()
	context.equal(stream.configure(Fixture.new()._config(), _identity(), _key(), _digest(), 0, 100, 128), CODE.OK, "bounded stream configured")
	return stream


func _row(frame: int) -> Array[PackedByteArray]:
	return Fixture.new()._row(frame)


func _empty() -> Array[Driver.LocalInput]:
	return []


## The unsigned header and body of one row, so a test can sign it with a different key or digest.
func _unsigned_row(frame: int, inputs: Array[PackedByteArray], digest: PackedByteArray) -> PackedByteArray:
	var packet: PackedByteArray = Stream.encode_header(Stream.ROW, frame, 2, 1, _identity(), digest)
	for bytes: PackedByteArray in inputs:
		packet.append_array(bytes)
	return packet


## A signed packet without its tag, so a test can change a field and sign it again.
func _unsigned(packet: PackedByteArray) -> PackedByteArray:
	var body: PackedByteArray = packet.slice(0, Stream.HEADER_BYTES - Stream.TAG_BYTES)
	body.append_array(packet.slice(Stream.HEADER_BYTES))
	return body


func _wire_golden(context: RefCounted) -> void:
	var stream: RefCounted = _stream(context)
	context.equal(
		stream.encode_row(16909060, _row(0)).hex_encode(),
		"465247530201020001000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1fd2deccf9f3deb3d06e7cc546fabec43b04030201731411334fcded23e53b538704c81eba0001",
		"independent little-endian frame, dimensions, identity, configuration and tag golden"
	)
	context.equal(stream.encode_end(0).size(), 80, "empty stream has fixed header only")
	var identity: PackedByteArray = _identity()
	context.equal(stream.configure(Fixture.new()._config(), identity, _key(), _digest(), 0, 100, 128), CODE.OK, "own caller identity")
	identity.fill(255)
	context.equal(stream.encode_end(0).slice(12, 44), _identity(), "identity mutation does not change lifetime")


# Value: protects=only the agreed host drives a viewer; fails_when=a forged or foreign packet changes playback;
# why_new=the byte cases cover shape, order and lifetime, not the keyed tag; seam=none
func _authentication(context: RefCounted) -> void:
	var stream: RefCounted = _stream(context)
	var viewer: RefCounted = stream.playback_session()
	var other_key: PackedByteArray = _key()
	other_key[0] = 99
	var forged: PackedByteArray = Stream.authenticate(_unsigned_row(0, _row(0), _digest()), other_key)
	context.equal(stream.receive_packet(forged, 1), CODE.PROTOCOL_FAILED, "a foreign key cannot forge a row")
	context.equal(viewer.host_frontier(), -1, "a forged row changes no history")
	var mutated: PackedByteArray = stream.encode_row(0, _row(0))
	mutated[Stream.HEADER_BYTES] = 200
	context.equal(stream.receive_packet(mutated, 1), CODE.PROTOCOL_FAILED, "a changed body keeps the old tag")
	context.equal(viewer.host_frontier(), -1, "a changed body changes no history")
	var foreign_digest: PackedByteArray = Stream.configuration_digest(Fixture.new()._config(), "other-seed", "rules-1")
	var foreign: PackedByteArray = Stream.authenticate(_unsigned_row(0, _row(0), foreign_digest), _key())
	context.equal(stream.receive_packet(foreign, 1), CODE.PROTOCOL_FAILED, "another agreed configuration is refused")
	context.equal(viewer.host_frontier(), -1, "a foreign configuration changes no history")
	context.equal(stream.poll(100), CODE.PROTOCOL_FAILED, "forged traffic does not extend the host deadline")


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
	for length: int in [0, 79, 80, 81, 83, 65536]:
		var stream: RefCounted = _stream(context)
		var packet: PackedByteArray = stream.encode_row(0, _row(0))
		packet.resize(length)
		context.equal(stream.receive_packet(packet, 0), CODE.PROTOCOL_FAILED, "exact row length required")
		context.equal(stream.playback_session().host_frontier(), -1, "length error is atomic")
	var invalid_frame: RefCounted = _stream(context)
	var exhausted: PackedByteArray = invalid_frame.encode_row(0, _row(0))
	exhausted.encode_u32(60, 4294967295)
	# The host signs the exhausted frame, so the frame bound is the reason for the refusal.
	exhausted = Stream.authenticate(_unsigned(exhausted), _key())
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
	context.equal(stream.configure(Fixture.new()._config(), fresh, _key(), _digest(), 10, 100, 128), CODE.OK, "new connection lifetime")
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


# Value: protects=fresh viewer lifetime from old stream packets/timeouts; fails_when=viewer reconfigure keeps stream authority; why_new=identity tests replace stream; seam=none
func _viewer_lifetime(context: RefCounted) -> void:
	_check_viewer_lifetime(context, true)


func _viewer_lifetime_control(context: RefCounted) -> void:
	_check_viewer_lifetime(context, false)


func _check_viewer_lifetime(context: RefCounted, replace_viewer: bool) -> void:
	for complete_end: bool in [false, true]:
		var stream: RefCounted = _stream(context)
		var viewer: RefCounted = stream.playback_session()
		var packets: Array[PackedByteArray] = [stream.encode_row(0, _row(0)), stream.encode_end(1), stream.encode_keepalive()]
		if complete_end:
			context.equal(stream.receive_packet(stream.encode_end(0), 0), CODE.OK, "old lifetime may already have cleanly ended")
		var config: RefCounted = Fixture.new()._config()
		if replace_viewer:
			context.equal(viewer.configure(config), CODE.OK, "public viewer configuration creates a new lifetime")
		else:
			config.queue_capacity = 0
			context.equal(viewer.configure(config), CODE.INVALID_CONFIGURATION, "failed viewer configuration preserves lifetime control")
		if replace_viewer:
			var deadline: RefCounted = _stream(context)
			context.equal(deadline.playback_session().configure(Fixture.new()._config()), CODE.OK, "replace viewer before old deadline")
			context.equal(deadline.poll(1000), CODE.INVALID_CONFIGURATION, "old deadline cannot terminate replacement viewer")
			context.equal(deadline.playback_session().status().reason, CODE.OK, "old timeout preserves replacement viewer lifecycle")
			for packet: PackedByteArray in packets:
				context.equal(stream.receive_packet(packet, 90), CODE.INVALID_CONFIGURATION, "old stream cannot deliver into replacement viewer")
			context.equal(stream.poll(1000), CODE.INVALID_CONFIGURATION, "old deadline cannot terminate replacement viewer")
			context.equal(stream.encode_row(0, _row(0)).is_empty(), true, "stale stream cannot encode rows")
			context.equal(stream.encode_end(0).is_empty(), true, "stale stream cannot encode end")
			context.equal(stream.encode_keepalive().is_empty(), true, "stale stream cannot encode liveness")
			context.equal(viewer.host_frontier(), -1, "replacement viewer retains no old input")
			context.equal(viewer.status().reason, CODE.OK, "replacement viewer remains live")
		else:
			context.equal(stream.receive_packet(packets[2], 1), CODE.TERMINATED if complete_end else CODE.OK, "rejected configuration preserves stream state")
			context.equal(stream.poll(99), CODE.OK, "rejected configuration preserves stream clock")
		var fresh: PackedByteArray = _identity()
		fresh[31] += 1
		context.equal(stream.configure(Fixture.new()._config(), fresh, _key(), _digest(), 10, 100, 128), CODE.OK, "explicit stream configuration restores fresh ownership")
		context.equal(stream.receive_packet(packets[0], 109), CODE.PROTOCOL_FAILED, "old identity remains fenced after stream recovery")
		context.equal(stream.receive_packet(stream.encode_row(0, _row(0)), 11), CODE.OK, "fresh lifetime accepts its own row and clock")


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
	context.equal(stream.configure(Fixture.new()._config(), _identity(), _key(), _digest(), 0, 100, 81), CODE.INVALID_CONFIGURATION, "row cannot exceed physical packet cap")
	context.equal(stream.poll(0), CODE.NOT_CONFIGURED, "failed configure does not install viewer")
	stream = _stream(context)
	context.equal(stream.receive_packet(stream.encode_row(5, _row(5)), 0), CODE.NETWORK_BACKPRESSURE, "bounded future refused")
	context.equal(stream.playback_session().host_frontier(), -1, "refused future not retained")
	context.equal(stream.receive_packet(stream.encode_row(0, _row(0)), 1), CODE.OK, "head receives")
	var driver: RefCounted = Driver.new(stream.playback_session(), GameFixture.Game.new())
	context.equal(driver.step(1, _empty()).code, CODE.OK, "free one ring slot")
	context.equal(stream.receive_packet(stream.encode_row(5, _row(5)), 2), CODE.OK, "caller retries exact refused packet")
	context.equal(stream.encode_row(2147483647, _row(0)).is_empty(), true, "exhausted row cannot encode")
	context.equal(stream.encode_end(2147483647).size(), 80, "exclusive end accepts exhausted next frame")


# Value: protects=callback and request ownership; fails_when=stream polls expire an active game callback; why_new=byte flows service completed batches; seam=none
func _busy(context: RefCounted) -> void:
	var stream: RefCounted = _stream(context)
	stream.receive_packet(stream.encode_row(0, _row(0)), 0)
	var viewer: RefCounted = stream.playback_session()
	var advance: Types.Result = viewer.begin_advance()
	context.equal(advance.code, CODE.READY, "open expert batch")
	context.equal(stream.poll(1000), CODE.BUSY, "active batch cannot expire host")
	context.equal(stream.receive_packet(stream.encode_keepalive(), 1000), CODE.BUSY, "keepalive cannot consume clock during batch")
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
	context.equal(game.stream_codes, PackedInt32Array([CODE.BUSY, CODE.BUSY, CODE.BUSY, CODE.BUSY]), "every stream mutation refuses callback reentry")
	context.equal(callbacks.poll(2), CODE.OK, "callback reentry consumes no clock")


# Value: protects=live input-idle host; fails_when=valid keepalive expires or advances viewer; why_new=row delivery conflates liveness and input; seam=none
func _keepalive(context: RefCounted) -> void:
	var stream: RefCounted = _stream(context)
	var keepalive: PackedByteArray = stream.encode_keepalive()
	context.equal(
		keepalive.hex_encode(),
		"465247530203020001000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1fd2deccf9f3deb3d06e7cc546fabec43b000000000f63910fb2758ff54f8fd57c2bc1a1eb",
		"keepalive kind, reserved frame, configuration and tag independent golden"
	)
	context.equal(stream.receive_packet(stream.encode_row(0, _row(0)), 1), CODE.OK, "ordinary host packet control")
	for now_us: int in [100, 199, 298, 397]:
		context.equal(stream.receive_packet(keepalive, now_us), CODE.OK, "idle host refreshes liveness before deadline")
		context.equal(stream.playback_session().host_frontier(), 0, "keepalive contributes no confirmed input")
		context.equal(stream.playback_session().status().current_frame, 0, "keepalive simulates no frame")
	context.equal(stream.poll(496), CODE.OK, "host remains live over several timeout periods")
	context.equal(stream.receive_packet(keepalive, 497), CODE.PROTOCOL_FAILED, "deadline equality still expires")
	context.equal(stream.playback_session().status().reason, CODE.PROTOCOL_FAILED, "idle host loss is terminal")

	for invalid_field: String in ["foreign_identity", "reserved_frame", "extra_body"]:
		var viewer: RefCounted = _stream(context)
		var invalid: PackedByteArray = viewer.encode_keepalive()
		if invalid_field == "foreign_identity":
			invalid[12] ^= 1
		elif invalid_field == "reserved_frame":
			invalid.encode_u32(60, 1)
			invalid = Stream.authenticate(_unsigned(invalid), _key())
		else:
			invalid.append(0)
		context.equal(viewer.receive_packet(invalid, 90), CODE.INVALID_FRAME if invalid_field == "reserved_frame" else CODE.PROTOCOL_FAILED, "invalid keepalive refused")
		context.equal(viewer.receive_packet(viewer.encode_keepalive(), 1), CODE.OK, "invalid keepalive consumes no clock")
		context.equal(viewer.poll(101), CODE.PROTOCOL_FAILED, "invalid keepalive does not refresh liveness")
	var ending: RefCounted = _stream(context)
	context.equal(ending.receive_packet(ending.encode_end(1), 0), CODE.OK, "end with missing row")
	context.equal(ending.receive_packet(ending.encode_keepalive(), 99), CODE.OK, "idle host may still fill clean-end gap")
	context.equal(ending.playback_session().recommended_steps(), 0, "keepalive cannot complete clean-end gap")
	context.equal(ending.receive_packet(ending.encode_row(0, _row(0)), 100), CODE.OK, "missing tail still accepted")
	context.equal(ending.receive_packet(ending.encode_keepalive(), 101), CODE.TERMINATED, "completed end cannot reopen stream")
	context.equal(ending.poll(1000), CODE.OK, "completed clean stream needs no liveness")
	context.equal(Stream.new().encode_keepalive().is_empty(), true, "unconfigured keepalive cannot encode")


# Value: protects=reconfiguration keeps the caller's playback policy; fails_when=a fresh viewer silently drops the
# declared delay; why_new=lifetime cases replace the viewer without a policy; seam=none
func _policy_preserved(context: RefCounted) -> void:
	var stream: RefCounted = _stream(context)
	context.equal(stream.playback_session().set_playback(2, 1, 3), CODE.OK, "declared playback policy")
	context.equal(stream.configure(Fixture.new()._config(), _identity(), _key(), _digest(), 0, 100, 128), CODE.OK, "reconfigured viewer")
	context.equal(stream.playback_session().playback_policy(), PackedInt64Array([2, 1, 3]), "reconfigured viewer keeps the declared policy")
	var narrow: RefCounted = Fixture.new()._config()
	narrow.queue_capacity = 2
	context.equal(stream.configure(narrow, _identity(), _key(), _digest(), 0, 100, 128), CODE.OK, "narrower viewer")
	context.equal(stream.playback_session().playback_policy(), PackedInt64Array([0, 1, 1]), "a policy that no longer fits falls back to the defaults")


# Value: protects=the byte envelope carries every supported roster and sample width; fails_when=the header or the
# body drifts from the configured shape; why_new=other wire cases use two players and one byte; seam=none
func _wide_shapes(context: RefCounted) -> void:
	for players: int in [2, 4, 8]:
		for width: int in [1, 4]:
			var label: String = "shape %d x %d" % [players, width]
			var config: RefCounted = Fixture.new()._config()
			config.player_count = players
			config.input_width = width
			config.neutral_input.resize(width)
			var stream: RefCounted = Stream.new()
			context.equal(stream.configure(config, _identity(), _key(), _digest(), 0, 100, 65536), CODE.OK, label + " configures")
			var game: GameFixture.Game = GameFixture.Game.new()
			var driver: RefCounted = Driver.new(stream.playback_session(), game)
			var expected: int = 0
			for frame: int in range(3):
				var row: Array[PackedByteArray] = []
				for player: int in range(players):
					var bytes: PackedByteArray = PackedByteArray()
					bytes.resize(width)
					bytes.fill((frame + player) % 256)
					row.append(bytes)
					expected = expected * 3 + bytes[0] + frame
				var packet: PackedByteArray = stream.encode_row(frame, row)
				context.equal(packet.size(), 80 + players * width, label + " row size")
				context.equal(packet[6], players, label + " header roster")
				context.equal(packet.decode_u32(8), width, label + " header width")
				context.equal(stream.receive_packet(packet, frame), CODE.OK, label + " row accepted")
				context.equal(driver.step(frame, _empty()).code, CODE.OK, label + " advance")
			context.equal(game.value, expected, label + " canonical state")
			var sample: PackedByteArray = PackedByteArray()
			sample.resize(width)
			sample.fill(7)
			var short: PackedByteArray = Stream.encode_header(Stream.ROW, 3, players, width, _identity(), _digest())
			short.append_array(sample)
			context.equal(stream.receive_packet(short, 4), CODE.PROTOCOL_FAILED, label + " short row is refused")
