class_name FortressHandshake
extends RefCounted

const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const H = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
const Validation = preload("res://addons/fortress_rollback/protocol/protocol_validation.gd")
const Agreement = preload("res://addons/fortress_rollback/protocol/handshake_agreement.gd")

var _local: T.Message = null
var _remote: PackedByteArray = PackedByteArray()
var _limits: T.Limits = null
var _options: H.Options = null
var _state: Dictionary = {}
var _outbox: Array[PackedByteArray] = []
var _events: Array[Dictionary] = []
var _transitions: Array[Dictionary] = []


## Variant parameters admit hostile callers without engine conversion errors.
func configure(local: Variant, remote_sender: Variant, options: Variant) -> int:
	if _local != null:
		return H.Code.WRONG_STATE
	if not local is T.Message or not remote_sender is PackedByteArray or not options is H.Options or not H.valid_options(options):
		return H.Code.INVALID_ARGUMENT
	if not Validation.config(local.config) or not _valid_local(local, remote_sender):
		return H.Code.INVALID_ARGUMENT
	var limits: T.Limits = T.Limits.new()
	limits.player_count = local.config.player_count
	limits.input_width = local.config.input_width
	limits.max_packet_bytes = options.max_packet_bytes
	var encoded: T.Result = Codec.encode(local, limits)
	if encoded.code != T.Code.OK:
		return H.Code.INVALID_ARGUMENT
	_local = Codec.decode(encoded.bytes, limits).message
	_remote = remote_sender.duplicate()
	_limits = limits
	_options = H.Options.new()
	for field: String in ["roundtrips", "retry_interval_us", "timeout_us", "max_packet_bytes", "max_pending_tokens", "max_consumed_tokens",
		"max_outbox", "max_events", "max_transitions"]:
		_options.set(field, options.get(field))
	_state = {"state": "initializing", "remaining": options.roundtrips, "requests_sent": 0, "pending": {}, "consumed": {}, "remote_connection": "", "mismatch": {},
		"timeout_sent": false, "now_us": -1, "start_us": 0, "last_send_us": 0, "remote_packet_bytes": options.max_packet_bytes}
	return H.Code.OK


func begin(now_us: Variant, token: Variant) -> int:
	if _local == null or _state.state != "initializing":
		return H.Code.WRONG_STATE
	if not _valid_time(now_us):
		return H.Code.INVALID_ARGUMENT
	var plan: Dictionary = _plan(now_us)
	plan.state.state = "synchronizing"
	plan.state.start_us = now_us
	_trace(plan, "begin_synchronization")
	var code: int = _send(plan, token)
	return _commit(plan) if code == H.Code.OK else code


func poll(now_us: Variant, next_token: Variant = null) -> int:
	if _local == null:
		return H.Code.WRONG_STATE
	if not _valid_time(now_us):
		return H.Code.INVALID_ARGUMENT
	var plan: Dictionary = _plan(now_us)
	if plan.state.state == "synchronizing" and plan.state.mismatch.is_empty():
		var elapsed: int = now_us - plan.state.start_us
		if _options.timeout_us >= 0 and elapsed > _options.timeout_us and not plan.state.timeout_sent:
			plan.state.timeout_sent = true
			plan.events.append({"kind": "sync_timeout", "elapsed_ms": elapsed / 1000})
			_trace(plan, "report_timeout", "", "", elapsed / 1000)
		if now_us - plan.state.last_send_us > _options.retry_interval_us:
			var code: int = _send(plan, next_token)
			if code != H.Code.OK:
				if code == H.Code.BACKPRESSURE:
					_report_pressured_timeout(now_us, plan)
				return code
	var code: int = _commit(plan)
	if code == H.Code.BACKPRESSURE:
		_report_pressured_timeout(now_us, plan)
	return code


func _report_pressured_timeout(now_us: int, refused: Dictionary) -> void:
	if _state.timeout_sent or not refused.state.timeout_sent:
		return
	# Refused retry state stays atomic; its independent deadline diagnostic survives.
	var timeout: Dictionary = _plan(now_us)
	timeout.state.timeout_sent = true
	var elapsed: int = now_us - timeout.state.start_us
	timeout.events.append({"kind": "sync_timeout", "elapsed_ms": elapsed / 1000})
	_trace(timeout, "report_timeout", "", "", elapsed / 1000)
	_commit(timeout)


