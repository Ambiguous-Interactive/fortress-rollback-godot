extends Node

# gdlint: disable=constant-name,max-returns

# Value: protects=real browser direct WebRTC gameplay; fails_when=server lifecycle or binary delivery diverges; why_new=injected witnesses omit sockets; seam=SDK public API

const SDK = preload("res://addons/signal_fish/signal_fish_client.gd")
const SDKMesh = preload("res://addons/signal_fish/webrtc/sf_webrtc_mesh.gd")
const Membership = preload("res://addons/fortress_rollback/transport/signalfish_membership.gd")
const Adapter = preload("res://addons/fortress_rollback/transport/signalfish_adapter.gd")
const Direct = preload("res://addons/fortress_rollback/transport/signalfish_webrtc.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const S = preload("res://addons/fortress_rollback/core/session_types.gd")
const Setup = preload("res://webrtc_setup.gd")
const Game = preload("res://webrtc_game.gd")
const Mixed = preload("res://webrtc_mixed.gd")
const FAILURE_SIGNALS: PackedStringArray = ["protocol_error", "server_error", "room_join_failed", "authentication_error", "connection_failed",
	"reconnection_failed", "disconnected", "going_away", "room_left", "reconnected"]
const MEMBERSHIP_SIGNALS: PackedStringArray = ["room_joined", "player_joined", "player_left", "player_reconnected", "spectator_joined", "new_peer"]
var clients: Array[SDK] = []
var infos: Dictionary = {}
var lobby_ready: Dictionary = {}
var room_infos: Dictionary = {}
var adapters: Array[Adapter] = []
var meshes: Array[SDKMesh] = []
var memberships: Array[Membership] = []
var peers: Array[Peer] = []
var transports: Array[Direct] = []
var games: Array[Game] = []
var errors: Array[String] = []
var records: Array[Dictionary] = []
var received_binary: int = 0
var sent_packets: int = 0
var received_packets: int = 0
var active_comparisons: int = 0
var stage: String = "initial"
var transport_us: int = 0
var transport_epoch_us: int = -1
var token_serial: int = 0
var next_progress_us: int = 0
var endpoint: String = ""
var player_count: int = 0
var local_index: int = 0
var membership_frozen: bool = false
var tearing_down: bool = false
var mixed_enabled: bool = false
var mixed: Mixed = Mixed.new()

func _ready() -> void:
	mixed_enabled = JavaScriptBridge.eval("window.fortressMixed || false")
	endpoint = JavaScriptBridge.eval("window.fortressEndpoint")
	player_count = int(JavaScriptBridge.eval("window.fortressPlayers"))
	local_index = int(JavaScriptBridge.eval("window.fortressLocal"))
	_run.call_deferred()

func _publish(value: Dictionary) -> void:
	JavaScriptBridge.eval("document.body.dataset.fortressWebrtc = " + JSON.stringify(JSON.stringify(value)))

func _run() -> void:
	var ok: bool = await Setup.new().run(self, player_count)
	if ok: ok = await _play(player_count)
	ok = ok and _healthy(true)
	var control: bool = JavaScriptBridge.eval("window.fortressCorrupt || window.fortressDefaultFactory || false")
	if ok or control:
		JavaScriptBridge.eval("document.body.dataset.fortressGameplayDone = 'true'")
		if ok:
			ok = await _wait(func() -> bool: return JavaScriptBridge.eval("window.fortressTeardownArmed || false"), true)
			ok = ok and _healthy(true)
		elif not await _wait_cleanup("window.fortressTeardownArmed || false"):
			errors.append("teardown_barrier")
	tearing_down = true
	JavaScriptBridge.eval("document.body.dataset.fortressTeardownArmed = 'true'")
	if ok or control:
		if not await _wait_cleanup("window.fortressTeardownReady || false"):
			ok = false
			errors.append("teardown_barrier")
	_cleanup()
	if not ok or not errors.is_empty():
		_publish({"passed": false, "failure": {"players": player_count, "stage": stage, "errors": errors}})
		return
	_publish({"passed": true, "records": records, "binary_receives": received_binary})


func _wait_cleanup(expression: String) -> bool:
	for attempt: int in 1000:
		if JavaScriptBridge.eval(expression): return true
		await get_tree().create_timer(0.002).timeout
	return false

func _play(count: int) -> bool:
	stage = "handshake"
	if not await _wait(func() -> bool:
		for peer: Peer in peers:
			if peer.network_status().state != "running": return false
		return true, true): return false
	JavaScriptBridge.eval("document.body.dataset.fortressHandshakeReady = 'true'")
	if not await _wait(func() -> bool: return JavaScriptBridge.eval("window.fortressFirstStepReady || false"), true): return false
	stage = "gameplay"
	JavaScriptBridge.eval("window.fortressFaultActive = true")
	for frame: int in 40:
		if not await _wait(func() -> bool:
			for peer: Peer in peers:
				for endpoint_status: Dictionary in peer.network_status().peers.values():
					if endpoint_status.last_received_frame < frame - 1: return false
			return true, true): return false
		_update_transport_clock()
		for index: int in clients.size():
			var slot: int = memberships[index].slot(clients[index].get_player_id())
			var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(slot, frame, PackedByteArray([_sample(frame, slot)]))]
			var stepped: Driver.StepResult = peers[index].step(transport_us, samples)
			if stepped.code != S.Code.OK:
				errors.append("step_%d_at_%d" % [stepped.code, frame])
				return false
		JavaScriptBridge.eval("document.body.dataset.fortressFrame = '%d'" % frame)
		if frame == 0 and not await _wait_cleanup("window.fortressFirstDeliveryReady || false"):
			errors.append("prediction_barrier")
			return false
		if frame >= 3:
			if games[0].history.get(frame - 2) != _expected(frame - 2, count):
				errors.append("canonical_prefix_frame_%d" % (frame - 2))
				return false
			active_comparisons += 1
		for turn: int in 8:
			if not _service(): return false
		await get_tree().create_timer(0.002).timeout
	stage = "final_confirmation"
	if not await _wait(func() -> bool:
		for peer: Peer in peers:
			if peer.status().confirmed_frame < 38: return false
		return true, true): return false
	if not _healthy(true): return false
	stage = "canonical_state"
	var comparisons: int = 0
	var minimum_confirmed: int = 2147483647
	for index: int in clients.size():
		minimum_confirmed = mini(minimum_confirmed, peers[index].status().confirmed_frame)
		if peers[index].status().confirmed_frame < 38: return false
		for frame: int in range(1, 39):
			var expected: PackedByteArray = _expected(frame, count)
			if games[index].history.get(frame) != expected: return false
			comparisons += 1
	if not _healthy(true): return false
	records.append({"players": count, "frames_submitted": 40, "minimum_confirmed": minimum_confirmed, "canonical_comparisons": comparisons,
		"direct": _transport_totals(), "rollback_loads": games[0].loads, "active_comparisons": active_comparisons,
		"mixed": mixed.report() if mixed_enabled else {}})
	return true

