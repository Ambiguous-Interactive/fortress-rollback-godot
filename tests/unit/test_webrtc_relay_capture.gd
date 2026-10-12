extends RefCounted

# Value: protects=bounded overlap evidence; fails_when=later relay variants exhaust early inventory; why_new=browser callbacks lacked native coverage; seam=actual SDK signal
const Fixture = preload("res://tests/unit/test_signalfish_fallback.gd")
const Mixed = preload("res://scripts/reference/browser/webrtc_mixed.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const Envelope = preload("res://addons/fortress_rollback/transport/signalfish_relay_envelope.gd")
const M = preload("res://tests/unit/test_signalfish_membership.gd")

func cases() -> PackedStringArray:
	return PackedStringArray(["later_traffic", "boundaries", "capture_cap", "invalid"])

func run_case(name: String, context: RefCounted) -> void:
	var helper: RefCounted = Fixture.new()
	var fixture: Dictionary = helper.build(context)
	# The observer receives the real SDK signal without filling the unrelated transport ingress FIFO.
	fixture.relay.detach()
	var host: Host = Host.new()
	host.clients = [fixture.client]
	host.memberships = [fixture.membership]
	var mixed: RefCounted = Mixed.new()
	mixed.uuid = M.U
	mixed._observe_relay(host)
	match name:
		"later_traffic":
			var original: PackedByteArray = _payload(context, fixture, T.Kind.INPUT, 2)
			_emit(fixture, original)
			for index: int in 130:
				_emit(fixture, _payload(context, fixture, T.Kind.INPUT_ACK, index + 4))
				_emit(fixture, _payload(context, fixture, T.Kind.INPUT, index + 4))
			_emit(fixture, original)
			context.equal(mixed.accepted_binary, 262, "all addressed binary traffic remains counted")
			context.equal(mixed.relay_payloads.keys(), [original.hex_encode()], "late exact echo retains only original early input")
			context.equal(host.errors, [], "later valid variants cannot overflow overlap evidence")
		"boundaries":
			var last: PackedByteArray = _payload(context, fixture, T.Kind.INPUT, 2)
			var multi: PackedByteArray = _payload(context, fixture, T.Kind.INPUT, 0, 0, 3)
			_emit(fixture, _payload(context, fixture, T.Kind.INPUT, 0))
			_emit(fixture, last)
			_emit(fixture, multi)
			_emit(fixture, _payload(context, fixture, T.Kind.INPUT, 3))
			_emit(fixture, _payload(context, fixture, T.Kind.INPUT, 2, 0, 2))
			_emit(fixture, _payload(context, fixture, T.Kind.INPUT_ACK, 2))
			context.equal(mixed.accepted_binary, 6, "boundary exclusions preserve addressed count")
			context.equal(mixed.relay_payloads.size(), 3, "only inputs ending at or below frame three are retained")
			context.equal(mixed.relay_payloads.has(last.hex_encode()), true, "exclusive end frame three remains eligible")
			context.equal(mixed.relay_payloads.has(multi.hex_encode()), true, "multi-frame candidate ending at three remains eligible")
			context.equal(host.errors, [], "boundary capture remains healthy")
		"capture_cap":
			for index: int in 128:
				_emit(fixture, _payload(context, fixture, T.Kind.INPUT, 0, index))
			context.equal(host.errors, [], "128 distinct early candidates fit unchanged cap")
			_emit(fixture, _payload(context, fixture, T.Kind.INPUT, 0, 0))
			context.equal(host.errors, [], "duplicate at capacity consumes no inventory slot")
			_emit(fixture, _payload(context, fixture, T.Kind.INPUT, 0, 128))
			context.equal(mixed.relay_payloads.size(), 128, "early inventory remains bounded")
			context.equal(host.errors, ["mixed_capture_overflow"], "distinct early overflow still fails loudly")
			context.equal(mixed.accepted_binary, 130, "overflow does not hide addressed traffic count")
		"invalid":
			_emit(fixture, PackedByteArray([1, 2, 3]))
			context.equal(mixed.accepted_binary, 1, "valid envelope remains counted despite malformed protocol")
			var bytes: PackedByteArray = _payload(context, fixture, T.Kind.INPUT, 0)
			var session: PackedByteArray = fixture.membership.handshake_message().session_id
			fixture.client.game_data_binary_received.emit(M.V, 0, Envelope.encode(session, M.V, M.U, bytes))
			fixture.client.game_data_binary_received.emit(M.W, 1, Envelope.encode(session, M.V, M.U, bytes))
			fixture.client.game_data_binary_received.emit(M.V, 1, Envelope.encode(session, M.V, M.W, bytes))
			var other_session: PackedByteArray = session.duplicate()
			other_session[0] ^= 1
			fixture.client.game_data_binary_received.emit(M.V, 1, Envelope.encode(other_session, M.V, M.U, bytes))
			context.equal(mixed.accepted_binary, 1, "envelope fences exclude unrelated traffic")
			context.equal(mixed.relay_payloads.size(), 0, "malformed protocol cannot enter early inventory")
			context.equal(host.errors, [], "unrelated envelopes cannot trigger capture overflow")
	helper.destroy(fixture)
	host.free()
	context.finish()

func _payload(context: RefCounted, fixture: Dictionary, kind: int, frame: int, epoch: int = 0, frames: int = 1) -> PackedByteArray:
	var message: T.Message = T.Message.new()
	message.kind = kind
	message.session_id = fixture.membership.handshake_message().session_id
	message.sender_id = fixture.membership.identity(M.V)
	message.start_frame = frame
	message.frame_count = frames
	message.ack_frame = frame
	message.players = PackedByteArray([1])
	for index: int in frames:
		message.data.append((frame + index) & 255)
	for index: int in 2:
		var status: T.Status = T.Status.new()
		status.epoch = epoch
		message.statuses.append(status)
	var encoded: T.Result = Codec.encode(message, T.Limits.new())
	context.equal(encoded.code, T.Code.OK, "regression traffic uses valid actual protocol encoding")
	return encoded.bytes

func _emit(fixture: Dictionary, bytes: PackedByteArray) -> void:
	var session: PackedByteArray = fixture.membership.handshake_message().session_id
	fixture.client.game_data_binary_received.emit(M.V, 1, Envelope.encode(session, M.V, M.U, bytes))

class Host:
	extends Node
	var clients: Array = []
	var memberships: Array = []
	var player_count: int = 2
	var errors: Array[String] = []
