class_name FortressPeerSession
extends RefCounted

## Final outer-step outcome after game callbacks and peer controls. Mutating reentry remains BUSY.
signal step_completed(code: int, frame_before: int, frame_after: int)

# gdlint: disable=max-returns
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const H = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const V = preload("res://addons/fortress_rollback/protocol/protocol_validation.gd")
const L = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")
const Checksums = preload("res://addons/fortress_rollback/core/peer_checksums.gd")
const Endpoint = preload("res://addons/fortress_rollback/protocol/input_endpoint.gd")


class Packet:
	extends RefCounted
	var to: PackedByteArray
	var bytes: PackedByteArray

	func _init(destination: PackedByteArray, payload: PackedByteArray) -> void:
		to = destination.duplicate()
		bytes = payload.duplicate()


var _core: Session = null
var _driver: Driver = null
var _config: Config = null
var _peers: Dictionary = {}
var _ids: Array[PackedByteArray] = []
var _busy: bool = false
var _now: int = -1
var _lifecycle: L.Options
var _checksums: Checksums
var _events: Array[Dictionary] = []
var _fatal_event: Dictionary = {}
var _next_wait: int = 0
var _frames_ahead: int = 0
var _terminal_notified: bool = false
var _checksum_confirmation: int = -1
var _diagnostic_failure: Dictionary = {}
var _max_pending: int = 0


## Caller supplies transport identity, clock, tokens and game callbacks.
func configure(config: Variant, local: Variant, game: Variant, handshake_options: Variant, input_options: Variant, lifecycle_options: Variant = null) -> int:
	if _busy:
		return I.Code.BUSY
	if _core != null:
		return I.Code.WRONG_STATE
	if not config is Config or config.validate() != Types.Code.OK or config.sync_test:
		return I.Code.INVALID_ARGUMENT
	if not local is T.Message or not V.config(local.config) or not game is RefCounted:
		return I.Code.INVALID_ARGUMENT
	if not handshake_options is H.Options or not H.valid_options(handshake_options) or not input_options is I.Options or not I.valid_options(input_options):
		return I.Code.INVALID_ARGUMENT
	var controls: Variant = L.Options.new() if lifecycle_options == null else lifecycle_options
	if not L.valid_options(controls):
		return I.Code.INVALID_ARGUMENT
	var profile: T.Config = local.config
	if profile.player_count != config.player_count or profile.input_width != config.input_width or profile.input_delay != config.input_delay:
		return I.Code.INVALID_ARGUMENT
	if profile.max_prediction != config.max_prediction_frames or profile.neutral_input != config.neutral_input:
		return I.Code.INVALID_ARGUMENT
	var locals: PackedInt32Array = PackedInt32Array()
	var remotes: Dictionary = {}
	for slot: int in range(profile.player_count):
		var sender: PackedByteArray = profile.roster[slot]
		if sender == local.sender_id:
			locals.append(slot)
		else:
			remotes[sender.hex_encode()] = sender.duplicate()
	var declared: PackedInt32Array = config.local_players.duplicate()
	declared.sort()
	if locals != declared or remotes.is_empty():
		return I.Code.INVALID_ARGUMENT
	if config.input_delay > max_input_delay(config):
		return I.Code.INVALID_ARGUMENT
	if remotes.size() > 1 and (config.max_prediction_frames == 0 or (config.max_prediction_frames == 1 and config.input_delay == 0)):
		return I.Code.INVALID_ARGUMENT
	var core_config: Config = config.owned_copy()
	core_config.capture_confirmed_snapshots = controls.enabled and config.checksums_enabled and profile.desync_interval > 0
	var core: Session = Session.new()
	if core.configure(core_config) != Types.Code.OK or core.set_confirmation_limit(-1).code != Types.Code.OK:
		return I.Code.INVALID_ARGUMENT
	var driver: Driver = Driver.new()
	if driver.configure(core, game) != Types.Code.OK:
		return I.Code.INVALID_ARGUMENT
	var peers: Dictionary = {}
	var keys: Array = remotes.keys()
	keys.sort()
	for key: String in keys:
		var slots: PackedInt32Array = PackedInt32Array()
		for slot: int in range(profile.player_count):
			if profile.roster[slot] == remotes[key]:
				slots.append(slot)
		var endpoint: Endpoint = Endpoint.new()
		var code: int = endpoint.configure(local, remotes[key], handshake_options, input_options, _accept_remote.bind(slots), controls)
		if code != I.Code.OK:
			return code
		peers[key] = endpoint
	_core = core
	_max_pending = input_options.max_pending_frames
	_driver = driver
	_config = core_config.owned_copy()
	_config.local_players = locals
	_peers = peers
	for key: String in keys:
		_ids.append(remotes[key].duplicate())
	_lifecycle = L.copy_options(controls)
	_checksums = Checksums.new()
	# A peer can confirm up to max_prediction + its delay frames ahead, and delays never exceed max_input_delay.
	_checksums.configure(
		_ids, profile.desync_interval if _lifecycle.enabled and config.checksums_enabled else 0, _lifecycle.max_checksum_frames,
		config.max_prediction_frames + max_input_delay(config)
	)
	return I.Code.OK


