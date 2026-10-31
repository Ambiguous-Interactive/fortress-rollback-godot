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
	signal player_left(player_id: String)
	signal player_reconnected(player_id: String)
	var room: String = "room-one"
	var state: int = Relay.SPECTATING
	var connection: int = Relay.CONNECTED
	var player: String = ""
	var on_room: Callable

	func get_room_id() -> String:
		if on_room.is_valid():
			var callback: Callable = on_room
			on_room = Callable()
			callback.call()
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
	var on_info: Callable

	func to_dict() -> Dictionary:
		if on_info.is_valid():
			var callback: Callable = on_info
			on_info = Callable()
			callback.call()
		var data: Dictionary = super.to_dict()
		data.capabilities = capabilities.duplicate()
		return data


class JSONInfo:
	extends RefCounted
	# Variant deliberately probes malformed optional-SDK public properties.
	var protocol_version: Variant = 3
	var max_outbound_message_size: Variant = 4096

	func to_dict() -> Dictionary:
		return {"protocol_version": 3.0, "max_outbound_message_size": 4096.0, "capabilities": ["spectator_relay"], "game_data_formats": ["message_pack"]}


class DepartureGame:
	extends GameFixture.Game
	var departure: Callable
	var input_code: int = -1

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		departure.call()
		input_code = inputs.size().code
		return false if input_code != Types.Code.OK else super.simulate_frame(frame, inputs)


class CallbackConfig:
	extends RefCounted
	var client: RefCounted
	var reads: int = 0
	var attack: bool = false

	# Variant represents fields supplied by the optional SDK configuration object.
	func _get(field: StringName) -> Variant:
		match field:
			"game_data_format":
				return "message_pack"
			"decode_msgpack_payloads":
				return false
			"max_inbound_frame_bytes", "max_buffered_bytes":
				return 100000
			"max_inbound_packets_per_poll":
				reads += 1
				if attack and reads == 2:
					client.player = FOREIGN
				return 128
		return null


func cases() -> PackedStringArray:
	return PackedStringArray(
		[
			"startup",
			"playback",
			"obsolete_rows",
			"refusal",
			"queue_pressure",
			"expiry",
			"lifetimes",
			"configuration",
			"sdk_numbers",
			"busy",
			"blocked_liveness",
			"retained_callbacks",
			"busy_deadline",
			"control_retry",
			"control_invalid",
			"control_lifetime",
			"control_expiry",
			"control_busy",
			"control_row_pressure",
			"reordered_recovery",
			"heartbeat_fairness",
			"clean_tail_retries",
			"post_completion",
			"terminal_failures",
			"getter_lifetime",
			"status_lifetime",
			"configure_lifetime",
			"source_departures",
			"source_callback_lifetime"
		]
	)


func run_case(name: String, context: RefCounted) -> void:
	call("_" + name, context)
	context.finish()


func _fixture(context: RefCounted, negotiate: bool = true, receives: int = 1, packets: int = 2) -> Dictionary:
	var helper: RefCounted = StreamFixture.new()
	var stream: Stream = Stream.new()
	context.equal(stream.configure(Fixture.new()._config(), helper._identity(), helper._key(), helper._digest(), 0, 100, 128), Types.Code.OK, "viewer configured")
	var client: Client = Client.new()
	var config: RelayFixture.SDKConfig = RelayFixture.SDKConfig.new()
	var info: Info = Info.new()
	var relay: Relay = Relay.new()
	var options: Relay.Options = Relay.Options.new()
	options.max_packet_bytes = 128
	options.max_received_packets = packets
	options.max_received_bytes = 128 * packets
	options.max_receives_per_poll = receives
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
		context.equal(fixture.relay.status().host.liveness_time_us, frame + 1, "SDK caller can observe actual accepted host activity")
		context.equal(fixture.driver.step(frame, _empty()).code, Types.Code.OK, "viewer plays finalized host row")
		for player: int in 2:
			expected = expected * 3 + Fixture.new()._row(frame)[player][0] + frame
		context.equal(fixture.game.value, expected, "independent original canonical state")
	_emit(fixture, fixture.stream.encode_end(12))
	context.equal(fixture.relay.poll(13).received, 1, "END delivered")
	context.equal(fixture.relay.status().received_bytes, 0, "retained bytes drained")
	context.equal(fixture.relay.status().host.end_frame, 12, "SDK observation preserves authenticated final target")
	context.equal(fixture.relay.status().host.timeout_remaining_us, -1, "complete tail disables host expiry without implying playback completion")
	fixture.relay.detach()


