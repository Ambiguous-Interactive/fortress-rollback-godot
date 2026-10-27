class_name FortressPeerSession
extends RefCounted

## Final step or recovery outcome after game callbacks and peer controls. Mutating reentry remains BUSY.
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
const Drop = preload("res://addons/fortress_rollback/core/peer_drop_barrier.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const Endpoint = preload("res://addons/fortress_rollback/protocol/input_endpoint.gd")
const Advisor = preload("res://addons/fortress_rollback/core/delay_advisor.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
const ExpertBatch = preload("res://addons/fortress_rollback/core/peer_request_batch.gd")


class Packet:
	extends RefCounted
	var to: PackedByteArray
	var bytes: PackedByteArray

	func _init(destination: PackedByteArray, payload: PackedByteArray) -> void:
		to = destination.duplicate()
		bytes = payload.duplicate()


var _core: Session = null
var _driver: Driver = null
var _expert_mode: bool = false
var _manual_batch: RefCounted
var _manual_identity: int = 0
var _manual_before: int = 0
var _manual_operation: int = 0
var _config: Config = null
var _peers: Dictionary = {}
var _ids: Array[PackedByteArray] = []
var _slots_by_peer: Array[PackedInt32Array] = []
## A coordinated drop barrier agrees the frozen frame between the survivors.
## The survivor that owns the lowest surviving slot proposes the cut, every other
## survivor answers with the frame window it can still freeze, and the proposer
## commits the frame that all of them can retain.
var _drops: Drop = Drop.new()
var _busy: bool = false
var _now: int = -1
var _lifecycle: L.Options
var _checksums: Checksums
## The connection identity of the local peer; it names the local connected era.
var _local_connection: PackedByteArray = PackedByteArray()
var _events: Array[Dictionary] = []
var _fatal_event: Dictionary = {}
var _next_wait: int = 0
var _frames_ahead: int = 0
var _terminal_notified: bool = false
var _checksum_confirmation: int = -1
var _diagnostic_failure: Dictionary = {}
var _fps: int = 60
var _advisor: Advisor = Advisor.new()


## Caller supplies transport identity, clock, tokens and game callbacks.
func configure(config: Variant, local: Variant, game: Variant, handshake_options: Variant, input_options: Variant, lifecycle_options: Variant = null) -> int:
	return _configure(config, local, game, handshake_options, input_options, lifecycle_options, false)


## Configure a peer without game callbacks. The caller dispatches and acknowledges every ordered request.
func configure_expert(config: Variant, local: Variant, handshake_options: Variant, input_options: Variant, lifecycle_options: Variant = null) -> int:
	return _configure(config, local, null, handshake_options, input_options, lifecycle_options, true)


func _configure(config: Variant, local: Variant, game: Variant, handshake_options: Variant, input_options: Variant, lifecycle_options: Variant, expert: bool) -> int:
	if _has_mutation_guard():
		return I.Code.BUSY
	if _core != null:
		return I.Code.WRONG_STATE
	if not config is Config or config.validate() != Types.Code.OK or config.sync_test:
		return I.Code.INVALID_ARGUMENT
	if not local is T.Message or not V.config(local.config) or (not expert and not game is RefCounted):
		return I.Code.INVALID_ARGUMENT
	if not handshake_options is H.Options or not H.valid_options(handshake_options) or not input_options is I.Options or not I.valid_options(input_options):
		return I.Code.INVALID_ARGUMENT
	var controls: Variant = L.Options.new() if lifecycle_options == null else lifecycle_options
	if not L.valid_options(controls):
		return I.Code.INVALID_ARGUMENT
	var profile: T.Config = local.config
	if profile.player_count != config.player_count or profile.input_width != config.input_width or profile.input_delay != config.input_delay:
		return I.Code.INVALID_ARGUMENT
	if profile.max_prediction != config.max_prediction_frames or profile.queue_capacity != config.queue_capacity or profile.neutral_input != config.neutral_input:
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
	var agreed_local: T.Message = local
	if controls.enabled and controls.disconnect_behavior == L.Disconnect.CONTINUE:
		# Every target needs an era, a retained interval and its bounded control header.
		var control_bytes: int = Codec.HEADER_BYTES + 54 + 2 + profile.player_count * 12
		if handshake_options.max_packet_bytes < control_bytes or local.features != 0:
			return I.Code.INVALID_ARGUMENT
		var limits: T.Limits = T.Limits.new()
		limits.player_count = profile.player_count
		limits.input_width = profile.input_width
		limits.max_packet_bytes = handshake_options.max_packet_bytes
		var encoded: T.Result = Codec.encode(local, limits)
		if encoded.code != T.Code.OK:
			return I.Code.INVALID_ARGUMENT
		agreed_local = Codec.decode(encoded.bytes, limits).message
		agreed_local.features = T.FEATURE_HISTORY_DROP
	var core_config: Config = config.owned_copy()
	core_config.capture_confirmed_snapshots = controls.enabled and config.checksums_enabled and profile.desync_interval > 0
	var core: Session = Session.new()
	if core.configure(core_config) != Types.Code.OK or core.set_confirmation_limit(-1).code != Types.Code.OK:
		return I.Code.INVALID_ARGUMENT
	var driver: Driver = null
	if not expert:
		driver = Driver.new()
		if driver.configure(core, game) != Types.Code.OK:
			return I.Code.INVALID_ARGUMENT
	var peers: Dictionary = {}
	var keys: Array = remotes.keys()
	keys.sort()
	var slots_by_peer: Array[PackedInt32Array] = []
	for key: String in keys:
		var slots: PackedInt32Array = PackedInt32Array()
		for slot: int in range(profile.player_count):
			if profile.roster[slot] == remotes[key]:
				slots.append(slot)
		var endpoint: Endpoint = Endpoint.new()
		var code: int = endpoint.configure(agreed_local, remotes[key], handshake_options, input_options, _accept_remote.bind(slots), controls)
		if code != I.Code.OK:
			return code
		peers[key] = endpoint
		slots_by_peer.append(slots)
	_core = core
	_fps = profile.fps
	_driver = driver
	_expert_mode = expert
	_config = core_config.owned_copy()
	_config.local_players = locals
	_peers = peers
	_slots_by_peer = slots_by_peer
	_drops.reset()
	for key: String in keys:
		_ids.append(remotes[key].duplicate())
	_lifecycle = L.copy_options(controls)
	_local_connection = local.connection_id.duplicate()
	_checksums = Checksums.new()
	# A peer can confirm up to max_prediction + its delay frames ahead, and delays never exceed max_input_delay.
	_checksums.configure(
		_ids,
		profile.desync_interval if _lifecycle.enabled and config.checksums_enabled else 0,
		_lifecycle.max_checksum_frames,
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
## Omit local slots already retained by a stalled attempt; every other local slot needs a current sample.
func step(now_us: Variant, local_inputs: Variant) -> Driver.StepResult:
	if _busy or _core == null:
		return _step(now_us, local_inputs)
	return _notify_completed(_step(now_us, local_inputs))


## Poll transport controls and correct simulated history without submitting another local input.
## Bounded historical carriers refresh receipt gossip, including for already-confirmed senders.
## Delivery and confirmation can still lag; check status before declaring a clean final boundary.
func recover(now_us: Variant) -> Driver.StepResult:
	if _busy or _core == null:
		return _recover(now_us)
	return _notify_completed(_recover(now_us))


## Save exactly the finalized recorded boundary without polling, advancing or publishing transport controls.
## Call recover() first when confirmation or correction lags. Returns the driver's first failed callback metadata.
func capture_replay_boundary() -> Driver.StepResult:
	var before: int = status().current_frame
	if _expert_mode:
		return _result(Types.Code.BUSY if _has_mutation_guard() else Types.Code.UNSUPPORTED, before, before)
	if _has_mutation_guard():
		return _result(Types.Code.BUSY, before, before)
	if _core == null:
		return _result(Types.Code.NOT_CONFIGURED, before, before)
	if _core.status().lifecycle == Types.Lifecycle.TERMINATED:
		return _result(Types.Code.TERMINATED, before, before)
	if not _running():
		return _result(Types.Code.NOT_SYNCHRONIZED, before, before)
	var shared_gate: int = _core._mutation_code()
	if shared_gate != Types.Code.OK:
		return _result(shared_gate, before, before)
	if _barrier_pending():
		return _result(Types.Code.PREDICTION_STALL, before, before)
	_busy = true
	var captured: Driver.StepResult = _driver.capture_replay_boundary()
	if _core.status().lifecycle == Types.Lifecycle.TERMINATED:
		_remember_diagnostic()
	return _notify_completed(captured)


func _notify_completed(result: Driver.StepResult) -> Driver.StepResult:
	if result.code == Types.Code.BUSY:
		return result
	_busy = true
	_core._begin_driver_notification()
	step_completed.emit(result.code, result.frame_before, result.frame_after)
	_core._end_driver_notification()
	var completed: Types.Status = _core.status()
	result.reason = completed.reason
	result.failure_frame = completed.failure_frame
	result.failure_kind = completed.failure_kind
	if completed.lifecycle == Types.Lifecycle.TERMINATED:
		_terminate_links()
	_busy = false
	return result


## Open ordered SAVE/LOAD/ADVANCE requests after ordinary input publication and peer controls.
## READY owns the peer until every request is acknowledged or close() cancels the batch.
## Like step(), accepts omitted slots only when their current samples are already staged.
func begin_step(now_us: Variant, local_inputs: Variant) -> Types.Result:
	return _begin_manual(now_us, local_inputs, 0)


## Correct and finalize history without another local sample or forward frame.
func begin_recovery(now_us: Variant) -> Types.Result:
	return _begin_manual(now_us, [], 1)


## Open a SAVE-only batch for the finalized recorded boundary, without polling or network publication.
func begin_capture_replay_boundary() -> Types.Result:
	return _begin_manual(_now, [], 2)


func _begin_manual(now_us: Variant, local_inputs: Variant, operation: int) -> Types.Result:
	if not _expert_mode:
		return Types.Result.new(Types.Code.UNSUPPORTED if _core != null else Types.Code.NOT_CONFIGURED)
	if _has_mutation_guard():
		return Types.Result.new(Types.Code.BUSY)
	_manual_before = status().current_frame
	_manual_operation = operation
	var opened: Types.Result
	if operation == 2:
		if _core.status().lifecycle == Types.Lifecycle.TERMINATED:
			return Types.Result.new(Types.Code.TERMINATED)
		if not _running():
			return Types.Result.new(Types.Code.NOT_SYNCHRONIZED)
		var shared_gate: int = _core._mutation_code()
		if shared_gate != Types.Code.OK:
			return Types.Result.new(shared_gate)
		if _barrier_pending():
			return Types.Result.new(Types.Code.PREDICTION_STALL)
		_busy = true
		opened = _core.begin_capture_replay_boundary()
	else:
		opened = _prepare_step(now_us, local_inputs) if operation == 0 else _prepare_recovery(now_us)
	if opened.code == Types.Code.READY:
		_manual_batch = opened.batch
		_manual_identity = _core._batch_id
		return Types.Result.new(Types.Code.READY, ExpertBatch.new(self, _manual_identity))
	var result: Driver.StepResult = _result(opened.code, _manual_before, status().current_frame)
	if _busy and operation != 2:
		result = _finish_requests(result, operation == 0)
	_notify_completed(result)
	return Types.Result.new(result.code)


## READY means another ordered request remains; STALE_REQUEST and BUSY leave the active request unchanged.
## The final result and notification include peer controls and first-cause failure diagnostics.
func complete_request(batch_id: int, request_id: int, callback_ok: bool, checksum: PackedByteArray = PackedByteArray()) -> Driver.StepResult:
	var before: int = status().current_frame
	if _core == null:
		return _result(Types.Code.NOT_CONFIGURED, before, before)
	if not _expert_mode:
		return _result(Types.Code.UNSUPPORTED, before, before)
	if _core._has_driver_guard():
		return _result(Types.Code.BUSY, before, before)
	if _manual_batch == null:
		return _result(Types.Code.STALE_REQUEST, before, before)
	var completed: Types.Result = _core.complete_request(batch_id, request_id, callback_ok, checksum)
	if completed.code == Types.Code.STALE_REQUEST:
		return _result(completed.code, _manual_before, before)
	if _core._batch != null:
		return _result(Types.Code.READY, _manual_before, before)
	return _finish_manual(completed.code)


func _next_manual_request(identity: int) -> Types.Request:
	if _manual_batch == null or identity != _manual_identity or _core._has_driver_guard():
		return null
	var request: Types.Request = _manual_batch.next_request()
	if request == null:
		_finish_manual(_core.status().reason)
	return request


func _finish_manual(code: int) -> Driver.StepResult:
	_manual_batch = null
	var result: Driver.StepResult = _result(code, _manual_before, status().current_frame)
	if _manual_operation != 2:
		result = _finish_requests(result, _manual_operation == 0)
	return _notify_completed(result)


func _recover(now_us: Variant) -> Driver.StepResult:
	if _expert_mode:
		return _result(Types.Code.BUSY if _has_mutation_guard() else Types.Code.UNSUPPORTED, status().current_frame, status().current_frame)
	var before: int = status().current_frame
	return _consume_prepared(_prepare_recovery(now_us), before, false)


func _step(now_us: Variant, local_inputs: Variant) -> Driver.StepResult:
	if _expert_mode:
		return _result(Types.Code.BUSY if _has_mutation_guard() else Types.Code.UNSUPPORTED, status().current_frame, status().current_frame)
	var before: int = status().current_frame
	return _consume_prepared(_prepare_step(now_us, local_inputs), before, true)


func _begin_core_requests(now_us: int, forward: bool) -> Types.Result:
	var polled: Types.Result = _core.poll(now_us)
	if polled.code != Types.Code.OK:
		return polled
	return _core.begin_advance() if forward else _core.begin_recovery()


func _consume_prepared(opened: Types.Result, before: int, forward: bool) -> Driver.StepResult:
	if opened.code == Types.Code.BUSY or not _busy:
		return _result(opened.code, before, before)
	var result: Driver.StepResult = _driver._consume_prepared_requests(opened, before)
	return _finish_requests(result, forward)


func _finish_requests(result: Driver.StepResult, forward: bool) -> Driver.StepResult:
	if result.code == Types.Code.OK or (forward and result.code == Types.Code.PREDICTION_STALL):
		_checksum_confirmation = _core.status().confirmed_frame
	_busy = false
	_service_controls(_now, false)
	if _core.status().lifecycle == Types.Lifecycle.TERMINATED:
		return _result(_core.status().reason, result.frame_before, _core.status().current_frame)
	return result


func _prepare_recovery(now_us: Variant) -> Types.Result:
	var gate: int = _gate(now_us)
	if gate != I.Code.OK:
		return Types.Result.new(_step_code(gate))
	if not _running():
		return Types.Result.new(Types.Code.NOT_SYNCHRONIZED)
	var limit: int = _core._check_advance_limits()
	if limit != Types.Code.OK:
		if limit == Types.Code.FRAME_EXHAUSTED:
			_now = now_us
			_terminate_links()
		return Types.Result.new(limit)
	var polled: int = _poll(now_us, [], [], true)
	if polled != I.Code.OK:
		return Types.Result.new(_step_failure(polled))
	var control_code: int = _service_controls(now_us, true)
	if control_code != I.Code.OK:
		return Types.Result.new(_step_failure(control_code))
	_busy = true
	return _begin_core_requests(now_us, false)


## Every endpoint retains the scheduled sample before requests become available.
func _prepare_step(now_us: Variant, local_inputs: Variant) -> Types.Result:
	var before: int = status().current_frame
	var gate: int = _gate(now_us)
	if gate != I.Code.OK:
		return Types.Result.new(_step_code(gate))
	if not _running():
		return Types.Result.new(Types.Code.NOT_SYNCHRONIZED)
	var limit: int = _core._check_advance_limits()
	if limit != Types.Code.OK:
		if limit == Types.Code.FRAME_EXHAUSTED:
			_now = now_us
			_terminate_links()
		return Types.Result.new(limit)
	var code: int = _samples_code(local_inputs, before)
	if code != Types.Code.OK:
		return Types.Result.new(code)
	_now = now_us
	var polled: int = _poll(now_us, [])
	if polled != I.Code.OK:
		return Types.Result.new(_step_failure(polled))
	var control_code: int = _service_controls(now_us, true)
	if control_code != I.Code.OK:
		return Types.Result.new(_step_failure(control_code))
	if _barrier_pending():
		# The coordinated drop holds the match until the survivors agree the frozen frame.
		return Types.Result.new(Types.Code.PREDICTION_STALL)
	_busy = true
	for sample: Driver.LocalInput in local_inputs:
		var result: Types.Result = _core.submit_local_input(sample.player, sample.sample_frame, sample.bytes)
		if result.code != Types.Code.OK:
			_busy = false
			return Types.Result.new(result.code)
	var scheduled: int = _core.scheduled_local_input(_config.local_players[0]).frame
	var data: PackedByteArray = PackedByteArray()
	for player: int in _config.local_players:
		data.append_array(_core.scheduled_local_input(player).bytes)
	var statuses: Array[T.Status] = _statuses()
	for index: int in range(_ids.size()):
		if _is_gone(index):
			continue
		var endpoint: Endpoint = _endpoint(index)
		if endpoint._last_submitted_frame() == scheduled:
			continue
		var sent: int = endpoint.submit(scheduled, data, statuses, now_us)
		if sent != I.Code.OK:
			_busy = false
			_collect_events()
			_check_failure()
			return Types.Result.new(_step_failure(sent))
	code = _confirmation_code()
	if code != Types.Code.OK:
		_busy = false
		return Types.Result.new(code)
	_now = now_us
	return _begin_core_requests(now_us, true)


func status() -> Types.Status:
	return _core.status() if _core != null else Types.Status.new()


## Shared expert-engine counters. Returned values belong to the caller.
func statistics() -> Types.Statistics:
	return _core.statistics() if _core != null else Types.Statistics.new()


## Confirmed frames recorded so far; null unless config.replay_max_frames > 0.
func replay() -> RefCounted:
	return _core.replay() if _core != null else null


## Owned finalized inputs for a simulated, mesh-confirmed frame; null while unavailable or under correction.
## Read before queue history wraps. Rows remain owned across later steps and completion notifications.
func confirmed_inputs(frame: int) -> Types.FrameInputs:
	return _core.confirmed_inputs(frame) if _core != null else null


## Owned sample staged for the current frame, including during prediction or network pressure.
## Its frame includes input delay. Retry step with status().current_frame as LocalInput.sample_frame.
## MISSING_LOCAL_INPUT means the slot needs a new sample; successful advancement releases staged samples.
func scheduled_local_input(player: int) -> Types.InputResult:
	if _core == null:
		var result: Types.InputResult = Types.InputResult.new()
		result.code = Types.Code.NOT_CONFIGURED
		return result
	return _core.scheduled_local_input(player)


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
	if _has_mutation_guard():
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
	# Every endpoint must be able to take the whole batch before the core changes, so a refused
	# raise leaves the match running instead of ending it.
	var starts: PackedInt64Array = PackedInt64Array()
	var earliest: int = -1
	var added: int = delay - current
	for index: int in range(_ids.size()):
		if _is_gone(index):
			# A departed peer receives no more frames.
			starts.append(-1)
			continue
		var observed: Dictionary = _endpoint(index).status()
		var start: int = observed.last_submitted_frame + 1 if observed.last_submitted_frame != -1 else _config.input_delay
		var accepted: int = _endpoint(index).can_submit_frames(start, last + added - start + 1)
		if accepted != I.Code.OK:
			# The endpoint cannot take the added frames yet, so the raise waits for a later attempt.
			# Every refusal is retryable: the match keeps running and the delay stays unchanged.
			return Types.Code.NETWORK_BACKPRESSURE
		starts.append(start)
		earliest = start if earliest == -1 else mini(earliest, start)
	# The catch-up frames are the local queue's retained rows. A released row cannot be rebuilt,
	# so the raise is refused before the core changes and the match keeps running.
	var rows: Array[PackedByteArray] = []
	if earliest != -1:
		for frame: int in range(earliest, last + 1):
			var retained: PackedByteArray = _core.retained_local_input(player, frame)
			if retained.is_empty():
				return Types.Code.NETWORK_BACKPRESSURE
			rows.append(retained)
	var changed: Types.Result = _core.set_input_delay(player, delay)
	if changed.code != Types.Code.OK:
		return changed.code
	# The added frames repeat the player's latest input, and the queue holds them now.
	var fresh: Array[PackedByteArray] = []
	for frame: int in range(last + 1, changed.value + 1):
		fresh.append(_core.retained_local_input(player, frame))
	var statuses: Array[T.Status] = _statuses()
	for index: int in range(_ids.size()):
		if _is_gone(index):
			continue
		var inputs: Array[PackedByteArray] = []
		if starts[index] <= last:
			inputs.append_array(rows.slice(starts[index] - earliest, rows.size()))
		inputs.append_array(fresh)
		# One packet per remote carries the catch-up and added frames, as upstream flushes once.
		var sent: int = _endpoint(index).submit_frames(starts[index], inputs, statuses, _now, last)
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
		if _is_dropped(index):
			row["dropped"] = true
			row["freeze_frame"] = _drops.freeze_frame(_ids[index].hex_encode())
		elif _is_gone(index):
			row["departed"] = true
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
	if _has_mutation_guard():
		return result
	for index: int in range(_ids.size()):
		for bytes: PackedByteArray in _endpoint(index).drain_outbox():
			result.append(Packet.new(_ids[index], bytes))
	return result


func drain_events() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if _has_mutation_guard():
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
	var pending: bool = _manual_batch != null and not _core._has_driver_guard()
	if pending:
		_busy = false
	var code: int = _gate(now_us)
	if pending:
		_busy = true
	if code != I.Code.OK:
		return code
	if typeof(reason) != TYPE_INT or reason < 0 or reason > 255:
		return I.Code.INVALID_ARGUMENT
	_now = now_us
	for index: int in range(_ids.size()):
		if _is_gone(index):
			# A departed peer holds no open link.
			continue
		var closed: int = _endpoint(index).close(now_us, reason)
		if closed != I.Code.OK:
			code = closed
	_collect_events(true)
	_core.terminate(Types.Code.TERMINATED)
	_manual_batch = null
	_busy = false
	_terminate_links()
	return code


func drain_transitions() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if _has_mutation_guard():
		return result
	for index: int in range(_ids.size()):
		for transition: Dictionary in _endpoint(index).drain_transitions():
			transition["peer"] = _ids[index].duplicate()
			result.append(transition)
	return result


func _endpoint(index: int) -> Endpoint:
	return _peers[_ids[index].hex_encode()]


## The connected era of one peer: the first two bytes of its connection identity.
## A peer that connects again with a new connection identity starts a new era.
## The local peer uses index -1.
func _era(index: int) -> int:
	var connection: String = _local_connection.hex_encode()
	if index >= 0:
		connection = str(_endpoint(index).status().get("remote_connection", ""))
	if connection.length() < 4:
		return 0
	return connection.substr(0, 4).hex_to_int()


func _has_mutation_guard() -> bool:
	return _busy or (_core != null and _core._has_driver_guard())


func _gate(now_us: Variant) -> int:
	if _has_mutation_guard():
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
	var sender_index: int = _ids.find(attributed_sender)
	if sender_index != -1 and _is_dropped(sender_index):
		# A departed peer's late packets no longer change the match.
		return I.Code.OK
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


func _poll(now_us: int, tokens: Array, statuses: Array[T.Status] = [], force_status_gossip: bool = false) -> int:
	_now = now_us
	if statuses.is_empty():
		statuses = _statuses()
	var status_nudge: bool = force_status_gossip or _gossip_nudge_needed()
	var result: int = I.Code.OK
	for index: int in range(_ids.size()):
		if _is_gone(index):
			continue
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
	for index: int in range(_ids.size()):
		if _is_gone(index):
			# A departed peer no longer holds the match.
			continue
		if not _endpoint(index)._is_running():
			return false
	return true


func _samples_code(samples: Variant, frame: int) -> int:
	if not samples is Array or samples.size() > _config.local_players.size():
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
	for player: int in _config.local_players:
		if not seen.has(player) and _core.scheduled_local_input(player).code != Types.Code.OK:
			return Types.Code.MISSING_LOCAL_INPUT
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
	var receipt_fold: int = Queue.FRAME_MAX
	for slot: int in range(receipts.size()):
		if _core.frozen_frame(slot) != -1:
			# A dropped slot no longer holds the gossip refresh back.
			continue
		receipt_fold = mini(receipt_fold, receipts[slot])
	return observed.confirmed_frame < receipt_fold


func _confirmation_code() -> int:
	var active: Array[Endpoint] = []
	for index: int in range(_ids.size()):
		if not _is_gone(index):
			active.append(_endpoint(index))
	var frames: PackedInt64Array = _core.received_frames()
	# The fold starts above every slot, so a frozen slot cannot cap the frontier through
	# the seed value of the first slot.
	var limit: int = Queue.FRAME_MAX
	for slot: int in range(frames.size()):
		if _core.frozen_frame(slot) != -1:
			# A dropped slot no longer holds the mesh frontier back.
			continue
		var bound: int = frames[slot]
		if not _config.local_players.has(slot):
			for endpoint: Endpoint in active:
				bound = mini(bound, endpoint._peer_received_frame(slot))
		limit = mini(limit, bound)
	if limit == Queue.FRAME_MAX:
		# Every slot is frozen, so the frontier cannot move.
		return Types.Code.OK
	limit = mini(limit, _drops.confirmation_ceiling())
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
	for index: int in range(_ids.size()):
		if _is_gone(index):
			# A departed peer is no longer a failure of the match.
			continue
		if _endpoint(index)._has_failed():
			_core.terminate(Types.Code.PROTOCOL_FAILED)
	if _core.status().lifecycle == Types.Lifecycle.TERMINATED:
		_remember_diagnostic()


## Step result with the core session's terminal cause and failed callback metadata attached.
func _result(code: int, before: int, after: int) -> Driver.StepResult:
	var result: Driver.StepResult = Driver.StepResult.new(code, before, after)
	var status: Types.Status = _core.status() if _core != null else Types.Status.new()
	result.reason = status.reason
	result.failure_frame = status.failure_frame
	result.failure_kind = status.failure_kind
	return result


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
			if event.kind == "disconnected" and not local_close:
				# The departed peer keeps its own event; the survivors either freeze it or stop.
				if _core.status().lifecycle != Types.Lifecycle.TERMINATED:
					_drop_peer(index)
				_publish_event(event)
				continue
			if event.kind == "drop_barrier":
				# A survivor answers the coordinated drop of a departed peer.
				if _core.status().lifecycle != Types.Lifecycle.TERMINATED:
					_drops.received(self, index, event)
				continue
			if event.kind == "event_capacity_exceeded":
				_core.terminate(Types.Code.PROTOCOL_FAILED)
			_publish_event(event)
	if _core.status().lifecycle == Types.Lifecycle.TERMINATED:
		_terminate_links()


## The coordinated drop of a departed peer owns the agreement state.
## The peer session keeps the transport, the simulation and the publication.
func _drop_peer(index: int) -> bool:
	return _drops.observed(self, index)


## A pending coordinated drop holds the match until the survivors agree the frozen frame.
func _barrier_pending() -> bool:
	return _drops.pending()


func _is_dropped(index: int) -> bool:
	return _drops.is_dropped(_ids[index].hex_encode())


## A departed peer is gone from the match; a dropped peer is gone and frozen.
func _is_gone(index: int) -> bool:
	return _drops.is_gone(_ids[index].hex_encode())


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
	_drops.service(self, now_us)
	if _core.status().lifecycle == Types.Lifecycle.TERMINATED:
		_terminate_links()
		return I.Code.TERMINATED
	var current: int = _core.status().current_frame
	if send_reports:
		_frames_ahead = -2147483648
	for index: int in range(_ids.size()):
		if _is_gone(index):
			continue
		if send_reports:
			_frames_ahead = maxi(_frames_ahead, _endpoint(index)._average_frame_advantage())
	if send_reports and current > _next_wait and _frames_ahead >= 3:
		_next_wait = current + 60
		_publish_event({"kind": "wait_recommendation", "skip_frames": _frames_ahead})
		if _core.status().lifecycle == Types.Lifecycle.TERMINATED:
			_terminate_links()
			return I.Code.TERMINATED
	if send_reports and _publish_delay_recommendation():
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
				if _is_gone(index):
					continue
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


## Returns true when publication overflowed the event queue and ended the match.
func _publish_delay_recommendation() -> bool:
	var player: int = _config.local_players[0]
	var round_trip_ms: int = 0
	for index: int in range(_ids.size()):
		if _is_gone(index):
			# A departed peer has no live round trip time.
			continue
		round_trip_ms = maxi(round_trip_ms, _endpoint(index)._round_trip_time_ms())
	var current: int = _core.input_delay(player)
	# set_input_delay needs a prior sample, so none is suggested before one.
	var local_count: int = _config.local_players.size() if _core.received_frames()[player] != -1 else 0
	var suggested: int = _advisor.observe(local_count, current, max_input_delay(_config), round_trip_ms, _fps)
	if suggested == -1:
		return false
	_publish_event({"kind": "input_delay_recommendation", "player": player, "current_delay": current, "suggested_delay": suggested, "round_trip_time_ms": round_trip_ms})
	return _core.status().lifecycle == Types.Lifecycle.TERMINATED


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
