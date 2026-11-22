class_name FortressOnlineMatch
extends RefCounted

const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Protocol = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const Handshake = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const Inputs = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const Membership = preload("res://addons/fortress_rollback/transport/signalfish_membership.gd")
const Adapter = preload("res://addons/fortress_rollback/transport/signalfish_adapter.gd")
const Direct = preload("res://addons/fortress_rollback/transport/signalfish_webrtc.gd")
const Relay = preload("res://addons/fortress_rollback/transport/signalfish_relay.gd")
const Fallback = preload("res://addons/fortress_rollback/transport/signalfish_fallback.gd")
const RelayTypes = preload("res://addons/fortress_rollback/transport/signalfish_relay_types.gd")
const Simulation = preload("res://examples/offline/simulation.gd")

## Largest packet the transports carry. Input batches are sized to fit it.
const PACKET_BYTES: int = 1024
const NATIVE_TAG_BYTES: int = 16
# One local slot per room participant fits the direct route's datagram budget.
const NATIVE_PACKET_BYTES: int = 1200
## Frames a suggestion stays on offer. Latency can recover, and a raise cannot be undone.
const SUGGESTION_FRAMES: int = 600
const REPLAY_FRAMES: int = 36000
## Bounded service rounds per tick. The batch stops early once the transport is idle.
const SERVICE_ROUNDS: int = 8

var game: Simulation = Simulation.new()
var peer: Peer = Peer.new()
var driver: Driver = Driver.new()
var membership: Membership = Membership.new()
var adapter: Adapter = Adapter.new()
var direct: Direct = Direct.new()
var relay: Relay = Relay.new()
var fallback: Fallback = Fallback.new()
var local_slot: int = -1
var failure: String = ""
var latest_event: String = "none"
var stalls: int = 0

## Latest measured delay suggestion for this player, or -1 when there is none to apply.
var suggested_delay: int = -1
## Frame the suggestion arrived on.
var suggested_frame: int = 0
var has_started: bool = false
## Choose before freeze. Captures local canonical state and inputs for diagnostic export.
var capture_trace: bool = false
## Choose before freeze. Retains the first ten minutes of confirmed gameplay at 60 Hz.
var record_replay: bool = false
var has_recorded_replay: bool = false
## Finishing stops local sampling while transport and correction settle the recorded boundary.
var replay_finishing: bool = false
var replay_captured: bool = false
var replay_capture_code: int = Types.Code.NOT_CONFIGURED
var _held: int = -1
var _tokens: int = 0
var _pending: Array[Peer.Packet] = []
var _last_now: int = -1
var _is_servicing: bool = false
var _revision: int = 0
var _native_identity: PackedByteArray
var _native_relay_only: bool = false
var _native_sync_deadline: int = -1


func status() -> Types.Status:
	return driver.status() if driver.uses_native_backend() else peer.status()


## New rooms and sorted full UUID rosters define a fresh application match.
## Domain separation includes the game/config revision; same-room restarts are refused.
static func session_identity(room_id: String, roster: PackedStringArray, native_name: String = "") -> PackedByteArray:
	if not Membership.valid_uuid(room_id) or roster.size() < 2 or roster.size() > 8 or (native_name.is_empty() and roster.size() != 2):
		return PackedByteArray()
	var sorted: PackedStringArray = roster.duplicate()
	sorted.sort()
	for index: int in sorted.size():
		if not Membership.valid_uuid(sorted[index]) or (index > 0 and sorted[index - 1] == sorted[index]):
			return PackedByteArray()
	var profile: String = "fortress-online-integer-v1|delay2|width1|players2" if native_name.is_empty() else native_name
	return (profile + "|" + room_id + "|" + "|".join(sorted)).sha256_buffer().slice(0, NATIVE_TAG_BYTES)


func freeze(client: Object, mesh: Object, roster: PackedStringArray, incarnation: PackedByteArray) -> Error:
	return _freeze_room(client, mesh, roster, incarnation, "")


func freeze_native(client: Object, mesh: Object, roster: PackedStringArray, incarnation: PackedByteArray, native_name: String) -> Error:
	if native_name.is_empty():
		return ERR_INVALID_PARAMETER
	return _freeze_room(client, mesh, roster, incarnation, native_name)


