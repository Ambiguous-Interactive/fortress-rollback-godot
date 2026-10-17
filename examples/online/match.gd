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
var has_started: bool = false
## Choose before freeze. Captures local canonical state and inputs for diagnostic export.
var capture_trace: bool = false
var _held: int = -1
var _tokens: int = 0
var _pending: Array[Peer.Packet] = []
var _last_now: int = -1


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
	if capture_trace:
		config.diagnostic_trace_frames = 120
		config.diagnostic_seed = str(game.rng_state)
		config.diagnostic_version = "fortress-online-integer-v1"
	config.storage_budget_bytes = config.required_storage_bytes()
	var handshake: Handshake.Options = Handshake.Options.new()
	handshake.timeout_us = 30000000
	if membership.configure_peer(peer, config, game, handshake, Inputs.Options.new()) != Inputs.Code.OK:
		return ERR_INVALID_DATA
	return adapter.attach(client, mesh, membership)


func start_transport(client: Object, mesh: Object, sdk_config: Object, info: Object, now_us: int) -> Error:
	if has_started or adapter.status().route != "mesh":
		return ERR_UNAVAILABLE
	var options: Direct.Options = Direct.Options.new()
	options.max_packet_bytes = 1024
	if direct.configure(mesh, membership, adapter, peer, options) != Direct.Code.OK:
		return ERR_UNAVAILABLE
	var relay_options: Relay.Options = Relay.Options.new()
	relay_options.max_packet_bytes = 1024
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
	if not failure.is_empty() or not has_started:
		return false
	if now_us < 0 or now_us < _last_now:
		failure = "Invalid clock or input. Leave and create a new room."
		return false
	_last_now = now_us
	return _poll_protocol(now_us)


func tick(now_us: int, buttons: int) -> void:
	if not failure.is_empty() or not has_started:
		return
	if now_us < 0 or now_us < _last_now or buttons < 0 or buttons > 15:
		failure = "Invalid clock or input. Leave and create a new room."
		return
	_last_now = now_us
	for _batch: int in 8:
		if not _poll_protocol(now_us):
			break
		if not _service(now_us):
			break
	if failure.is_empty() and peer.network_status().state == "running":
		if _held < 0:
			_held = buttons
		var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(local_slot, peer.status().current_frame, PackedByteArray([_held]))]
		var result: Driver.StepResult = peer.step(now_us, samples)
		if result.code == Types.Code.OK:
			_held = -1
		elif result.code in [Types.Code.PREDICTION_STALL, Types.Code.NETWORK_BACKPRESSURE]:
			stalls += 1
		else:
			failure = "Game stopped (%d). Leave and create a new room." % result.code
		if failure.is_empty():
			_service(now_us)
	_collect_events()


## Delay this player's input by one more frame; the other player receives the added frames as ordinary input.
func raise_input_delay() -> int:
	if not has_started or local_slot < 0:
		return Types.Code.NOT_SYNCHRONIZED
	return peer.set_input_delay(local_slot, peer.input_delay(local_slot) + 1)


func _poll_protocol(now_us: int) -> bool:
	for _attempt: int in 2:
		var code: int = peer.poll(now_us, [next_token()])
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
		if event.kind in ["sync_timeout", "incompatible"] and failure.is_empty():
			failure = "Rollback synchronization failed (%s). Leave and create a new room." % event.kind
	peer.drain_transitions()
	if peer.status().lifecycle == Types.Lifecycle.TERMINATED and failure.is_empty():
		failure = "Session ended (%d). Leave and create a new room." % peer.status().reason


func _service(now_us: int) -> bool:
	if _pending.is_empty():
		_pending = peer.drain_outbox()
	if not _pending.is_empty():
		var accepted: int = fallback.enqueue_batch(_pending)
		if accepted == Fallback.Code.OK:
			_pending.clear()
		elif accepted != Fallback.Code.BACKPRESSURE:
			failure = "Transport queue stopped (%d). Leave and create a new room." % accepted
			return false
	var result: Fallback.Result = fallback.poll(now_us, next_token)
	if result.code not in [Fallback.Code.OK, Fallback.Code.BACKPRESSURE]:
		failure = "Transport stopped (%d). Leave and create a new room." % result.code
		return false
	return true


func detach() -> void:
	fallback.detach()
	direct.detach()
	relay.detach()
	adapter.detach()
	_pending.clear()
	has_started = false