# Value: protects=late authenticated rows after ring reuse; fails_when=obsolete duplicates report peer failure;
# why_new=playback covers fresh rows only; seam=public SDK ingress
func _obsolete_rows(context: RefCounted) -> void:
	var fixture: Dictionary = _fixture(context)
	var obsolete: PackedByteArray = fixture.stream.encode_row(0, Fixture.new()._row(0))
	var expected: int = 0
	for frame: int in range(12):
		_emit(fixture, fixture.stream.encode_row(frame, Fixture.new()._row(frame)))
		context.equal(fixture.relay.poll(frame + 1).code, Relay.Code.OK, "original row received through repeated wraps")
		context.equal(fixture.driver.step(frame + 1, _empty()).code, Types.Code.OK, "original row played")
		for player: int in range(2):
			expected = expected * 3 + Fixture.new()._row(frame)[player][0] + frame
	context.equal(fixture.stream.playback_session().receive_host_frame(0, Fixture.new()._row(0)).code, Types.Code.INVALID_FRAME, "direct API still identifies evicted row")
	for index: int in 2:
		var frame: int = index * 12
		var malformed: PackedByteArray = fixture.stream.encode_row(frame, Fixture.new()._row(frame))
		malformed[malformed.size() - 1] = 255
		malformed = Stream.authenticate(StreamFixture.new()._unsigned(malformed), StreamFixture.new()._key())
		_emit(fixture, malformed)
		var rejected: Relay.Types.Result = fixture.relay.poll(13 + index)
		context.equal(rejected.code, Relay.Code.PEER_FAILURE, "malformed past and current rows are not obsolete duplicates")
		context.equal(rejected.peer_code, Types.Code.INVALID_CONFIGURATION, "invalid finalized status keeps its diagnostic")
		context.equal(fixture.stream.playback_session().host_frontier(), 11, "malformed current row cannot close the next gap")
	var exhausted: PackedByteArray = obsolete.duplicate()
	exhausted.encode_u32(60, 4294967295)
	exhausted = Stream.authenticate(StreamFixture.new()._unsigned(exhausted), StreamFixture.new()._key())
	_emit(fixture, exhausted)
	context.equal(fixture.relay.poll(15).peer_code, Types.Code.INVALID_FRAME, "exhausted future frame cannot become an obsolete duplicate")
	_emit(fixture, obsolete)
	_emit(fixture, fixture.stream.encode_row(12, Fixture.new()._row(12)))
	context.equal(fixture.relay.poll(20).code, Relay.Code.OK, "late evicted duplicate does not report peer failure")
	context.equal(fixture.relay.status().received_packets, 1, "obsolete packet releases its bounded queue slot")
	context.equal(fixture.relay.poll(21).code, Relay.Code.OK, "fresh row behind obsolete duplicate remains deliverable")
	context.equal(fixture.driver.step(21, _empty()).code, Types.Code.OK, "fresh row still plays")
	for player: int in range(2):
		expected = expected * 3 + Fixture.new()._row(12)[player][0] + 12
	context.equal(fixture.game.value, expected, "obsolete row cannot replay or rewrite canonical history")
	_emit(fixture, obsolete)
	context.equal(fixture.relay.poll(120).code, Relay.Code.OK, "obsolete traffic before deadline is inert")
	_emit(fixture, obsolete)
	context.equal(fixture.relay.poll(121).peer_code, Types.Code.PROTOCOL_FAILED, "obsolete duplicate cannot refresh host liveness")
	context.equal(fixture.driver.step(121, _empty()).code, Types.Code.TERMINATED, "real host expiry stops playback")
	fixture.relay.detach()
	var conflict: Dictionary = _fixture(context)
	_emit(conflict, conflict.stream.encode_row(0, Fixture.new()._row(0)))
	conflict.relay.poll(1)
	conflict.driver.step(1, _empty())
	_emit(conflict, conflict.stream.encode_row(0, Fixture.new()._row(1)))
	context.equal(conflict.relay.poll(2).code, Relay.Code.PEER_FAILURE, "retained conflicting past row remains a failure")
	context.equal(conflict.driver.step(2, _empty()).code, Types.Code.TERMINATED, "retained conflict still stops buffered playback")
	conflict.relay.detach()
	var tail: Dictionary = _fixture(context)
	var old_tail: PackedByteArray = tail.stream.encode_row(0, Fixture.new()._row(0))
	for frame: int in range(6):
		_emit(tail, tail.stream.encode_row(frame, Fixture.new()._row(frame)))
		tail.relay.poll(frame + 1)
		tail.driver.step(frame + 1, _empty())
	_emit(tail, tail.stream.encode_row(6, Fixture.new()._row(6)))
	_emit(tail, tail.stream.encode_end(7))
	context.equal(tail.relay.poll(7).code, Relay.Code.OK, "final row received before END")
	context.equal(tail.relay.poll(8).code, Relay.Code.OK, "declared clean tail remains playable")
	_emit(tail, old_tail)
	context.equal(tail.relay.poll(9).code, Relay.Code.OK, "obsolete duplicate cannot turn a closed tail into peer failure")
	context.equal(tail.driver.step(9, _empty()).code, Types.Code.OK, "closed original tail still plays")
	context.equal(tail.driver.step(10, _empty()).code, Types.Code.TERMINATED, "closed tail still completes normally")
	context.equal(tail.stream.playback_session().is_complete(), true, "late obsolete row preserves clean completion authority")
	tail.relay.detach()


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
	_capacity_lifetime(context)
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
		if event in ["replace_stream", "replace_session"]:
			context.equal(fixture.relay.status().host, {}, "stale bridge cannot describe replacement viewer host: " + event)
		context.equal(fixture.relay.poll(1).code, Relay.Code.INCOMPATIBLE_MODE if event == "budget" else Relay.Code.WRONG_STATE, "old SDK lifetime cannot deliver " + event)
		if event == "replace_session":
			context.equal(fixture.stream.playback_session().status().lifecycle, Types.Lifecycle.RUNNING, "independently configured viewer survives stale bridge")
		fixture.relay.detach()


# Value: protects=agreed SDK ingress capacity throughout viewing; fails_when=shrunk SDK limits silently outlive queued host rows;
# why_new=setup size checks omit public configuration changes after attachment; seam=public SDK properties
func _capacity_lifetime(context: RefCounted) -> void:
	for field: String in ["max_inbound_frame_bytes", "max_buffered_bytes"]:
		for fits: bool in [false, true]:
			var fixture: Dictionary = _fixture(context)
			_emit(fixture, fixture.stream.encode_row(0, Fixture.new()._row(0)))
			var minimum: int = 256 if field == "max_inbound_frame_bytes" else 128
			fixture.config.set(field, minimum if fits else minimum - 1)
			var result: RefCounted = fixture.relay.poll(1)
			context.equal(result.code, Relay.Code.OK if fits else Relay.Code.TOO_LARGE, "runtime SDK capacity must still fit agreed packets: " + field)
			context.equal(result.received, 1 if fits else 0, "incompatible capacity cannot deliver queued history")
			context.equal(fixture.driver.step(0, _empty()).code, Types.Code.OK if fits else Types.Code.TERMINATED, "capacity failure retires buffered playback")
			context.equal(fixture.game.value, Fixture.new()._row(0)[1][0] if fits else 0, "only compatible lifetime simulates host input")
			fixture.config.set(field, 100000)
			context.equal(fixture.relay.poll(2).code, Relay.Code.OK if fits else Relay.Code.TOO_LARGE, "restoring capacity cannot revive failed lifetime")
			fixture.relay.detach()


# Value: protects=real SDK JSON metadata configures viewing; fails_when=raw JSON floats replace authoritative typed properties; seam=public SDK shape
func _sdk_numbers(context: RefCounted) -> void:
	for value: Variant in [3, 2, 3.5, false, "3", NAN, INF]:
		var fixture: Dictionary = _fixture(context, false)
		fixture.relay.detach()
		var helper: RefCounted = StreamFixture.new()
		fixture.stream.configure(Fixture.new()._config(), helper._identity(), helper._key(), helper._digest(), 0, 100, 128)
		var info: JSONInfo = JSONInfo.new()
		info.protocol_version = value
		var options: Relay.Options = Relay.Options.new()
		options.max_packet_bytes = 128
		var code: int = fixture.relay.configure(fixture.client, fixture.config, info, fixture.stream, HOST, options)
		context.equal(code, Relay.Code.OK if value is int and value == 3 else Relay.Code.INCOMPATIBLE_MODE, "typed protocol property controls admission")
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