func _freeze_room(client: Object, mesh: Object, roster: PackedStringArray, incarnation: PackedByteArray, native_name: String) -> Error:
	if _is_busy():
		return ERR_BUSY
	_is_servicing = true
	var revision: int = _revision
	var code: Error = _freeze(client, mesh, roster, incarnation, revision, native_name)
	if revision != _revision:
		detach()
		code = ERR_UNAVAILABLE
	_is_servicing = false
	return code


func _freeze(client: Object, mesh: Object, roster: PackedStringArray, incarnation: PackedByteArray, revision: int, native_name: String) -> Error:
	var room: String = client.call("get_room_id")
	if revision != _revision:
		return ERR_UNAVAILABLE
	var session_id: PackedByteArray = session_identity(room, roster, native_name)
	if session_id.is_empty():
		return ERR_INVALID_DATA
	var profile: Protocol.Config = Protocol.Config.new()
	profile.player_count = roster.size()
	profile.input_width = 1 if native_name.is_empty() else Driver.Native.INPUT_BYTES
	profile.neutral_input.resize(profile.input_width)
	profile.input_delay = 2 if native_name.is_empty() else 0
	profile.desync_interval = 30 if native_name.is_empty() else 0
	var player: String = client.call("get_player_id")
	if revision != _revision:
		return ERR_UNAVAILABLE
	var code: Error = membership.configure(player, roster, session_id, incarnation, profile)
	if code != OK:
		return code
	local_slot = membership.slot(membership.local_uuid())
	if not native_name.is_empty():
		var endpoints: PackedInt32Array = PackedInt32Array()
		for slot: int in roster.size():
			endpoints.append(0 if slot == local_slot else slot + 1)
		if driver.configure_native(endpoints, game, game.snapshot_bytes()) != Types.Code.OK:
			return ERR_INVALID_DATA
		_native_identity = session_id
		return adapter.attach(client, mesh, membership)
	var config: Config = Config.new()
	config.sync_test = false
	config.check_distance = 0
	config.input_delay = 2
	config.max_snapshot_bytes = Simulation.SNAPSHOT_BYTES
	config.diagnostic_seed = str(game.rng_state)
	config.diagnostic_version = "fortress-online-integer-v1"
	config.replay_max_frames = REPLAY_FRAMES if record_replay else 0
	if capture_trace:
		config.diagnostic_trace_frames = 120
		config.diagnostic_replay_command = "godot --headless --path . --script scripts/diagnose_trace.gd -- fortress-diagnostics.json"
	config.storage_budget_bytes = config.required_storage_bytes()
	var handshake: Handshake.Options = Handshake.Options.new()
	handshake.timeout_us = 30000000
	handshake.max_packet_bytes = PACKET_BYTES
	if membership.configure_peer(peer, config, game, handshake, Inputs.Options.new()) != Inputs.Code.OK:
		return ERR_INVALID_DATA
	return adapter.attach(client, mesh, membership)


func start_transport(client: Object, mesh: Object, sdk_config: Object, info: Object, now_us: int) -> Error:
	if _is_busy():
		return ERR_BUSY
	_is_servicing = true
	var revision: int = _revision
	var code: Error = _start_transport(client, mesh, sdk_config, info, now_us, revision)
	if revision != _revision:
		detach()
		code = ERR_UNAVAILABLE
	_is_servicing = false
	return code


func _start_transport(client: Object, mesh: Object, sdk_config: Object, info: Object, now_us: int, revision: int) -> Error:
	if has_started:
		return ERR_UNAVAILABLE
	var route: String = adapter.status().route
	if driver.uses_native_backend():
		return _start_native_transport(client, mesh, sdk_config, info, now_us, revision, route)
	if revision != _revision or route != "mesh":
		return ERR_UNAVAILABLE
	var options: Direct.Options = Direct.Options.new()
	options.max_packet_bytes = PACKET_BYTES
	if direct.configure(mesh, membership, adapter, peer, options) != Direct.Code.OK:
		return ERR_UNAVAILABLE
	if revision != _revision:
		return ERR_UNAVAILABLE
	var relay_options: Relay.Options = Relay.Options.new()
	relay_options.max_packet_bytes = PACKET_BYTES
	if relay.configure(client, sdk_config, info, membership, adapter, peer, relay_options) != Relay.Code.OK:
		return ERR_UNAVAILABLE
	if revision != _revision:
		return ERR_UNAVAILABLE
	if fallback.configure(direct, relay, membership, adapter, peer) != Fallback.Code.OK:
		return ERR_UNAVAILABLE
	if revision != _revision:
		return ERR_UNAVAILABLE
	if peer.begin(now_us, [next_token()]) != Inputs.Code.OK:
		return ERR_UNAVAILABLE
	if revision != _revision:
		return ERR_UNAVAILABLE
	has_started = true
	return OK