func begin(now_us: Variant, tokens: Variant) -> int:
	var code: int = _gate(now_us)
	if code != I.Code.OK:
		return code
	if not _valid_tokens(tokens, false):
		return I.Code.INVALID_ARGUMENT
	for index: int in range(_ids.size()):
		if _endpoint(index).status().state != "initializing":
			return I.Code.WRONG_STATE
	_now = now_us
	for index: int in range(_ids.size()):
		code = _endpoint(index).begin(now_us, tokens[index])
		if code != I.Code.OK:
			return code
	_now = now_us
	return I.Code.OK


func poll(now_us: Variant, tokens: Variant = []) -> int:
	var code: int = _gate(now_us)
	if code != I.Code.OK:
		return code
	if not _valid_tokens(tokens, true):
		return I.Code.INVALID_ARGUMENT
	return _poll(now_us, tokens)


func receive(packet: Variant, attributed_sender: Variant, now_us: Variant, next_token: Variant = null) -> int:
	var code: int = _gate(now_us)
	if code != I.Code.OK:
		return code
	if not attributed_sender is PackedByteArray or not _peers.has(attributed_sender.hex_encode()):
		return I.Code.WRONG_SOURCE
	return _receive(packet, attributed_sender, now_us, next_token)


## Retry gossip observes the receipt bank at the start of this packet service.
func receive_and_poll(packet: Variant, attributed_sender: Variant, now_us: Variant, next_token: Variant = null, tokens: Variant = []) -> int:
	var code: int = _gate(now_us)
	if code != I.Code.OK:
		return code
	if not attributed_sender is PackedByteArray or not _peers.has(attributed_sender.hex_encode()):
		return I.Code.WRONG_SOURCE
	if not _valid_tokens(tokens, true):
		return I.Code.INVALID_ARGUMENT
	var statuses: Array[T.Status] = _statuses()
	code = _receive(packet, attributed_sender, now_us, next_token)
	return _poll(now_us, tokens, statuses) if code == I.Code.OK else code


## Configured attempts emit once, including stalls and errors; unconfigured and BUSY calls emit nothing.
func step(now_us: Variant, local_inputs: Variant) -> Driver.StepResult:
	if _busy or _core == null:
		return _step(now_us, local_inputs)
	var result: Driver.StepResult = _step(now_us, local_inputs)
	_busy = true
	step_completed.emit(result.code, result.frame_before, result.frame_after)
	_busy = false
	return result