# Value: protects=owned ACCEPT retries; fails_when=refusal loses bytes or invents host receipt; why_new=first control handoff; seam=caller transport
func _control_retry(context: RefCounted) -> void:
	var fixture: Dictionary = _fixture(context, false)
	_emit(fixture, fixture.publisher.encode_offer())
	context.equal(fixture.relay.poll(1).code, Relay.Code.OK, "control sender is optional")
	context.equal(fixture.relay.status().accept_pending, true, "offer stages bounded authenticated acceptance")
	var expected: PackedByteArray = fixture.stream.encode_accept()
	for refusal: int in [ERR_BUSY, ERR_OUT_OF_MEMORY]:
		var sender: Callable = func(packet: PackedByteArray) -> int:
			context.equal(packet, expected, "every refusal retries exact acceptance")
			context.equal(fixture.relay.poll(2).code, Relay.Code.WRONG_STATE, "control callback cannot reenter service")
			packet.fill(0)
			return refusal
		context.equal(fixture.relay.poll(2, sender).code, Relay.Code.BACKPRESSURE, "recoverable control pressure")
		context.equal(fixture.publisher.prepare_packet().code, Types.Code.NOT_SYNCHRONIZED, "refused control cannot authorize publication")
	var delivered: Array[PackedByteArray] = []
	var accept: Callable = func(packet: PackedByteArray) -> int:
		delivered.append(packet)
		return OK
	context.equal(fixture.relay.poll(3, accept).code, Relay.Code.OK, "separate control transport accepts")
	context.equal(delivered[0], expected, "callback mutation cannot change owned retry")
	context.equal(fixture.relay.status().accept_pending, false, "accepted control releases retained bytes")
	context.equal(fixture.publisher.prepare_packet().code, Types.Code.NOT_SYNCHRONIZED, "transport acceptance alone is not host receipt")
	context.equal(fixture.relay.poll(4, accept).code, Relay.Code.OK, "accepted control is not resent without another offer")
	context.equal(delivered.size(), 1, "one send per pending offer")
	context.equal(fixture.publisher.receive_accept(delivered[0]), Types.Code.OK, "actual authenticated host receipt completes agreement")
	_emit(fixture, fixture.publisher.encode_offer())
	context.equal(fixture.relay.poll(5, accept).code, Relay.Code.OK, "lost-delivery recovery can repeat an offer")
	context.equal(delivered.size(), 2, "repeated offer resends one acceptance")
	context.equal(delivered[1], expected, "offer retry has identical agreement bytes")
	fixture.relay.detach()


func _control_invalid(context: RefCounted) -> void:
	for output: Variant in [true, 0.0, "0", null, FAILED]:
		var fixture: Dictionary = _fixture(context, false)
		_emit(fixture, fixture.publisher.encode_offer())
		var sender: Callable = func(_packet: PackedByteArray) -> Variant: return output
		context.equal(fixture.relay.poll(1, sender).code, Relay.Code.SDK_FAILURE, "malformed or fatal control return fails closed")
		context.equal(fixture.relay.status().code, Relay.Code.SDK_FAILURE, "control failure remains latched")
		context.equal(fixture.relay.status().accept_pending, false, "fatal control failure releases acceptance")
		context.equal(fixture.driver.step(0, _empty()).code, Types.Code.TERMINATED, "control failure cannot leave playback live")
		fixture.relay.detach()


func _control_lifetime(context: RefCounted) -> void:
	for event: String in ["detach", "room", "stream", "replace"]:
		var fixture: Dictionary = _fixture(context, false)
		_emit(fixture, fixture.publisher.encode_offer())
		var sender: Callable = func(_packet: PackedByteArray) -> Variant:
			match event:
				"detach":
					fixture.relay.detach()
				"room":
					fixture.client.room = "replacement"
				"stream", "replace":
					if event == "replace":
						fixture.relay.detach()
					var helper: RefCounted = StreamFixture.new()
					context.equal(
						fixture.stream.configure(Fixture.new()._config(), helper._identity(), helper._key(), helper._digest(), 1, 100, 128),
						Types.Code.OK,
						"callback installs a new stream lifetime"
					)
					if event == "replace":
						var options: Relay.Options = Relay.Options.new()
						options.max_packet_bytes = 128
						context.equal(
							fixture.relay.configure(fixture.client, fixture.config, fixture.info, fixture.stream, HOST, options),
							Relay.Code.OK,
							"callback installs new bridge lifetime"
						)
			return true
		context.equal(fixture.relay.poll(1, sender).code, Relay.Code.WRONG_STATE, "lifetime invalidation wins over malformed output")
		if event in ["stream", "replace"]:
			context.equal(fixture.stream.playback_session().status().lifecycle, Types.Lifecycle.RUNNING, "old control cannot terminate new viewer")
		if event == "replace":
			context.equal(fixture.relay.poll(2).code, Relay.Code.OK, "new bridge remains usable after callback replacement")
		fixture.relay.detach()


func _control_expiry(context: RefCounted) -> void:
	var fixture: Dictionary = _fixture(context, false)
	_emit(fixture, fixture.publisher.encode_offer())
	fixture.relay.poll(1)
	var calls: Array[int] = [0]
	var sender: Callable = func(_packet: PackedByteArray) -> int:
		calls[0] += 1
		return ERR_BUSY
	context.equal(fixture.relay.poll(100, sender).code, Relay.Code.BACKPRESSURE, "control can retry just before host deadline")
	context.equal(fixture.relay.poll(101, sender).code, Relay.Code.PEER_FAILURE, "deadline equality beats pending acceptance")
	context.equal(calls[0], 1, "expired acceptance never reaches control callback")
	context.equal(fixture.relay.status().accept_pending, false, "expiry releases acceptance")
	fixture.relay.detach()


func _control_busy(context: RefCounted) -> void:
	var fixture: Dictionary = _fixture(context, false)
	_emit(fixture, fixture.publisher.encode_offer())
	fixture.relay.poll(1)
	_emit(fixture, fixture.stream.encode_row(0, Fixture.new()._row(0)))
	fixture.relay.poll(2)
	var batch: Types.Result = fixture.stream.playback_session().begin_advance()
	context.equal(batch.code, Types.Code.READY, "outstanding expert request holds callback guard")
	var calls: Array[int] = [0]
	var sender: Callable = func(_packet: PackedByteArray) -> int:
		calls[0] += 1
		return OK
	context.equal(fixture.relay.poll(3, sender).code, Relay.Code.BACKPRESSURE, "active playback defers control callback")
	context.equal(calls[0], 0, "control sender is not entered through active game callback")
	context.equal(fixture.relay.status().accept_pending, true, "active callback retains acceptance")
	fixture.relay.detach()


func _control_row_pressure(context: RefCounted) -> void:
	var fixture: Dictionary = _fixture(context, false)
	_emit(fixture, fixture.publisher.encode_offer())
	fixture.relay.poll(1)
	_emit(fixture, fixture.stream.encode_row(5, Fixture.new()._row(5)))
	var calls: Array[int] = [0]
	var sender: Callable = func(packet: PackedByteArray) -> int:
		calls[0] += 1
		context.equal(fixture.publisher.receive_accept(packet), Types.Code.OK, "row pressure cannot suppress authenticated control agreement")
		return OK
	context.equal(fixture.relay.poll(2, sender).code, Relay.Code.BACKPRESSURE, "original row pressure remains visible")
	context.equal(calls[0], 1, "independent control path makes progress behind refused gameplay")
	context.equal(fixture.relay.status().received_packets, 1, "control acceptance leaves refused row owned")
	context.equal(fixture.relay.status().accept_pending, false, "control transport acceptance releases only control packet")
	fixture.relay.detach()