func _start_native_transport(client: Object, mesh: Object, sdk_config: Object, info: Object, now_us: int, revision: int, route: String) -> Error:
	if revision != _revision or route not in ["mesh", "relay"]:
		return ERR_UNAVAILABLE
	var relay_options: Relay.Options = Relay.Options.new()
	relay_options.max_packet_bytes = NATIVE_PACKET_BYTES
	if relay.configure(client, sdk_config, info, membership, adapter, null, relay_options, _receive_native) != Relay.Code.OK:
		return ERR_UNAVAILABLE
	_native_relay_only = route == "relay"
	if not _native_relay_only:
		var direct_options: Direct.Options = Direct.Options.new()
		direct_options.max_packet_bytes = NATIVE_PACKET_BYTES
		if direct.configure(mesh, membership, adapter, null, direct_options, _receive_native) != Direct.Code.OK:
			return ERR_UNAVAILABLE
		if fallback.configure(direct, relay, membership, adapter, null, null, _receive_native) != Fallback.Code.OK:
			return ERR_UNAVAILABLE
	if revision != _revision:
		return ERR_UNAVAILABLE
	_native_sync_deadline = now_us + 30000000
	has_started = true
	return OK


func _receive_native(uuid: String, bytes: PackedByteArray) -> int:
	var slot: int = membership.slot(uuid)
	if slot < 0 or slot == local_slot:
		return Inputs.Code.WRONG_SOURCE
	if bytes.size() <= NATIVE_TAG_BYTES or bytes.slice(0, NATIVE_TAG_BYTES) != _native_identity:
		return Inputs.Code.WRONG_CONNECTION
	if not driver.receive_native(slot + 1, bytes.slice(NATIVE_TAG_BYTES)):
		return Inputs.Code.WRONG_CONNECTION
	return Inputs.Code.OK


func _tick_native(now_us: int, buttons: int) -> void:
	if not _service_native(now_us):
		return
	var sample: PackedByteArray = PackedByteArray()
	if driver.scheduled_local_input(local_slot).code == Types.Code.MISSING_LOCAL_INPUT:
		sample.resize(Driver.Native.INPUT_BYTES)
		sample.encode_u32(0, buttons)
	var samples: Array[PackedByteArray] = [sample]
	var result: Driver.StepResult = driver.step_local(now_us, samples)
	if not has_started:
		return
	match result.code:
		Types.Code.OK:
			_native_sync_deadline = -1
		Types.Code.NOT_SYNCHRONIZED:
			if now_us >= _native_sync_deadline:
				failure = "Native rollback synchronization timed out."
		Types.Code.PREDICTION_STALL:
			stalls += 1
		_:
			var detail: String = driver.native_terminal_detail()
			failure = "Native match ended (%s)." % (Types.reason_text(result.code) if detail.is_empty() else detail)
	if failure.is_empty():
		latest_event = "interrupted" if not driver.native_interrupted_endpoints().is_empty() else ("synchronizing" if _native_sync_deadline >= 0 else "running")
		_service_native(now_us)


func _service_native(now_us: int) -> bool:
	if _pending.is_empty():
		var roster: PackedStringArray = membership.roster()
		for datagram: Dictionary in driver.drain_native_packets():
			var bytes: PackedByteArray = _native_identity + datagram.bytes
			_pending.append(Peer.Packet.new(membership.identity(roster[datagram.endpoint - 1]), bytes))
	for _index: int in mini(_pending.size(), SERVICE_ROUNDS):
		var batch: Array[Peer.Packet] = [_pending[0]]
		var code: int = relay.enqueue_batch(batch) if _native_relay_only else fallback.enqueue_batch(batch)
		if not has_started or code == Relay.Code.BACKPRESSURE:
			break
		if code != Relay.Code.OK:
			failure = _transport_stopped_text("Native transport queue stopped", code)
			return false
		_pending.pop_front()
	var result: Relay.Result = relay.poll(now_us) if _native_relay_only else fallback.poll(now_us)
	if not has_started:
		return false
	if result.code not in [Relay.Code.OK, Relay.Code.BACKPRESSURE]:
		failure = _transport_stopped_text("Native transport stopped", result.code)
		return false
	return true