## Every endpoint retains the scheduled sample before the game can advance.
func _step(now_us: Variant, local_inputs: Variant) -> Driver.StepResult:
	var before: int = status().current_frame
	var gate: int = _gate(now_us)
	if gate != I.Code.OK:
		return Driver.StepResult.new(_step_code(gate), before, before)
	if not _running():
		return Driver.StepResult.new(Types.Code.NOT_SYNCHRONIZED, before, before)
	var code: int = _samples_code(local_inputs, before)
	if code != Types.Code.OK:
		return Driver.StepResult.new(code, before, before)
	_now = now_us
	var polled: int = _poll(now_us, [])
	if polled != I.Code.OK:
		return Driver.StepResult.new(_step_failure(polled), before, before)
	var control_code: int = _service_controls(now_us, true)
	if control_code != I.Code.OK:
		return Driver.StepResult.new(_step_failure(control_code), before, before)
	_busy = true
	var scheduled: int = -1
	for sample: Driver.LocalInput in local_inputs:
		var result: Types.Result = _core.submit_local_input(sample.player, sample.sample_frame, sample.bytes)
		if result.code != Types.Code.OK:
			_busy = false
			return Driver.StepResult.new(result.code, before, before)
		scheduled = result.value
	var data: PackedByteArray = PackedByteArray()
	for player: int in _config.local_players:
		data.append_array(_core.scheduled_local_input(player).bytes)
	var statuses: Array[T.Status] = _statuses()
	for index: int in range(_ids.size()):
		var endpoint: Endpoint = _endpoint(index)
		if endpoint.status().last_submitted_frame == scheduled:
			continue
		var sent: int = endpoint.submit(scheduled, data, statuses, now_us)
		if sent != I.Code.OK:
			_busy = false
			_collect_events()
			_check_failure()
			return Driver.StepResult.new(_step_failure(sent), before, before)
	code = _confirmation_code()
	if code != Types.Code.OK:
		_busy = false
		return Driver.StepResult.new(code, before, before)
	_now = now_us
	var empty: Array[Driver.LocalInput] = []
	var advanced: Driver.StepResult = _driver.step(now_us, empty)
	if advanced.code in [Types.Code.OK, Types.Code.PREDICTION_STALL]:
		_checksum_confirmation = _core.status().confirmed_frame
	_busy = false
	_service_controls(now_us, false)
	if _core.status().lifecycle == Types.Lifecycle.TERMINATED:
		return Driver.StepResult.new(_core.status().reason, before, _core.status().current_frame)
	return advanced


func status() -> Types.Status:
	return _core.status() if _core != null else Types.Status.new()


## Shared expert-engine counters. Returned values belong to the caller.
func statistics() -> Types.Statistics:
	return _core.statistics() if _core != null else Types.Statistics.new()


## Confirmed frames recorded so far; null unless config.replay_max_frames > 0.
func replay() -> RefCounted:
	return _core.replay() if _core != null else null


## Local delay now in effect, or -1 before configuration or for a slot that is not local.
func input_delay(player: int) -> int:
	return _core.input_delay(player) if _core != null else -1


## Largest delay any peer may use. Each peer's queue for a remote slot spans that remote's delay,
## its own delay and two prediction windows, so equal queue capacities on every peer always hold it.
static func max_input_delay(config: Config) -> int:
	return (config.queue_capacity - 2 * config.max_prediction_frames - 2) / 2


## Raises one local player's delay mid-match, between steps or while stalled. Peers receive the
## added frames, which repeat that player's latest input, as ordinary input. The agreed config owns
## the starting delay, so decreases, changes before the first step and several local players are UNSUPPORTED.
## Delays above max_input_delay(config) are INVALID_CONFIGURATION.
func set_input_delay(player: int, delay: int) -> int:
	if _busy:
		return Types.Code.BUSY
	if _core == null:
		return Types.Code.NOT_CONFIGURED
	if _core.status().lifecycle == Types.Lifecycle.TERMINATED:
		return Types.Code.TERMINATED
	if not _running():
		return Types.Code.NOT_SYNCHRONIZED
	if not _config.local_players.has(player):
		return Types.Code.INVALID_PLAYER
	if delay < 0 or delay > max_input_delay(_config):
		return Types.Code.INVALID_CONFIGURATION
	var current: int = _core.input_delay(player)
	if delay == current:
		return Types.Code.OK
	var last: int = _core.received_frames()[player]
	if _config.local_players.size() > 1 or last == -1 or delay < current:
		return Types.Code.UNSUPPORTED
	# A backpressured step leaves an endpoint behind the core; it receives its missing frames first.
	var starts: PackedInt64Array = PackedInt64Array()
	for index: int in range(_ids.size()):
		var observed: Dictionary = _endpoint(index).status()
		var start: int = observed.last_submitted_frame + 1 if observed.last_submitted_frame != -1 else _config.input_delay
		if observed.pending_frames + last + 1 - start + delay - current > _max_pending:
			return Types.Code.NETWORK_BACKPRESSURE
		starts.append(start)
	var changed: Types.Result = _core.set_input_delay(player, delay)
	if changed.code != Types.Code.OK:
		return changed.code
	var statuses: Array[T.Status] = _statuses()
	for index: int in range(_ids.size()):
		for frame: int in range(starts[index], changed.value + 1):
			var sent: int = _endpoint(index).submit(frame, _core.retained_local_input(player, frame), statuses, _now)
			if sent != I.Code.OK:
				# Peers would disagree about the added frames, so the match cannot continue.
				_core.terminate(Types.Code.PROTOCOL_FAILED)
				_collect_events()
				_check_failure()
				return _step_failure(sent)
	return Types.Code.OK