# Value: protects=reordered gap recovery under ring pressure; fails_when=refused future row blocks missing history; why_new=liveness bypass tests only heartbeats; seam=SDK signals
func _reordered_recovery(context: RefCounted) -> void:
	for layout: Array in [[false, 1, 1], [true, 1, 1], [true, 2, 1], [true, 1, 2]]:
		var future_first: bool = layout[0]
		var receives: int = layout[1]
		var future_count: int = layout[2]
		var fixture: Dictionary = _fixture(context, true, receives, future_count + 1)
		if future_first:
			for frame: int in range(5, 5 + future_count):
				_emit(fixture, fixture.stream.encode_row(frame, Fixture.new()._row(frame)))
			context.equal(fixture.relay.poll(1).code, Relay.Code.BACKPRESSURE, "future rows wait at ring capacity")
		_emit(fixture, fixture.stream.encode_row(0, Fixture.new()._row(0)))
		if not future_first:
			_emit(fixture, fixture.stream.encode_row(5, Fixture.new()._row(5)))
		var received: int = 0
		for now_us: int in [2, 3]:
			var result: Relay.Types.Result = fixture.relay.poll(now_us)
			context.equal(result.received <= receives, true, "service work stays inside configured packet budget")
			received += result.received
		context.equal(received, 1, "eligible earlier row passes retained future rows within bounded service")
		context.equal(fixture.relay.status().received_bytes, (Stream.HEADER_BYTES + 4) * future_count, "only exact refused future packets remain charged")
		context.equal(fixture.stream.playback_session().host_frontier(), 0, "reordered arrival recovers the original contiguous prefix")
		if fixture.stream.playback_session().host_frontier() < 0:
			fixture.relay.detach()
			continue
		context.equal(fixture.driver.step(0, _empty()).code, Types.Code.OK, "earlier row advances playback and frees capacity")
		var expected: int = 0
		for player: int in 2:
			expected = expected * 3 + Fixture.new()._row(0)[player][0]
		context.equal(fixture.game.value, expected, "first original row matches independent state")
		var now_us: int = 4
		for frame: int in range(1, 5 + future_count):
			if frame < 5:
				_emit(fixture, fixture.stream.encode_row(frame, Fixture.new()._row(frame)))
			for _turn: int in range(future_count + 1):
				var result: Relay.Types.Result = fixture.relay.poll(now_us)
				context.equal(result.received <= receives, true, "recovery retains bounded work across polls")
				now_us += 1
			context.equal(fixture.driver.step(frame, _empty()).code, Types.Code.OK, "viewer plays complete original history")
			for player: int in 2:
				expected = expected * 3 + Fixture.new()._row(frame)[player][0] + frame
			context.equal(fixture.game.value, expected, "reordered relay preserves independent canonical game state")
		context.equal(fixture.relay.status().received_packets, 0, "all retained packets release only after actual acceptance")
		context.equal(fixture.relay.status().received_bytes, 0, "successful recovery releases every retained byte")
		fixture.relay.detach()


# Value: protects=row service under continuous host liveness; fails_when=each heartbeat resets the receive cursor; why_new=blocked liveness is one-shot; seam=SDK signals
func _heartbeat_fairness(context: RefCounted) -> void:
	for layout: Array in [[false, 0], [true, 0], [true, 1], [true, 2]]:
		var repeated: bool = layout[0]
		var blocked: int = layout[1]
		var fixture: Dictionary = _fixture(context, true, 1, 8)
		for frame: int in range(5, 5 + blocked):
			_emit(fixture, fixture.stream.encode_row(frame, Fixture.new()._row(frame)))
		_emit(fixture, fixture.stream.encode_row(0, Fixture.new()._row(0)))
		var turns: int = blocked + 2
		for now_us: int in range(1, turns + 1):
			if repeated or now_us == 1:
				_emit(fixture, fixture.stream.encode_keepalive())
			var result: Relay.Types.Result = fixture.relay.poll(now_us)
			context.equal(result.received <= 1, true, "each turn stays within its one-packet budget")
		context.equal(fixture.stream.playback_session().host_frontier(), 0, "continued heartbeats cannot starve the original confirmed row")
		var pending_heartbeats: int = turns - 1 if repeated else 0
		context.equal(
			fixture.relay.status().received_bytes,
			blocked * (Stream.HEADER_BYTES + 4) + pending_heartbeats * Stream.HEADER_BYTES,
			"only exact refused rows and unprocessed heartbeats remain charged"
		)
		if fixture.stream.playback_session().host_frontier() == 0:
			context.equal(fixture.driver.step(0, _empty()).code, Types.Code.OK, "viewer plays its original row despite ongoing heartbeats")
			var expected: int = 0
			for player: int in 2:
				expected = expected * 3 + Fixture.new()._row(0)[player][0]
			context.equal(fixture.game.value, expected, "fair service preserves independent original state")
		context.equal(fixture.relay.poll(turns + 100).peer_code, Types.Code.PROTOCOL_FAILED, "deadline equality beats queued heartbeat and future rows")
		context.equal(fixture.relay.status().received_bytes, 0, "expiry releases every pending original packet")
		fixture.relay.detach()


# Value: protects=relay clean tail with reordered controls; fails_when=trailing retries report peer failure;
# why_new=playback case stops polling at END; seam=public SDK signals
func _clean_tail_retries(context: RefCounted) -> void:
	for receives: int in [1, 4]:
		var fixture: Dictionary = _fixture(context, true, receives, 8)
		context.equal(fixture.stream.playback_session().set_playback(2, 1, 3), Types.Code.OK, "paused delayed viewer")
		var row: PackedByteArray = fixture.stream.encode_row(0, Fixture.new()._row(0))
		var end: PackedByteArray = fixture.stream.encode_end(1)
		for packet: PackedByteArray in [row, end, fixture.stream.encode_keepalive(), end, fixture.publisher.encode_offer(), row]:
			_emit(fixture, packet)
		for turn: int in range(6):
			context.equal(fixture.relay.poll(turn + 1).code, Relay.Code.OK, "late authenticated controls preserve clean tail")
		context.equal(fixture.stream.playback_session().status().current_frame, 0, "relay does not simulate paused tail")
		context.equal(fixture.relay.status().received_packets, 0, "all duplicate controls drain")
		context.equal(fixture.relay.status().rejected, 0, "accepted retries are not failures")
		context.equal(fixture.driver.step(0, _empty()).code, Types.Code.OK, "final original row remains playable")
		context.equal(fixture.game.value, 1, "canonical final original state")
		context.equal(fixture.driver.step(1, _empty()).code, Types.Code.TERMINATED, "clean completion follows final callback")
		fixture.relay.detach()


