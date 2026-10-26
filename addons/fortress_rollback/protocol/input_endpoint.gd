class_name FortressInputEndpoint
extends RefCounted

# gdlint: disable=max-returns

const L = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")
const Lifecycle = preload("res://addons/fortress_rollback/protocol/endpoint_lifecycle.gd")

const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const H = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const Handshake = preload("res://addons/fortress_rollback/protocol/handshake.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
const V = preload("res://addons/fortress_rollback/protocol/protocol_validation.gd")

var _status_nudge_interval_us: int = 200000
var _lifecycle: L.Options = null
var _fatal_event: Dictionary = {}
var _handshake: Handshake = null
var _local: T.Message = null
var _remote: PackedByteArray = PackedByteArray()
var _local_players: PackedByteArray = PackedByteArray()
var _remote_players: PackedByteArray = PackedByteArray()
var _options: I.Options = null
var _limits: T.Limits = null
var _accept_input: Callable = Callable()
var _busy: bool = false
var _state: Dictionary = {}
var _outbox: Array[PackedByteArray] = []
var _events: Array[Dictionary] = []
var _transitions: Array[Dictionary] = []


## Variant ingress prevents implicit conversion of hostile callers.
func configure(local: Variant, remote_sender: Variant, handshake_options: Variant, options: Variant, accept_input: Variant, lifecycle_options: Variant = null) -> int:
	if _busy:
		return I.Code.BUSY
	if _handshake != null:
		return I.Code.WRONG_STATE
	if not local is T.Message or not V.config(local.config) or not remote_sender is PackedByteArray:
		return I.Code.INVALID_ARGUMENT
	if not handshake_options is H.Options or not H.valid_options(handshake_options) or not options is I.Options or not I.valid_options(options):
		return I.Code.INVALID_ARGUMENT
	if not accept_input is Callable or not accept_input.is_valid():
		return I.Code.INVALID_ARGUMENT
	if lifecycle_options != null and not L.valid_options(lifecycle_options):
		return I.Code.INVALID_ARGUMENT
	var local_players: PackedByteArray = PackedByteArray()
	var remote_players: PackedByteArray = PackedByteArray()
	for slot: int in range(local.config.player_count):
		if local.config.roster[slot] == local.sender_id:
			local_players.append(slot)
		elif local.config.roster[slot] == remote_sender:
			remote_players.append(slot)
	if local_players.is_empty() or remote_players.is_empty():
		return I.Code.INVALID_ARGUMENT
	var local_width: int = local_players.size() * local.config.input_width
	var remote_width: int = remote_players.size() * local.config.input_width
	var overhead: int = 60 + maxi(local_players.size(), remote_players.size()) + 7 * local.config.player_count
	if handshake_options.max_packet_bytes < overhead + maxi(local_width, remote_width):
		return I.Code.INVALID_ARGUMENT
	if (options.max_pending_frames + 1) * local_width + options.max_received_frames * remote_width > options.max_buffer_bytes:
		return I.Code.INVALID_ARGUMENT
	var handshake: Handshake = Handshake.new()
	var code: int = handshake.configure(local, remote_sender, handshake_options)
	if code != I.Code.OK:
		return code
	_limits = T.Limits.new()
	_limits.max_packet_bytes = handshake_options.max_packet_bytes
	_limits.max_input_frames = I.MAX_INPUT_FRAMES
	_limits.player_count = local.config.player_count
	_limits.input_width = local.config.input_width
	_local = Codec.decode(Codec.encode(local, _limits).bytes, _limits).message
	_remote = remote_sender.duplicate()
	_local_players = local_players
	_remote_players = remote_players
	_options = I.Options.new()
	for field: String in ["retry_interval_us", "max_pending_frames", "max_received_frames", "max_input_frames", "max_outbox", "max_events",
		"max_transitions", "max_buffer_bytes"]:
		_options.set(field, options.get(field))
	_lifecycle = L.copy_options(lifecycle_options) if lifecycle_options != null and lifecycle_options.enabled else null
	_status_nudge_interval_us = lifecycle_options.keepalive_interval_us if lifecycle_options != null else L.Options.new().keepalive_interval_us
	_handshake = handshake
	_accept_input = accept_input
	var statuses: Array[Dictionary] = []
	for slot: int in range(_limits.player_count):
		statuses.append({"disconnected": false, "last_frame": -1, "epoch": 0})
	_state = {"now_us": -1, "last_submitted_frame": -1, "last_sent_frame": -1, "last_received_frame": -1, "last_acked_frame": -1,
		"last_input_progress_us": -1, "last_input_send_us": -1, "last_nudge_us": -1, "last_acked_input": PackedByteArray(),
		"pending": {}, "received": {}, "peer_statuses": statuses, "connect_statuses": statuses.duplicate(true), "terminated": false}
	if _lifecycle != null:
		_state.merge(Lifecycle.initial(_lifecycle))
	return I.Code.OK


func begin(now_us: Variant, token: Variant) -> int:
	var code: int = _gate(now_us)
	if code != I.Code.OK:
		return code
	code = _handshake.begin(now_us, token)
	if code == I.Code.OK:
		_state.now_us = now_us
		_state.last_input_progress_us = now_us
		if _lifecycle != null:
			Lifecycle.start(_state, now_us)
	return code


func poll(now_us: Variant, next_token: Variant = null, statuses: Variant = [], status_nudge: Variant = false) -> int:
	var code: int = _gate(now_us)
	if code != I.Code.OK:
		return code
	if not statuses is Array or typeof(status_nudge) != TYPE_BOOL:
		return I.Code.INVALID_ARGUMENT
	if not statuses.is_empty():
		code = _status_code(statuses)
		if code != I.Code.OK:
			return code
	if _handshake.status().state != "running":
		code = _handshake.poll(now_us, next_token)
		if code == I.Code.OK:
			_state.now_us = now_us
			if _lifecycle != null:
				_state.last_send_us = maxi(_state.last_send_us, _handshake.status().last_send_us)
		return code
	var plan: Dictionary = _plan(now_us)
	if not statuses.is_empty():
		_merge_statuses(plan, statuses, "connect_statuses")
	var is_nudge_due: bool = status_nudge and plan.state.pending.is_empty() and not plan.state.last_acked_input.is_empty() \
		and now_us - plan.state.last_input_send_us > _status_nudge_interval_us \
		and (plan.state.last_nudge_us == -1 or now_us - plan.state.last_nudge_us > _status_nudge_interval_us)
	if now_us - plan.state.last_input_progress_us > _options.retry_interval_us:
		if not plan.state.pending.is_empty():
			_send_pending(plan)
		plan.state.last_input_progress_us = now_us
		if not is_nudge_due:
			_trace(plan, "retry", "sent" if not plan.outbox.is_empty() else "empty")
	if is_nudge_due:
		_send_input(plan, plan.state.last_acked_frame, [plan.state.last_acked_input])
		plan.state.last_nudge_us = now_us
		_trace(plan, "status_nudge", "sent")
	if _lifecycle != null:
		if not plan.outbox.is_empty():
			plan.state.last_send_us = now_us
		Lifecycle.poll(plan, _lifecycle, _packet, _encode, plan.outbox.is_empty() or _outbox.size() + plan.outbox.size() < _options.max_outbox)
	return _commit(plan)


func receive(packet: Variant, attributed_sender: Variant, now_us: Variant, next_token: Variant = null) -> int:
	var code: int = _gate(now_us)
	if code != I.Code.OK:
		return code
	if not attributed_sender is PackedByteArray:
		return I.Code.INVALID_ARGUMENT
	if attributed_sender != _remote:
		return I.Code.WRONG_SOURCE
	var result: T.Result = Codec.decode(packet, _limits)
	if result.code != T.Code.OK:
		return I.Code.INVALID_PACKET
	var message: T.Message = result.message
	if message.session_id != _local.session_id or message.sender_id != _remote:
		return I.Code.WRONG_SOURCE
	if message.kind in [T.Kind.SYNC_REQUEST, T.Kind.SYNC_REPLY]:
		code = _handshake.receive(packet, attributed_sender, now_us, next_token)
		if code == I.Code.OK:
			_state.now_us = now_us
			if _lifecycle != null:
				var sync_plan: Dictionary = _plan(now_us)
				sync_plan.state.last_send_us = maxi(sync_plan.state.last_send_us, _handshake.status().last_send_us)
				Lifecycle.received(sync_plan)
				return _commit(sync_plan)
		return code
	var handshake_status: Dictionary = _handshake.status()
	var connection: String = message.connection_id.hex_encode()
	if connection == "0000000000000000" or (not handshake_status.remote_connection.is_empty() and connection != handshake_status.remote_connection):
		return I.Code.WRONG_CONNECTION
	if message.kind == T.Kind.INPUT:
		if message.players != _remote_players:
			return I.Code.INVALID_PACKET
		code = _status_code(message.statuses)
		if code != I.Code.OK:
			return code
	elif message.kind != T.Kind.INPUT_ACK and _lifecycle == null:
		return I.Code.UNSUPPORTED_KIND
	if handshake_status.state != "running":
		# Unordered final replies can arrive after a synchronized sender's gameplay.
		# Validate identity and shape, then discard; normal input retries repair it.
		if handshake_status.state == "synchronizing" and handshake_status.mismatch.is_empty():
			return I.Code.OK
		return I.Code.WRONG_STATE
	var plan: Dictionary = _plan(now_us)
	if message.kind not in [T.Kind.INPUT, T.Kind.INPUT_ACK]:
		if _lifecycle == null:
			return I.Code.UNSUPPORTED_KIND
		code = Lifecycle.receive_control(plan, message, _packet, _encode)
		return _commit(plan) if code == I.Code.OK else code
	if message.kind == T.Kind.INPUT_ACK:
		if _lifecycle != null:
			Lifecycle.received(plan)
		_ack(plan, message.ack_frame)
		_trace(plan, "receive_ack", "applied" if plan.state.last_acked_frame != _state.last_acked_frame else "ignored")
		return _commit(plan)
	return _receive_frames(plan, message)


func submit(frame: Variant, data: Variant, statuses: Variant, now_us: Variant) -> int:
	var code: int = _gate(now_us)
	if code != I.Code.OK:
		return code
	if _handshake.status().state != "running":
		return I.Code.WRONG_STATE
	if typeof(frame) != TYPE_INT or not V.frame(frame, false):
		return I.Code.INVALID_FRAME
	if not data is PackedByteArray or data.size() != _local_players.size() * _limits.input_width:
		return I.Code.INVALID_ARGUMENT
	code = _status_code(statuses)
	if code != I.Code.OK:
		return code
	if frame <= _state.last_submitted_frame:
		if not _state.pending.has(frame):
			return I.Code.INVALID_FRAME
		if _state.pending[frame] != data:
			return I.Code.CONFLICT
		var duplicate: Dictionary = _plan(now_us)
		_merge_statuses(duplicate, statuses, "connect_statuses")
		return _commit(duplicate)
	if frame != _state.last_submitted_frame + 1 and not (_state.last_submitted_frame == -1 and frame == _local.config.input_delay):
		return I.Code.INVALID_FRAME
	if _state.pending.size() >= _options.max_pending_frames:
		return I.Code.BACKPRESSURE
	var plan: Dictionary = _plan(now_us)
	plan.state.pending[frame] = data.duplicate()
	plan.state.last_submitted_frame = frame
	if _lifecycle != null:
		Lifecycle.sample(plan.state, frame, _lifecycle)
	_merge_statuses(plan, statuses, "connect_statuses")
	_send_pending(plan)
	_trace(plan, "submit", "sent")
	return _commit(plan)


## Schedules consecutive new frames and sends them in one input packet, as upstream flushes a delay gap-fill once.
## Frames after sampled_through repeat earlier input, so like upstream they add no time-sync sample.
func submit_frames(start_frame: Variant, inputs: Variant, statuses: Variant, now_us: Variant, sampled_through: Variant) -> int:
	var code: int = _gate(now_us)
	if code != I.Code.OK:
		return code
	if _handshake.status().state != "running":
		return I.Code.WRONG_STATE
	if typeof(start_frame) != TYPE_INT or typeof(sampled_through) != TYPE_INT or not inputs is Array or inputs.is_empty():
		return I.Code.INVALID_ARGUMENT
	if start_frame != _state.last_submitted_frame + 1 and not (_state.last_submitted_frame == -1 and start_frame == _local.config.input_delay):
		return I.Code.INVALID_FRAME
	code = _status_code(statuses)
	if code != I.Code.OK:
		return code
	if _state.pending.size() + inputs.size() > _options.max_pending_frames:
		return I.Code.BACKPRESSURE
	var plan: Dictionary = _plan(now_us)
	for offset: int in range(inputs.size()):
		var frame: int = start_frame + offset
		var data: Variant = inputs[offset]
		if not V.frame(frame, false):
			return I.Code.INVALID_FRAME
		if not data is PackedByteArray or data.size() != _local_players.size() * _limits.input_width:
			return I.Code.INVALID_ARGUMENT
		plan.state.pending[frame] = data.duplicate()
		plan.state.last_submitted_frame = frame
		if _lifecycle != null and frame <= sampled_through:
			Lifecycle.sample(plan.state, frame, _lifecycle)
	_merge_statuses(plan, statuses, "connect_statuses")
	_send_pending(plan)
	_trace(plan, "submit", "sent")
	return _commit(plan)


## Whether the endpoint can accept a batch of frames right now. The checks mirror the
## submission path, so a caller can refuse a change before it changes any state.
## A batch carries at least one frame, and its first frame continues the submitted run.
func can_submit_frames(start_frame: int, count: int) -> int:
	if _handshake == null or _handshake.status().state != "running":
		return I.Code.WRONG_STATE
	if _state.terminated:
		return I.Code.TERMINATED
	if count < 1:
		return I.Code.INVALID_ARGUMENT
	if start_frame != _state.last_submitted_frame + 1 and not (_state.last_submitted_frame == -1 and start_frame == _local.config.input_delay):
		return I.Code.INVALID_FRAME
	if _state.pending.size() + count > _options.max_pending_frames:
		return I.Code.BACKPRESSURE
	# One batch sends one packet and records one transition.
	if _outbox.size() + 1 > _options.max_outbox:
		return I.Code.BACKPRESSURE
	if _transitions.size() + 1 > _options.max_transitions:
		return I.Code.BACKPRESSURE
	return I.Code.OK


func status() -> Dictionary:
	if _handshake == null:
		return {}
	var result: Dictionary = _state.duplicate(true)
	var handshake: Dictionary = _handshake.status()
	result.state = "terminated" if _state.terminated else handshake.state
	result.remote_connection = handshake.remote_connection
	result.handshake = handshake
	result.local_players = _local_players.duplicate()
	result.remote_players = _remote_players.duplicate()
	result.pending_frames = _state.pending.size()
	return result


func _last_submitted_frame() -> int:
	return _state.last_submitted_frame


func _average_frame_advantage() -> int:
	return _state.average_frame_advantage


func _round_trip_time_ms() -> int:
	return _state.round_trip_time_ms


func _is_running() -> bool:
	return _handshake != null and not _state.terminated and _handshake.status().state == "running"


func _has_failed() -> bool:
	var handshake: Dictionary = _handshake.status()
	return _state.terminated or handshake.state in ["terminated", "failed"] or not handshake.mismatch.is_empty()


func _peer_received_frame(slot: int) -> int:
	return _state.peer_statuses[slot].last_frame


func drain_outbox() -> Array[PackedByteArray]:
	var result: Array[PackedByteArray] = []
	if _busy or _handshake == null:
		return result
	result = _handshake.drain_outbox()
	for packet: PackedByteArray in _outbox:
		result.append(packet.duplicate())
	_outbox.clear()
	return result


func drain_events() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if _busy or _handshake == null:
		return result
	result = _handshake.drain_events()
	for event: Dictionary in _events:
		result.append(event.duplicate(true))
	_events.clear()
	if not _fatal_event.is_empty():
		result.append(_fatal_event.duplicate(true))
		_fatal_event.clear()
	return result


func drain_transitions() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if _busy or _handshake == null:
		return result
	result = _handshake.drain_transitions()
	for transition: Dictionary in _transitions:
		result.append(transition.duplicate(true))
	_transitions.clear()
	return result


func _gate(now_us: Variant) -> int:
	if _busy:
		return I.Code.BUSY
	if _handshake == null:
		return I.Code.WRONG_STATE
	if _state.terminated:
		return I.Code.TERMINATED
	if typeof(now_us) != TYPE_INT or now_us < 0 or now_us < _state.now_us:
		return I.Code.INVALID_ARGUMENT
	return I.Code.OK


func _status_code(statuses: Variant) -> int:
	if not statuses is Array or statuses.size() != _limits.player_count:
		return I.Code.INVALID_ARGUMENT
	for status_value: Variant in statuses:
		if not status_value is T.Status or not V.frame(status_value.last_frame) or status_value.epoch < 0 or status_value.epoch > 65535:
			return I.Code.INVALID_ARGUMENT
		if status_value.disconnected or status_value.epoch != 0:
			return I.Code.UNSUPPORTED_KIND
	return I.Code.OK


func _plan(now_us: int) -> Dictionary:
	var state: Dictionary = _state.duplicate(true)
	state.now_us = now_us
	return {"state": state, "outbox": [], "events": [], "transitions": []}


func _packet(kind: int) -> T.Message:
	var message: T.Message = T.Message.new()
	message.kind = kind
	message.session_id = _local.session_id
	message.sender_id = _local.sender_id
	message.connection_id = _local.connection_id
	return message


func _send_pending(plan: Dictionary) -> void:
	var width: int = _local_players.size() * _limits.input_width
	var overhead: int = 60 + _local_players.size() + 7 * _limits.player_count
	# Each peer can have a different limit, so batches fit the smaller one. An honest remote limit always holds one frame.
	var packet_bytes: int = mini(_limits.max_packet_bytes, _handshake.remote_packet_bytes())
	var count: int = clampi((packet_bytes - overhead) / width, 1, _options.max_input_frames)
	var frames: Array = plan.state.pending.keys()
	frames.sort()
	var inputs: Array[PackedByteArray] = []
	for index: int in range(mini(count, frames.size())):
		inputs.append(plan.state.pending[frames[index]])
	_send_input(plan, frames[0], inputs)
	plan.state.last_input_send_us = plan.state.now_us


func _send_input(plan: Dictionary, start_frame: int, inputs: Array[PackedByteArray]) -> void:
	var message: T.Message = _packet(T.Kind.INPUT)
	message.ack_frame = plan.state.last_received_frame
	message.players = _local_players
	for value: Dictionary in plan.state.connect_statuses:
		var status_value: T.Status = T.Status.new()
		status_value.last_frame = value.last_frame
		message.statuses.append(status_value)
	message.start_frame = start_frame
	message.frame_count = inputs.size()
	for data: PackedByteArray in inputs:
		message.data.append_array(data)
	plan.state.last_sent_frame = maxi(plan.state.last_sent_frame, start_frame + inputs.size() - 1)
	plan.outbox.append(Codec.encode(message, _limits).bytes)


func _ack(plan: Dictionary, frame: int) -> void:
	if frame <= plan.state.last_acked_frame or frame > plan.state.last_sent_frame:
		return
	var frames: Array = plan.state.pending.keys()
	frames.sort()
	for pending_frame: int in frames:
		if pending_frame > frame:
			break
		plan.state.last_acked_input = plan.state.pending[pending_frame].duplicate()
		plan.state.pending.erase(pending_frame)
		plan.state.last_acked_frame = pending_frame


func _merge_statuses(plan: Dictionary, statuses: Array, field: String = "peer_statuses") -> void:
	for slot: int in range(statuses.size()):
		plan.state[field][slot].last_frame = maxi(plan.state[field][slot].last_frame, statuses[slot].last_frame)


func _receive_frames(plan: Dictionary, message: T.Message) -> int:
	if message.players != _remote_players:
		return I.Code.INVALID_PACKET
	var code: int = _status_code(message.statuses)
	if code != I.Code.OK:
		return code
	var width: int = _remote_players.size() * _limits.input_width
	var staged: Array[Dictionary] = []
	for index: int in range(message.frame_count):
		var frame: int = message.start_frame + index
		var bytes: PackedByteArray = message.data.slice(index * width, (index + 1) * width)
		if plan.state.received.has(frame) and plan.state.received[frame] != bytes:
			return I.Code.CONFLICT
		if frame > plan.state.last_received_frame:
			staged.append({"frame": frame, "data": bytes})
	var gap: bool = message.start_frame > plan.state.last_received_frame + 1
	if plan.state.last_received_frame == -1 and message.start_frame == _local.config.input_delay:
		gap = false
	if gap:
		staged.clear()
	_merge_statuses(plan, message.statuses)
	if _lifecycle != null:
		Lifecycle.received(plan)
	# Reserve every publication before invoking the irreversible retention sink.
	var reply: T.Message = _packet(T.Kind.INPUT_ACK)
	reply.ack_frame = plan.state.last_received_frame if staged.is_empty() else staged[-1].frame
	plan.outbox.append(Codec.encode(reply, _limits).bytes)
	_trace(plan, "receive_input", "gap" if gap else ("duplicate" if staged.is_empty() else "progress"))
	if not staged.is_empty():
		plan.events.append({"kind": "inputs_received", "start_frame": staged[0].frame, "frame_count": staged.size()})
	code = _capacity(plan)
	if code != I.Code.OK:
		return code
	_busy = true
	for entry: Dictionary in staged:
		var accepted: Variant = _accept_input.call(entry.frame, entry.data.duplicate()) if _accept_input.is_valid() else null
		if typeof(accepted) != TYPE_INT or accepted != 0:
			_busy = false
			_state = plan.state
			_state.terminated = true
			for event: Dictionary in plan.events:
				if event.kind != "inputs_received":
					_events.append(event)
			_events.append({"kind": "input_failed", "frame": entry.frame})
			plan.transitions[-1].disposition = "input_failed"
			plan.transitions[-1].last_received_frame = _state.last_received_frame
			_transitions.append(plan.transitions[-1])
			return I.Code.INPUT_FAILED
		plan.state.received[entry.frame] = entry.data
		plan.state.last_received_frame = entry.frame
		while plan.state.received.size() > _options.max_received_frames:
			var frames: Array = plan.state.received.keys()
			frames.sort()
			plan.state.received.erase(frames[0])
	_busy = false
	if not staged.is_empty():
		plan.state.last_input_progress_us = plan.state.now_us
	# An undecodable gap cannot validate a piggyback ACK; stale duplicates can.
	if not gap:
		_ack(plan, message.ack_frame)
	plan.transitions[-1].last_received_frame = plan.state.last_received_frame
	plan.transitions[-1].last_acked_frame = plan.state.last_acked_frame
	plan.transitions[-1].pending_frames = plan.state.pending.size()
	return _commit(plan)


func _trace(plan: Dictionary, action: String, disposition: String) -> void:
	plan.transitions.append({"action": action, "disposition": disposition, "last_received_frame": plan.state.last_received_frame,
		"last_acked_frame": plan.state.last_acked_frame, "pending_frames": plan.state.pending.size()})


func _capacity(plan: Dictionary) -> int:
	if _lifecycle != null and _events.size() + plan.events.size() > _options.max_events:
		_state.terminated = true
		_state.now_us = plan.state.now_us
		_fatal_event = {"kind": "event_capacity_exceeded", "terminal_cause": plan.events.duplicate(true)}
		return I.Code.BACKPRESSURE
	if _outbox.size() + plan.outbox.size() > _options.max_outbox or _events.size() + plan.events.size() > _options.max_events:
		return I.Code.BACKPRESSURE
	if _transitions.size() + plan.transitions.size() > _options.max_transitions:
		return I.Code.BACKPRESSURE
	return I.Code.OK


func _commit(plan: Dictionary) -> int:
	var code: int = _capacity(plan)
	if code != I.Code.OK:
		if _lifecycle != null and plan.state.terminated and _events.size() + plan.events.size() <= _options.max_events:
			_state = plan.state
			for event: Dictionary in plan.events:
				_events.append(event)
			return code
		if _lifecycle != null and _events.size() + plan.events.size() > _options.max_events:
			_state.terminated = true
			_state.now_us = plan.state.now_us
			_fatal_event = {"kind": "event_capacity_exceeded", "terminal_cause": plan.events.duplicate(true)}
		return code
	if _lifecycle != null and not plan.outbox.is_empty():
		plan.state.last_send_us = plan.state.now_us
	_state = plan.state
	for packet: PackedByteArray in plan.outbox:
		_outbox.append(packet)
	for event: Dictionary in plan.events:
		_events.append(event)
	for transition: Dictionary in plan.transitions:
		_transitions.append(transition)
	return I.Code.OK


func _encode(message: T.Message) -> PackedByteArray:
	return Codec.encode(message, _limits).bytes


func update_local_frame_advantage(frame: Variant) -> int:
	if _busy:
		return I.Code.BUSY
	if _lifecycle == null or _handshake == null or _state.terminated:
		return I.Code.WRONG_STATE
	if typeof(frame) != TYPE_INT or not V.frame(frame):
		return I.Code.INVALID_FRAME
	if frame == -1 or _state.last_received_frame == -1:
		return I.Code.OK
	# Bound before multiplication; signed-64 microseconds cannot overflow this cap.
	var half_rtt: int = _state.round_trip_time_ms / 2
	var delta: int = 2147483647 if half_rtt > 2147483647 * 1000 / _local.config.fps else half_rtt * _local.config.fps / 1000
	var remote_frame: int = mini(2147483647, _state.last_received_frame + delta)
	_state.local_frame_advantage = clampi(remote_frame - frame, -2147483648, 2147483647)
	return I.Code.OK


func send_checksum(frame: Variant, checksum: Variant, now_us: Variant) -> int:
	var code: int = _gate(now_us)
	if code != I.Code.OK:
		return code
	if _lifecycle == null or _handshake.status().state != "running":
		return I.Code.WRONG_STATE
	if typeof(frame) != TYPE_INT or not V.frame(frame, false) or not checksum is PackedByteArray or checksum.size() != 16:
		return I.Code.INVALID_ARGUMENT
	var plan: Dictionary = _plan(now_us)
	var report: T.Message = _packet(T.Kind.CHECKSUM_REPORT)
	report.frame = frame
	report.checksum = checksum.duplicate()
	plan.outbox.append(_encode(report))
	return _commit(plan)


## A coordinated drop barrier message. The payload carries the barrier phase, the pinned
## operation identity, the agreed frame window and the frozen value's digest.
func send_drop_barrier(payload: Variant, now_us: Variant) -> int:
	var code: int = _gate(now_us)
	if code != I.Code.OK:
		return code
	if _lifecycle == null or _handshake.status().state != "running":
		return I.Code.WRONG_STATE
	if not payload is Dictionary:
		return I.Code.INVALID_ARGUMENT
	var message: T.Message = _packet(T.Kind.DROP_BARRIER)
	var fields: Array[String] = ["phase", "stage", "reason", "coordinator", "coordinator_generation", "operation"]
	fields.append_array(["target_set_digest", "cut", "bound", "available_through", "cut_digest", "chunk_index", "chunk_count"])
	for field: String in fields:
		if not payload.get(field, null) is int:
			return I.Code.INVALID_ARGUMENT
		message.set(field, payload[field])
	if not payload.get("data", null) is PackedByteArray or not payload.get("bytes", null) is PackedByteArray:
		return I.Code.INVALID_ARGUMENT
	message.data = payload["data"]
	message.bytes = payload["bytes"]
	var plan: Dictionary = _plan(now_us)
	var encoded: PackedByteArray = _encode(message)
	if encoded.is_empty():
		# The codec refuses an out-of-range or unbounded barrier field.
		return I.Code.INVALID_ARGUMENT
	plan.outbox.append(encoded)
	return _commit(plan)


func close(now_us: Variant, reason: Variant = 0) -> int:
	var code: int = _gate(now_us)
	if code != I.Code.OK:
		return code
	if _lifecycle == null or _handshake.status().state != "running":
		return I.Code.WRONG_STATE
	if typeof(reason) != TYPE_INT or reason < 0 or reason > 255:
		return I.Code.INVALID_ARGUMENT
	var plan: Dictionary = _plan(now_us)
	var goodbye: T.Message = _packet(T.Kind.GOODBYE)
	goodbye.reason = reason
	for index: int in range(3):
		plan.outbox.append(_encode(goodbye))
	plan.state.terminated = true
	plan.events.append({"kind": "disconnected", "reason": reason})
	return _commit(plan)