## Bounded observations without transport identities or tokens. Trace payloads require explicit configuration opt-in.
## Reading does not drain publication queues. The terminal cause survives event drains.
func diagnostics() -> Dictionary:
	var observed: Types.Status = status()
	var counts: Types.Statistics = statistics()
	var peers: Array[Dictionary] = []
	for index: int in range(_ids.size()):
		var endpoint: Dictionary = _endpoint(index).status()
		var row: Dictionary = {"index": index, "state": endpoint.state}
		for field: String in ["pending_frames", "last_received_frame", "last_acked_frame", "round_trip_time_ms", "average_frame_advantage"]:
			row[field] = endpoint.get(field, 0)
		peers.append(row)
	var report: Dictionary = {
		"schema": "fortress-peer-diagnostics-v1",
		"current_frame": observed.current_frame,
		"confirmed_frame": observed.confirmed_frame,
		"lifecycle": observed.lifecycle,
		"reason": observed.reason,
		"failure_frame": observed.failure_frame,
		"pending_rollback_frame": observed.pending_rollback_frame,
		"frames_ahead": _frames_ahead,
		"statistics":
		{
			"rollback_count": counts.rollback_count,
			"resimulated_frames": counts.resimulated_frames,
			"advanced_frames": counts.advanced_frames,
			"prediction_stalls": counts.prediction_stalls,
			"last_rollback_depth": counts.last_rollback_depth,
			"max_rollback_depth": counts.max_rollback_depth
		},
		"peers": peers,
		"failure": _owned_event(_diagnostic_failure)
	}

	if _config != null and _config.diagnostic_trace_frames > 0:
		report["trace"] = _core.diagnostic_trace()
	return report


func _diagnostic_event(event: Dictionary, depth: int = 0) -> Dictionary:
	var result: Dictionary = {}
	for field: String in ["kind", "frame"]:
		if event.has(field):
			result[field] = event[field]
	if event.has("reason"):
		# Agreement reasons contain private negotiated values; retain only the field name.
		if event.reason is Dictionary:
			result["field"] = str(event.reason.get("field", "unknown")).left(64)
		elif event.reason is String:
			result["reason"] = event.reason.left(64)
		elif typeof(event.reason) == TYPE_INT:
			result["reason"] = event.reason
	if event.has("peer"):
		result["peer_index"] = _ids.find(event.peer)
	for field: String in ["local_checksum", "remote_checksum"]:
		if event.has(field):
			result[field] = event[field].hex_encode()
	if depth < 2 and event.has("terminal_cause"):
		var causes: Array[Dictionary] = []
		for cause: Dictionary in event.terminal_cause:
			causes.append(_diagnostic_event(cause, depth + 1))
		result["terminal_cause"] = causes
	return result


func peer_ids() -> Array[PackedByteArray]:
	var result: Array[PackedByteArray] = []
	for sender: PackedByteArray in _ids:
		result.append(sender.duplicate())
	return result


func network_status() -> Dictionary:
	var peers: Dictionary = {}
	for key: String in _peers:
		peers[key] = _peers[key].status()
	var state: String = "unconfigured"
	if _core != null:
		state = "running" if _running() else "synchronizing"
		if _core.status().lifecycle == Types.Lifecycle.TERMINATED:
			state = "terminated"
	return {"state": state, "peers": peers, "last_now_us": _now, "frames_ahead": _frames_ahead, "checksums": _checksums.status() if _checksums != null else {}}


func drain_outbox() -> Array[Packet]:
	var result: Array[Packet] = []
	if _busy:
		return result
	for index: int in range(_ids.size()):
		for bytes: PackedByteArray in _endpoint(index).drain_outbox():
			result.append(Packet.new(_ids[index], bytes))
	return result


func drain_events() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if _busy:
		return result
	_collect_events()
	for event: Dictionary in _events:
		result.append(_owned_event(event))
	_events.clear()
	if not _fatal_event.is_empty():
		result.append(_owned_event(_fatal_event))
		_fatal_event.clear()
	return result