# Value: protects=SDK getter lifetime ownership; fails_when=detach during a getter dereferences cleared state; why_new=control callbacks run after the gate; seam=SDK API
func _getter_lifetime(context: RefCounted) -> void:
	for entry: String in ["poll", "ingress", "status"]:
		for action: String in [
			"control", "reentry", "detach", "replace", "signal", "ingress", "signal_ingress", "terminate_ingress", "overflow_signal", "player_change", "config_change"
		]:
			var fixture: Dictionary = _fixture(context)
			var previous: RefCounted = fixture.stream.playback_session()
			var packet: PackedByteArray = fixture.stream.encode_row(0, Fixture.new()._row(0))
			fixture.client.on_room = func() -> void:
				if action == "reentry":
					context.equal(fixture.relay.status().code, Relay.Code.WRONG_STATE, "SDK getter cannot recursively inspect its own gate")
					context.equal(fixture.relay.poll(1).code, Relay.Code.WRONG_STATE, "SDK getter cannot recursively poll its own gate")
				elif action == "ingress":
					_emit(fixture, packet)
				elif action == "player_change":
					fixture.client.player = FOREIGN
				elif action == "config_change":
					fixture.config.decode_msgpack_payloads = true
				elif action == "signal":
					fixture.client.spectator_left.emit("room-one", "ROOM", 0, [])
				elif action == "overflow_signal":
					for index: int in 3:
						_emit(fixture, packet)
					fixture.client.spectator_left.emit("room-one", "ROOM", 0, [])
				elif action in ["signal_ingress", "terminate_ingress"]:
					if action == "signal_ingress":
						fixture.client.spectator_left.emit("room-one", "ROOM", 0, [])
					else:
						previous.terminate(Types.Code.PROTOCOL_FAILED)
					_emit(fixture, packet)
				elif action in ["detach", "replace"]:
					fixture.relay.detach()
					if action == "replace":
						var helper: RefCounted = StreamFixture.new()
						context.equal(
							fixture.stream.configure(Fixture.new()._config(), helper._identity(), helper._key(), helper._digest(), 1, 100, 128),
							Types.Code.OK,
							"SDK getter replaces stream"
						)
						var options: Relay.Options = Relay.Options.new()
						options.max_packet_bytes = 128
						context.equal(
							fixture.relay.configure(fixture.client, fixture.config, fixture.info, fixture.stream, HOST, options), Relay.Code.OK, "SDK getter installs fresh bridge"
						)
			if entry == "poll":
				var result: Relay.Types.Result = fixture.relay.poll(1)
				var expected: int = Relay.Code.OK if action in ["control", "reentry", "ingress"] else Relay.Code.WRONG_STATE
				context.equal(result.code, Relay.Code.RECEIVE_OVERFLOW if action == "overflow_signal" else expected, "getter lifetime result")
			elif entry == "ingress":
				_emit(fixture, packet)
				context.equal(
					fixture.relay.status().received_packets,
					(2 if action == "ingress" else 1) if action in ["control", "reentry", "ingress"] else 0,
					"old ingress cannot enqueue into replacement"
				)
			else:
				var observation: Dictionary = fixture.relay.status()
				if action in ["detach", "replace"]:
					context.equal(observation.code, Relay.Code.WRONG_STATE, "getter replacement rejects old status lifetime")
					context.equal(observation.host, {}, "old status call cannot report replacement host liveness")
				elif action == "control":
					context.equal(observation.host.code, Types.Code.OK, "unchanged status lifetime retains host observation")
			if (
				action in ["detach", "replace", "signal", "signal_ingress", "terminate_ingress", "overflow_signal"]
				or action in ["player_change", "config_change"]
			):
				context.equal(previous.status().lifecycle, Types.Lifecycle.TERMINATED, "getter detach retires original viewer")
			else:
				context.equal(previous.status().lifecycle, Types.Lifecycle.RUNNING, "rejected recursion leaves original playback live")
			if action == "signal":
				context.equal(fixture.relay.status().code, Relay.Code.WRONG_STATE, "getter cannot erase a latched lifetime failure")
			if action == "player_change":
				context.equal(fixture.relay.status().code, Relay.Code.WRONG_STATE, "gate refuses an identity changed by a later getter")
			if action in ["signal_ingress", "terminate_ingress"]:
				var stopped: Dictionary = fixture.relay.status()
				context.equal(stopped.received_packets, 0, "nested traffic cannot refill terminated viewer")
				context.equal(stopped.received_bytes, 0, "nested terminal traffic retains no bytes")
				context.equal(stopped.last_receive_code, Relay.Code.WRONG_STATE, "nested terminal traffic records lifetime rejection")
			if action == "overflow_signal":
				context.equal(fixture.relay.status().code, Relay.Code.RECEIVE_OVERFLOW, "later SDK signal preserves first terminal cause")
			if action == "replace":
				context.equal(fixture.stream.playback_session().status().lifecycle, Types.Lifecycle.RUNNING, "old gate cannot terminate replacement viewer")
				context.equal(fixture.relay.status().host.liveness_time_us, 1, "fresh status call observes replacement host baseline")
				context.equal(fixture.relay.poll(2).code, Relay.Code.OK, "replacement gate remains usable")
			fixture.client.on_room = Callable()
			fixture.relay.detach()