static func _expected(frame: int, count: int) -> PackedByteArray:
	var expected: PackedByteArray = PackedByteArray()
	expected.resize(4 + 4 * count)
	expected.encode_u32(0, frame)
	for slot: int in count:
		var value: int = 0
		for previous: int in frame: value = (value * 33 + _sample(previous, slot)) & 0xffffffff
		expected.encode_u32(4 + 4 * slot, value)
	return expected

func _transport_totals() -> Dictionary:
	return {"sent": sent_packets, "received": received_packets}

func _direct_options() -> Direct.Options:
	var options: Direct.Options = Direct.Options.new()
	options.max_packet_bytes = 1024
	if not JavaScriptBridge.eval("window.fortressMixedDefault || false"):
		options.max_sends_per_poll = 32
		options.max_receives_per_poll = 32
	return options

func _wait(condition: Callable, use_transport: bool = false) -> bool:
	print("WEBRTC_STAGE ", stage)
	var diagnostics: Dictionary = _new_wait_diagnostics()
	for attempt: int in 3000:
		for client: SDK in clients: client.poll()
		for mesh: SDKMesh in meshes: mesh.poll()
		if use_transport:
			for turn: int in 8:
				if not _service(): return false
		if not errors.is_empty(): return false
		if condition.call(): return true
		_service_wait_diagnostics(attempt, diagnostics)
		await get_tree().create_timer(0.002).timeout
	for peer: Peer in peers:
		print("TIMEOUT_STATUS ", peer.status().current_frame, " ", peer.status().confirmed_frame, " ", peer.status().pending_rollback_frame)
	errors.append("wait_timeout_" + stage)
	return false

func _new_wait_diagnostics() -> Dictionary:
	return {"count": 0, "next_us": _ticks_usec() + (5000000 if stage == "gameplay" else 0)}

func _service_wait_diagnostics(attempt: int, diagnostics: Dictionary) -> void:
	var now_us: int = _ticks_usec()
	if stage in ["gameplay", "final_confirmation"] and diagnostics.count < 6 and now_us >= diagnostics.next_us:
		_wait_diagnostic(attempt)
		diagnostics.count += 1
		diagnostics.next_us = now_us + 5000000

func _wait_diagnostic(attempt: int) -> void:
	var label: String = "FINAL_CONFIRMATION_STATUS " if stage == "final_confirmation" else "GAMEPLAY_WAIT_STATUS "
	for peer: Peer in peers:
		print(label, JSON.stringify(_wait_snapshot(peer, attempt)))