## Fixed-membership close queues goodbye on every link and halts advancement.
func close(now_us: Variant, reason: Variant = 0) -> int:
	var code: int = _gate(now_us)
	if code != I.Code.OK:
		return code
	if typeof(reason) != TYPE_INT or reason < 0 or reason > 255:
		return I.Code.INVALID_ARGUMENT
	_now = now_us
	for index: int in range(_ids.size()):
		var closed: int = _endpoint(index).close(now_us, reason)
		if closed != I.Code.OK:
			code = closed
	_collect_events(true)
	_core.terminate(Types.Code.TERMINATED)
	_terminate_links()
	return code


func drain_transitions() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if _busy:
		return result
	for index: int in range(_ids.size()):
		for transition: Dictionary in _endpoint(index).drain_transitions():
			transition["peer"] = _ids[index].duplicate()
			result.append(transition)
	return result


func _endpoint(index: int) -> Endpoint:
	return _peers[_ids[index].hex_encode()]


func _gate(now_us: Variant) -> int:
	if _busy:
		return I.Code.BUSY
	if _core == null:
		return I.Code.WRONG_STATE
	if _core.status().lifecycle == Types.Lifecycle.TERMINATED:
		return I.Code.TERMINATED
	if not now_us is int or now_us < 0 or now_us < _now:
		return I.Code.INVALID_ARGUMENT
	return I.Code.OK


func _valid_tokens(tokens: Variant, optional: bool) -> bool:
	if not tokens is Array or (tokens.size() != _ids.size() and not (optional and tokens.is_empty())):
		return false
	for token: Variant in tokens:
		if not token is PackedByteArray or token.size() != 16:
			return false
		var nonzero: bool = false
		for byte: int in token:
			nonzero = nonzero or byte != 0
		if not nonzero:
			return false
	return true


func _receive(packet: Variant, attributed_sender: PackedByteArray, now_us: int, next_token: Variant) -> int:
	var endpoint: Endpoint = _peers[attributed_sender.hex_encode()]
	var previous_now: int = _now
	_now = now_us
	_busy = true
	var code: int = endpoint.receive(packet, attributed_sender, now_us, next_token)
	_busy = false
	if code in [I.Code.WRONG_SOURCE, I.Code.WRONG_CONNECTION]:
		_now = previous_now
		return code
	if code == I.Code.OK:
		_now = now_us
	_collect_events()
	_check_failure()
	if _running() and _core.status().lifecycle != Types.Lifecycle.TERMINATED:
		_confirmation_code()
		_service_controls(now_us, false)
	return code


func _poll(now_us: int, tokens: Array, statuses: Array[T.Status] = []) -> int:
	_now = now_us
	if statuses.is_empty():
		statuses = _statuses()
	var status_nudge: bool = _gossip_nudge_needed()
	var result: int = I.Code.OK
	for index: int in range(_ids.size()):
		if _lifecycle.enabled:
			_endpoint(index).update_local_frame_advantage(_core.status().current_frame)
		var code: int = _endpoint(index).poll(now_us, null if tokens.is_empty() else tokens[index], statuses, status_nudge)
		if code != I.Code.OK:
			_collect_events()
			_check_failure()
			if code != I.Code.BACKPRESSURE or _core.status().lifecycle == Types.Lifecycle.TERMINATED:
				return code
			result = code
	_now = now_us
	_collect_events()
	_check_failure()
	if _running() and _core.status().lifecycle != Types.Lifecycle.TERMINATED:
		_confirmation_code()
		_service_controls(now_us, false)
	return result


func _running() -> bool:
	if _core == null:
		return false
	for key: String in _peers:
		if _peers[key].status().state != "running":
			return false
	return true


func _samples_code(samples: Variant, frame: int) -> int:
	if not samples is Array or samples.size() != _config.local_players.size():
		return Types.Code.MISSING_LOCAL_INPUT
	var seen: Dictionary = {}
	for sample: Variant in samples:
		if not sample is Driver.LocalInput or not _config.local_players.has(sample.player) or seen.has(sample.player):
			return Types.Code.INVALID_PLAYER
		if sample.sample_frame != frame:
			return Types.Code.INVALID_FRAME
		if sample.bytes.size() != _config.input_width:
			return Types.Code.INPUT_WIDTH
		var previous: Types.InputResult = _core.scheduled_local_input(sample.player)
		if previous.code == Types.Code.OK and previous.bytes != sample.bytes:
			return Types.Code.INPUT_ALREADY_SUBMITTED
		seen[sample.player] = true
	return Types.Code.OK