# Value: protects=status rejects obsolete playback before driver callbacks; fails_when=gate only latches failure;
# why_new=poll and ingress retire viewers but status previously left playable rows live; seam=SDK properties and retained driver
func _status_lifetime(context: RefCounted) -> void:
	_status_owned_requests(context)
	for action: String in [
		"control", "capacity_control", "room", "connection", "role", "identity", "raw", "budget", "frame_capacity", "buffer_capacity", "first_cause", "replace_session"
	]:
		var fixture: Dictionary = _fixture(context)
		_emit(fixture, fixture.publisher.encode_offer())
		context.equal(fixture.relay.poll(1).received, 1, "offer retains caller-owned acceptance")
		_emit(fixture, fixture.stream.encode_row(0, Fixture.new()._row(0)))
		context.equal(fixture.relay.poll(2).received, 1, "original row is playable before status observation")
		_emit(fixture, fixture.stream.encode_row(1, Fixture.new()._row(1)))
		var expected: int = Relay.Code.WRONG_STATE
		match action:
			"control", "capacity_control":
				expected = Relay.Code.OK
				if action == "capacity_control":
					fixture.config.max_inbound_frame_bytes = 256
					fixture.config.max_buffered_bytes = 128
			"room", "first_cause":
				fixture.client.room = "room-two"
				if action == "first_cause":
					fixture.driver.terminate(Types.Code.DESYNC)
			"connection":
				fixture.client.connection = -1
			"role":
				fixture.client.state = -1
			"identity":
				fixture.client.player = FOREIGN
			"raw", "budget":
				expected = Relay.Code.INCOMPATIBLE_MODE
				if action == "raw":
					fixture.config.decode_msgpack_payloads = true
				else:
					fixture.config.max_inbound_packets_per_poll = 0
			"frame_capacity", "buffer_capacity":
				expected = Relay.Code.TOO_LARGE
				fixture.config.set("max_inbound_frame_bytes" if action == "frame_capacity" else "max_buffered_bytes", 255 if action == "frame_capacity" else 127)
			"replace_session":
				context.equal(fixture.stream.playback_session().configure(Fixture.new()._config()), Types.Code.OK, "independent replacement owns a fresh playback lifetime")
		var healthy: bool = expected == Relay.Code.OK
		var observation: Dictionary = fixture.relay.status()
		context.equal(observation.code, expected, "status adjudicates SDK lifetime: " + action)
		context.equal(observation.received_packets, 1 if healthy else 0, "failed status releases queued row: " + action)
		context.equal(observation.received_bytes > 0, healthy, "failed status releases owned bytes: " + action)
		context.equal(observation.accept_pending, healthy, "failed status releases pending acceptance: " + action)
		if action == "replace_session":
			context.equal(fixture.driver.status().lifecycle, Types.Lifecycle.RUNNING, "stale status preserves independent replacement")
			context.equal(observation.host, {}, "stale status hides replacement host")
		else:
			context.equal(fixture.driver.step(3, _empty()).code, Types.Code.OK if healthy else Types.Code.TERMINATED, "status fences already playable callbacks: " + action)
			context.equal(fixture.game.value, 1 if healthy else 0, "failed status cannot simulate original buffered row: " + action)
			if not healthy:
				context.equal(fixture.driver.status().reason, Types.Code.DESYNC if action == "first_cause" else Types.Code.PROTOCOL_FAILED, "status preserves first terminal cause")
		fixture.client.room = "room-one"
		fixture.client.connection = Relay.CONNECTED
		fixture.client.state = Relay.SPECTATING
		fixture.client.player = ""
		fixture.config.decode_msgpack_payloads = false
		fixture.config.max_inbound_packets_per_poll = 128
		fixture.config.max_inbound_frame_bytes = 100000
		fixture.config.max_buffered_bytes = 100000
		context.equal(fixture.relay.status().code, expected, "restoring SDK state cannot revive failed lifetime")
		fixture.relay.detach()


func _status_owned_requests(context: RefCounted) -> void:
	for changed: bool in [false, true]:
		for manual: bool in [false, true]:
			var fixture: Dictionary = _fixture(context)
			_emit(fixture, fixture.stream.encode_row(0, Fixture.new()._row(0)))
			context.equal(fixture.relay.poll(1).received, 1, "original row ready before owned status observation")
			if manual:
				var session: RefCounted = fixture.stream.playback_session()
				var opened: Types.Result = session.begin_advance()
				context.equal(opened.code, Types.Code.READY, "expert owns a spectator request")
				var request: Types.Request = opened.batch.next_request()
				context.equal(request.kind, Types.Kind.ADVANCE, "first spectator request owns bounded inputs")
				fixture.client.room = "room-two" if changed else "room-one"
				context.equal(fixture.relay.status().code, Relay.Code.WRONG_STATE if changed else Relay.Code.OK, "owned request still detects SDK room lifetime")
				context.equal(request.inputs.size().code, Types.Code.EXPIRED_VIEW if changed else Types.Code.OK, "terminal status expires expert inputs immediately")
				context.equal(session.status().lifecycle, Types.Lifecycle.TERMINATED if changed else Types.Lifecycle.RUNNING, "healthy observation preserves expert ownership")
			else:
				var game: DepartureGame = DepartureGame.new()
				var client_ref: WeakRef = weakref(fixture.client)
				var relay_ref: WeakRef = weakref(fixture.relay)
				game.departure = func() -> void:
					client_ref.get_ref().room = "room-two" if changed else "room-one"
					relay_ref.get_ref().status()
				var driver: Driver = Driver.new(fixture.stream.playback_session(), game)
				context.equal(driver.step(2, _empty()).code, Types.Code.TERMINATED if changed else Types.Code.OK, "terminal callback status prevents frame commit")
				context.equal(game.input_code, Types.Code.EXPIRED_VIEW if changed else Types.Code.OK, "terminal callback status expires inputs immediately")
				context.equal(driver.status().current_frame, 0 if changed else 1, "only healthy callback commits original row")
			fixture.relay.detach()


# Value: protects=atomic SDK viewer configuration; fails_when=getter detachment partially installs stale state; why_new=runtime getters follow installation; seam=SDK API
func _configure_lifetime(context: RefCounted) -> void:
	_joint_observation(context)
	for boundary: String in ["room", "protocol"]:
		for action: String in [
			"control", "reentry", "detach", "replace", "player_change", "state_change", "connection_change", "options_change", "config_change", "signal", "joined_signal"
		]:
			var fixture: Dictionary = _fixture(context, false)
			fixture.relay.detach()

			var helper: RefCounted = StreamFixture.new()
			context.equal(
				fixture.stream.configure(Fixture.new()._config(), helper._identity(), helper._key(), helper._digest(), 0, 100, 128), Types.Code.OK, "fresh setup lifetime"
			)
			var options: Relay.Options = Relay.Options.new()
			options.max_packet_bytes = 128
			var callback: Callable = func() -> void:
				if action == "player_change":
					fixture.client.player = FOREIGN
				elif action == "state_change":
					fixture.client.state = -1
				elif action == "connection_change":
					fixture.client.connection = -1
				elif action == "options_change":
					options.max_received_packets = 0
				elif action == "config_change":
					fixture.config.decode_msgpack_payloads = true
				elif action == "signal":
					fixture.client.spectator_left.emit("room-one", "ROOM", 0, [])
				elif action == "joined_signal":
					fixture.client.spectator_joined.emit(RefCounted.new())
				if action in ["detach", "replace"]:
					fixture.relay.detach()
				if action in ["reentry", "replace"]:
					context.equal(
						fixture.relay.configure(fixture.client, fixture.config, fixture.info, fixture.stream, HOST, options),
						Relay.Code.WRONG_STATE,
						"recursive configuration cannot install another lifetime"
					)
			if boundary == "room":
				fixture.client.on_room = callback
			else:
				fixture.info.on_info = callback
			var code: int = fixture.relay.configure(fixture.client, fixture.config, fixture.info, fixture.stream, HOST, options)
			var accepted: bool = action in ["control", "reentry", "options_change"] or (boundary == "protocol" and action == "player_change")
			var expected: int = Relay.Code.OK if accepted else Relay.Code.WRONG_STATE
			if boundary == "protocol" and action == "config_change":
				expected = Relay.Code.INCOMPATIBLE_MODE
			context.equal(code, expected, "only uninterrupted configuration commits")
			context.equal(
				fixture.client.get_signal_connection_list("game_data_binary_received").size(), 1 if code == Relay.Code.OK else 0, "rejected setup installs no SDK callbacks"
			)
			for signal_name: String in Relay.LIFETIME_SIGNALS:
				if fixture.client.has_signal(signal_name):
					context.equal(fixture.client.get_signal_connection_list(signal_name).size(), 1 if code == Relay.Code.OK else 0, "setup releases temporary lifetime listener")
			context.equal(fixture.stream.playback_session().status().lifecycle, Types.Lifecycle.RUNNING, "partial setup cannot acquire or terminate fresh playback")
			if action == "options_change":
				context.equal(fixture.relay._options.max_received_packets, 128, "setup freezes caller options before callbacks")
			if code != Relay.Code.OK:
				fixture.client.connection = Relay.CONNECTED
				fixture.client.state = Relay.SPECTATING
				fixture.config.decode_msgpack_payloads = false
				context.equal(
					fixture.relay.configure(fixture.client, fixture.config, fixture.info, fixture.stream, HOST, options),
					Relay.Code.OK,
					"rejected setup releases configuration guard"
				)
			fixture.relay.detach()