func receive(packet: Variant, attributed_sender: Variant, now_us: Variant, next_token: Variant = null) -> int:
	var input_code: int = _receive_input(attributed_sender, now_us)
	if input_code != H.Code.OK:
		return input_code
	var result: T.Result = Codec.decode(packet, _limits)
	if result.code != T.Code.OK:
		return H.Code.INVALID_PACKET
	var message: T.Message = result.message
	var identity_code: int = _received_identity(message)
	if identity_code != H.Code.OK:
		return identity_code
	var plan: Dictionary = _plan(now_us)
	if message.kind == T.Kind.SYNC_REQUEST:
		var reply: PackedByteArray = _packet(T.Kind.SYNC_REPLY, message.token)
		plan.outbox.append(reply)
		plan.state.last_send_us = plan.state.now_us
		var disposition: String = "answered_only"
		if plan.state.state == "synchronizing":
			disposition = "already_incompatible" if not plan.state.mismatch.is_empty() else "observed"
			_observe(plan, message)
			if disposition == "observed" and not plan.state.mismatch.is_empty():
				disposition = "incompatible"
		_trace(plan, "handle_request", message.token.hex_encode(), disposition)
	else:
		var code: int = _reply(plan, message, next_token)
		if code != H.Code.OK:
			return code
	return _commit(plan)


func status() -> Dictionary:
	return _state.duplicate(true)


## Receive limit the remote advertised, or the local limit before a reply is accepted.
func remote_packet_bytes() -> int:
	return _state.remote_packet_bytes


func drain_outbox() -> Array[PackedByteArray]:
	var result: Array[PackedByteArray] = []
	for packet: PackedByteArray in _outbox:
		result.append(packet.duplicate())
	_outbox.clear()
	return result


func drain_events() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event: Dictionary in _events:
		result.append(event.duplicate(true))
	_events.clear()
	return result


func drain_transitions() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for transition: Dictionary in _transitions:
		result.append(transition.duplicate(true))
	_transitions.clear()
	return result


func _reply(plan: Dictionary, message: T.Message, next_token: Variant) -> int:
	var token: String = message.token.hex_encode()
	var disposition: String = "not_synchronizing"
	if plan.state.state == "synchronizing":
		if not plan.state.mismatch.is_empty():
			disposition = "already_incompatible"
		elif not plan.state.pending.has(token):
			disposition = "duplicate" if plan.state.consumed.has(token) else "unknown"
		else:
			if plan.state.consumed.size() >= _options.max_consumed_tokens:
				return H.Code.BACKPRESSURE
			plan.state.pending.erase(token)
			plan.state.consumed[token] = true
			_observe(plan, message)
			disposition = "incompatible"
			if plan.state.mismatch.is_empty():
				disposition = "accepted"
				if plan.state.remote_connection.is_empty():
					plan.state.remote_connection = message.connection_id.hex_encode()
				plan.state.remote_packet_bytes = message.max_packet_bytes
				plan.state.remaining -= 1
				if plan.state.remaining == 0:
					plan.state.state = "running"
					plan.events.append({"kind": "synchronized"})
				else:
					plan.events.append({"kind": "synchronizing", "total": _options.roundtrips, "count": _options.roundtrips - plan.state.remaining,
						"total_requests_sent": plan.state.requests_sent, "elapsed_ms": (plan.state.now_us - plan.state.start_us) / 1000})
	_trace(plan, "handle_reply", token, disposition)
	if disposition == "accepted" and plan.state.remaining > 0:
		return _send(plan, next_token)
	return H.Code.OK


func _observe(plan: Dictionary, message: T.Message) -> void:
	if not plan.state.mismatch.is_empty():
		return
	plan.state.mismatch = Agreement.mismatch(_local, message)
	if not plan.state.mismatch.is_empty():
		plan.events.append({"kind": "incompatible", "reason": plan.state.mismatch.duplicate(true)})