func next_token(_remote_uuid: String = "") -> PackedByteArray:
	_tokens += 1
	var token: PackedByteArray = PackedByteArray()
	token.resize(16)
	token.encode_s64(0, _tokens)
	return token


## Service elapsed protocol deadlines before SDK callbacks, without receiving bytes or advancing gameplay.
func poll_protocol_time(now_us: int) -> bool:
	if _is_busy():
		return has_started and failure.is_empty()
	if not failure.is_empty() or not has_started:
		return false
	if now_us < 0 or now_us < _last_now:
		failure = "Invalid clock or input. Leave and create a new room."
		return false
	_last_now = now_us
	_is_servicing = true
	var healthy: bool = driver.uses_native_backend() or _poll_protocol(now_us)
	_is_servicing = false
	return healthy


## Conflicting retained local input leaves clocks and service unchanged; retry the original buttons.
func tick(now_us: int, buttons: int) -> void:
	if _is_busy():
		return
	_is_servicing = true
	_tick(now_us, buttons)
	_is_servicing = false


func _tick(now_us: int, buttons: int) -> void:
	if not failure.is_empty() or not has_started:
		return
	if now_us < 0 or now_us < _last_now or buttons < 0 or buttons > 15:
		failure = "Invalid clock or input. Leave and create a new room."
		return
	if _local_input_code(buttons) == Types.Code.INPUT_ALREADY_SUBMITTED:
		return
	_last_now = now_us
	if driver.uses_native_backend():
		_tick_native(now_us, buttons)
		return
	for _batch: int in SERVICE_ROUNDS:
		if not _poll_protocol(now_us):
			break
		if not _service(now_us):
			break
		# An idle route has nothing to deliver, send or wait for. Stop early and
		# leave the rest of the frame's budget to the browser and the game.
		if _pending.is_empty() and fallback.idle():
			break
	if not has_started:
		return
	if failure.is_empty() and replay_finishing:
		_finish_replay_boundary(now_us)
	elif failure.is_empty() and peer.network_status().state == "running":
		if _held < 0:
			_held = buttons
		var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(local_slot, peer.status().current_frame, PackedByteArray([_held]))]
		var result: Driver.StepResult = peer.step(now_us, samples)
		if not has_started:
			return
		if result.code == Types.Code.OK:
			_held = -1
			has_recorded_replay = has_recorded_replay or (record_replay and peer.status().current_frame > 0 and peer.status().confirmed_frame >= 0)
		elif result.code in [Types.Code.PREDICTION_STALL, Types.Code.NETWORK_BACKPRESSURE]:
			stalls += 1
		else:
			failure = "Game stopped: %s (code %d). Leave and create a new room." % [Types.reason_text(result.code), result.code]
		if failure.is_empty():
			_service(now_us)
	if has_started:
		_collect_events()


func _local_input_code(buttons: int) -> int:
	if driver.uses_native_backend() or not has_started or not failure.is_empty() or replay_finishing or buttons < 0 or buttons > 15:
		return Types.Code.OK
	var code: int = peer._core._check_advance_limits()
	if code != Types.Code.OK:
		return code
	var candidate: int = _held if _held >= 0 else buttons
	return peer._core.validate_local_input(local_slot, peer.status().current_frame, PackedByteArray([candidate]))


## Stop local gameplay and request final-state evidence while game callbacks remain legal.
## Keep ticking until replay_captured or a non-retryable replay_capture_code; ordinary exports remain available.
func finish_replay() -> int:
	if _is_busy():
		return Types.Code.BUSY
	if not has_started or not failure.is_empty():
		return Types.Code.NOT_SYNCHRONIZED
	if driver.uses_native_backend() or not record_replay:
		return Types.Code.UNSUPPORTED
	if replay_finishing:
		return Types.Code.OK
	replay_finishing = true
	replay_capture_code = Types.Code.PREDICTION_STALL
	return Types.Code.OK


func _finish_replay_boundary(now_us: int) -> void:
	if replay_captured or replay_capture_code not in [Types.Code.PREDICTION_STALL, Types.Code.NETWORK_BACKPRESSURE]:
		return
	var recovered: Driver.StepResult = peer.recover(now_us)
	if not has_started:
		return
	replay_capture_code = recovered.code
	if recovered.code == Types.Code.OK:
		replay_capture_code = peer.capture_replay_boundary().code
		if not has_started:
			return
		replay_captured = replay_capture_code == Types.Code.OK
		has_recorded_replay = has_recorded_replay or replay_captured or (peer.replay() != null and peer.replay().frame_count() > 0)
	if peer.status().lifecycle == Types.Lifecycle.TERMINATED:
		failure = "Final replay state could not be captured: %s (code %d). Download the available replay before leaving." % [
			Types.reason_text(peer.status().reason), peer.status().reason]
	if failure.is_empty():
		_service(now_us)