# Value: protects=joint SDK configuration and identity consistency; fails_when=final config getter changes captured identity;
# why_new=ordinary getter fixtures mutate within one object only; seam=SDK property API
func _joint_observation(context: RefCounted) -> void:
	for entry: String in ["setup", "ingress"]:
		var fixture: Dictionary = _fixture(context, false)
		fixture.relay.detach()
		var helper: RefCounted = StreamFixture.new()
		context.equal(
			fixture.stream.configure(Fixture.new()._config(), helper._identity(), helper._key(), helper._digest(), 0, 100, 128), Types.Code.OK, "joint-observation fresh stream"
		)
		var config: CallbackConfig = CallbackConfig.new()
		config.client = fixture.client
		config.attack = entry == "setup"
		var options: Relay.Options = Relay.Options.new()
		options.max_packet_bytes = 128
		var code: int = fixture.relay.configure(fixture.client, config, fixture.info, fixture.stream, HOST, options)
		context.equal(code, Relay.Code.WRONG_STATE if entry == "setup" else Relay.Code.OK, "configuration requires consistent joint observations")
		if entry == "setup":
			context.equal(fixture.client.get_signal_connection_list("game_data_binary_received").size(), 0, "joint-observation rejection installs no callbacks")
			context.equal(fixture.stream.playback_session().status().lifecycle, Types.Lifecycle.RUNNING, "joint-observation rejection does not acquire viewer")
		else:
			config.reads = 0
			config.attack = true
			_emit(fixture, fixture.publisher.encode_offer())
			context.equal(fixture.relay.status().received_packets, 0, "changed identity cannot accept authenticated offer")
			context.equal(fixture.relay.status().received_bytes, 0, "changed identity retains no offer bytes")
			context.equal(fixture.relay.status().last_receive_code, Relay.Code.WRONG_STATE, "joint-observation mismatch rejects ingress")
			context.equal(fixture.stream.playback_session().status().lifecycle, Types.Lifecycle.TERMINATED, "joint-observation mismatch retires attached viewer")
		fixture.relay.detach()


# Value: protects=known host loss stops buffered playback; fails_when=roster departures wait for timeout;
# why_new=room lifetime tests omit selected remote host; seam=public SDK signals
func _source_departures(context: RefCounted) -> void:
	for signal_name: String in ["player_left", "player_reconnected"]:
		for boundary: String in ["idle", "getter", "protocol_setup", "getter_setup"]:
			for selected: bool in [false, true]:
				var fixture: Dictionary = _fixture(context)
				var departing: String = HOST if selected else FOREIGN
				var callback: Callable = func() -> void: fixture.client.emit_signal(signal_name, departing)
				var setup: bool = boundary.ends_with("setup")
				if setup:
					fixture.relay.detach()
					var helper: RefCounted = StreamFixture.new()
					context.equal(
						fixture.stream.configure(Fixture.new()._config(), helper._identity(), helper._key(), helper._digest(), 0, 100, 128), Types.Code.OK, "fresh source lifetime"
					)
					if boundary == "protocol_setup":
						fixture.info.on_info = callback
					else:
						fixture.client.on_room = callback
					var options: Relay.Options = Relay.Options.new()
					options.max_packet_bytes = 128
					context.equal(
						fixture.relay.configure(fixture.client, fixture.config, fixture.info, fixture.stream, HOST, options),
						Relay.Code.WRONG_STATE if selected else Relay.Code.OK,
						"setup fences only selected source departure"
					)
					context.equal(fixture.stream.playback_session().status().lifecycle, Types.Lifecycle.RUNNING, "rejected setup cannot acquire fresh viewer")
				else:
					_emit(fixture, fixture.stream.encode_row(0, Fixture.new()._row(0)))
					context.equal(fixture.relay.poll(1).received, 1, "playable original row buffered before host event")
					_emit(fixture, fixture.stream.encode_row(1, Fixture.new()._row(1)))
					if boundary == "getter":
						fixture.client.on_room = callback
					else:
						callback.call()
					context.equal(fixture.relay.poll(2).code, Relay.Code.WRONG_STATE if selected else Relay.Code.OK, "only selected source ends ingress")
					context.equal(fixture.relay.status().received_packets, 0, "departed source releases queued rows")
					context.equal(fixture.driver.step(2, _empty()).code, Types.Code.TERMINATED if selected else Types.Code.OK, "known host loss blocks already playable row")
					context.equal(fixture.game.value, 0 if selected else 1, "no callback after known host loss")
				fixture.relay.detach()