func _send(plan: Dictionary, token: Variant) -> int:
	if not token is PackedByteArray or token.size() != 16:
		return H.Code.INVALID_ARGUMENT
	var key: String = token.hex_encode()
	if plan.state.consumed.has(key):
		return H.Code.TOKEN_REUSED
	var disposition: String = "collision" if plan.state.pending.has(key) else "fresh"
	if disposition == "fresh" and plan.state.pending.size() >= _options.max_pending_tokens:
		return H.Code.BACKPRESSURE
	plan.state.pending[key] = true
	plan.state.requests_sent = mini(plan.state.requests_sent + 1, 4294967295)
	plan.state.last_send_us = plan.state.now_us
	plan.outbox.append(_packet(T.Kind.SYNC_REQUEST, token))
	_trace(plan, "send_request", key, disposition)
	return H.Code.OK


func _packet(kind: int, token: PackedByteArray) -> PackedByteArray:
	var message: T.Message = T.Message.new()
	message.kind = kind
	message.session_id = _local.session_id
	message.sender_id = _local.sender_id
	message.connection_id = _local.connection_id
	message.token = token
	message.min_compat_version = _local.min_compat_version
	message.features = _local.features
	message.config = _local.config
	message.config_digest = _local.config_digest
	message.max_packet_bytes = _options.max_packet_bytes
	return Codec.encode(message, _limits).bytes


func _plan(now_us: int) -> Dictionary:
	var state: Dictionary = _state.duplicate(true)
	state.now_us = now_us
	return {"state": state, "outbox": [], "events": [], "transitions": []}


func _trace(plan: Dictionary, action: String, token: String = "", disposition: String = "", elapsed: int = -1) -> void:
	plan.transitions.append({"action": action, "token": token, "disposition": disposition, "state": plan.state.state, "remaining": plan.state.remaining,
		"outstanding_request_count": plan.state.pending.size(), "remote_connection": plan.state.remote_connection, "timeout_sent": plan.state.timeout_sent,
		"mismatch": plan.state.mismatch.duplicate(true), "elapsed_ms": elapsed})


func _commit(plan: Dictionary) -> int:
	if _outbox.size() + plan.outbox.size() > _options.max_outbox or _events.size() + plan.events.size() > _options.max_events:
		return H.Code.BACKPRESSURE
	if _transitions.size() + plan.transitions.size() > _options.max_transitions:
		return H.Code.BACKPRESSURE
	_state = plan.state
	_outbox.append_array(plan.outbox)
	_events.append_array(plan.events)
	_transitions.append_array(plan.transitions)
	return H.Code.OK


func _valid_time(now_us: Variant) -> bool:
	return typeof(now_us) == TYPE_INT and now_us >= 0 and now_us >= _state.now_us


func _nonzero(bytes: PackedByteArray, width: int) -> bool:
	if bytes.size() != width:
		return false
	for byte: int in bytes:
		if byte != 0:
			return true
	return false


func _valid_local(local: T.Message, remote_sender: PackedByteArray) -> bool:
	if local.kind != T.Kind.SYNC_REQUEST or not _nonzero(remote_sender, 8) or not _nonzero(local.sender_id, 8):
		return false
	if not _nonzero(local.session_id, 16) or not _nonzero(local.connection_id, 8) or local.sender_id == remote_sender:
		return false
	if local.min_compat_version != 1 or local.features != 0 or local.config == null:
		return false
	var identities: Dictionary = {}
	for identity: PackedByteArray in local.config.roster:
		if not _nonzero(identity, 8):
			return false
		identities[identity.hex_encode()] = true
	return identities.has(local.sender_id.hex_encode()) and identities.has(remote_sender.hex_encode())


func _received_identity(message: T.Message) -> int:
	if message.session_id != _local.session_id or message.sender_id != _remote:
		return H.Code.WRONG_SOURCE
	if not _nonzero(message.connection_id, 8) or (not _state.remote_connection.is_empty() and message.connection_id.hex_encode() != _state.remote_connection):
		return H.Code.WRONG_CONNECTION
	if message.kind not in [T.Kind.SYNC_REQUEST, T.Kind.SYNC_REPLY]:
		return H.Code.UNSUPPORTED_KIND
	if _state.state == "initializing":
		return H.Code.WRONG_STATE
	return H.Code.OK


func _receive_input(attributed_sender: Variant, now_us: Variant) -> int:
	if _local == null:
		return H.Code.WRONG_STATE
	if not _valid_time(now_us) or not attributed_sender is PackedByteArray:
		return H.Code.INVALID_ARGUMENT
	return H.Code.OK if attributed_sender == _remote else H.Code.WRONG_SOURCE
