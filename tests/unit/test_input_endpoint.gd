extends RefCounted

# Value: protects=retention before ACK and loss recovery; fails_when=invalid packets trim history or duplicate traffic starves retries; why_new=first input endpoint; seam=none
const E = preload("res://addons/fortress_rollback/protocol/input_endpoint.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const H = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")


class Sink:
	extends RefCounted
	var frames: Dictionary = {}
	var fail_frame: int = -1
	var endpoint: E = null
	var reentry: Array[int] = []

	func accept(frame: int, data: PackedByteArray) -> int:
		if endpoint != null:
			reentry.append(endpoint.poll(100))
			reentry.append(endpoint.submit(0, PackedByteArray([1]), [], 100))
			reentry.append(endpoint.begin(100, PackedByteArray()))
			reentry.append(endpoint.receive(PackedByteArray(), PackedByteArray(), 100))
			reentry.append(endpoint.configure(null, null, null, null, null))
			reentry.append(endpoint.drain_outbox().size())
		if frame == fail_frame:
			return 1
		frames[frame] = data.duplicate()
		data.fill(255)
		return 0


func cases() -> PackedStringArray:
	return PackedStringArray(["loss_ack", "retry", "validation", "retention", "capacity", "ownership", "status_nudge", "status_nudge_transitions"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"loss_ack": _loss_ack(context)
		"retry": _retry(context)
		"validation": _validation(context)
		"retention": _retention(context)
		"capacity": _capacity(context)
		"ownership": _ownership(context)
		"status_nudge": _status_nudge(context)
		"status_nudge_transitions": _status_nudge_transitions(context)
	context.finish()


func _id(value: int, width: int = 8) -> PackedByteArray:
	var result: PackedByteArray = PackedByteArray()
	result.resize(width)
	result[0] = value
	return result


func _local(sender: int = 1, roster: Array[PackedByteArray] = [], delay: int = 0) -> T.Message:
	var message: T.Message = T.Message.new()
	message.kind = T.Kind.SYNC_REQUEST
	message.sender_id = _id(sender)
	message.connection_id = _id(10 * sender)
	message.session_id = _id(9, 16)
	if roster.is_empty():
		message.config.roster = [_id(1), _id(2)]
	else:
		message.config.roster = roster
	message.config.player_count = message.config.roster.size()
	message.config.input_delay = delay
	return message


func _statuses(count: int = 2, last_frame: int = -1) -> Array[T.Status]:
	var result: Array[T.Status] = []
	for slot: int in range(count):
		var value: T.Status = T.Status.new()
		value.last_frame = last_frame
		result.append(value)
	return result


func _ready(sink: Sink, options: I.Options = null, roster: Array[PackedByteArray] = [], delay: int = 0, max_packet: int = 65536, remote_packet: int = 65536) -> E:
	var endpoint: E = E.new()
	var handshake_options: H.Options = H.Options.new()
	handshake_options.roundtrips = 1
	handshake_options.max_packet_bytes = max_packet
	endpoint.configure(_local(1, roster, delay), _id(2), handshake_options, options if options != null else I.Options.new(), sink.accept)
	endpoint.begin(0, _id(1, 16))
	endpoint.drain_outbox()
	var reply: T.Message = _local(2, roster, delay)
	reply.kind = T.Kind.SYNC_REPLY
	reply.token = _id(1, 16)
	reply.max_packet_bytes = remote_packet
	var limits: T.Limits = T.Limits.new()
	limits.player_count = reply.config.player_count
	endpoint.receive(Codec.encode(reply, limits).bytes, _id(2), 1)
	endpoint.drain_events()
	endpoint.drain_transitions()
	return endpoint


func _input(start: int, bytes: PackedByteArray, ack: int = -1, players: PackedByteArray = PackedByteArray([1]), count: int = 2) -> T.Message:
	var message: T.Message = _local(2)
	message.kind = T.Kind.INPUT
	message.start_frame = start
	message.players = players
	message.frame_count = bytes.size() / players.size()
	message.statuses = _statuses(count)
	message.data = bytes
	message.ack_frame = ack
	return message


func _encode(message: T.Message, count: int = 2) -> PackedByteArray:
	var limits: T.Limits = T.Limits.new()
	limits.player_count = count
	return Codec.encode(message, limits).bytes


func _ack_packet(frame: int) -> PackedByteArray:
	var message: T.Message = _local(2)
	message.kind = T.Kind.INPUT_ACK
	message.ack_frame = frame
	return _encode(message)


func _decoded(packet: PackedByteArray, count: int = 2) -> T.Message:
	var limits: T.Limits = T.Limits.new()
	limits.player_count = count
	return Codec.decode(packet, limits).message


func _loss_ack(context: RefCounted) -> void:
	var sink: Sink = Sink.new()
	var endpoint: E = _ready(sink)
	for frame: int in range(3):
		context.equal(endpoint.submit(frame, PackedByteArray([10 + frame]), _statuses(), 2 + frame), I.Code.OK, "retain consecutive local sample")
		var sent: T.Message = _decoded(endpoint.drain_outbox()[0])
		context.equal(sent.start_frame, 0, "resend oldest unacknowledged prefix")
		context.equal(sent.frame_count, frame + 1, "batch all retained inputs")
		context.equal(sent.ack_frame, -1, "no invented remote retention")
	context.equal(endpoint.receive(_ack_packet(3), _id(2), 5), I.Code.OK, "future ACK ignored")
	context.equal(endpoint.status().pending_frames, 3, "future ACK preserves history")
	context.equal(endpoint.receive(_ack_packet(1), _id(2), 6), I.Code.OK, "inclusive ACK")
	context.equal(endpoint.status().pending.keys(), [2], "ACK removes through its frame")
	context.equal(endpoint.receive(_ack_packet(0), _id(2), 7), I.Code.OK, "stale ACK")
	context.equal(endpoint.status().last_acked_frame, 1, "stale ACK cannot rewind")
	context.equal(endpoint.receive(_encode(_input(1, PackedByteArray([8]))), _id(2), 8), I.Code.OK, "initial gap ignored")
	context.equal(sink.frames, {}, "gap never reaches sink")
	context.equal(_decoded(endpoint.drain_outbox()[0]).ack_frame, -1, "gap reACKs contiguous floor")
	var bytes: PackedByteArray = _encode(_input(0, PackedByteArray([7, 8]), 2))
	context.equal(endpoint.receive(bytes, _id(2), 9), I.Code.OK, "complete missing prefix")
	context.equal(sink.frames, {0: PackedByteArray([7]), 1: PackedByteArray([8])}, "retain each frame before ack")
	context.equal(endpoint.status().pending_frames, 0, "valid piggyback inclusive ACK")
	context.equal(_decoded(endpoint.drain_outbox()[0]).ack_frame, 1, "advertise retained prefix")
	context.equal(endpoint.receive(bytes, _id(2), 10), I.Code.OK, "lost ACK repaired by duplicate")
	context.equal(sink.frames.size(), 2, "duplicate never reapplies input")
	context.equal(_decoded(endpoint.drain_outbox()[0]).ack_frame, 1, "duplicate cumulative ACK")
	context.state(0, JSON.stringify(endpoint.status()).to_utf8_buffer())


func _retry(context: RefCounted) -> void:
	var options: I.Options = I.Options.new()
	options.retry_interval_us = 200
	var sink: Sink = Sink.new()
	var endpoint: E = _ready(sink, options)
	endpoint.submit(0, PackedByteArray([3]), _statuses(), 2)
	endpoint.drain_outbox()
	context.equal(endpoint.receive(_encode(_input(0, PackedByteArray([4]))), _id(2), 100), I.Code.OK, "new input refreshes pacer")
	endpoint.drain_outbox()
	context.equal(endpoint.receive(_encode(_input(0, PackedByteArray([4]))), _id(2), 290), I.Code.OK, "duplicate input")
	endpoint.drain_outbox()
	endpoint.receive(_ack_packet(-1), _id(2), 299)
	context.equal(endpoint.poll(300), I.Code.OK, "strict retry equality")
	context.equal(endpoint.drain_outbox().size(), 0, "duplicate and ACK cannot move retry")
	context.equal(endpoint.poll(301, null, _statuses(2, 9)), I.Code.OK, "retry after strict interval")
	var retry_packets: Array[PackedByteArray] = endpoint.drain_outbox()
	context.equal(retry_packets.size(), 1, "duplicate traffic cannot suppress retry")
	if retry_packets.is_empty():
		return
	var retry: T.Message = _decoded(retry_packets[0])
	context.equal(retry.start_frame, 0, "retry retains oldest")
	context.equal(retry.statuses[0].last_frame, 9, "retry uses current gossip")
	context.equal(retry.ack_frame, 0, "retry piggybacks actual receive")
	context.equal(endpoint.submit(1, PackedByteArray([5]), _statuses(), 490), I.Code.OK, "new local send")
	endpoint.drain_outbox()
	context.equal(endpoint.poll(502), I.Code.OK, "local sends do not postpone retry")
	context.equal(endpoint.drain_outbox().size(), 1, "retry paced from preceding retry")
	context.equal(endpoint.status().connect_statuses[0].last_frame, 9, "stale gossip does not rewind")


func _validation(context: RefCounted) -> void:
	var sink: Sink = Sink.new()
	var endpoint: E = _ready(sink)
	endpoint.submit(0, PackedByteArray([5]), _statuses(), 2)
	endpoint.drain_outbox()
	var valid: T.Message = _input(0, PackedByteArray([6]), 0)
	var before: Dictionary = endpoint.status()
	var packets: Array[PackedByteArray] = [PackedByteArray([1])]
	var bad: T.Message = _input(0, PackedByteArray([6]), 0, PackedByteArray([0]))
	packets.append(_encode(bad))
	for packet: PackedByteArray in packets:
		context.equal(endpoint.receive(packet, _id(2), 3), I.Code.INVALID_PACKET, "malformed ownership packet")
		context.equal(endpoint.status(), before, "malformed packet preserves ACK and state")
	context.equal(endpoint.receive(_encode(valid), _id(3), 3), I.Code.WRONG_SOURCE, "attributed source")
	valid.sender_id = _id(3)
	context.equal(endpoint.receive(_encode(valid), _id(2), 3), I.Code.WRONG_SOURCE, "header source")
	valid.sender_id = _id(2)
	valid.connection_id = _id(21)
	context.equal(endpoint.receive(_encode(valid), _id(2), 3), I.Code.WRONG_CONNECTION, "connection era")
	valid.connection_id = _id(20)
	valid.statuses[0].disconnected = true
	context.equal(endpoint.receive(_encode(valid), _id(2), 3), I.Code.UNSUPPORTED_KIND, "disconnect lifecycle explicitly unsupported")
	context.equal(sink.frames.size(), 0, "invalid packets never call retention")
	context.equal(endpoint.status(), before, "all rejected packets atomic")
	for bad_time: Variant in [-1, 1, true, 2.0, null]:
		context.equal(endpoint.poll(bad_time), I.Code.INVALID_ARGUMENT, "clock exact integer and nondecreasing")
	context.equal(endpoint.submit(true, PackedByteArray([1]), _statuses(), 3), I.Code.INVALID_FRAME, "bool frame rejected")
	context.equal(endpoint.submit(1, PackedByteArray([1]), [null, null], 3), I.Code.INVALID_ARGUMENT, "status types rejected")
	context.equal(endpoint.poll(3, null, [null, null]), I.Code.INVALID_ARGUMENT, "poll statuses validated before retry")
	context.equal(endpoint.status(), before, "scalar rejects preserve state")


func _retention(context: RefCounted) -> void:
	var sink: Sink = Sink.new()
	var endpoint: E = _ready(sink)
	sink.endpoint = endpoint
	sink.fail_frame = 1
	endpoint.submit(0, PackedByteArray([3]), _statuses(), 2)
	endpoint.drain_outbox()
	context.equal(endpoint.receive(_encode(_input(0, PackedByteArray([7, 8]), 0)), _id(2), 3), I.Code.INPUT_FAILED, "sink refusal terminal")
	context.equal(endpoint.status().state, "terminated", "fail closed")
	context.equal(endpoint.status().last_received_frame, 0, "only accepted prefix retained")
	context.equal(endpoint.status().last_acked_frame, -1, "piggyback ACK never consumes on sink refusal")
	context.equal(endpoint.drain_outbox().size(), 0, "never ACK unretained frame")
	context.equal(endpoint.drain_events()[0], {"kind": "input_failed", "frame": 1}, "failure has frame")
	context.equal(sink.reentry, [9, 9, 9, 9, 9, 0, 9, 9, 9, 9, 9, 0], "all mutation reentry guarded through callback")
	context.equal(endpoint.poll(4), I.Code.TERMINATED, "terminal cannot retry")
	context.equal(endpoint.submit(1, PackedByteArray([3]), _statuses(), 4), I.Code.TERMINATED, "terminal cannot submit")
	var retained: Sink = Sink.new()
	var options: I.Options = I.Options.new()
	options.max_received_frames = 1
	endpoint = _ready(retained, options)
	endpoint.receive(_encode(_input(0, PackedByteArray([1, 2, 3]))), _id(2), 2)
	endpoint.drain_outbox()
	context.equal(endpoint.receive(_encode(_input(2, PackedByteArray([99]))), _id(2), 3), I.Code.CONFLICT, "retained actual input immutable")
	context.equal(endpoint.receive(_encode(_input(0, PackedByteArray([99]))), _id(2), 3), I.Code.OK, "pruned stale input ignored")
	context.equal(_decoded(endpoint.drain_outbox()[0]).ack_frame, 2, "pruned stale retransmit reACKs actual prefix")
	context.equal(retained.frames[0], PackedByteArray([1]), "stale input never overwrites sink")


func _capacity(context: RefCounted) -> void:
	var options: I.Options = I.Options.new()
	options.max_pending_frames = 2
	options.max_outbox = 1
	var sink: Sink = Sink.new()
	var endpoint: E = _ready(sink, options)
	endpoint.submit(0, PackedByteArray([3]), _statuses(), 2)
	var before: Dictionary = endpoint.status()
	context.equal(endpoint.submit(1, PackedByteArray([4]), _statuses(), 3), I.Code.BACKPRESSURE, "publication capacity")
	context.equal(endpoint.status(), before, "failed submit never retains partial frame")
	context.equal(endpoint.receive(_encode(_input(0, PackedByteArray([7]), 0)), _id(2), 3), I.Code.BACKPRESSURE, "ACK publication reserved before sink")
	context.equal(sink.frames, {}, "capacity prevents irreversible sink")
	context.equal(endpoint.status(), before, "capacity preserves piggyback ACK")
	endpoint.drain_outbox()
	context.equal(endpoint.submit(1, PackedByteArray([4]), _statuses(), 3), I.Code.OK, "drain recovers")
	endpoint.drain_outbox()
	context.equal(endpoint.submit(2, PackedByteArray([5]), _statuses(), 4), I.Code.BACKPRESSURE, "history never discards oldest pending")
	context.equal(endpoint.status().pending_frames, 2, "bounded history")
	context.equal(endpoint.submit(1, PackedByteArray([4]), _statuses(), 4), I.Code.OK, "retained duplicate idempotent")
	context.equal(endpoint.submit(1, PackedByteArray([9]), _statuses(), 4), I.Code.CONFLICT, "retained duplicate conflict")
	options.max_input_frames = 1
	endpoint = _ready(Sink.new(), options)
	for frame: int in range(2):
		context.equal(endpoint.submit(frame, PackedByteArray([frame]), _statuses(), 2 + frame), I.Code.OK, "bounded batch submit")
		context.equal(_decoded(endpoint.drain_outbox()[0]).frame_count, 1, "oldest prefix obeys batch cap")
	context.equal(endpoint.receive(_ack_packet(1), _id(2), 4), I.Code.OK, "ACK unsent frame ignored")
	context.equal(endpoint.status().pending_frames, 2, "unsent frame cannot discard history")
	endpoint.receive(_ack_packet(0), _id(2), 5)
	endpoint.poll(200002)
	context.equal(_decoded(endpoint.drain_outbox()[0]).start_frame, 1, "next oldest after inclusive ack")
	options.max_pending_frames = 4097
	context.equal(E.new().configure(_local(), _id(2), H.Options.new(), options, sink.accept), I.Code.INVALID_ARGUMENT, "hard pending bound")
	options.max_pending_frames = 2
	options.max_buffer_bytes = 1
	context.equal(E.new().configure(_local(), _id(2), H.Options.new(), options, sink.accept), I.Code.INVALID_ARGUMENT, "retained memory budget")

	var large: I.Options = I.Options.new()
	var large_sink: Sink = Sink.new()
	endpoint = _ready(large_sink, large)
	var remote_bytes: PackedByteArray = PackedByteArray()
	for frame: int in range(128):
		context.equal(endpoint.submit(frame, PackedByteArray([frame]), _statuses(), 2 + frame), I.Code.OK, "maximum batch history")
		var sent: T.Message = _decoded(endpoint.drain_outbox()[0])
		context.equal(sent.frame_count, frame + 1, "maximum frame batch cap includes boundary")
		remote_bytes.append(frame)
	context.equal(endpoint.receive(_encode(_input(0, remote_bytes, 127)), _id(2), 130), I.Code.OK, "maximum batch retained before inclusive ACK")
	context.equal(large_sink.frames.size(), 128, "all maximum batch callbacks accounted")
	context.equal(endpoint.status().pending_frames, 0, "maximum batch ACK releases full prefix")
	context.equal(_decoded(endpoint.drain_outbox()[0]).ack_frame, 127, "maximum batch cumulative ACK")
	# max_input_frames caps what this peer sends. A peer with a larger cap must still be heard.
	var narrow: I.Options = I.Options.new()
	narrow.max_input_frames = 4
	var narrow_sink: Sink = Sink.new()
	endpoint = _ready(narrow_sink, narrow)
	context.equal(endpoint.receive(_encode(_input(0, PackedByteArray([0, 1, 2, 3, 4, 5]))), _id(2), 2), I.Code.OK, "larger remote batch accepted")
	context.equal(narrow_sink.frames.size(), 6, "every frame of a larger remote batch delivered")
	# 127 bytes is the exact two-player handshake size, which leaves room for 52 one-byte frames.
	# Either side's limit applies: a remote advertising 127 bytes caps a local 65536-byte endpoint the same way.
	for limits: Array in [[127, 65536], [65536, 127]]:
		endpoint = _ready(large_sink, large, [], 0, limits[0], limits[1])
		for frame: int in range(53):
			context.equal(endpoint.submit(frame, PackedByteArray([frame]), _statuses(), 2 + frame), I.Code.OK, "packet byte cap retains unsent suffix")
			var packets: Array[PackedByteArray] = endpoint.drain_outbox()
			context.equal(packets[0].size() <= 127, true, "every batch respects the smaller packet byte cap")
			context.equal(_decoded(packets[0]).frame_count, mini(52, frame + 1), "packet cap truncates oldest prefix")
		context.equal(endpoint.receive(_ack_packet(52), _id(2), 58), I.Code.OK, "packet-cap unsent ACK ignored")
		context.equal(endpoint.status().pending_frames, 53, "packet-cap suffix protected")
		endpoint.receive(_ack_packet(51), _id(2), 59)
		context.equal(endpoint.status().pending.keys(), [52], "inclusive transmitted prefix removed")


func _ownership(context: RefCounted) -> void:
	var roster: Array[PackedByteArray] = [_id(1), _id(2), _id(1), _id(2)]
	var sink: Sink = Sink.new()
	var endpoint: E = _ready(sink, null, roster)
	context.equal(endpoint.status().local_players, PackedByteArray([0, 2]), "sorted exact local slots")
	context.equal(endpoint.status().remote_players, PackedByteArray([1, 3]), "sorted exact remote slots")
	var sample: PackedByteArray = PackedByteArray([3, 4])
	var statuses: Array[T.Status] = _statuses(4, 8)
	context.equal(endpoint.submit(0, sample, statuses, 2), I.Code.OK, "multi-local input")
	sample.fill(99)
	statuses[0].last_frame = 99
	var sent: T.Message = _decoded(endpoint.drain_outbox()[0], 4)
	context.equal(sent.players, PackedByteArray([0, 2]), "canonical player ordering")
	context.equal(sent.data, PackedByteArray([3, 4]), "local bytes owned")
	context.equal(sent.statuses[0].last_frame, 8, "submitted statuses owned")
	context.equal(endpoint.status().peer_statuses[0].last_frame, -1, "outgoing statuses never fabricate peer observations")
	var remote: T.Message = _input(0, PackedByteArray([7, 8, 9, 10]), -1, PackedByteArray([1, 3]), 4)
	context.equal(endpoint.receive(_encode(remote, 4), _id(2), 3), I.Code.OK, "multi-remote batch retained")
	context.equal(sink.frames, {0: PackedByteArray([7, 8]), 1: PackedByteArray([9, 10])}, "remote packed slot bytes")
	var status: Dictionary = endpoint.status()
	status.pending[0].fill(99)
	status.received[1].fill(99)
	status.peer_statuses[0].last_frame = 99
	status.connect_statuses[0].last_frame = 99
	context.equal(endpoint.status().pending[0], PackedByteArray([3, 4]), "status pending owned")
	context.equal(endpoint.status().received[1], PackedByteArray([9, 10]), "sink and status cannot mutate retained bytes")
	context.equal(endpoint.status().peer_statuses[0].last_frame, -1, "status peer gossip owned")
	context.equal(endpoint.status().connect_statuses[0].last_frame, 8, "outgoing gossip cache owned")
	var delayed: Sink = Sink.new()
	endpoint = _ready(delayed, null, [], 2)
	context.equal(endpoint.receive(_encode(_input(2, PackedByteArray([7]))), _id(2), 2), I.Code.OK, "agreed initial delay allowed")
	context.equal(endpoint.status().last_received_frame, 2, "initial delay retained")
	context.equal(endpoint.submit(2, PackedByteArray([8]), _statuses(), 3), I.Code.OK, "local agreed initial delay allowed")
	context.equal(endpoint.submit(4, PackedByteArray([8]), _statuses(), 4), I.Code.INVALID_FRAME, "later gap rejected")
	context.state(0, JSON.stringify(endpoint.status()).to_utf8_buffer())


# Value: protects=idle status capacity and clocks; fails_when=ACK traffic postpones carrier or refusal commits it; why_new=pending retry never sends ACKed input; seam=none
func _status_nudge(context: RefCounted) -> void:
	# First-carrier clocks include the largest accepted integer, before any nudge timestamp exists.
	for now_us: int in [200010, 9223372036854775806, 9223372036854775807]:
		var boundary_options: I.Options = I.Options.new()
		boundary_options.max_outbox = 1
		var boundary_sink: Sink = Sink.new()
		var boundary_endpoint: E = _ready(boundary_sink, boundary_options)
		var boundary_statuses: Array[T.Status] = _statuses()
		boundary_endpoint.submit(0, PackedByteArray([7]), boundary_statuses, 9)
		boundary_endpoint.drain_outbox()
		boundary_endpoint.receive(_ack_packet(0), _id(2), 10)
		boundary_endpoint.drain_transitions()
		boundary_statuses[1].last_frame = 0
		boundary_endpoint.receive(_encode(_input(0, PackedByteArray([3]))), _id(2), 11)
		var boundary_before: Dictionary = boundary_endpoint.status()
		context.equal(boundary_endpoint.poll(now_us, null, boundary_statuses, true), I.Code.BACKPRESSURE, "wide-clock carrier respects queued ACK")
		context.equal(boundary_endpoint.status(), boundary_before, "wide-clock refusal preserves state and sentinel")
		context.equal(boundary_endpoint.drain_outbox().size(), 1, "wide-clock refusal preserves owned ACK")
		context.equal(boundary_endpoint.poll(now_us, null, boundary_statuses, true), I.Code.OK, "first carrier accepts wide clock")
		var boundary_packets: Array[PackedByteArray] = boundary_endpoint.drain_outbox()
		context.equal(boundary_packets.size(), 1, "first carrier publishes at wide clock")
		if boundary_packets.size() == 1:
			var boundary_message: T.Message = _decoded(boundary_packets[0])
			context.equal(boundary_message.data, PackedByteArray([7]), "wide-clock carrier preserves original sample")
			context.equal(boundary_message.statuses[1].last_frame, 0, "wide-clock carrier publishes fresh receipt")
		context.equal(boundary_endpoint.status().last_nudge_us, now_us, "wide-clock carrier commits nudge timestamp")
		context.equal(boundary_endpoint.poll(now_us, null, boundary_statuses, true), I.Code.OK, "same-clock repeated carrier poll accepted")
		context.equal(boundary_endpoint.drain_outbox().size(), 0, "same clock cannot publish a second carrier")
	var options: I.Options = I.Options.new()
	options.max_pending_frames = 1
	options.max_received_frames = 1
	options.max_outbox = 1
	options.max_buffer_bytes = 3
	var sink: Sink = Sink.new()
	var endpoint: E = _ready(sink, options)
	var statuses: Array[T.Status] = _statuses()
	var sample: PackedByteArray = PackedByteArray([7])
	context.equal(endpoint.submit(0, sample, statuses, 9), I.Code.OK, "minimum retained geometry includes acknowledged frame")
	sample[0] = 99
	endpoint.drain_outbox()
	context.equal(endpoint.receive(_ack_packet(0), _id(2), 10), I.Code.OK, "ACK frees ordinary pending queue")
	context.equal(endpoint.status().pending_frames, 0, "nudge requires no pending output")
	context.equal(endpoint.receive(_ack_packet(0), _id(2), 100000), I.Code.OK, "standalone ACK churn")
	context.equal(endpoint.poll(200009, null, statuses, true), I.Code.OK, "last input send equality excluded")
	context.equal(endpoint.drain_outbox().size(), 0, "strict nudge boundary")
	context.equal(endpoint.receive(_encode(_input(0, PackedByteArray([3]))), _id(2), 200009), I.Code.OK, "incoming input fills outbox with ACK")
	var before: Dictionary = endpoint.status()
	statuses[1].last_frame = 0
	context.equal(endpoint.poll(200010, null, statuses, true), I.Code.BACKPRESSURE, "carrier respects full outbox")
	context.equal(endpoint.status(), before, "failed carrier preserves bytes statuses and clocks")
	context.equal(endpoint.drain_outbox().size(), 1, "caller owns queued ACK")
	context.equal(endpoint.poll(200010, null, statuses, true), I.Code.OK, "same clock retry after pressure")
	var packets: Array[PackedByteArray] = endpoint.drain_outbox()
	context.equal(packets.size(), 1, "one carrier at minimum capacity")
	if packets.size() != 1:
		return
	var message: T.Message = _decoded(packets[0])
	context.equal(message.data, PackedByteArray([7]), "carrier retains immutable submitted bytes")
	context.equal(message.start_frame, 0, "carrier repeats ACKed frame")
	context.equal(message.frame_count, 1, "carrier has bounded single frame")
	context.equal(message.ack_frame, 0, "carrier includes actual remote ACK floor")
	context.equal(message.statuses[1].last_frame, 0, "carrier refreshes receipt gossip")
	context.equal(endpoint.poll(200011, null, statuses, null), I.Code.INVALID_ARGUMENT, "nudge policy rejects hostile caller")
	context.equal(endpoint.submit(1, PackedByteArray([8]), statuses, 200012), I.Code.OK, "new traffic takes over carrier")
	endpoint.drain_outbox()
	context.equal(endpoint.receive(_ack_packet(1), _id(2), 200013), I.Code.OK, "new traffic fully acknowledged")
	context.equal(endpoint.poll(400012, null, statuses, true), I.Code.OK, "new input resets last input clock")
	context.equal(endpoint.drain_outbox().size(), 0, "input send equality suppresses carrier")
	context.equal(endpoint.poll(400013, null, statuses), I.Code.OK, "default standalone policy remains idle")
	context.equal(endpoint.drain_outbox().size(), 0, "policy disabled does not publish carrier")
	context.equal(endpoint.poll(400013, null, statuses, true), I.Code.OK, "explicit policy resumes gossip")
	packets = endpoint.drain_outbox()
	context.equal(packets.size(), 1, "repeat nudge survives ACK drainage")
	if packets.size() == 1:
		context.equal(_decoded(packets[0]).data, PackedByteArray([8]), "latest ACKed bytes replace prior carrier")


# Value: protects=drained minimum transition capacity permits gossip; fails_when=idle retry and carrier need two slots; why_new=carrier test uses default traces; seam=none
func _status_nudge_transitions(context: RefCounted) -> void:
	var options: I.Options = I.Options.new()
	options.max_transitions = 1
	options.max_outbox = 1
	var endpoint: E = _ready(Sink.new(), options)
	var statuses: Array[T.Status] = _statuses()
	context.equal(endpoint.status().state, "running", "minimum transition capacity accepted")
	context.equal(endpoint.submit(0, PackedByteArray([7]), statuses, 9), I.Code.OK, "submit original carrier")
	endpoint.drain_outbox()
	endpoint.drain_transitions()
	context.equal(endpoint.receive(_ack_packet(0), _id(2), 10), I.Code.OK, "acknowledge original carrier")
	endpoint.drain_transitions()
	statuses[1].last_frame = 0
	context.equal(endpoint.poll(200010, null, statuses, true), I.Code.OK, "simultaneous idle retry and nudge fit minimum trace capacity")
	var packets: Array[PackedByteArray] = endpoint.drain_outbox()
	context.equal(packets.size(), 1, "drained endpoint publishes a carrier")
	if packets.size() == 1:
		context.equal(_decoded(packets[0]).data, PackedByteArray([7]), "original acknowledged bytes survive collision")
		context.equal(_decoded(packets[0]).statuses[1].last_frame, 0, "carrier publishes current gossip")
	context.equal(endpoint.drain_transitions(), [{"action": "status_nudge", "disposition": "sent", "last_received_frame": -1,
		"last_acked_frame": 0, "pending_frames": 0}], "one complete nudge transition")
	context.equal(endpoint.status().last_input_progress_us, 200010, "idle retry clock still advances")
	context.equal(endpoint.status().last_nudge_us, 200010, "nudge clock commits")
	context.equal(endpoint.status().last_input_send_us, 9, "nudge preserves ordinary input send clock")
	context.equal(endpoint.poll(400010, null, statuses, true), I.Code.OK, "strict timer equality with minimum traces")
	context.equal(endpoint.drain_outbox().size(), 0, "no carrier at equality")
	context.equal(endpoint.drain_transitions().size(), 0, "no trace at equality")
	context.equal(endpoint.receive(_ack_packet(0), _id(2), 400010), I.Code.OK, "queue one unrelated transition")
	var before: Dictionary = endpoint.status()
	statuses[1].last_frame = 1
	context.equal(endpoint.poll(400011, null, statuses, true), I.Code.BACKPRESSURE, "undrained transition still bounds publication")
	context.equal(endpoint.status(), before, "trace pressure preserves gossip and all clocks")
	context.equal(endpoint.drain_outbox().size(), 0, "trace pressure publishes no carrier")
	context.equal(endpoint.drain_transitions().size(), 1, "caller drains existing ACK trace")
	context.equal(endpoint.poll(400011, null, statuses, true), I.Code.OK, "same-clock retry recovers after trace drain")
	packets = endpoint.drain_outbox()
	context.equal(packets.size(), 1, "repeated simultaneous deadlines continue gossip")
	if packets.size() == 1:
		context.equal(_decoded(packets[0]).statuses[1].last_frame, 1, "recovered carrier publishes advanced gossip")
	context.equal(endpoint.drain_transitions().size(), 1, "repeated nudge remains one transition")
	context.equal(endpoint.poll(600012, null, statuses), I.Code.OK, "ordinary idle retry remains available")
	context.equal(endpoint.drain_outbox().size(), 0, "disabled nudge sends no input")
	context.equal(endpoint.drain_transitions(), [{"action": "retry", "disposition": "empty", "last_received_frame": -1,
		"last_acked_frame": 0, "pending_frames": 0}], "ordinary idle retry observation is unchanged")
	context.equal(endpoint.submit(1, PackedByteArray([8]), statuses, 600013), I.Code.OK, "pending traffic replaces nudge")
	endpoint.drain_outbox()
	endpoint.drain_transitions()
	context.equal(endpoint.poll(800013, null, statuses, true), I.Code.OK, "pending retry remains available with nudge policy")
	packets = endpoint.drain_outbox()
	context.equal(packets.size(), 1, "ordinary pending retry publishes one packet")
	if packets.size() == 1:
		context.equal(_decoded(packets[0]).start_frame, 1, "pending retry uses unacknowledged input")
	context.equal(endpoint.drain_transitions(), [{"action": "retry", "disposition": "sent", "last_received_frame": -1,
		"last_acked_frame": 0, "pending_frames": 1}], "ordinary pending retry observation is unchanged")
	context.state(0, JSON.stringify(endpoint.status()).to_utf8_buffer())
