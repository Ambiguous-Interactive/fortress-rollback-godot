extends RefCounted

const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const S = preload("res://addons/fortress_rollback/core/session_types.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")

const FIRST_FRAME: int = 144
const SECOND_FRAME: int = 192
const PREDICTION_BOUND: int = 8

var mode: String = ""
var cursor: int = 0
var phases: Array[Dictionary] = []
var retained_sample: int = -1


func is_phase(frame: int) -> bool:
	return not mode.is_empty() and frame in [FIRST_FRAME, SECOND_FRAME]


func is_phase_input(next_frame: int) -> bool:
	return not mode.is_empty() and (next_frame > FIRST_FRAME and next_frame < FIRST_FRAME + PREDICTION_BOUND 		or next_frame > SECOND_FRAME and next_frame <= SECOND_FRAME + 3)


func run(host: Node, frame: int) -> bool:
	var peer: Peer = host.peers[0]
	var receiver: bool = host.local_index == (0 if frame == FIRST_FRAME else 1)
	var end: int = frame + (PREDICTION_BOUND - 1 if frame == FIRST_FRAME else 3)
	if not await host._wait(func() -> bool: return peer.status().confirmed_frame == frame - 1, true) or not _recover(host, frame):
		return false
	JavaScriptBridge.eval("document.body.dataset.fortressAsymmetricReady = '%d'" % frame)
	if not await host._wait(func() -> bool: return JavaScriptBridge.eval("window.fortressAsymmetricStart === %d" % frame), true):
		return false
	var attempts: Array[Dictionary] = []
	var held: Dictionary = await _hold(host, frame, end, receiver, attempts)
	if held.is_empty():
		return false
	JavaScriptBridge.eval("document.body.dataset.fortressAsymmetricHeld = '%d'" % frame)
	if not await host._wait_cleanup("window.fortressAsymmetricEnd === %d" % frame):
		host.errors.append("asymmetric_end_timeout")
		return false
	var after: Dictionary = await _finish(host, frame, end, receiver, held)
	if after.is_empty():
		return false
	phases.append({"base": frame, "limit": end, "receiver": receiver, "held": held, "after": after, "stalls": attempts})
	cursor = end
	return true


func _hold(host: Node, frame: int, end: int, receiver: bool, attempts: Array[Dictionary]) -> Dictionary:
	var peer: Peer = host.peers[0]
	if not receiver and not await host._wait(func() -> bool: return _received(peer) == end - 1, true):
		return {}
	var callback_start: int = host.games[0].callbacks.size()
	for input_frame: int in range(frame, end):
		if not host._step_frame(input_frame) or not host._service_batch():
			return {}
		await host._wait_turn()
	if receiver and frame == FIRST_FRAME:
		JavaScriptBridge.eval("document.body.dataset.fortressAsymmetricSpeculated = '%d'" % frame)
		if not await host._wait(func() -> bool: return JavaScriptBridge.eval("window.fortressAsymmetricStall === %d" % frame), true):
			return {}
		var stall: Driver.StepResult = host._attempt_frame(end)
		attempts.append({"code": stall.code, "before": stall.frame_before, "after": stall.frame_after})
		if stall.code != S.Code.PREDICTION_STALL or stall.frame_before != end or stall.frame_after != end:
			host.errors.append("asymmetric_prediction_boundary")
			return {}
		retained_sample = end
	var held: Dictionary = _state(host)
	held["callbacks"] = [callback_start, host.games[0].callbacks.size()]
	var expected_receipt: int = frame - 1 if receiver else end - 1
	if held.frame != end or held.received != expected_receipt or (receiver and held.confirmed != frame - 1):
		host.errors.append("asymmetric_original_prefix")
		return {}
	return held


func _finish(host: Node, frame: int, end: int, receiver: bool, held: Dictionary) -> Dictionary:
	if mode == "withheld":
		var unchanged: Dictionary = _state(host)
		if unchanged.received != held.received or unchanged.frame != end:
			host.errors.append("asymmetric_withheld_delivery")
			return {}
		return unchanged
	var peer: Peer = host.peers[0]
	if (receiver and not await host._wait(func() -> bool: return _received(peer) == end - 1, true)) or not _recover(host, end):
		return {}
	var after: Dictionary = _state(host)
	after["callbacks"] = [held.callbacks[1], host.games[0].callbacks.size()]
	for boundary: int in range(frame, end + 1):
		if host.games[0].history.get(boundary) != host._expected(boundary, host.player_count):
			host.errors.append("asymmetric_original_boundary_%d" % boundary)
			return {}
	host.active_comparisons += end - frame
	JavaScriptBridge.eval("document.body.dataset.fortressAsymmetricRecovered = '%d'" % frame)
	if not await host._wait(func() -> bool: return JavaScriptBridge.eval("window.fortressAsymmetricContinue === %d" % frame), true):
		return {}
	return after


func _recover(host: Node, frame: int) -> bool:
	host._update_transport_clock()
	var result: Driver.StepResult = host.peers[0].recover(host.transport_us)
	if result.code != S.Code.OK or result.frame_before != frame or result.frame_after != frame 		or host.games[0].bytes() != host._expected(frame, host.player_count):
		host.errors.append("asymmetric_recovery_%d_%d" % [frame, result.code])
		return false
	return true


func _state(host: Node) -> Dictionary:
	var peer: Peer = host.peers[0]
	var endpoint: Dictionary = peer.network_status().peers.values()[0]
	return {"frame": peer.status().current_frame, "confirmed": peer.status().confirmed_frame, "received": endpoint.last_received_frame,
		"acked": endpoint.last_acked_frame, "turn": host.pressure_service_turn, "binary": host.mixed.accepted_binary,
		"loads": host.games[0].loads, "canonical": host.games[0].bytes().hex_encode()}


func _received(peer: Peer) -> int:
	return peer.network_status().peers.values()[0].last_received_frame


func history(host: Node) -> Array[String]:
	var original: Array[String] = []
	var game: RefCounted = host.games[0]
	for boundary: int in range(1, host.frame_count + 1):
		var state: PackedByteArray = game.history[boundary]
		original.append(state.hex_encode())
	return original
