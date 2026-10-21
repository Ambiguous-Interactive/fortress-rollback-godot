extends RefCounted

const Publisher = preload("res://addons/fortress_rollback/core/spectator_publisher.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Stream = preload("res://addons/fortress_rollback/core/spectator_stream.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Fixture = preload("res://tests/unit/test_spectator_session.gd")
const GameFixture = preload("res://tests/unit/test_driver.gd")
const CODE = Types.Code




func _key() -> PackedByteArray:
	var key: PackedByteArray = PackedByteArray()
	key.resize(32)
	for value: int in range(32):
		key[value] = value + 1
	return key


func _digest(config: Variant = null) -> PackedByteArray:
	var agreed: Variant = config if config != null else Fixture.new()._config()
	return Stream.configuration_digest(agreed, "seed-1", "rules-1")

func cases() -> PackedStringArray:
	return PackedStringArray(["retained_publication", "clean_end", "lifetime_and_busy"])


func run_case(name: String, context: RefCounted) -> void:
	call("_" + name, context)
	context.finish()


func _identity() -> PackedByteArray:
	var identity: PackedByteArray = PackedByteArray()
	identity.resize(32)
	return identity


func _config() -> RefCounted:
	return Fixture.new().host_config()


## One startup exchange between the publisher and a viewer stream.
func _negotiate(context: RefCounted, publisher: RefCounted) -> RefCounted:
	var stream: RefCounted = Stream.new()
	context.equal(stream.configure(Fixture.new()._config(), _identity(), _key(), _digest(), 0, 100, 128), CODE.OK, "configured viewer")
	context.equal(Fixture.new().negotiate(publisher, stream), CODE.OK, "envelope agreed before the first row")
	return stream


func _step(context: RefCounted, driver: RefCounted, frame: int) -> void:
	var inputs: Array[Driver.LocalInput] = []
	for player: int in range(2):
		inputs.append(Driver.LocalInput.new(player, frame, Fixture.new()._row(frame)[player]))
	context.equal(driver.step(frame, inputs).code, CODE.OK, "host advances actual row")


# Value: protects=refused packet survives host overwrite; fails_when=retry rereads evicted row or changes cursor; why_new=demo lacks isolated refusal ownership; seam=none
func _retained_publication(context: RefCounted) -> void:
	var host: RefCounted = Session.new()
	context.equal(host.configure(_config()), CODE.OK, "bounded host")
	var driver: RefCounted = Driver.new(host, GameFixture.Game.new())
	var publisher: RefCounted = Publisher.new()
	context.equal(publisher.configure(host, _identity(), _key(), _digest(), 128), CODE.OK, "bounded publisher")
	_negotiate(context, publisher)
	context.equal(publisher.prepare_packet().code, CODE.PREDICTION_STALL, "idle host has no row")
	_step(context, driver, 0)
	context.equal(host.confirmed_inputs(0) != null, true, "control: original host row retained")
	var original: PackedByteArray = publisher.prepare_packet().bytes
	var changed: PackedByteArray = publisher.prepare_packet().bytes
	changed.fill(255)
	context.equal(publisher.acknowledge_packet(changed), CODE.STALE_REQUEST, "mutated acknowledgement cannot consume row")
	for frame: int in range(1, 6):
		_step(context, driver, frame)
	context.equal(host.confirmed_inputs(0) == null, true, "negative control: original source cursor lost at ring wrap")
	context.equal(publisher.prepare_packet().bytes, original, "refused row survives source eviction and caller mutation")
	context.equal(publisher.next_frame(), 0, "preparing and refusing cannot skip a row")
	context.equal(publisher.encode_keepalive()[5], Stream.KEEPALIVE, "liveness remains sendable with retained row")
	context.equal(publisher.acknowledge_packet(original), CODE.OK, "transport accepts original bytes")
	context.equal(publisher.next_frame(), 1, "exact acceptance advances once")
	context.equal(publisher.acknowledge_packet(original), CODE.STALE_REQUEST, "duplicate acceptance cannot skip next row")
	context.equal(publisher.prepare_packet().bytes.decode_u32(60), 1, "next retained source row follows")
	for frame: int in range(6, 8):
		_step(context, driver, frame)
	context.equal(publisher.prepare_packet().code, CODE.HISTORY_UNAVAILABLE, "missing row beyond retained head fails explicitly")


# Value: protects=confirmed rows precede exact exclusive end; fails_when=END overtakes unsent input or idle pulse moves cursor; why_new=receiver tests bypass sender; seam=none
func _clean_end(context: RefCounted) -> void:
	for frames: int in [0, 3]:
		var host: RefCounted = Session.new()
		host.configure(_config())
		var driver: RefCounted = Driver.new(host, GameFixture.Game.new())
		var publisher: RefCounted = Publisher.new()
		publisher.configure(host, _identity(), _key(), _digest(), 128)
		var stream: RefCounted = _negotiate(context, publisher)
		for frame: int in range(frames):
			_step(context, driver, frame)
		context.equal(publisher.finish_host(), CODE.OK, "freeze confirmed exclusive end")
		for frame: int in range(frames + 1):
			var packet: PackedByteArray = publisher.prepare_packet().bytes
			context.equal(packet[5], Stream.END if frame == frames else Stream.ROW, "all rows precede end")
			context.equal(packet.decode_u32(60), frame, "wire frame matches accepted cursor")
			context.equal(stream.receive_packet(packet, frame), CODE.OK, "real receiver accepts publisher bytes")
			context.equal(publisher.acknowledge_packet(packet), CODE.OK, "accept complete packet")
		context.equal(publisher.prepare_packet().code, CODE.TERMINATED, "accepted END closes publication")
		context.equal(publisher.encode_keepalive().is_empty(), true, "closed publisher emits no heartbeat")
		var viewer_driver: RefCounted = Driver.new(stream.playback_session(), GameFixture.Game.new())
		var empty: Array[Driver.LocalInput] = []
		for frame: int in range(frames):
			context.equal(viewer_driver.step(frame, empty).code, CODE.OK, "viewer plays every host row")
		context.equal(viewer_driver.step(frames, empty).code, CODE.TERMINATED, "viewer observes clean end")

	var gated_host: RefCounted = Session.new()
	gated_host.configure(_config())
	gated_host.set_confirmation_limit(-1)
	var gated_driver: RefCounted = Driver.new(gated_host, GameFixture.Game.new())
	var gated: RefCounted = Publisher.new()
	gated.configure(gated_host, _identity(), _key(), _digest(), 128)
	_negotiate(context, gated)
	_step(context, gated_driver, 0)
	context.equal(gated.finish_host(), CODE.PREDICTION_STALL, "unconfirmed tail cannot become clean END")
	context.equal(gated.prepare_packet().code, CODE.PREDICTION_STALL, "unconfirmed row cannot publish")
	gated_host.set_confirmation_limit(0)
	context.equal(gated.finish_host(), CODE.OK, "confirmed tail freezes")
	_step(context, gated_driver, 1)
	context.equal(gated.prepare_packet().code, CODE.INVALID_FRAME, "host advancing beyond frozen end fails explicitly")
	for retain_end: bool in [false, true]:
		var stopped: RefCounted = Session.new()
		stopped.configure(_config())
		var stopped_driver: RefCounted = Driver.new(stopped, GameFixture.Game.new())
		var frozen: RefCounted = Publisher.new()
		frozen.configure(stopped, _identity(), _key(), _digest(), 128)
		_negotiate(context, frozen)
		_step(context, stopped_driver, 0)
		frozen.finish_host()
		var pending: PackedByteArray = frozen.prepare_packet().bytes
		if retain_end:
			frozen.acknowledge_packet(pending)
			pending = frozen.prepare_packet().bytes
		_step(context, stopped_driver, 1)
		context.equal(frozen.acknowledge_packet(pending), CODE.INVALID_FRAME, "frozen host advance fences retained ROW and END acknowledgement")
		context.equal(frozen.next_frame(), 1 if retain_end else 0, "refused frozen acknowledgement preserves cursor")
		context.equal(frozen.encode_keepalive().is_empty(), true, "frozen host advance cannot prolong old stream liveness")


# Value: protects=source lifetime and active batch fences; fails_when=reconfigure or callback acknowledges old bytes; why_new=receiver busy tests omit sender; seam=none
func _lifetime_and_busy(context: RefCounted) -> void:
	var host: RefCounted = Session.new()
	host.configure(_config())
	var driver: RefCounted = Driver.new(host, GameFixture.Game.new())
	var publisher: RefCounted = Publisher.new()
	context.equal(publisher.configure(host, _identity(), _key(), _digest(), 81), CODE.INVALID_CONFIGURATION, "reject undersized packet bound")
	context.equal(publisher.prepare_packet().code, CODE.NOT_CONFIGURED, "rejected configure remains inert")
	publisher.configure(host, _identity(), _key(), _digest(), 128)
	_negotiate(context, publisher)
	_step(context, driver, 0)
	var packet: PackedByteArray = publisher.prepare_packet().bytes
	for player: int in range(2):
		host.submit_local_input(player, 1, Fixture.new()._row(1)[player])
	var batch: Types.Result = host.begin_advance()
	context.equal(batch.code, CODE.READY, "active host batch")
	context.equal(publisher.prepare_packet().code, CODE.BUSY, "prepared bytes do not bypass host guard")
	context.equal(publisher.acknowledge_packet(packet), CODE.BUSY, "active batch cannot move cursor")
	context.equal(publisher.configure(host, _identity(), _key(), _digest(), 128), CODE.BUSY, "active publisher cannot be replaced")
	context.equal(publisher.finish_host(), CODE.BUSY, "active batch cannot end host")
	context.equal(publisher.encode_keepalive().is_empty(), true, "callback cannot publish heartbeat")
	var request: Types.Request = batch.batch.next_request()
	host.complete_request(request.batch_id, request.request_id, true)
	context.equal(host.configure(_config()), CODE.OK, "fresh source lifetime with same dimensions")
	context.equal(publisher.prepare_packet().code, CODE.INVALID_CONFIGURATION, "fresh source cannot emit stale retained bytes")
	context.equal(publisher.acknowledge_packet(packet), CODE.STALE_REQUEST, "fresh source cannot accept old acknowledgement")
	context.equal(publisher.encode_keepalive().is_empty(), true, "fresh source cannot keep old receiver alive")
	context.equal(publisher.finish_host(), CODE.INVALID_CONFIGURATION, "fresh source cannot freeze old end")

	context.equal(publisher.configure(host, _identity(), _key(), _digest(), 128), CODE.OK, "explicit fresh publisher lifetime")
	_negotiate(context, publisher)
	_step(context, driver, 0)
	packet = publisher.prepare_packet().bytes
	host.terminate(CODE.PROTOCOL_FAILED)
	context.equal(publisher.prepare_packet().code, CODE.TERMINATED, "source loss fences retained packet")
	context.equal(publisher.acknowledge_packet(packet), CODE.TERMINATED, "source loss fences acknowledgement")
	context.equal(publisher.encode_keepalive().is_empty(), true, "source loss emits no heartbeat")
