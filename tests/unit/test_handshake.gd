extends RefCounted

# Value: protects=byte handshake source/config/time/echo gates; fails_when=hostile traffic advances peers or partial queue failure; why_new=first endpoint; seam=none
const Endpoint = preload("res://addons/fortress_rollback/protocol/handshake.gd")
const H = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")


class CountingEndpoint:
	extends Endpoint
	var identity_checks: int = 0

	func _nonzero(bytes: PackedByteArray, width: int) -> bool:
		identity_checks += 1
		return super._nonzero(bytes, width)


func cases() -> PackedStringArray:
	return PackedStringArray(["roundtrips", "echoes", "mismatch", "time", "identity", "backpressure", "timeout_pressure", "ownership"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"roundtrips": _roundtrips(context)
		"echoes": _echoes(context)
		"mismatch": _mismatch(context)
		"time": _time(context)
		"identity": _identity(context)
		"backpressure": _backpressure(context)
		"timeout_pressure": _timeout_pressure(context)
		"ownership": _ownership(context)
	context.finish()


func _id(value: int, width: int = 8) -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(width)
	bytes[0] = value
	return bytes


func _message(sender: int = 1, connection: int = 10) -> T.Message:
	var message: T.Message = T.Message.new()
	message.kind = T.Kind.SYNC_REQUEST
	message.session_id = _id(9, 16)
	message.sender_id = _id(sender)
	message.connection_id = _id(connection)
	message.config.roster = [_id(1), _id(2)]
	return message


func _endpoint(options: H.Options = null) -> Endpoint:
	var endpoint: Endpoint = Endpoint.new()
	var chosen: H.Options = options if options != null else H.Options.new()
	chosen.retry_interval_us = 200
	endpoint.configure(_message(), _id(2), chosen)
	return endpoint


func _packet(kind: int, token: int, changes: Dictionary = {}, connection: int = 20) -> PackedByteArray:
	var message: T.Message = _message(2, connection)
	message.kind = kind
	message.token = _id(token, 16)
	for field: String in changes:
		if field in ["min_compat_version", "features", "config_digest", "session_id", "sender_id", "max_packet_bytes"]:
			message.set(field, changes[field])
		elif field == "roster":
			var roster: Array[PackedByteArray] = []
			for identity: PackedByteArray in changes[field]:
				roster.append(identity)
			message.config.roster = roster
		else:
			message.config.set(field, changes[field])
	return Codec.encode(message, T.Limits.new()).bytes


func _roundtrips(context: RefCounted) -> void:
	var options: H.Options = H.Options.new()
	options.roundtrips = 3
	var endpoint: Endpoint = _endpoint(options)
	context.equal(endpoint.begin(0, _id(1, 16)), H.Code.OK, "start")
	endpoint.drain_outbox()
	context.equal(endpoint.remote_packet_bytes(), 65536, "local packet limit before any reply")
	var advertised: Array[int] = [9000, 4000, 70000]
	for token: int in range(1, 4):
		var reply: PackedByteArray = _packet(T.Kind.SYNC_REPLY, token, {"max_packet_bytes": advertised[token - 1]})
		context.equal(endpoint.receive(reply, _id(2), token, _id(token + 1, 16)), H.Code.OK, "valid echo")
		context.equal(endpoint.remote_packet_bytes(), [9000, 4000, 4000][token - 1], "smallest advertised packet limit kept")
		context.equal(endpoint.status().remaining, 3 - token, "single decrement")
		context.equal(endpoint.status().remote_connection, _id(20).hex_encode(), "first roundtrip binds")
		var packets: Array[PackedByteArray] = endpoint.drain_outbox()
		context.equal(packets.size(), 1 if token < 3 else 0, "request only when remaining")
		var events: Array[Dictionary] = endpoint.drain_events()
		context.equal(events.size(), 1, "one event")
		context.equal(events[0].kind, "synchronizing" if token < 3 else "synchronized", "event after post state")
	context.equal(endpoint.status().state, "running", "running")
	context.equal(endpoint.receive(_packet(T.Kind.SYNC_REQUEST, 90, {"fps": 30}), _id(2), 4), H.Code.OK, "running answers foreign config")
	context.equal(endpoint.drain_outbox().size(), 1, "running reply")
	context.equal(endpoint.drain_events().size(), 0, "no running config poison")
	context.equal(endpoint.receive(_packet(T.Kind.SYNC_REQUEST, 91, {"max_packet_bytes": 100}), _id(2), 5), H.Code.OK, "running answers a request")
	endpoint.drain_outbox()
	context.equal(endpoint.remote_packet_bytes(), 4000, "a remote request does not change the packet limit")
	context.state(0, JSON.stringify(endpoint.drain_transitions()).to_utf8_buffer())


func _echoes(context: RefCounted) -> void:
	var endpoint: Endpoint = _endpoint()
	context.equal(endpoint.begin(0, _id(1, 16)), H.Code.OK, "start")
	endpoint.drain_outbox()
	context.equal(endpoint.receive(_packet(T.Kind.SYNC_REPLY, 99, {"fps": 30}), _id(2), 1), H.Code.OK, "unknown before config")
	context.equal(endpoint.status().mismatch, {}, "unknown cannot poison")
	context.equal(endpoint.poll(201, _id(1, 16)), H.Code.OK, "live collision emits")
	context.equal(endpoint.status().pending.size(), 1, "collision one outstanding")
	context.equal(endpoint.status().requests_sent, 2, "collision counted send")
	context.equal(endpoint.receive(_packet(T.Kind.SYNC_REPLY, 1), _id(2), 202, _id(2, 16)), H.Code.OK, "one collision echo")
	context.equal(endpoint.status().remaining, 4, "one success")
	context.equal(endpoint.receive(_packet(T.Kind.SYNC_REPLY, 1, {"fps": 30}), _id(2), 203), H.Code.OK, "duplicate before config")
	context.equal(endpoint.status().remaining, 4, "duplicate no decrement")
	context.equal(endpoint.status().mismatch, {}, "duplicate no poison")
	var before: Dictionary = endpoint.status()
	context.equal(endpoint.poll(403, _id(1, 16)), H.Code.TOKEN_REUSED, "consumed fence")
	context.equal(endpoint.status(), before, "fence atomic")
	context.state(0, JSON.stringify(endpoint.drain_transitions()).to_utf8_buffer())


func _mismatch(context: RefCounted) -> void:
	var changes: Array[Dictionary] = [{"min_compat_version": 2}, {"player_count": 3, "roster": [_id(1), _id(2), _id(3)]},
		{"input_width": 2, "neutral_input": PackedByteArray([0, 0])}, {"fps": 30}, {"max_prediction": 4}, {"desync_interval": 0}, {"features": 1},
		{"input_delay": 1}, {"input_format": 2}, {"snapshot_format": 2}, {"checksum_algorithm": 2}, {"queue_capacity": 256}, {"neutral_input": PackedByteArray([1])},
		{"roster": [_id(2), _id(1)]}, {"config_digest": _id(1)}]
	var expected: Array[String] = ["min_compat_version", "player_count", "input_width", "fps", "max_prediction", "desync_interval", "features",
		"input_delay", "input_format", "snapshot_format", "checksum_algorithm", "queue_capacity", "neutral_input", "roster", "config_digest"]
	for index: int in range(changes.size()):
		var endpoint: Endpoint = _endpoint()
		endpoint.begin(0, _id(1, 16))
		endpoint.drain_outbox()
		context.equal(endpoint.receive(_packet(T.Kind.SYNC_REQUEST, 90, changes[index]), _id(2), 1), H.Code.OK, "bounded mismatch delivered")
		context.equal(endpoint.status().mismatch.get("field", "missing"), expected[index], "precise reason")
		context.equal(endpoint.status().remaining, 5, "mismatch no progress")
		context.equal(endpoint.status().remote_connection, "", "request never binds")
		context.equal(endpoint.drain_events().size(), 1, "one terminal incompatibility")
		context.equal(endpoint.drain_outbox().size(), 1, "mismatch answered")
		context.equal(endpoint.poll(9223372036854775807), H.Code.OK, "terminal no retry token needed")
		context.equal(endpoint.receive(_packet(T.Kind.SYNC_REQUEST, 91), _id(2), 9223372036854775807), H.Code.OK, "failed answers matching requests")
		context.equal(endpoint.drain_outbox().size(), 1, "only reply after fail")
		context.equal(endpoint.drain_events().size(), 0, "sticky failure once")
		context.state(index, JSON.stringify(endpoint.status()).to_utf8_buffer())
	var endpoint: Endpoint = _endpoint()
	endpoint.begin(0, _id(1, 16))
	context.equal(endpoint.receive(_packet(T.Kind.SYNC_REPLY, 1, {"fps": 30, "features": 1}), _id(2), 1), H.Code.OK, "known incompatible echo")
	context.equal(endpoint.status().mismatch.field, "fps", "upstream precedence")
	context.equal(endpoint.status().pending.size(), 0, "bad known echo consumed")
	context.equal(endpoint.status().remote_connection, "", "bad echo never binds")


func _time(context: RefCounted) -> void:
	var options: H.Options = H.Options.new()
	options.timeout_us = 200
	var endpoint: Endpoint = _endpoint(options)
	endpoint.begin(10, _id(1, 16))
	endpoint.drain_outbox()
	context.equal(endpoint.poll(210), H.Code.OK, "equal boundary no retry")
	context.equal(endpoint.drain_events().size(), 0, "equal boundary no timeout")
	context.equal(endpoint.poll(211, _id(2, 16)), H.Code.OK, "strictly later retry and timeout")
	context.equal(endpoint.drain_outbox().size(), 1, "retry")
	context.equal(endpoint.drain_events()[0], {"kind": "sync_timeout", "elapsed_ms": 0}, "timeout payload")
	context.equal(endpoint.poll(412, _id(3, 16)), H.Code.OK, "timeout nonterminal")
	context.equal(endpoint.drain_events().size(), 0, "timeout once")
	var before: Dictionary = endpoint.status()
	for invalid: Variant in [-1, 411, 412.0, true, null]:
		context.equal(endpoint.poll(invalid), H.Code.INVALID_ARGUMENT, "bad clock")
		context.equal(endpoint.status(), before, "bad clock atomic")
	context.equal(endpoint.receive(_packet(T.Kind.SYNC_REPLY, 1), _id(2), 412, _id(4, 16)), H.Code.OK, "timed out still recovers")
	context.equal(endpoint.status().remaining, 4, "timeout progress")
	options.retry_interval_us = 2000000
	options.timeout_us = 1000000
	endpoint = Endpoint.new()
	options.retry_interval_us = 2000000
	endpoint.configure(_message(), _id(2), options)
	endpoint.begin(0, _id(1, 16))
	var start_trace: Array[Dictionary] = endpoint.drain_transitions()
	context.equal(start_trace[0].elapsed_ms, -1, "absent elapsed sentinel")
	context.equal(endpoint.poll(1000000), H.Code.OK, "timeout equal real millisecond boundary")
	context.equal(endpoint.drain_events().size(), 0, "real timeout equality silent")
	context.equal(endpoint.poll(1001000), H.Code.OK, "real timeout with no retry")
	context.equal(endpoint.drain_events()[0].elapsed_ms, 1001, "event milliseconds once")
	context.equal(endpoint.drain_transitions()[0].elapsed_ms, 1001, "trace milliseconds once")
	endpoint = _endpoint()
	context.equal(endpoint.begin(0, _id(1, 16)), H.Code.OK, "start reply timer regression")
	endpoint.drain_outbox()
	context.equal(endpoint.receive(_packet(T.Kind.SYNC_REQUEST, 90), _id(2), 190), H.Code.OK, "queue matching reply near retry boundary")
	context.equal(endpoint.drain_outbox().size(), 1, "matching request produces reply")
	context.equal(endpoint.poll(201), H.Code.OK, "queued reply refreshes retry timer without needing token")
	context.equal(endpoint.drain_outbox().size(), 0, "no retry eleven microseconds after reply")
	context.equal(endpoint.poll(390), H.Code.OK, "reply retry equality remains silent")
	context.equal(endpoint.poll(391, _id(2, 16)), H.Code.OK, "retry strictly after reply interval")
	context.equal(endpoint.drain_outbox().size(), 1, "retry resumes from reply enqueue time")


func _identity(context: RefCounted) -> void:
	var endpoint: Endpoint = _endpoint()
	endpoint.begin(0, _id(1, 16))
	var before: Dictionary = endpoint.status()
	context.equal(endpoint.receive(_packet(T.Kind.SYNC_REPLY, 1), _id(3), 1), H.Code.WRONG_SOURCE, "transport source")
	context.equal(endpoint.receive(_packet(T.Kind.SYNC_REPLY, 1, {"session_id": _id(8, 16)}), _id(2), 1), H.Code.WRONG_SOURCE, "session source")
	context.equal(endpoint.receive(_packet(T.Kind.SYNC_REPLY, 1, {"sender_id": _id(3)}), _id(2), 1), H.Code.WRONG_SOURCE, "header source")
	context.equal(endpoint.receive(PackedByteArray([1]), _id(2), 1), H.Code.INVALID_PACKET, "malformed")
	context.equal(endpoint.receive(_packet(T.Kind.KEEP_ALIVE, 1), _id(2), 1), H.Code.UNSUPPORTED_KIND, "handshake scope")
	context.equal(endpoint.receive(_packet(T.Kind.SYNC_REPLY, 1, {}, 0), _id(2), 1), H.Code.WRONG_CONNECTION, "zero era")
	context.equal(endpoint.status(), before, "all hostile atomic")
	endpoint.receive(_packet(T.Kind.SYNC_REPLY, 1), _id(2), 1, _id(2, 16))
	before = endpoint.status()
	context.equal(endpoint.receive(_packet(T.Kind.SYNC_REPLY, 2, {}, 21), _id(2), 2), H.Code.WRONG_CONNECTION, "bound era")
	context.equal(endpoint.status(), before, "era rejection atomic")


func _backpressure(context: RefCounted) -> void:
	var invalid: H.Options = H.Options.new()
	invalid.max_transitions = 1
	context.equal(Endpoint.new().configure(_message(), _id(2), invalid), H.Code.INVALID_ARGUMENT, "begin requires two transition slots")
	invalid.max_transitions = 2
	invalid.max_consumed_tokens = invalid.roundtrips - 1
	context.equal(Endpoint.new().configure(_message(), _id(2), invalid), H.Code.INVALID_ARGUMENT, "history must hold all roundtrips")
	var minimum: H.Options = H.Options.new()
	minimum.roundtrips = 128
	minimum.max_consumed_tokens = 128
	minimum.max_pending_tokens = 1
	minimum.max_transitions = 2
	minimum.max_events = 1
	minimum.max_outbox = 1
	var bounded: Endpoint = _endpoint(minimum)
	context.equal(bounded.begin(0, _id(1, 16)), H.Code.OK, "max rounds starts with smallest coherent queues")
	for token: int in range(1, 129):
		bounded.drain_outbox()
		bounded.drain_events()
		bounded.drain_transitions()
		context.equal(bounded.receive(_packet(T.Kind.SYNC_REPLY, token), _id(2), token, _id(token + 1, 16)), H.Code.OK, "max rounds progresses after drains")
	context.equal(bounded.status().state, "running", "max rounds completes")
	context.equal(bounded.status().consumed.size(), 128, "minimum history holds every accepted token")
	for bound: String in ["max_pending_tokens", "max_outbox", "max_events", "max_transitions"]:
		var options: H.Options = H.Options.new()
		options.set(bound, 1 if bound != "max_transitions" else 2)
		var endpoint: Endpoint = _endpoint(options)
		context.equal(endpoint.begin(0, _id(1, 16)), H.Code.OK, "bounded start")
		if bound == "max_pending_tokens":
			var before: Dictionary = endpoint.status()
			context.equal(endpoint.poll(201, _id(2, 16)), H.Code.BACKPRESSURE, "pending capacity")
			context.equal(endpoint.status(), before, "pending atomic")
			continue
		if bound not in ["max_outbox", "max_transitions"]:
			endpoint.drain_outbox()
			endpoint.drain_transitions()
			endpoint.receive(_packet(T.Kind.SYNC_REPLY, 1), _id(2), 1, _id(2, 16))
			endpoint.drain_outbox()
			endpoint.drain_transitions()
		var before: Dictionary = endpoint.status()
		context.equal(endpoint.receive(_packet(T.Kind.SYNC_REPLY, 1 if bound in ["max_outbox", "max_transitions"] else 2), _id(2), 2, _id(3, 16)),
			H.Code.BACKPRESSURE, "queue bound %s" % bound)
		context.equal(endpoint.status(), before, "all state atomic %s" % bound)
	var options: H.Options = H.Options.new()
	options.max_outbox = 1
	var endpoint: Endpoint = _endpoint(options)
	endpoint.begin(0, _id(1, 16))
	context.equal(endpoint.receive(_packet(T.Kind.SYNC_REQUEST, 9, {"fps": 30}), _id(2), 1), H.Code.BACKPRESSURE, "reply blocked before failure")
	context.equal(endpoint.status().mismatch, {}, "no premature terminal state")
	endpoint.drain_outbox()
	context.equal(endpoint.receive(_packet(T.Kind.SYNC_REQUEST, 9, {"fps": 30}), _id(2), 1), H.Code.OK, "retry same request after drain")
	context.equal(endpoint.status().mismatch.field, "fps", "terminal with reply queued")


# Value: protects=deadline diagnostics under retry pressure; fails_when=atomic send refusal also rolls back expiry; why_new=timeout and capacity were tested separately
func _timeout_pressure(context: RefCounted) -> void:
	for bound: String in ["max_pending_tokens", "max_outbox"]:
		var options: H.Options = H.Options.new()
		options.set(bound, 1)
		options.timeout_us = 1000
		var endpoint: Endpoint = _endpoint(options)
		context.equal(endpoint.begin(0, _id(1, 16)), H.Code.OK, "begin bounded handshake")
		endpoint.drain_events()
		endpoint.drain_transitions()
		context.equal(endpoint.poll(1000, _id(2, 16)), H.Code.BACKPRESSURE, "exact deadline still retries")
		context.equal(endpoint.drain_events().is_empty(), true, "strict deadline does not expire early")
		var before: Dictionary = endpoint.status()
		context.equal(endpoint.poll(1001, PackedByteArray()), H.Code.INVALID_ARGUMENT, "invalid callback token remains refused")
		context.equal(endpoint.status(), before, "invalid callback keeps atomic state")
		context.equal(endpoint.poll(1001, _id(2, 16)), H.Code.BACKPRESSURE, "retry refusal remains observable")
		var events: Array[Dictionary] = endpoint.drain_events()
		context.equal(events.size(), 1, "exactly one due timeout survives retry pressure")
		if not events.is_empty():
			context.equal(events[0].kind, "sync_timeout", "timeout diagnostic retained")
		context.equal(endpoint.status().timeout_sent, true, "timeout committed without publishing a retry")
		context.equal(endpoint.status().requests_sent, before.requests_sent, "unsent request never enters state")
		context.equal(endpoint.status().pending, before.pending, "unsent token never enters history")
		context.equal(endpoint.poll(2002, _id(3, 16)), H.Code.BACKPRESSURE, "later pressure still refuses")
		context.equal(endpoint.drain_events().is_empty(), true, "timeout never duplicates")


func _ownership(context: RefCounted) -> void:
	var oversized: T.Message = _message()
	oversized.config.roster = []
	for index: int in range(100000):
		var identity: PackedByteArray = _id(1)
		identity.encode_u32(0, index + 1)
		oversized.config.roster.append(identity)
	var counted: CountingEndpoint = CountingEndpoint.new()
	context.equal(counted.configure(oversized, _id(2), H.Options.new()), H.Code.INVALID_ARGUMENT, "oversized roster rejected")
	context.equal(counted.identity_checks <= 4, true, "oversized roster rejected before proportional validation (%d checks)" % counted.identity_checks)
	context.equal(counted.status(), {}, "oversized roster never publishes state")
	var local: T.Message = _message()
	var remote: PackedByteArray = _id(2)
	var options: H.Options = H.Options.new()
	var endpoint: Endpoint = Endpoint.new()
	context.equal(endpoint.configure(local, remote, options), H.Code.OK, "configure")
	local.config.fps = 30
	local.config.roster[0][0] = 5
	remote[0] = 6
	options.roundtrips = 1
	var token: PackedByteArray = _id(1, 16)
	context.equal(endpoint.begin(0, token), H.Code.OK, "frozen inputs")
	token[0] = 3
	var outgoing: T.Message = Codec.decode(endpoint.drain_outbox()[0], T.Limits.new()).message
	context.equal(outgoing.config.fps, 60, "config copied")
	context.equal(outgoing.token, _id(1, 16), "token copied")
	context.equal(endpoint.receive(_packet(T.Kind.SYNC_REPLY, 1), _id(2), 1, _id(2, 16)), H.Code.OK, "owned remote")
	var status: Dictionary = endpoint.status()
	status.pending.clear()
	status.remaining = 0
	context.equal(endpoint.status().remaining, 4, "status owned")
	context.equal(endpoint.status().pending.size(), 1, "pending owned")
	context.equal(endpoint.configure(_message(), _id(2), H.Options.new()), H.Code.WRONG_STATE, "one shot")
	for bad: Variant in [null, 1, {}]:
		context.equal(Endpoint.new().configure(bad, _id(2), H.Options.new()), H.Code.INVALID_ARGUMENT, "type gate")
	local = _message()
	local.config.roster = [_id(1), _id(1)]
	context.equal(Endpoint.new().configure(local, _id(2), H.Options.new()), H.Code.INVALID_ARGUMENT, "remote absent in repeated roster")
	local.config.player_count = 3
	local.config.roster = [_id(1), _id(1), _id(2)]
	context.equal(Endpoint.new().configure(local, _id(2), H.Options.new()), H.Code.OK, "repeated endpoint ownership")
	local.config.player_count = 2
	local.config.roster = [_id(1), _id(3)]
	context.equal(Endpoint.new().configure(local, _id(2), H.Options.new()), H.Code.INVALID_ARGUMENT, "remote absent")