func _wait_snapshot(peer: Peer, attempt: int) -> Dictionary:
	var core: S.Status = peer.status()
	var endpoints: Dictionary = {}
	var network: Dictionary = peer.network_status()
	for key: String in network.peers:
		var endpoint_status: Dictionary = network.peers[key]
		var selected: Dictionary = {}
		for field: String in ["last_submitted_frame", "last_sent_frame", "last_received_frame", "last_acked_frame", "pending_frames",
			"last_input_progress_us", "peer_statuses", "connect_statuses"]:
			selected[field] = endpoint_status[field]
		selected["pending_frame_ids"] = endpoint_status.pending.keys()
		endpoints[key] = selected
	return {"attempt": attempt, "stage": stage, "local_index": local_index, "players": player_count,
		"current_frame": core.current_frame, "confirmed_frame": core.confirmed_frame, "pending_rollback_frame": core.pending_rollback_frame,
		"transport_us": 0 if transport_epoch_us == -1 else _ticks_usec() - transport_epoch_us, "endpoints": endpoints}

func _ticks_usec() -> int:
	return Time.get_ticks_usec()

func _reset_transport_clock() -> void:
	transport_epoch_us = _ticks_usec()
	transport_us = 0

func _update_transport_clock() -> void:
	if transport_epoch_us == -1: _reset_transport_clock()
	transport_us = _ticks_usec() - transport_epoch_us

func _next_token(_remote_uuid: String = "") -> PackedByteArray:
	token_serial += 1
	var token: PackedByteArray = PackedByteArray()
	token.resize(16)
	token.encode_u64(0, local_index + 1)
	token.encode_u64(8, token_serial)
	return token

func _poll_tokens(peer: Peer) -> Array[PackedByteArray]:
	var tokens: Array[PackedByteArray] = []
	for remote: PackedByteArray in peer.peer_ids(): tokens.append(_next_token())
	return tokens

func _service() -> bool:
	_update_transport_clock()
	if not _healthy(): return false
	for index: int in clients.size():
		clients[index].poll()
		meshes[index].poll()
		if not errors.is_empty(): return false
		for _attempt: int in 2:
			var polled: int = peers[index].poll(transport_us, _poll_tokens(peers[index]))
			if polled not in [I.Code.OK, I.Code.BACKPRESSURE] or peers[index].status().lifecycle == S.Lifecycle.TERMINATED:
				errors.append("peer_poll_%d" % polled)
				return false
			peers[index].drain_events()
			peers[index].drain_transitions()
			if polled == I.Code.OK: break
		if mixed_enabled:
			if not mixed.service(self): return false
		else:
			var packets: Array[Peer.Packet] = peers[index].drain_outbox()
			if not packets.is_empty():
				var accepted: int = transports[index].enqueue_batch(packets)
				if accepted != 0:
					errors.append("direct_enqueue_%d" % accepted)
					return false
			var result: Direct.Result = transports[index].poll(transport_us, _next_token)
			if result.code != 0:
				errors.append("direct_poll_%d_peer_%d" % [result.code, result.peer_code])
				return false
			sent_packets += result.sent
			received_packets += result.received
		peers[index].drain_events()
		peers[index].drain_transitions()
	if transport_us >= next_progress_us:
		Setup.publish_progress(self)
		next_progress_us = transport_us + 500000
	return _healthy()

func _observe_client(client: SDK) -> void:
	# Variant defaults match the optional payloads of the pinned SDK's different public signals.
	for signal_name: String in FAILURE_SIGNALS:
		client.connect(signal_name, func(_first: Variant = null, _second: Variant = null) -> void:
			print("SDK_FAILURE ", signal_name, " ", _first, " ", _second)
			_record_failure(signal_name))
	for signal_name: String in MEMBERSHIP_SIGNALS:
		client.connect(signal_name, func(_first: Variant = null, _second: Variant = null) -> void:
			if membership_frozen: _record_failure(signal_name))

func _record_failure(signal_name: String) -> void:
	if not tearing_down: errors.append(signal_name)

func _healthy(final: bool = false) -> bool:
	if not errors.is_empty(): return false
	for index: int in clients.size():
		if not clients[index].is_connected_to_server() or not clients[index].is_authenticated():
			errors.append("sdk_connection_lifetime")
			return false
		if clients[index].get_player_id() != memberships[index].local_uuid() or clients[index].get_room_id() != room_infos[index].room_id:
			errors.append("sdk_identity_lifetime")
			return false
		if adapters[index].status().route != "mesh" or transports[index].status().code != 0:
			errors.append("direct_status_%s_%d" % [adapters[index].status().route, transports[index].status().code])
			return false
		if final and peers[index].network_status().state != "running":
			errors.append("protocol_not_running")
			return false
	return true

static func _sample(frame: int, slot: int) -> int:
	return (frame * 17 + slot * 31 + 1) & 255

func _cleanup() -> void:
	tearing_down = true
	mixed.detach()
	for direct: Direct in transports: direct.detach()
	for adapter: Adapter in adapters: adapter.detach()
	for mesh: SDKMesh in meshes: mesh.free()
	for client: SDK in clients:
		client.close()
		client.free()
	clients.clear()
	infos.clear()
	lobby_ready.clear()
	room_infos.clear()
	adapters.clear()
	meshes.clear()
	memberships.clear()
	peers.clear()
	transports.clear()
	games.clear()
