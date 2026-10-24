extends RefCounted

# Value: protects=SDK spectator ingress ownership and expiry; fails_when=foreign traffic or buffered rows outlive their room; why_new=no SDK viewer bridge; seam=public SDK signals
const Relay = preload("res://addons/fortress_rollback/transport/signalfish_spectator_relay.gd")
const Stream = preload("res://addons/fortress_rollback/core/spectator_stream.gd")
const StreamFixture = preload("res://tests/unit/test_spectator_stream.gd")
const Fixture = preload("res://tests/unit/test_spectator_session.gd")
const RelayFixture = preload("res://tests/unit/test_signalfish_relay.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const GameFixture = preload("res://tests/unit/test_driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const HOST: String = RelayFixture.V
const FOREIGN: String = RelayFixture.W


class Client:
	extends RefCounted
	signal game_data_binary_received(from_uuid: String, encoding: int, bytes: PackedByteArray)
	signal spectator_left(room_id: String, room_code: String, reason: int, spectators: Array)
	signal spectator_joined(info: RefCounted)
	signal new_spectator_joined(spectator: RefCounted, spectators: Array, reason: int)
	signal spectator_disconnected(spectator_id: String, reason: int, spectators: Array)
	signal disconnected(code: int, reason: String)
	var room: String = "room-one"
	var state: int = Relay.SPECTATING
	var connection: int = Relay.CONNECTED
	var player: String = ""

	func get_room_id() -> String:
		return room

	func get_connection_state() -> int:
		return connection

	func get_player_id() -> String:
		return player

	func get_session_state() -> int:
		return state


class Info:
	extends RelayFixture.Info
	var capabilities: Array[String] = ["spectator_relay"]

	func to_dict() -> Dictionary:
		var data: Dictionary = super.to_dict()
		data.capabilities = capabilities.duplicate()
		return data


func cases() -> PackedStringArray:
	return PackedStringArray(
		["startup", "playback", "refusal", "queue_pressure", "expiry", "lifetimes", "configuration", "busy", "blocked_liveness", "retained_callbacks", "busy_deadline"]
	)


func run_case(name: String, context: RefCounted) -> void:
	call("_" + name, context)
	context.finish()


func _fixture(context: RefCounted, negotiate: bool = true) -> Dictionary:
	var helper: RefCounted = StreamFixture.new()
	var stream: Stream = Stream.new()
	context.equal(stream.configure(Fixture.new()._config(), helper._identity(), helper._key(), helper._digest(), 0, 100, 128), Types.Code.OK, "viewer configured")
	var client: Client = Client.new()
	var config: RelayFixture.SDKConfig = RelayFixture.SDKConfig.new()
	var info: Info = Info.new()
	var relay: Relay = Relay.new()
	var options: Relay.Options = Relay.Options.new()
	options.max_packet_bytes = 128
	options.max_received_packets = 2
	options.max_received_bytes = 256
	options.max_receives_per_poll = 1
	context.equal(relay.configure(client, config, info, stream, HOST, options), Relay.Code.OK, "read-only SDK ingress configured")
	var publisher: RefCounted = helper._publisher(context)
	if negotiate:
		context.equal(Fixture.new().negotiate(publisher, stream), Types.Code.OK, "separate explicit startup control exchange")
	var game: RefCounted = GameFixture.Game.new()
	var driver: Driver = Driver.new(stream.playback_session(), game)
	return {"relay": relay, "stream": stream, "client": client, "config": config, "info": info, "publisher": publisher, "driver": driver, "game": game}


func _emit(fixture: Dictionary, packet: PackedByteArray) -> void:
	fixture.client.game_data_binary_received.emit(HOST, 1, packet)


func _startup(context: RefCounted) -> void:
	var fixture: Dictionary = _fixture(context, false)
	_emit(fixture, fixture.publisher.encode_offer())
	context.equal(fixture.publisher.prepare_packet().code, Types.Code.NOT_SYNCHRONIZED, "host cannot infer viewer acceptance")
	context.equal(fixture.relay.poll(1).received, 1, "SDK carries authenticated OFFER")
	var accept: PackedByteArray = fixture.stream.encode_accept()
	context.equal(accept.size(), Stream.NEGOTIATION_BYTES, "acceptance remains explicitly caller-owned")
	context.equal(fixture.publisher.prepare_packet().code, Types.Code.NOT_SYNCHRONIZED, "relay does not invent spectator uplink")
	context.equal(fixture.publisher.receive_accept(accept), Types.Code.OK, "external control handoff completes publisher agreement")
	fixture.relay.detach()


func _playback(context: RefCounted) -> void:
	var fixture: Dictionary = _fixture(context)
	var expected: int = 0
	for frame: int in 12:
		var bytes: PackedByteArray = fixture.stream.encode_row(frame, Fixture.new()._row(frame))
		_emit(fixture, bytes)
		bytes[bytes.size() - 1] ^= 1
		context.equal(fixture.relay.poll(frame + 1).received, 1, "owned SDK packet delivered through ring wrap")
		context.equal(fixture.driver.step(frame, _empty()).code, Types.Code.OK, "viewer plays finalized host row")
		for player: int in 2:
			expected = expected * 3 + Fixture.new()._row(frame)[player][0] + frame
		context.equal(fixture.game.value, expected, "independent original canonical state")
	_emit(fixture, fixture.stream.encode_end(12))
	context.equal(fixture.relay.poll(13).received, 1, "END delivered")
	context.equal(fixture.relay.status().received_bytes, 0, "retained bytes drained")
	fixture.relay.detach()


func _refusal(context: RefCounted) -> void:
	var fixture: Dictionary = _fixture(context)
	var bytes: PackedByteArray = fixture.stream.encode_row(0, Fixture.new()._row(0))
	var forged: PackedByteArray = bytes.duplicate()
	forged[64] ^= 1
	for _index: int in 4:
		fixture.client.game_data_binary_received.emit(FOREIGN, 1, bytes)
		fixture.client.game_data_binary_received.emit(HOST, 0, bytes)
		_emit(fixture, forged)
	var helper: RefCounted = StreamFixture.new()
	var foreign: PackedByteArray = helper._identity()
	foreign[0] ^= 1
	_emit(fixture, Stream.encode_offer(foreign, helper._digest(), 2, 1, helper._key()))
	context.equal(fixture.relay.status().received_packets, 0, "foreign identity and forged tags never occupy receive capacity")
	context.equal(fixture.relay.status().code, Relay.Code.OK, "foreign floods do not terminate viewer")
	context.equal(fixture.relay.poll(99).code, Relay.Code.OK, "foreign input leaves liveness untouched")
	context.equal(fixture.relay.poll(100).peer_code, Types.Code.PROTOCOL_FAILED, "strict expiry despite foreign input")
	fixture.relay.detach()


func _queue_pressure(context: RefCounted) -> void:
	var fixture: Dictionary = _fixture(context)
	for frame: int in 2:
		_emit(fixture, fixture.stream.encode_row(frame, Fixture.new()._row(frame)))
	context.equal(fixture.relay.poll(1).received, 1, "one receive per service turn")
	context.equal(fixture.relay.status().received_packets, 1, "FIFO tail remains owned")
	context.equal(fixture.relay.poll(2).received, 1, "next bounded turn drains tail")
	for frame: int in [2, 3, 4]:
		_emit(fixture, fixture.stream.encode_row(frame, Fixture.new()._row(frame)))
	context.equal(fixture.relay.status().code, Relay.Code.RECEIVE_OVERFLOW, "valid-host overflow explicitly fails closed")
	context.equal(fixture.relay.status().received_packets, 0, "overflow releases terminal retained packets")
	context.equal(fixture.driver.step(0, _empty()).code, Types.Code.TERMINATED, "buffered history cannot play after overflow")
	fixture.relay.detach()


func _expiry(context: RefCounted) -> void:
	var fixture: Dictionary = _fixture(context)
	_emit(fixture, fixture.stream.encode_row(0, Fixture.new()._row(0)))
	context.equal(fixture.relay.poll(100).peer_code, Types.Code.PROTOCOL_FAILED, "deadline equality wins before buffered row")
	context.equal(fixture.stream.playback_session().host_frontier(), -1, "expired packet never reaches input history")
	context.equal(fixture.driver.step(0, _empty()).code, Types.Code.TERMINATED, "expired viewer cannot consume buffered gameplay")
	fixture.relay.detach()


func _lifetimes(context: RefCounted) -> void:
	var roster: Dictionary = _fixture(context)
	_emit(roster, roster.stream.encode_row(0, Fixture.new()._row(0)))
	roster.client.new_spectator_joined.emit(RefCounted.new(), [], 0)
	roster.client.spectator_disconnected.emit(FOREIGN, 0, [])
	context.equal(roster.relay.poll(1).received, 1, "other viewers' roster signals preserve queued host delivery")
	context.equal(roster.driver.step(0, _empty()).code, Types.Code.OK, "other viewers cannot terminate playback")
	roster.relay.detach()
	for event: String in ["left", "baseline", "replace_room", "replace_stream", "replace_session", "old_callback", "closed", "identity", "budget"]:
		var fixture: Dictionary = _fixture(context)
		var row: PackedByteArray = fixture.stream.encode_row(0, Fixture.new()._row(0))
		_emit(fixture, row)
		match event:
			"left":
				fixture.client.spectator_left.emit("room-one", "ROOM", 0, [])
			"baseline":
				fixture.client.spectator_joined.emit(RefCounted.new())
			"closed":
				fixture.client.connection = 4
			"identity":
				fixture.client.player = FOREIGN
			"budget":
				fixture.config.max_inbound_packets_per_poll = 0
			"replace_room":
				fixture.client.room = "room-two"
			"replace_stream":
				var helper: RefCounted = StreamFixture.new()
				context.equal(
					fixture.stream.configure(Fixture.new()._config(), helper._identity(), helper._key(), helper._digest(), 0, 100, 128),
					Types.Code.OK,
					"fresh stream with equal dimensions"
				)
			"replace_session":
				context.equal(fixture.stream.playback_session().configure(Fixture.new()._config()), Types.Code.OK, "independent viewer replacement")
			"old_callback":
				var callback: Callable = fixture.client.get_signal_connection_list("game_data_binary_received")[0].callable
				fixture.relay.detach()
				callback.call(HOST, 1, row)
		context.equal(fixture.relay.poll(1).code, Relay.Code.INCOMPATIBLE_MODE if event == "budget" else Relay.Code.WRONG_STATE, "old SDK lifetime cannot deliver " + event)
		if event == "replace_session":
			context.equal(fixture.stream.playback_session().status().lifecycle, Types.Lifecycle.RUNNING, "independently configured viewer survives stale bridge")
		fixture.relay.detach()


func _configuration(context: RefCounted) -> void:
	for field: String in ["capability", "version", "raw", "role", "size"]:
		var fixture: Dictionary = _fixture(context)
		fixture.relay.detach()
		var helper: RefCounted = StreamFixture.new()
		fixture.stream.configure(Fixture.new()._config(), helper._identity(), helper._key(), helper._digest(), 0, 100, 128)
		var options: Relay.Options = Relay.Options.new()
		options.max_packet_bytes = 128
		match field:
			"capability":
				fixture.info.capabilities.clear()
			"version":
				fixture.info.protocol_version = 2
			"raw":
				fixture.config.decode_msgpack_payloads = true
			"role":
				fixture.client.state = 5
			"size":
				fixture.config.max_inbound_frame_bytes = 128
		var code: int = fixture.relay.configure(fixture.client, fixture.config, fixture.info, fixture.stream, HOST, options)
		context.equal(
			code,
			Relay.Code.WRONG_STATE if field == "role" else (Relay.Code.TOO_LARGE if field == "size" else Relay.Code.INCOMPATIBLE_MODE),
			"specific configuration refusal " + field
		)
		fixture.relay.detach()


func _busy(context: RefCounted) -> void:
	var fixture: Dictionary = _fixture(context)
	_emit(fixture, fixture.stream.encode_row(0, Fixture.new()._row(0)))
	var batch: Types.Result = fixture.stream.playback_session().begin_advance()
	# No row has reached the session yet, so use the callback guard directly through its public driver next.
	context.equal(batch.code, Types.Code.PREDICTION_STALL, "queued transport is separate from session input")
	context.equal(fixture.relay.poll(1).received, 1, "release ingress for callback guard test")
	batch = fixture.stream.playback_session().begin_advance()
	context.equal(batch.code, Types.Code.READY, "expert request remains outstanding")
	_emit(fixture, fixture.stream.encode_row(1, Fixture.new()._row(1)))
	context.equal(fixture.relay.poll(2).code, Relay.Code.BACKPRESSURE, "active request defers buffered delivery")
	context.equal(fixture.relay.status().received_packets, 1, "BUSY retains original FIFO packet")
	fixture.relay.detach()
	context.equal(fixture.stream.playback_session().status().lifecycle, Types.Lifecycle.TERMINATED, "detach terminates an outstanding expert batch")


func _empty() -> Array[Driver.LocalInput]:
	return []


func _blocked_liveness(context: RefCounted) -> void:
	var fixture: Dictionary = _fixture(context)
	_emit(fixture, fixture.stream.encode_row(5, Fixture.new()._row(5)))
	context.equal(fixture.relay.poll(1).code, Relay.Code.BACKPRESSURE, "future row waits for playback capacity")
	_emit(fixture, fixture.stream.encode_keepalive())
	context.equal(fixture.relay.poll(99).received, 1, "liveness bypasses blocked gameplay FIFO")
	context.equal(fixture.stream.playback_session().host_frontier(), -1, "heartbeat does not bridge missing history")
	context.equal(fixture.relay.poll(100).code, Relay.Code.BACKPRESSURE, "timely heartbeat keeps blocked viewer live")
	context.equal(fixture.relay.status().received_packets, 1, "original refused row remains owned")
	context.equal(fixture.relay.poll(199).peer_code, Types.Code.PROTOCOL_FAILED, "heartbeat expiry remains strict")
	fixture.relay.detach()


func _retained_callbacks(context: RefCounted) -> void:
	var fixture: Dictionary = _fixture(context)
	var old_binary: Callable = fixture.client.get_signal_connection_list("game_data_binary_received")[0].callable
	var old_end: Callable = fixture.client.get_signal_connection_list("spectator_left")[0].callable
	fixture.relay.detach()
	var helper: RefCounted = StreamFixture.new()
	fixture.stream.configure(Fixture.new()._config(), helper._identity(), helper._key(), helper._digest(), 0, 100, 128)
	var options: Relay.Options = Relay.Options.new()
	options.max_packet_bytes = 128
	context.equal(
		fixture.relay.configure(fixture.client, fixture.config, fixture.info, fixture.stream, HOST, options), Relay.Code.OK, "same bridge installs a fresh delivery lifetime"
	)
	Fixture.new().negotiate(fixture.publisher, fixture.stream)
	var row: PackedByteArray = fixture.stream.encode_row(0, Fixture.new()._row(0))
	old_binary.call(HOST, 1, row)
	old_end.call("room-one", "ROOM", 0, [])
	context.equal(fixture.relay.status().received_packets, 0, "retained original SDK callbacks cannot enqueue fresh matching bytes")
	context.equal(fixture.relay.status().code, Relay.Code.OK, "retained original ending callback cannot terminate replacement")
	_emit(fixture, row)
	context.equal(fixture.relay.poll(1).received, 1, "new lifetime's real signal remains active")
	fixture.relay.detach()


func _busy_deadline(context: RefCounted) -> void:
	for now_us: int in [100, 101]:
		var fixture: Dictionary = _fixture(context)
		_emit(fixture, fixture.stream.encode_row(0, Fixture.new()._row(0)))
		fixture.relay.poll(1)
		var batch: Types.Result = fixture.stream.playback_session().begin_advance()
		var request: Types.Request = batch.batch.next_request()
		for invalid: int in [-1, 0]:
			context.equal(fixture.relay.poll(invalid).peer_code, Types.Code.INVALID_TIME, "invalid time cannot bypass callback clock validation")
		context.equal(fixture.stream.playback_session().status().lifecycle, Types.Lifecycle.RUNNING, "invalid clocks cannot terminate pending playback")
		var result: Relay.Types.Result = fixture.relay.poll(now_us)
		context.equal(result.code, Relay.Code.BACKPRESSURE if now_us == 100 else Relay.Code.PEER_FAILURE, "pending request cannot suppress elapsed expiry")
		var completion: Types.Result = fixture.stream.playback_session().complete_request(request.batch_id, request.request_id, true)
		context.equal(completion.code, Types.Code.OK if now_us == 100 else Types.Code.TERMINATED, "expired request cannot commit its frame")
		context.equal(fixture.stream.playback_session().status().current_frame, 1 if now_us == 100 else 0, "strict deadline guards committed playback")
		fixture.relay.detach()