func _statuses() -> Array[T.Status]:
	var result: Array[T.Status] = []
	var frames: PackedInt64Array = _core.received_frames()
	for frame: int in frames:
		var entry: T.Status = T.Status.new()
		entry.last_frame = frame
		result.append(entry)
	return result


func _gossip_nudge_needed() -> bool:
	var observed: Types.Status = _core.status()
	if observed.current_frame - observed.confirmed_frame < _config.max_prediction_frames:
		return false
	var receipts: PackedInt64Array = _core.received_frames()
	var receipt_fold: int = receipts[0]
	for frame: int in receipts:
		receipt_fold = mini(receipt_fold, frame)
	return observed.confirmed_frame < receipt_fold


func _confirmation_code() -> int:
	var frames: PackedInt64Array = _core.received_frames()
	var limit: int = frames[0]
	for slot: int in range(frames.size()):
		var bound: int = frames[slot]
		if not _config.local_players.has(slot):
			for key: String in _peers:
				bound = mini(bound, _peers[key].status().peer_statuses[slot].last_frame)
		limit = mini(limit, bound)
	return _core.set_confirmation_limit(limit).code


func _accept_remote(frame: int, bytes: PackedByteArray, slots: PackedInt32Array) -> int:
	for index: int in range(slots.size()):
		var start: int = index * _config.input_width
		var code: int = _core.receive_input(slots[index], frame, bytes.slice(start, start + _config.input_width)).code
		if code != Types.Code.OK:
			_core.terminate(Types.Code.PROTOCOL_FAILED)
			return code
	return Types.Code.OK


func _check_failure() -> void:
	for key: String in _peers:
		var observed: Dictionary = _peers[key].status()
		if observed.state in ["terminated", "failed"] or not observed.handshake.mismatch.is_empty():
			_core.terminate(Types.Code.PROTOCOL_FAILED)
	if _core.status().lifecycle == Types.Lifecycle.TERMINATED:
		_remember_diagnostic()


func _step_failure(code: int) -> int:
	return _core.status().reason if _core.status().lifecycle == Types.Lifecycle.TERMINATED else _step_code(code)


func _step_code(code: int) -> int:
	match code:
		I.Code.BUSY:
			return Types.Code.BUSY
		I.Code.BACKPRESSURE:
			return Types.Code.NETWORK_BACKPRESSURE
		I.Code.INVALID_ARGUMENT:
			return Types.Code.INVALID_TIME
		I.Code.WRONG_STATE:
			return Types.Code.NOT_CONFIGURED
		I.Code.TERMINATED:
			return Types.Code.TERMINATED
	return Types.Code.PROTOCOL_FAILED


func _collect_events(local_close: bool = false) -> void:
	if _core == null:
		return
	for index: int in range(_ids.size()):
		for event: Dictionary in _endpoint(index).drain_events():
			event["peer"] = _ids[index].duplicate()
			if event.kind == "checksum_received":
				if _core.status().lifecycle == Types.Lifecycle.TERMINATED:
					continue
				var code: int = _checksums.receive(_ids[index], event.frame, event.checksum, _core.status().current_frame)
				if code != Types.Code.OK:
					_fatal_event = _owned_event(_checksums.failure)
					_core.terminate(code)
				continue
			if event.kind == "event_capacity_exceeded" or (event.kind == "disconnected" and not local_close):
				_core.terminate(Types.Code.PROTOCOL_FAILED)
			_publish_event(event)
	if _core.status().lifecycle == Types.Lifecycle.TERMINATED:
		_terminate_links()


func _publish_event(event: Dictionary) -> void:
	if _events.size() >= _lifecycle.max_events:
		if _fatal_event.is_empty():
			_fatal_event = {"kind": "event_capacity_exceeded", "terminal_cause": [_owned_event(event)]}
		elif _fatal_event.kind == "event_capacity_exceeded" and event.kind in ["disconnected", "event_capacity_exceeded"]:
			_retain_terminal_cause(event)
		_core.terminate(Types.Code.PROTOCOL_FAILED)
	else:
		_events.append(_owned_event(event))


func _retain_terminal_cause(event: Dictionary) -> void:
	var causes: Array = _fatal_event.terminal_cause
	for index: int in range(1, causes.size()):
		if causes[index].peer == event.peer:
			causes[index] = _owned_event(event)
			return
	if causes.size() <= _ids.size():
		causes.append(_owned_event(event))