# Value: protects=host loss fences active and retained callback lifetimes; fails_when=departure lets requests commit or old callbacks kill replacements;
# why_new=idle source tests omit owned callback views; seam=public SDK signals and game callbacks
func _source_callback_lifetime(context: RefCounted) -> void:
	for signal_name: String in ["player_left", "player_reconnected"]:
		for selected: bool in [false, true]:
			var fixture: Dictionary = _fixture(context)
			_emit(fixture, fixture.stream.encode_row(0, Fixture.new()._row(0)))
			context.equal(fixture.relay.poll(1).received, 1, "original row ready for callback")
			var game: DepartureGame = DepartureGame.new()
			var client_ref: WeakRef = weakref(fixture.client)
			game.departure = func() -> void: client_ref.get_ref().emit_signal(signal_name, HOST if selected else FOREIGN)
			var driver: Driver = Driver.new(fixture.stream.playback_session(), game)
			context.equal(driver.step(2, _empty()).code, Types.Code.TERMINATED if selected else Types.Code.OK, "host event during callback cannot commit abandoned playback")
			context.equal(game.input_code, Types.Code.EXPIRED_VIEW if selected else Types.Code.OK, "known host loss expires active bounded inputs")
			context.equal(fixture.stream.playback_session().status().current_frame, 0 if selected else 1, "only uninterrupted callback commits frame")
			fixture.relay.detach()
		var fixture: Dictionary = _fixture(context)
		var old_callback: Callable = fixture.client.get_signal_connection_list(signal_name)[0].callable
		fixture.stream.playback_session().terminate(Types.Code.DESYNC)
		fixture.client.emit_signal(signal_name, HOST)
		context.equal(fixture.stream.playback_session().status().reason, Types.Code.DESYNC, "known host loss preserves first terminal cause")
		fixture.relay.detach()
		var helper: RefCounted = StreamFixture.new()
		context.equal(
			fixture.stream.configure(Fixture.new()._config(), helper._identity(), helper._key(), helper._digest(), 0, 100, 128), Types.Code.OK, "explicit replacement viewer"
		)
		var options: Relay.Options = Relay.Options.new()
		options.max_packet_bytes = 128
		context.equal(fixture.relay.configure(fixture.client, fixture.config, fixture.info, fixture.stream, HOST, options), Relay.Code.OK, "fresh source observers")
		old_callback.call(HOST)
		context.equal(fixture.relay.status().code, Relay.Code.OK, "old source observer cannot end replacement")
		context.equal(fixture.stream.playback_session().status().lifecycle, Types.Lifecycle.RUNNING, "replacement playback remains live")
		fixture.relay.detach()
		for source_signal: String in ["player_left", "player_reconnected"]:
			context.equal(fixture.client.get_signal_connection_list(source_signal).size(), 0, "detach releases source observers")


# Value: protects=completed relay service and discarded late packets; fails_when=clean END becomes transport failure;
# why_new=tail retries stop before final playback termination; seam=public SDK signals and driver
func _post_completion(context: RefCounted) -> void:
	_control_completion(context)
	for frames: int in [0, 1]:
		var fixture: Dictionary = _fixture(context)
		if frames == 1:
			_emit(fixture, fixture.stream.encode_row(0, Fixture.new()._row(0)))
			context.equal(fixture.relay.poll(1).code, Relay.Code.OK, "original tail received")
		_emit(fixture, fixture.stream.encode_end(frames))
		context.equal(fixture.relay.poll(2).code, Relay.Code.OK, "clean END accepted")
		context.equal(fixture.relay.poll(3).code, Relay.Code.OK, "finished host remains healthy before playback completion")
		if frames == 1:
			context.equal(fixture.driver.step(3, _empty()).code, Types.Code.OK, "final original frame plays")
		# Leave one packet queued when the final playback call closes the session.
		_emit(fixture, fixture.stream.encode_keepalive())
		context.equal(fixture.driver.step(4, _empty()).code, Types.Code.TERMINATED, "normal clean playback completion")
		for now: int in [4, 1000]:
			var result: Relay.Types.Result = fixture.relay.poll(now)
			context.equal(result.code, Relay.Code.OK, "continued relay service preserves clean completion")
			context.equal(result.peer_code, Types.Code.TERMINATED, "peer code retains playback completion")
			context.equal(fixture.relay.status().received_packets, 0, "completion releases queued packets")
		for packet: PackedByteArray in [fixture.stream.encode_end(frames), fixture.stream.encode_keepalive(), fixture.publisher.encode_offer()]:
			_emit(fixture, packet)
		fixture.client.game_data_binary_received.emit(FOREIGN, 0, PackedByteArray([0]))
		context.equal(fixture.relay.status().code, Relay.Code.OK, "late packets cannot poison completed relay")
		context.equal(fixture.relay.status().received_bytes, 0, "completed ingress retains no bytes")
		context.equal(fixture.relay.poll(1001).code, Relay.Code.OK, "late ingress preserves completed service")
		context.equal(fixture.game.value, 1 if frames == 1 else 0, "completion never simulates another frame")
		fixture.client.player_left.emit(HOST)
		context.equal(fixture.relay.poll(1002).code, Relay.Code.WRONG_STATE, "completion preserves SDK lifetime fencing")
		context.equal(fixture.driver.status().reason, Types.Code.TERMINATED, "later lifetime loss preserves completed reason")
		fixture.relay.detach()


# Value: protects=cancellation remains distinct from completion; fails_when=terminal reason and final frame imply success;
# why_new=completion needs controls at empty and consumed final boundaries; seam=public SDK signals and driver
func _terminal_failures(context: RefCounted) -> void:
	for boundary: String in ["live", "tail", "empty_boundary", "played_boundary"]:
		for reason: int in [Types.Code.TERMINATED, Types.Code.CALLBACK_FAILED, Types.Code.PROTOCOL_FAILED, Types.Code.DESYNC]:
			var fixture: Dictionary = _fixture(context)
			if boundary != "live":
				if boundary != "empty_boundary":
					_emit(fixture, fixture.stream.encode_row(0, Fixture.new()._row(0)))
				context.equal(fixture.relay.poll(1).code, Relay.Code.OK, "host stream healthy before ending")
				_emit(fixture, fixture.stream.encode_end(0 if boundary == "empty_boundary" else 1))
				context.equal(fixture.relay.poll(2).code, Relay.Code.OK, "host ends before tail playback")
				if boundary == "played_boundary":
					context.equal(fixture.driver.step(2, _empty()).code, Types.Code.OK, "play final row before cancellation")
			fixture.driver.terminate(reason)
			context.equal(fixture.stream.playback_session().is_complete(), false, "termination without clean service never completes playback")
			context.equal(fixture.relay.poll(3).code, Relay.Code.PEER_FAILURE, "cancellation and failures are not clean completion")
			_emit(fixture, fixture.stream.encode_keepalive())
			context.equal(fixture.relay.status().code, Relay.Code.WRONG_STATE, "terminated incomplete ingress stays fenced")
			context.equal(fixture.driver.status().reason, reason, "transport preserves first terminal cause")
			fixture.relay.detach()


func _control_completion(context: RefCounted) -> void:
	for reason: int in [Types.Code.OK, Types.Code.TERMINATED, Types.Code.DESYNC]:
		var fixture: Dictionary = _fixture(context, true, 2)
		_emit(fixture, fixture.publisher.encode_offer())
		_emit(fixture, fixture.stream.encode_end(0))
		var send: Callable = func(_packet: PackedByteArray) -> int:
			if reason == Types.Code.OK:
				context.equal(fixture.driver.step(1, _empty()).code, Types.Code.TERMINATED, "sender services completed playback")
			else:
				fixture.driver.terminate(reason)
			return OK
		var result: Relay.Types.Result = fixture.relay.poll(1, send)
		context.equal(result.code, Relay.Code.OK if reason == Types.Code.OK else Relay.Code.PEER_FAILURE, "sender distinguishes completion from failure")
		context.equal(fixture.relay.status().received_packets, 0, "sender termination releases queued packets")
		fixture.relay.detach()
