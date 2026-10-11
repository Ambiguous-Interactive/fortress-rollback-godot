class_name FortressPeerSession
extends RefCounted

# gdlint: disable=max-returns
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const H = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const V = preload("res://addons/fortress_rollback/protocol/protocol_validation.gd")
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


## Caller supplies transport identity, clock, tokens and game callbacks.
func configure(config: Variant, local: Variant, game: Variant, handshake_options: Variant, input_options: Variant) -> int:
	if _busy:
		return I.Code.BUSY
	if _core != null:
		return I.Code.WRONG_STATE
	if not config is Config or config.validate() != Types.Code.OK or config.sync_test:
		return I.Code.INVALID_ARGUMENT
	if not local is T.Message or not V.config(local.config) or not game is RefCounted:
		return I.Code.INVALID_ARGUMENT
	if not handshake_options is H.Options or not input_options is I.Options:
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
	if remotes.size() > 1 and (config.max_prediction_frames == 0 or (config.max_prediction_frames == 1 and config.input_delay == 0)):
		return I.Code.INVALID_ARGUMENT
	var core: Session = Session.new()
	if core.configure(config) != Types.Code.OK or core.set_confirmation_limit(-1).code != Types.Code.OK:
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
		var code: int = endpoint.configure(local, remotes[key], handshake_options, input_options, _accept_remote.bind(slots))
		if code != I.Code.OK:
			return code
		peers[key] = endpoint
	_core = core
	_driver = driver
	_config = config.owned_copy()
	_config.local_players = locals
	_peers = peers
	for key: String in keys:
		_ids.append(remotes[key].duplicate())
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


## Every endpoint retains the scheduled sample before the game can advance.
func step(now_us: Variant, local_inputs: Variant) -> Driver.StepResult:
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
			_check_failure()
			return Driver.StepResult.new(_step_code(sent), before, before)
	code = _confirmation_code()
	if code != Types.Code.OK:
		_busy = false
		return Driver.StepResult.new(code, before, before)
	_now = now_us
	var empty: Array[Driver.LocalInput] = []
	var advanced: Driver.StepResult = _driver.step(now_us, empty)
	_busy = false
	return advanced


func status() -> Types.Status:
	return _core.status() if _core != null else Types.Status.new()


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
	return {"state": state, "peers": peers, "last_now_us": _now}


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
	for index: int in range(_ids.size()):
		for event: Dictionary in _endpoint(index).drain_events():
			event["peer"] = _ids[index].duplicate()
			result.append(event)
	return result


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
	_now = now_us
	_busy = true
	var code: int = endpoint.receive(packet, attributed_sender, now_us, next_token)
	_busy = false
	if code == I.Code.OK:
		_now = now_us
	_check_failure()
	if _running() and _core.status().lifecycle != Types.Lifecycle.TERMINATED:
		_confirmation_code()
	return code


func _poll(now_us: int, tokens: Array, statuses: Array[T.Status] = []) -> int:
	_now = now_us
	if statuses.is_empty():
		statuses = _statuses()
	for index: int in range(_ids.size()):
		var code: int = _endpoint(index).poll(now_us, null if tokens.is_empty() else tokens[index], statuses)
		if code != I.Code.OK:
			_check_failure()
			return code
	_now = now_us
	_check_failure()
	if _running() and _core.status().lifecycle != Types.Lifecycle.TERMINATED:
		_confirmation_code()
	return I.Code.OK


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
