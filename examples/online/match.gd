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
const Simulation = preload("res://examples/offline/simulation.gd")

## Largest packet the transports carry. Input batches are sized to fit it.
const PACKET_BYTES: int = 1024
## Frames a suggestion stays on offer. Latency can recover, and a raise cannot be undone.
const SUGGESTION_FRAMES: int = 600
const REPLAY_FRAMES: int = 36000
## Bounded service rounds per tick. The batch stops early once the transport is idle.
const SERVICE_ROUNDS: int = 8

var game: Simulation = Simulation.new()
var peer: Peer = Peer.new()
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


## New rooms and sorted full UUID rosters define a fresh application match.
## Domain separation includes the game/config revision; same-room restarts are refused.
static func session_identity(room_id: String, roster: PackedStringArray) -> PackedByteArray:
	if not Membership.valid_uuid(room_id) or roster.size() != 2:
		return PackedByteArray()
	var sorted: PackedStringArray = roster.duplicate()
	sorted.sort()
	if sorted[0] == sorted[1] or not Membership.valid_uuid(sorted[0]) or not Membership.valid_uuid(sorted[1]):
		return PackedByteArray()
	var hash: HashingContext = HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(("fortress-online-integer-v1|delay2|width1|players2|" + room_id + "|" + "|".join(sorted)).to_utf8_buffer())
	return hash.finish().slice(0, 16)


func freeze(client: Object, mesh: Object, roster: PackedStringArray, incarnation: PackedByteArray) -> Error:
	if _is_busy():
		return ERR_BUSY
	var session_id: PackedByteArray = session_identity(client.call("get_room_id"), roster)
	if session_id.is_empty():
		return ERR_INVALID_DATA
	var profile: Protocol.Config = Protocol.Config.new()
	profile.input_delay = 2
	profile.desync_interval = 30
	var code: Error = membership.configure(client.call("get_player_id"), roster, session_id, incarnation, profile)
	if code != OK:
		return code
	local_slot = membership.slot(membership.local_uuid())
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
	if has_started or adapter.status().route != "mesh":
		return ERR_UNAVAILABLE
	var options: Direct.Options = Direct.Options.new()
	options.max_packet_bytes = PACKET_BYTES
	if direct.configure(mesh, membership, adapter, peer, options) != Direct.Code.OK:
		return ERR_UNAVAILABLE
	var relay_options: Relay.Options = Relay.Options.new()
	relay_options.max_packet_bytes = PACKET_BYTES
	if relay.configure(client, sdk_config, info, membership, adapter, peer, relay_options) != Relay.Code.OK:
		return ERR_UNAVAILABLE
	if fallback.configure(direct, relay, membership, adapter, peer) != Fallback.Code.OK:
		return ERR_UNAVAILABLE
	if peer.begin(now_us, [next_token()]) != Inputs.Code.OK:
		return ERR_UNAVAILABLE
	has_started = true
	return OK


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
	var healthy: bool = _poll_protocol(now_us)
	_is_servicing = false
	return healthy


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
	_last_now = now_us
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
			failure = "Game stopped (%d). Leave and create a new room." % result.code
		if failure.is_empty():
			_service(now_us)
	if has_started:
		_collect_events()


## Stop local gameplay and request final-state evidence while game callbacks remain legal.
## Keep ticking until replay_captured or a non-retryable replay_capture_code; ordinary exports remain available.
func finish_replay() -> int:
	if _is_busy():
		return Types.Code.BUSY
	if not has_started or not failure.is_empty():
		return Types.Code.NOT_SYNCHRONIZED
	if not record_replay:
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
		failure = "Final replay state could not be captured (%d). Download the available replay before leaving." % peer.status().reason
	if failure.is_empty():
		_service(now_us)


## Delay this player's input by one more frame; the other player receives the added frames as ordinary input.
func raise_input_delay() -> int:
	if _is_busy() or replay_finishing:
		return Types.Code.BUSY
	if not has_started or local_slot < 0:
		return Types.Code.NOT_SYNCHRONIZED
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
			failure = "Protocol stopped (%d). Leave and create a new room." % code
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
		failure = "Session ended (%d). Leave and create a new room." % peer.status().reason


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
			failure = "Transport queue stopped (%d). Leave and create a new room." % accepted
			return false
	var result: Fallback.Result = fallback.poll(now_us, next_token)
	if not has_started:
		return false
	if result.code not in [Fallback.Code.OK, Fallback.Code.BACKPRESSURE]:
		failure = "Transport stopped (%d). Leave and create a new room." % result.code
		return false
	return true


func detach() -> void:
	has_started = false
	if peer._core != null:
		peer._core.terminate()
	fallback.detach()
	direct.detach()
	relay.detach()
	adapter.detach()
	_pending.clear()


func _is_busy() -> bool:
	return _is_servicing or peer._has_mutation_guard() or (peer._core != null and peer._core._mutation_code() == Types.Code.BUSY)