## Delay this player's input by one more frame; the other player receives the added frames as ordinary input.
func raise_input_delay() -> int:
	if _is_busy() or replay_finishing:
		return Types.Code.BUSY
	if not has_started or local_slot < 0:
		return Types.Code.NOT_SYNCHRONIZED
	if driver.uses_native_backend():
		return Types.Code.UNSUPPORTED
	return peer.set_input_delay(local_slot, peer.input_delay(local_slot) + 1)


## Apply the latest suggestion. The library only suggests; the game chooses whether to raise.
func apply_suggested_delay() -> int:
	if _is_busy() or replay_finishing:
		return Types.Code.BUSY
	if suggested_delay < 0:
		return Types.Code.INVALID_CONFIGURATION
	var code: int = peer.set_input_delay(local_slot, suggested_delay)
	if code == Types.Code.OK:
		suggested_delay = -1
	return code


func _poll_protocol(now_us: int) -> bool:
	for _attempt: int in 2:
		var code: int = peer.poll(now_us, [next_token()])
		if not has_started:
			return false
		if code not in [Inputs.Code.OK, Inputs.Code.BACKPRESSURE]:
			failure = _protocol_stopped_text(code)
			return false
		_collect_events()
		if not failure.is_empty():
			return false
		if code == Inputs.Code.OK:
			return true
	# A second poll uses the diagnostic space just freed, before buffered receive.
	return true


func _collect_events() -> void:
	for event: Dictionary in peer.drain_events():
		if event.kind != "inputs_received":
			latest_event = event.kind
		if event.kind == "input_delay_recommendation":
			suggested_delay = event.suggested_delay
			suggested_frame = peer.status().current_frame
		if event.kind in ["sync_timeout", "incompatible"] and failure.is_empty():
			failure = "Rollback synchronization failed (%s). Leave and create a new room." % event.kind
	peer.drain_transitions()
	if suggested_delay <= peer.input_delay(local_slot) or peer.status().current_frame - suggested_frame > SUGGESTION_FRAMES:
		suggested_delay = -1
	if peer.status().lifecycle == Types.Lifecycle.TERMINATED and failure.is_empty():
		failure = "Session ended: %s (code %d). Leave and create a new room." % [Types.reason_text(peer.status().reason), peer.status().reason]


func _service(now_us: int) -> bool:
	if _pending.is_empty():
		_pending = peer.drain_outbox()
	if not _pending.is_empty():
		var accepted: int = fallback.enqueue_batch(_pending)
		if not has_started:
			return false
		if accepted == Fallback.Code.OK:
			_pending.clear()
		elif accepted != Fallback.Code.BACKPRESSURE:
			failure = _transport_stopped_text("Transport queue stopped", accepted)
			return false
	var result: Fallback.Result = fallback.poll(now_us, next_token)
	if not has_started:
		return false
	if result.code not in [Fallback.Code.OK, Fallback.Code.BACKPRESSURE]:
		failure = _transport_stopped_text("Transport stopped", result.code)
		return false
	return true


## Plain-language stop lines keep the numeric code beside the text for tooling
## parity; each enum space renders through its own shared helper.
func _protocol_stopped_text(code: int) -> String:
	return _stopped_text("Protocol stopped", Inputs.reason_text(code), code)


func _transport_stopped_text(prefix: String, code: int) -> String:
	return _stopped_text(prefix, RelayTypes.reason_text(code), code)


func _stopped_text(prefix: String, text: String, code: int) -> String:
	return "%s: %s (code %d). Leave and create a new room." % [prefix, text, code]


func detach() -> void:
	_revision += 1
	has_started = false
	if driver.uses_native_backend():
		driver.terminate()
	if peer._core != null:
		peer._core.terminate()
	fallback.detach()
	direct.detach()
	relay.detach()
	adapter.detach()
	_pending.clear()


func _is_busy() -> bool:
	return _is_servicing or peer._has_mutation_guard() or (peer._core != null and peer._core._mutation_code() == Types.Code.BUSY)