func _service_controls(now_us: int, send_reports: bool) -> int:
	_collect_events()
	if _core.status().lifecycle == Types.Lifecycle.TERMINATED:
		return I.Code.TERMINATED
	if not _lifecycle.enabled:
		return I.Code.OK
	var current: int = _core.status().current_frame
	if send_reports:
		_frames_ahead = -2147483648
	for index: int in range(_ids.size()):
		if send_reports:
			_frames_ahead = maxi(_frames_ahead, _endpoint(index).status().average_frame_advantage)
	if send_reports and current > _next_wait and _frames_ahead >= 3:
		_next_wait = current + 60
		_publish_event({"kind": "wait_recommendation", "skip_frames": _frames_ahead})
		if _core.status().lifecycle == Types.Lifecycle.TERMINATED:
			_terminate_links()
			return I.Code.TERMINATED
	if send_reports:
		# Compare retained pairs before scheduling can evict their local/remote inventories.
		# Publication follows the outgoing report, retaining the source packet order.
		var prior_comparison: int = _checksums.compare(_core, _ids, _checksum_confirmation)
		var prior_failure: Dictionary = _owned_event(_checksums.failure) if prior_comparison != Types.Code.OK else {}
		var scheduled: Dictionary = _checksums.scheduled(_core, _checksum_confirmation)
		if prior_comparison == Types.Code.OK and not _checksums.failure.is_empty():
			return _checksum_failure(Types.Code.HISTORY_UNAVAILABLE, _checksums.failure)
		if not scheduled.is_empty():
			for index: int in range(_ids.size()):
				if _checksums.needs_send(_ids[index], scheduled.frame):
					var sent: int = _endpoint(index).send_checksum(scheduled.frame, scheduled.checksum, now_us)
					if sent != I.Code.OK:
						if prior_comparison != Types.Code.OK:
							return _checksum_failure(prior_comparison, prior_failure)
						_collect_events()
						_check_failure()
						return sent
					_checksums.sent(_ids[index], scheduled.frame)
		if prior_comparison != Types.Code.OK:
			return _checksum_failure(prior_comparison, prior_failure)
	if not send_reports:
		return I.Code.OK
	var compared: int = _checksums.compare(_core, _ids, _checksum_confirmation)
	if compared != Types.Code.OK:
		return _checksum_failure(compared, _checksums.failure)
	return I.Code.OK


func _checksum_failure(code: int, diagnostic: Dictionary) -> int:
	if code == Types.Code.DESYNC:
		_core._freeze_diagnostic_trace(diagnostic.frame, _ids.find(diagnostic.peer), diagnostic.local_checksum, diagnostic.remote_checksum)
	_fatal_event = _owned_event(diagnostic)
	_core.terminate(code, diagnostic.get("frame", -1))
	_terminate_links()
	return I.Code.TERMINATED


func _owned_event(event: Dictionary) -> Dictionary:
	return _owned_value(event)


# Variant accommodates bounded event dictionaries, arrays and scalar metadata.
func _owned_value(value: Variant) -> Variant:
	if value is PackedByteArray:
		return value.duplicate()
	if value is Array:
		var result: Array = []
		for entry: Variant in value:
			result.append(_owned_value(entry))
		return result
	if value is Dictionary:
		var result: Dictionary = {}
		for key: Variant in value:
			result[key] = _owned_value(value[key])
		return result
	return value


func _remember_diagnostic() -> void:
	if _diagnostic_failure.is_empty():
		if not _fatal_event.is_empty():
			_diagnostic_failure = _diagnostic_event(_fatal_event)
		else:
			for index: int in range(_events.size() - 1, -1, -1):
				if _events[index].kind in ["disconnected", "incompatible", "sync_timeout", "input_failed"]:
					_diagnostic_failure = _diagnostic_event(_events[index])
					break


func _terminate_links() -> void:
	_remember_diagnostic()
	if _terminal_notified or not _lifecycle.enabled or _now < 0:
		return
	_terminal_notified = true
	var failures: Array[Dictionary] = []
	for index: int in range(_ids.size()):
		if _endpoint(index).status().state == "running":
			var code: int = _endpoint(index).close(_now, 255)
			if code != I.Code.OK:
				failures.append({"peer": _ids[index].duplicate(), "code": code})
	if not failures.is_empty():
		if _fatal_event.is_empty():
			_fatal_event = {"kind": "goodbye_backpressure", "close_failures": failures}
		else:
			_fatal_event["close_failures"] = failures
