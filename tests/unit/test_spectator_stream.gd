extends RefCounted

# Value: protects=bounded confirmed spectator bytes; fails_when=wire reorder predicts or host loss plays buffered rows; why_new=row tests bypass bytes/time; seam=none
const Stream = preload("res://addons/fortress_rollback/core/spectator_stream.gd")
const Publisher = preload("res://addons/fortress_rollback/core/spectator_publisher.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Negotiation = preload("res://addons/fortress_rollback/core/spectator_negotiation.gd")
const Fixture = preload("res://tests/unit/test_spectator_session.gd")
const GameFixture = preload("res://tests/unit/test_driver.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const CODE = Types.Code


class ReentrantGame:
	extends GameFixture.Game
	var stream_ref: WeakRef
	var stream_codes: PackedInt32Array = PackedInt32Array()
	var accept_size: int = -1

	func _reenter() -> void:
		super._reenter()
		var stream: RefCounted = stream_ref.get_ref()
		accept_size = stream.encode_accept().size()
		stream_codes.append(stream.poll(1000))
		stream_codes.append(stream.receive_packet(stream.encode_end(1), 1000))
		stream_codes.append(stream.receive_packet(stream.encode_keepalive(), 1000))
		stream_codes.append(stream.receive_packet(Stream.encode_offer(stream._identity, stream._digest, 2, 1, stream._key), 1000))
		var key: PackedByteArray = PackedByteArray()
		key.resize(32)
		var digest: PackedByteArray = Stream.configuration_digest(Fixture.new()._config(), "seed-1", "rules-1")
		stream_codes.append(stream.configure(Fixture.new()._config(), stream._identity, key, digest, 1000, 100, 128))


func cases() -> PackedStringArray:
	return PackedStringArray(
		["wire_golden", "byte_delivery", "malformed", "authentication", "negotiation", "lifetime_and_timeout", "clean_tail", "bounds", "busy", "keepalive",
			"viewer_lifetime", "viewer_lifetime_control", "policy_preserved", "replaced_viewer", "wide_shapes", "offer_lifecycle", "closed_input_duplicates",
			"initial_state_agreement", "obsolete_rows", "host_observation"]
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


## One host publisher that shares the viewer's identity, key and configuration digest.
func _publisher(context: RefCounted) -> RefCounted:
	return _publisher_for(context, _identity())


## One host publisher for one agreed identity.
func _publisher_for(context: RefCounted, identity: PackedByteArray) -> RefCounted:
	var host: RefCounted = Session.new()
	context.equal(host.configure(Fixture.new().host_config()), CODE.OK, "bounded host")
	var publisher: RefCounted = Publisher.new()
	context.equal(publisher.configure(host, identity, _key(), _digest(), 128), CODE.OK, "bounded publisher")
	return publisher


## One startup exchange for the viewer's own identity.
func _negotiate(context: RefCounted, stream: RefCounted, identity: PackedByteArray, now_us: int = 0) -> void:
	context.equal(Fixture.new().negotiate(_publisher_for(context, identity), stream, now_us), CODE.OK, "envelope agreed for this lifetime")


## A configured viewer whose envelope version and optional kinds are already agreed.
func _stream(context: RefCounted) -> RefCounted:
	var stream: RefCounted = Stream.new()
	context.equal(stream.configure(Fixture.new()._config(), _identity(), _key(), _digest(), 0, 100, 128), CODE.OK, "bounded stream configured")
	_negotiate(context, stream, _identity())
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


## One frozen version 1 packet: the old header without the tag or the configuration digest.
func _legacy_row(frame: int) -> PackedByteArray:
	var packet: PackedByteArray = PackedByteArray()
	packet.append_array("FRGS".to_ascii_buffer())
	packet.append(1)
	packet.append(Stream.ROW)
	packet.append(2)
	packet.append(0)
	packet.append(0)
	packet.append(0)
	packet.append(0)
	packet.append(1)
	packet.append_array(_identity())
	packet.append(0)
	packet.append(0)
	packet.append(0)
	packet.append(frame)
	return packet


## One version 1 startup offer: the same shape with an envelope version this side cannot speak.
func _legacy_offer(version: int = 1) -> PackedByteArray:
	var packet: PackedByteArray = Stream.encode_header(Stream.OFFER, 0, 2, 1, _identity(), _digest(), version)
	packet.append_array(Negotiation.encode_capabilities(Negotiation.supported_versions(version), Negotiation.CAP_ALL))
	return Stream.authenticate(packet, _key())


## One version 1 answer to the startup offer.
func _legacy_accept(version: int = 1) -> PackedByteArray:
	var packet: PackedByteArray = Stream.encode_header(Stream.ACCEPT, 0, 2, 1, _identity(), _digest(), version)
	packet.append_array(Negotiation.encode_capabilities(Negotiation.supported_versions(version), Negotiation.CAP_ALL))
	return Stream.authenticate(packet, _key())


## One offer that names an optional kind this side does not know.
func _unknown_kind_offer() -> PackedByteArray:
	var packet: PackedByteArray = Stream.encode_header(Stream.OFFER, 0, 2, 1, _identity(), _digest(), Stream.VERSION)
	packet.append_array(Negotiation.encode_capabilities(Negotiation.supported_versions(Stream.VERSION), Negotiation.CAP_ALL | 8))
	return Stream.authenticate(packet, _key())


## One offer signed with another key.
func _foreign_offer() -> PackedByteArray:
	var other_key: PackedByteArray = _key()
	other_key[0] = 99
	var packet: PackedByteArray = Stream.encode_header(Stream.OFFER, 0, 2, 1, _identity(), _digest(), Stream.VERSION)
	packet.append_array(Negotiation.encode_capabilities(Negotiation.supported_versions(Stream.VERSION), Negotiation.CAP_ALL))
	return Stream.authenticate(packet, other_key)


## A signed packet without its tag, so a test can change a field and sign it again.
func _unsigned(packet: PackedByteArray) -> PackedByteArray:
	var body: PackedByteArray = packet.slice(0, Stream.HEADER_BYTES - Stream.TAG_BYTES)
	body.append_array(packet.slice(Stream.HEADER_BYTES))
	return body


func _wire_golden(context: RefCounted) -> void:
	var stream: RefCounted = _stream(context)
	context.equal(
		stream.encode_row(16909060, _row(0)).hex_encode(),
		"465247530301020001000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1fd2deccf9f3deb3d06e7cc546fabec43b040302015b1f1214e81754c82b0e314af242ac7c00010101",
		"independent little-endian frame, dimensions, identity, configuration and tag golden"
	)
	context.equal(stream.encode_end(0).size(), 80, "empty stream has fixed header only")
	var identity: PackedByteArray = _identity()
	context.equal(stream.configure(Fixture.new()._config(), identity, _key(), _digest(), 0, 100, 128), CODE.OK, "own caller identity")
	_negotiate(context, stream, _identity())
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
	# The changed body keeps its own stream, so the refusal cannot come from the row above.
	var changed: RefCounted = _stream(context)
	var mutated: PackedByteArray = changed.encode_row(0, _row(0))
	mutated[Stream.HEADER_BYTES] = 200
	context.equal(changed.receive_packet(mutated, 1), CODE.PROTOCOL_FAILED, "a changed body keeps the old tag")
	context.equal(changed.playback_session().host_frontier(), -1, "a changed body changes no history")
	var foreign_digest: PackedByteArray = Stream.configuration_digest(Fixture.new()._config(), "other-seed", "rules-1")
	var foreign: PackedByteArray = Stream.authenticate(_unsigned_row(0, _row(0), foreign_digest), _key())
	context.equal(stream.receive_packet(foreign, 1), CODE.PROTOCOL_FAILED, "another agreed configuration is refused")
	context.equal(viewer.host_frontier(), -1, "a foreign configuration changes no history")
	context.equal(stream.poll(100), CODE.PROTOCOL_FAILED, "forged traffic does not extend the host deadline")


# Value: protects=the envelope version and the optional kinds are agreed before the first row;
# fails_when=a peer that speaks another envelope starts a partial playback; why_new=the byte cases
# assume one agreed envelope; seam=none
func _negotiation(context: RefCounted) -> void:
	var publisher: RefCounted = _publisher(context)
	var stream: RefCounted = Stream.new()
	context.equal(stream.configure(Fixture.new()._config(), _identity(), _key(), _digest(), 0, 100, 128), CODE.OK, "configured viewer")
	context.equal(stream.agreement_state(), Negotiation.AgreementState.PENDING, "no agreement before the exchange")
	context.equal(stream.encode_accept().is_empty(), true, "no answer before an offer")
	context.equal(publisher.prepare_packet().code, CODE.NOT_SYNCHRONIZED, "an unagreed host publishes no row")
	context.equal(publisher.encode_keepalive().is_empty(), true, "an unagreed host sends no liveness")

	var offer: PackedByteArray = publisher.encode_offer()
	context.equal(offer.size(), Stream.NEGOTIATION_BYTES, "one fixed-width offer")
	context.equal(offer[4], Stream.VERSION, "the offer names the envelope version")
	context.equal(offer[5], Stream.OFFER, "the offer names its kind")
	context.equal(stream.receive_packet(offer, 0), CODE.OK, "the viewer accepts the offer")
	context.equal(stream.agreement_state(), Negotiation.AgreementState.AGREED, "the viewer agrees")
	context.equal(stream.agreement_version(), Stream.VERSION, "the agreed envelope version")
	context.equal(stream.agreement_kinds(), Negotiation.CAP_ALL, "the agreed optional kinds")
	context.equal(stream.agreement_reason(), CODE.OK, "no refusal reason")
	var accept: PackedByteArray = stream.encode_accept()
	context.equal(accept.size(), Stream.NEGOTIATION_BYTES, "one fixed-width answer")
	context.equal(publisher.receive_accept(accept), CODE.OK, "the host accepts the answer")
	context.equal(publisher.agreement_state(), Negotiation.AgreementState.AGREED, "the host agrees")
	context.equal(publisher.agreement_version(), Stream.VERSION, "the host agrees on the envelope version")
	context.equal(publisher.agreement_kinds(), Negotiation.CAP_ALL, "the host agrees on the optional kinds")
	context.equal(publisher.prepare_packet().code, CODE.PREDICTION_STALL, "the agreed host publishes its first row")

	# A peer that speaks another envelope version is refused before any row is played.
	var legacy_row: RefCounted = Stream.new()
	legacy_row.configure(Fixture.new()._config(), _identity(), _key(), _digest(), 0, 100, 128)
	context.equal(legacy_row.receive_packet(_legacy_row(0), 0), CODE.PROTOCOL_FAILED, "an untagged version 1 row is malformed")
	context.equal(legacy_row.playback_session().host_frontier(), -1, "a malformed row plays nothing")
	var refused: RefCounted = Stream.new()
	refused.configure(Fixture.new()._config(), _identity(), _key(), _digest(), 0, 100, 128)
	context.equal(refused.receive_packet(_legacy_offer(), 0), CODE.UNSUPPORTED, "another envelope version is refused")
	context.equal(refused.agreement_reason(), CODE.UNSUPPORTED, "one recorded refusal reason")
	context.equal(refused.agreement_state(), Negotiation.AgreementState.REFUSED, "the refused agreement is recorded")
	context.equal(refused.playback_session().host_frontier(), -1, "a refused version plays no row")
	context.equal(Driver.new(refused.playback_session(), GameFixture.Game.new()).step(0, _empty()).code, CODE.TERMINATED, "a refused version starts no playback")
	context.equal(refused.receive_packet(offer, 1), CODE.TERMINATED, "a refused viewer never agrees again")

	var host: RefCounted = _publisher(context)
	context.equal(host.receive_accept(_legacy_accept()), CODE.UNSUPPORTED, "the host refuses another envelope version")
	context.equal(host.agreement_reason(), CODE.UNSUPPORTED, "one recorded host refusal reason")
	context.equal(host.prepare_packet().code, CODE.NOT_SYNCHRONIZED, "a refused host publishes no row")
	_invalid_accept_versions(context, accept)

	# An answer that drops the kind that closes the stream is refused.
	var partial: PackedByteArray = Stream.encode_header(Stream.ACCEPT, 0, 2, 1, _identity(), _digest(), Stream.VERSION)
	partial.append_array(Negotiation.encode_capabilities(Negotiation.supported_versions(Stream.VERSION), Negotiation.CAP_ROW))
	var closing: RefCounted = _publisher(context)
	context.equal(closing.receive_accept(Stream.authenticate(partial, _key())), CODE.UNSUPPORTED, "an answer without the end kind is refused")
	context.equal(closing.prepare_packet().code, CODE.NOT_SYNCHRONIZED, "a refused host publishes no row")

	# An offer that names an unknown optional kind is refused before the first row.
	var unknown: RefCounted = Stream.new()
	unknown.configure(Fixture.new()._config(), _identity(), _key(), _digest(), 0, 100, 128)
	context.equal(unknown.receive_packet(_unknown_kind_offer(), 0), CODE.UNSUPPORTED, "an unknown optional kind is refused")
	context.equal(unknown.agreement_reason(), CODE.UNSUPPORTED, "one recorded kind refusal reason")

	# An unauthenticated exchange cannot move the agreement.
	var forged: RefCounted = Stream.new()
	forged.configure(Fixture.new()._config(), _identity(), _key(), _digest(), 0, 100, 128)
	context.equal(forged.receive_packet(_foreign_offer(), 0), CODE.PROTOCOL_FAILED, "an offer signed with another key is refused")
	context.equal(forged.agreement_state(), Negotiation.AgreementState.PENDING, "a forged offer agrees nothing")
	context.equal(forged.agreement_reason(), CODE.OK, "a forged offer records no refusal reason")

	# An authenticated packet with an impossible version is malformed, not a playback row.
	var impossible: RefCounted = _stream(context)
	var broken: PackedByteArray = impossible.encode_row(0, _row(0))
	broken[4] = 0
	broken = Stream.authenticate(_unsigned(broken), _key())
	context.equal(impossible.receive_packet(broken, 0), CODE.PROTOCOL_FAILED, "an authenticated packet with an impossible version is refused")
	context.equal(impossible.playback_session().host_frontier(), -1, "an impossible version plays no row")

	# A repeated offer repeats the agreement; a different one is a protocol failure.
	var repeated: RefCounted = Stream.new()
	repeated.configure(Fixture.new()._config(), _identity(), _key(), _digest(), 0, 100, 128)
	context.equal(repeated.receive_packet(offer, 0), CODE.OK, "the offer is accepted")
	context.equal(repeated.receive_packet(offer, 50), CODE.OK, "a retried offer repeats the agreement")
	context.equal(repeated.agreement_version(), Stream.VERSION, "the repeated agreement holds")
	context.equal(repeated.poll(100), CODE.OK, "a retried offer refreshes the host liveness")
	context.equal(repeated.receive_packet(_legacy_offer(), 100), CODE.PROTOCOL_FAILED, "a different offer is a protocol failure")
	context.equal(repeated.playback_session().status().reason, CODE.PROTOCOL_FAILED, "the conflicting offer terminates the viewer")

	# An agreed host keeps its agreement; a different answer cannot move it.
	var agreed_host: RefCounted = _publisher(context)
	var agreed_viewer: RefCounted = Stream.new()
	agreed_viewer.configure(Fixture.new()._config(), _identity(), _key(), _digest(), 0, 100, 128)
	context.equal(Fixture.new().negotiate(agreed_host, agreed_viewer), CODE.OK, "the exchange agrees")
	context.equal(agreed_host.receive_accept(agreed_viewer.encode_accept()), CODE.OK, "a retried answer repeats the agreement")
	context.equal(agreed_host.receive_accept(_legacy_accept()), CODE.PROTOCOL_FAILED, "a different answer cannot move an agreed host")
	context.equal(agreed_host.agreement_version(), Stream.VERSION, "the agreed host keeps its envelope version")


# Value: protects=bounded authenticated startup versions; fails_when=oversized shifts alias supported versions;
# why_new=legacy controls use valid mask indices; seam=none
func _invalid_accept_versions(context: RefCounted, valid: PackedByteArray) -> void:
	for version: int in [0, 32, 63, 64, 67, 127, 131, 195, 255]:
		var publisher: RefCounted = _publisher(context)
		var packet: PackedByteArray = valid.duplicate()
		packet[4] = version
		packet = Stream.authenticate(_unsigned(packet), _key())
		context.equal(publisher.receive_accept(packet), CODE.PROTOCOL_FAILED, "invalid version %d is malformed" % version)
		context.equal(publisher.agreement_state(), Negotiation.AgreementState.PENDING, "malformed version cannot agree")
		context.equal(publisher.agreement_version(), 0, "malformed version cannot publish a version")
		context.equal(publisher.prepare_packet().code, CODE.NOT_SYNCHRONIZED, "malformed version cannot publish rows")
		context.equal(publisher.encode_keepalive().is_empty(), true, "malformed version cannot publish liveness")
		context.equal(publisher.receive_accept(valid), CODE.OK, "valid corrected answer remains usable")
		context.equal(publisher.agreement_version(), Stream.VERSION, "corrected answer selects actual supported version")


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
	_negotiate(context, stream, fresh, 10)
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
			context.equal(deadline.host_deadline_elapsed(1000), false, "old deadline observation cannot authorize stopping replacement viewer")
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
			context.equal(stream.receive_packet(packets[2], 1), CODE.OK, "rejected configuration preserves stream state")
			context.equal(stream.poll(99), CODE.OK, "rejected configuration preserves stream clock")
			context.equal(stream.host_deadline_elapsed(101), not complete_end, "rejected replacement preserves original deadline or clean closure")
		var fresh: PackedByteArray = _identity()
		fresh[31] += 1
		context.equal(stream.configure(Fixture.new()._config(), fresh, _key(), _digest(), 10, 100, 128), CODE.OK, "explicit stream configuration restores fresh ownership")
		_negotiate(context, stream, fresh, 10)
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
	context.equal(stream.configure(Fixture.new()._config(), _identity(), _key(), _digest(), 0, 100, 87), CODE.INVALID_CONFIGURATION, "the packet cap must fit the startup exchange")
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
	context.equal(game.stream_codes, PackedInt32Array([CODE.BUSY, CODE.BUSY, CODE.BUSY, CODE.BUSY, CODE.BUSY]), "every stream mutation refuses callback reentry")
	context.equal(game.accept_size, 0, "game callback cannot issue startup acceptance")
	context.equal(callbacks.poll(2), CODE.OK, "callback reentry consumes no clock")


# Value: protects=live input-idle host; fails_when=valid keepalive expires or advances viewer; why_new=row delivery conflates liveness and input; seam=none
func _keepalive(context: RefCounted) -> void:
	var stream: RefCounted = _stream(context)
	var keepalive: PackedByteArray = stream.encode_keepalive()
	context.equal(
		keepalive.hex_encode(),
		"465247530303020001000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1fd2deccf9f3deb3d06e7cc546fabec43b00000000b2682cf93ac18d671c4dfca695dfb7a2",
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
	context.equal(ending.receive_packet(ending.encode_keepalive(), 101), CODE.OK, "late keepalive preserves closed input")
	context.equal(ending.playback_session().recommended_steps(), 1, "late keepalive does not reapply playback delay")
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


# Value: protects=restart stops retained old drivers; fails_when=replacement abandons a live viewer;
# why_new=lifetime cases only check delivery through the stream; seam=none
func _replaced_viewer(context: RefCounted) -> void:
	for replace: bool in [false, true]:
		var stream: RefCounted = _stream(context)
		var viewer: RefCounted = stream.playback_session()
		var game: RefCounted = GameFixture.Game.new()
		var driver: RefCounted = Driver.new(viewer, game)
		context.equal(stream.receive_packet(stream.encode_row(0, _row(0)), 0), CODE.OK, "buffer original lifetime row")
		var config: RefCounted = Fixture.new()._config()
		if not replace:
			config.queue_capacity = 0
		var identity: PackedByteArray = _identity()
		identity[31] ^= 1
		context.equal(stream.configure(config, identity, _key(), _digest(), 1, 100, 128), CODE.OK if replace else CODE.INVALID_CONFIGURATION, "replace or reject viewer")
		context.equal(driver.step(1, _empty()).code, CODE.TERMINATED if replace else CODE.OK, "retained driver obeys successful replacement")
		context.equal(game.trace.size(), 0 if replace else 1, "old callback cannot play buffered rows after restart")
		if replace:
			context.equal(viewer.receive_host_frame(1, _row(1)).code, CODE.TERMINATED, "retained old receiver is closed")
			context.equal(viewer.recommended_steps(), 0, "old advice loop stops")
			context.equal(viewer.status().reason, CODE.TERMINATED, "replacement publishes clean terminal cause")
			_negotiate(context, stream, identity, 1)
			context.equal(stream.receive_packet(stream.encode_row(0, _row(0)), 1), CODE.OK, "fresh lifetime receives original frame zero")
			var fresh_game: RefCounted = GameFixture.Game.new()
			context.equal(Driver.new(stream.playback_session(), fresh_game).step(1, _empty()).code, CODE.OK, "fresh viewer remains playable")
			context.equal(fresh_game.trace.size(), 1, "fresh callback runs once")
	var detached: RefCounted = _stream(context)
	var independent: RefCounted = detached.playback_session()
	context.equal(independent.configure(Fixture.new()._config()), CODE.OK, "caller replaces exposed viewer independently")
	context.equal(independent.receive_host_frame(0, _row(0)).code, CODE.OK, "independent viewer buffers its own row")
	context.equal(detached.configure(Fixture.new()._config(), _identity(), _key(), _digest(), 1, 100, 128), CODE.OK, "stream replaces its detached viewer")
	context.equal(Driver.new(independent, GameFixture.Game.new()).step(1, _empty()).code, CODE.OK, "stale stream cannot terminate independent viewer lifetime")
	for prior_reason: int in [CODE.OK, CODE.PROTOCOL_FAILED]:
		var ending: RefCounted = _stream(context)
		var previous: RefCounted = ending.playback_session()
		context.equal(ending.receive_packet(ending.encode_row(0, _row(0)), 0), CODE.OK, "retain clean delayed tail")
		context.equal(ending.receive_packet(ending.encode_end(1), 0), CODE.OK, "host input ends before playback")
		if prior_reason != CODE.OK:
			previous.terminate(prior_reason)
		context.equal(ending.configure(Fixture.new()._config(), _identity(), _key(), _digest(), 1, 100, 128), CODE.OK, "replace ended stream")
		context.equal(previous.status().reason, CODE.TERMINATED if prior_reason == CODE.OK else prior_reason, "replacement stops clean tail and preserves committed failures")
		context.equal(previous.recommended_steps(), 0, "replaced clean tail has no playback advice")


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
			var offer: PackedByteArray = Stream.encode_offer(_identity(), _digest(), players, width, _key())
			context.equal(stream.receive_packet(offer, 0), CODE.OK, label + " envelope agreed")
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
				context.equal(packet.size(), 80 + players * (width + 1), label + " row size")
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


# Value: protects=startup obeys elapsed expiry and callback ownership; fails_when=offers bypass poll;
# why_new=existing timeout and busy cases deliver rows or keepalives; seam=none
func _offer_lifecycle(context: RefCounted) -> void:
	_accept_lifecycle(context)
	var offer: PackedByteArray = _publisher(context).encode_offer()
	for agreed: bool in [false, true]:
		for arrival: int in [99, 100, 101]:
			var stream: RefCounted = Stream.new()
			context.equal(stream.configure(Fixture.new()._config(), _identity(), _key(), _digest(), 0, 100, 128), CODE.OK, "fresh viewer")
			if agreed:
				context.equal(stream.receive_packet(offer, 0), CODE.OK, "initial agreement")
			var expected: int = CODE.OK if arrival < 100 else CODE.PROTOCOL_FAILED
			context.equal(stream.receive_packet(offer, arrival), expected, "offer respects strict deadline")
			context.equal(stream.playback_session().status().reason, CODE.OK if arrival < 100 else CODE.PROTOCOL_FAILED, "expiry commits before agreement")
			if arrival < 100:
				context.equal(stream.poll(98), CODE.INVALID_TIME, "accepted offer consumes monotonic clock")
				context.equal(stream.poll(198), CODE.OK, "accepted offer refreshes liveness")
	var busy: RefCounted = _stream(context)
	context.equal(busy.receive_packet(busy.encode_row(0, _row(0)), 0), CODE.OK, "buffer row")
	var advance: Types.Result = busy.playback_session().begin_advance()
	context.equal(advance.code, CODE.READY, "active request")
	var request: Types.Request = advance.batch.next_request()
	context.equal(busy.receive_packet(offer, 1000), CODE.BUSY, "offer cannot mutate active request")
	context.equal(busy.receive_packet(_legacy_offer(), 1000), CODE.BUSY, "conflicting offer cannot terminate active request")
	var legacy_row: PackedByteArray = busy.encode_row(0, _row(0))
	legacy_row[4] = 1
	legacy_row = Stream.authenticate(_unsigned(legacy_row), _key())
	context.equal(busy.receive_packet(legacy_row, 1000), CODE.BUSY, "version refusal cannot terminate active request")
	context.equal(busy.playback_session().status().reason, CODE.OK, "busy refusal preserves lifecycle")
	context.equal(busy.playback_session().complete_request(request.batch_id, request.request_id, true).code, CODE.OK, "finish original request")
	context.equal(busy.poll(1), CODE.OK, "busy offers consume no clock")
	var stopped: RefCounted = _stream(context)
	stopped.playback_session().terminate(CODE.CALLBACK_FAILED)
	context.equal(stopped.receive_packet(offer, 1), CODE.TERMINATED, "offer cannot revive terminated viewer")
	context.equal(stopped.playback_session().status().reason, CODE.CALLBACK_FAILED, "original terminal reason preserved")
	var ended: RefCounted = _stream(context)
	context.equal(ended.receive_packet(ended.encode_end(0), 0), CODE.OK, "clean end")
	context.equal(ended.receive_packet(offer, 1), CODE.OK, "retried offer preserves closed input")
	context.equal(ended.playback_session().begin_advance().code, CODE.TERMINATED, "retried offer cannot reopen empty closed input")
	var replaced: RefCounted = _stream(context)
	context.equal(replaced.playback_session().configure(Fixture.new()._config()), CODE.OK, "replace exposed viewer")
	context.equal(replaced.encode_accept().is_empty(), true, "old agreement cannot answer for replacement viewer")


# Value: protects=only a live idle viewer authenticates startup acceptance; fails_when=delayed control starts host publication after viewer failure;
# why_new=offer lifecycle checks ingress but not the outgoing answer; seam=none
func _accept_lifecycle(context: RefCounted) -> void:
	for cause: String in ["live", "timeout", "failure", "complete", "busy"]:
		var stream: RefCounted = Stream.new()
		context.equal(stream.configure(Fixture.new()._config(), _identity(), _key(), _digest(), 0, 100, 128), CODE.OK, "fresh awaiting-answer viewer")
		var publisher: RefCounted = _publisher(context)
		context.equal(stream.receive_packet(publisher.encode_offer(), 0), CODE.OK, "offer accepted before control handoff")
		var original: PackedByteArray = stream.encode_accept()
		context.equal(original.is_empty(), false, "live viewer can answer startup")
		context.equal(publisher.agreement_state(), Negotiation.AgreementState.PENDING, "host still waits for actual answer")
		var viewer: RefCounted = stream.playback_session()
		var request: Types.Request
		match cause:
			"timeout":
				context.equal(stream.poll(100), CODE.PROTOCOL_FAILED, "viewer expires while answer waits")
			"failure":
				viewer.terminate(CODE.CALLBACK_FAILED)
			"complete":
				context.equal(stream.receive_packet(stream.encode_end(0), 0), CODE.OK, "close empty stream")
				context.equal(viewer.begin_advance().code, CODE.TERMINATED, "playback completes before answer retry")
			"busy":
				context.equal(stream.receive_packet(stream.encode_row(0, _row(0)), 0), CODE.OK, "retain first host row")
				var advance: Types.Result = viewer.begin_advance()
				context.equal(advance.code, CODE.READY, "active viewer request fences control")
				request = advance.batch.next_request()
		var answer: PackedByteArray = stream.encode_accept()
		context.equal(answer.is_empty(), cause != "live", "answer respects viewer lifecycle: " + cause)
		context.equal(publisher.receive_accept(answer), CODE.OK if cause == "live" else CODE.PROTOCOL_FAILED, "dead or busy viewer cannot start host publication")
		context.equal(publisher.agreement_state(), Negotiation.AgreementState.AGREED if cause == "live" else Negotiation.AgreementState.PENDING, "only live answer starts host")
		if cause == "busy":
			context.equal(viewer.complete_request(request.batch_id, request.request_id, true).code, CODE.OK, "complete viewer request")
			context.equal(stream.encode_accept(), original, "retry after request completion preserves exact acceptance")
			context.equal(publisher.receive_accept(stream.encode_accept()), CODE.OK, "control can retry after busy request")
		elif cause != "live":
			var reason: int = CODE.TERMINATED if cause == "complete" else (CODE.CALLBACK_FAILED if cause == "failure" else CODE.PROTOCOL_FAILED)
			context.equal(viewer.status().reason, reason, "encoding preserves first terminal cause")


# Value: protects=clean tail survives late retries; fails_when=input closure reports playback termination;
# why_new=clean-tail case sends no trailing packets; seam=none
func _closed_input_duplicates(context: RefCounted) -> void:
	for kind: String in [
		"row", "end", "keepalive", "offer", "conflicting_row", "conflicting_status", "conflicting_future", "conflicting_end", "conflicting_offer", "forged", "foreign"
	]:
		var stream: RefCounted = _stream(context)
		var viewer: RefCounted = stream.playback_session()
		context.equal(viewer.set_playback(2, 1, 3), CODE.OK, "hold a delayed tail")
		var row: PackedByteArray = stream.encode_row(0, _row(0))
		var end: PackedByteArray = stream.encode_end(1)
		var packet: PackedByteArray = row
		match kind:
			"end":
				packet = end
			"keepalive":
				packet = stream.encode_keepalive()
			"offer", "conflicting_offer":
				packet = Stream.encode_offer(_identity(), _digest(), 2, 1, _key())
				if kind == "conflicting_offer":
					var unsigned: PackedByteArray = _unsigned(packet)
					unsigned.encode_u32(64 + 4, Negotiation.CAP_ROW | Negotiation.CAP_END)
					packet = Stream.authenticate(unsigned, _key())
			"conflicting_row":
				packet = stream.encode_row(0, _row(1))
			"conflicting_status":
				packet = stream.encode_row(0, _row(0), PackedByteArray([Session.Queue.Status.DISCONNECTED, Session.Queue.Status.CONFIRMED]))
			"conflicting_future":
				packet = stream.encode_row(1, _row(1))
			"foreign":
				var foreign: PackedByteArray = _identity()
				foreign[0] ^= 1
				packet = Stream.authenticate(Stream.encode_header(Stream.KEEPALIVE, 0, 2, 1, foreign, _digest()), _key())
			"conflicting_end":
				packet = stream.encode_end(2)
			"forged":
				packet = end.duplicate()
				packet[64] ^= 1
		context.equal(stream.receive_packet(row, 1), CODE.OK, "retain original final row")
		context.equal(stream.receive_packet(end, 2), CODE.OK, "close complete input without playing it")
		context.equal(viewer.status().current_frame, 0, "tail remains paused before late packet")
		var expected: int = CODE.PROTOCOL_FAILED if kind.begins_with("conflicting") or kind in ["forged", "foreign"] else CODE.OK
		context.equal(stream.receive_packet(packet, 1000), expected, "late packet disposition: " + kind)
		if kind.begins_with("conflicting"):
			context.equal(viewer.status().reason, CODE.PROTOCOL_FAILED, "authenticated contradiction still terminates")
			continue
		context.equal(viewer.status().lifecycle, Types.Lifecycle.RUNNING, "retry or forgery cannot terminate accepted clean tail")
		context.equal(viewer.host_frontier(), 0, "late packet cannot change complete history")
		var game: RefCounted = GameFixture.Game.new()
		var driver: RefCounted = Driver.new(viewer, game)
		context.equal(driver.step(0, _empty()).code, CODE.OK, "play original final row")
		context.equal(game.value, 1, "canonical tail uses original row")
		context.equal(driver.step(1, _empty()).code, CODE.TERMINATED, "terminate only after tail playback")
		context.equal(stream.receive_packet(end, 1001), CODE.TERMINATED, "actual playback termination remains terminal")


# Value: protects=original state agreement before authenticated playback; fails_when=only seeds bind startup;
# why_new=existing match digest omits canonical initial bytes; seam=none
func _initial_state_agreement(context: RefCounted) -> void:
	var helper: RefCounted = Stream.new()
	context.equal(helper.has_method("configuration_digest_with_state"), true, "canonical initial state can bind startup")
	if not helper.has_method("configuration_digest_with_state"):
		return
	var config: RefCounted = Fixture.new()._config()
	var original: PackedByteArray = PackedByteArray([7, 0, 0, 0, 0, 0, 0, 0])
	var digest: PackedByteArray = helper.configuration_digest_with_state(config, "seed-1", "rules-1", original)
	context.equal(digest.hex_encode(), "fb45ca3df137d6c84f90667de679b66b", "independent SHA-256 configuration and canonical state golden")
	context.equal(helper.configuration_digest_with_state(config, "seed-1", "rules-1", original.duplicate()), digest, "equal owned state agrees")
	original[7] = 9
	var different: PackedByteArray = helper.configuration_digest_with_state(config, "seed-1", "rules-1", original)
	context.equal(different != digest, true, "one changed same-length state byte changes agreement")
	context.equal(digest.hex_encode(), "fb45ca3df137d6c84f90667de679b66b", "caller mutation cannot rewrite previously derived digest")
	var empty: PackedByteArray = helper.configuration_digest_with_state(config, "seed-1", "rules-1", PackedByteArray())
	context.equal(empty.size(), Stream.DIGEST_BYTES, "explicit empty snapshot has a state-bound digest")
	context.equal(empty != _digest(), true, "explicit empty snapshot is distinct from legacy unbound digest")
	context.equal(_digest().hex_encode(), "d2deccf9f3deb3d06e7cc546fabec43b", "legacy configuration digest is unchanged")
	original.resize(config.max_snapshot_bytes + 1)
	context.equal(helper.configuration_digest_with_state(config, "seed-1", "rules-1", original).is_empty(), true, "oversized initial state refused")
	context.equal(helper.configuration_digest_with_state(null, "seed-1", "rules-1", PackedByteArray()).is_empty(), true, "invalid configuration refused")
	context.equal(helper.configuration_digest_with_state(config, "seed\n", "rules-1", PackedByteArray()).is_empty(), true, "noncanonical metadata refused")
	for offered: PackedByteArray in [digest, different, _digest(), empty]:
		var viewer: RefCounted = Stream.new()
		context.equal(viewer.configure(config, _identity(), _key(), digest, 0, 100, 128), CODE.OK, "viewer agrees original canonical state")
		var offer: PackedByteArray = Stream.encode_offer(_identity(), offered, 2, 1, _key())
		context.equal(viewer.receive_packet(offer, 1), CODE.OK if offered == digest else CODE.PROTOCOL_FAILED, "startup accepts only matching initial state")
		context.equal(viewer.agreement_version(), Stream.VERSION if offered == digest else 0, "mismatch cannot negotiate playback")
		context.equal(viewer.playback_session().host_frontier(), -1, "startup never fabricates a confirmed row")
		if offered == digest:
			var game: RefCounted = GameFixture.Game.new()
			game.value = 7
			var driver: RefCounted = Driver.new(viewer.playback_session(), game)
			context.equal(viewer.receive_packet(viewer.encode_row(0, _row(0)), 2), CODE.OK, "state-bound original row admitted")
			context.equal(driver.step(0, _empty()).code, CODE.OK, "matching original world starts playback")
			context.equal(game.value, 64, "independent canonical state after initial value seven and original inputs")
		context.equal(viewer.poll(100), CODE.OK if offered == digest else CODE.PROTOCOL_FAILED, "mismatched state never refreshes host deadline")


# Value: protects=transport-independent obsolete row retries; fails_when=evicted input fails a healthy stream or renews liveness;
# why_new=relay masks errors only for SDK callers; seam=none
func _obsolete_rows(context: RefCounted) -> void:
	for closed_tail: bool in [false, true]:
		var stream: RefCounted = _stream(context)
		var viewer: RefCounted = stream.playback_session()
		var game: RefCounted = GameFixture.Game.new()
		var driver: RefCounted = Driver.new(viewer, game)
		var obsolete: PackedByteArray = stream.encode_row(0, _row(0))
		var expected: int = 0
		for frame: int in range(12):
			context.equal(stream.receive_packet(stream.encode_row(frame, _row(frame)), frame + 1), CODE.OK, "accept original through ring reuse")
			if not closed_tail or frame < 8:
				context.equal(driver.step(frame, _empty()).code, CODE.OK, "play original confirmed prefix")
				for player: int in range(2):
					expected = expected * 3 + _row(frame)[player][0] + frame
		if closed_tail:
			context.equal(stream.receive_packet(stream.encode_end(12), 13), CODE.OK, "close input with a retained unplayed tail")
		var before: int = viewer.status().current_frame
		var malformed: PackedByteArray = obsolete.duplicate()
		malformed[malformed.size() - 1] = 255
		malformed = Stream.authenticate(_unsigned(malformed), _key())
		context.equal(stream.receive_packet(malformed, 20), CODE.INVALID_CONFIGURATION, "obsolete rows still validate finalized statuses")
		var forged: PackedByteArray = obsolete.duplicate()
		forged[64] ^= 1
		context.equal(stream.receive_packet(forged, 20), CODE.PROTOCOL_FAILED, "obsolete rows still authenticate their bytes")
		context.equal(stream.receive_packet(obsolete, 20), CODE.OK, "authenticated obsolete row is inert for every transport")
		context.equal(stream.host_status().liveness_time_us, 13 if closed_tail else 12, "obsolete input cannot fabricate recent host activity")
		context.equal(viewer.status().current_frame, before, "obsolete traffic preserves displayed boundary")
		context.equal(viewer.host_frontier(), 11, "obsolete traffic preserves contiguous host history")
		context.equal(game.value, expected, "obsolete traffic never repeats simulation")
		if closed_tail:
			for frame: int in range(8, 12):
				context.equal(driver.step(frame, _empty()).code, CODE.OK, "late retry preserves complete clean tail")
				for player: int in range(2):
					expected = expected * 3 + _row(frame)[player][0] + frame
			context.equal(game.value, expected, "clean tail equals original canonical input history")
			context.equal(driver.step(12, _empty()).code, CODE.TERMINATED, "tail completion remains authoritative")
			context.equal(viewer.is_complete(), true, "obsolete retry cannot prevent clean completion")
		else:
			context.equal(stream.receive_packet(obsolete, 111), CODE.OK, "obsolete retry before deadline remains inert")
			context.equal(stream.receive_packet(obsolete, 112), CODE.PROTOCOL_FAILED, "obsolete retry cannot renew host deadline")
			context.equal(driver.step(12, _empty()).code, CODE.TERMINATED, "real host expiry stops viewing")


# Value: protects=host liveness and overtaking END are observable independently of playback;
# fails_when=observation consumes time or hides missing final inputs; why_new=playback status has no wire END or host deadline; seam=none
func _host_observation(context: RefCounted) -> void:
	var unconfigured: RefCounted = Stream.new()
	context.equal(unconfigured.has_method("host_status"), true, "custom transports can observe host liveness separately from playback")
	if not unconfigured.has_method("host_status"):
		return
	context.equal(unconfigured.host_status().code, CODE.NOT_CONFIGURED, "no host before configuration")
	context.equal(unconfigured.host_status().timeout_remaining_us, -1, "unconfigured host has no deadline")
	for closes: bool in [false, true]:
		var stream: RefCounted = _stream(context)
		var viewer: RefCounted = stream.playback_session()
		var initial: Dictionary = stream.host_status()
		context.equal(initial.size(), 7, "host observation contains only documented scalar fields")
		context.equal(initial.observed_time_us, 0, "initial protocol clock")
		context.equal(initial.liveness_time_us, 0, "configuration establishes first liveness baseline")
		context.equal(initial.timeout_remaining_us, 100, "full initial host deadline")
		context.equal(initial.end_frame, -1, "no invented clean ending")
		context.equal(initial.missing_frame, -1, "no invented input gap")
		context.equal(stream.receive_packet(stream.encode_row(2, _row(2)), 10), CODE.OK, "receive future row without its prefix")
		if closes:
			context.equal(stream.receive_packet(stream.encode_end(3), 20), CODE.OK, "END overtakes missing final inputs")
		var waiting: Dictionary = stream.host_status()
		context.equal(waiting.code, CODE.OK, "gapped stream remains serviceable")
		context.equal(waiting.missing_frame, 0, "first missing input remains visible")
		context.equal(waiting.end_frame, 3 if closes else -1, "report only authenticated exclusive END")
		context.equal(waiting.input_closed, false, "END cannot close incomplete input")
		context.equal(stream.receive_packet(stream.encode_keepalive(), 30), CODE.OK, "heartbeat refreshes host without repairing gap")
		context.equal(stream.poll(129), CODE.OK, "observe immediately before exact host deadline")
		var observed: Dictionary = stream.host_status()
		context.equal(observed.observed_time_us, 129, "observation uses accepted injected protocol clock")
		context.equal(observed.liveness_time_us, 30, "poll does not fabricate host receipt")
		context.equal(observed.timeout_remaining_us, 1, "one microsecond before deadline")
		context.equal(observed.missing_frame, 0, "heartbeat does not fill missing input")
		observed.liveness_time_us = 1000
		context.equal(stream.host_status().liveness_time_us, 30, "returned dictionary is caller-owned")
		context.equal(viewer.host_frontier(), -1, "reads do not accept input")
		context.equal(viewer.status().current_frame, 0, "reads do not play input")
		var events: Array[RefCounted] = viewer.drain_events()
		context.equal(events.size(), 1, "observational reads preserve waiting-for-host notification")
		if closes:
			context.equal(stream.receive_packet(stream.encode_row(0, _row(0)), 129), CODE.OK, "late prefix before expiry remains recoverable")
			context.equal(stream.host_status().missing_frame, 1, "next final gap is observable")
			context.equal(stream.receive_packet(stream.encode_row(1, _row(1)), 130), CODE.OK, "last gap releases complete clean tail")
			context.equal(stream.poll(1000), CODE.OK, "complete final input no longer needs host liveness")
			var complete: Dictionary = stream.host_status()
			context.equal(complete.end_frame, 3, "exclusive END remains visible during playback")
			context.equal(complete.missing_frame, -1, "complete input clears gap")
			context.equal(complete.input_closed, true, "last original row closes input")
			context.equal(complete.timeout_remaining_us, -1, "clean tail has no host deadline")
		else:
			context.equal(stream.poll(130), CODE.PROTOCOL_FAILED, "observational reads do not renew host deadline at equality")
			context.equal(stream.host_status().code, CODE.TERMINATED, "actual host failure is visible")
			context.equal(stream.host_status().timeout_remaining_us, 0, "elapsed host deadline stays elapsed")
	var replaced: RefCounted = _stream(context)
	context.equal(replaced.receive_packet(replaced.encode_end(3), 20), CODE.OK, "retain old lifetime final target")
	context.equal(replaced.playback_session().configure(Fixture.new()._config()), CODE.OK, "replace exposed viewer")
	context.equal(replaced.host_status().code, CODE.INVALID_CONFIGURATION, "old host observation cannot describe replacement as connected")
	context.equal(replaced.host_status().end_frame, -1, "replacement does not mix old END with new input")
	context.equal(replaced.host_status().liveness_time_us, -1, "replacement does not inherit old host liveness")
	context.equal(replaced.host_status().timeout_remaining_us, -1, "replacement does not inherit old deadline")
	var busy: RefCounted = _stream(context)
	context.equal(busy.receive_packet(busy.encode_row(0, _row(0)), 10), CODE.OK, "retain input before active request")
	context.equal(busy.playback_session().begin_advance().code, CODE.READY, "open expert request")
	context.equal(busy.host_status().code, CODE.BUSY, "observation reports active request ownership")
	context.equal(busy.host_status().liveness_time_us, 10, "busy observation retains accepted liveness")
	busy.playback_session().terminate()
