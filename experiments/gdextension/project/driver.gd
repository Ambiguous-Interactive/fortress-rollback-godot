extends Node

const Game = preload("res://reference_game.gd")
var game := Game.new(2)
var session := FortressNativeSession.new()
var history: Array = []
var loads: int = 0
var replaced: Dictionary = {}
var corrected_fault := false
var checkpoint := ""
var slot: int = -1
var control: String
var endpoint: String
var http := HTTPRequest.new()
var report: Dictionary = {}


func _ready() -> void:
	add_child(http)
	http.request_completed.connect(_reply)
	if OS.has_feature("web"):
		endpoint = str(JavaScriptBridge.eval("location.origin")) + "/tick"
	elif OS.has_feature("mobile"):
		endpoint = "http://127.0.0.1:45872/tick"
	else:
		var arguments := OS.get_cmdline_user_args()
		if arguments.size() != 1:
			push_error("Launch the witness with qualify.py to connect its reference peer.")
			get_tree().quit(1)
			return
		endpoint = arguments[0]
	_send()


func _send() -> void:
	if http.request(endpoint, ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(report)) != OK:
		get_tree().quit(1)


func _reply(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		get_tree().quit(1)
		return
	var cmd: Dictionary = JSON.parse_string(body.get_string_from_utf8())
	if cmd.has("finish"):
		report = {"ack": true}
		_send.call_deferred()
		return
	if cmd.has("done"):
		get_tree().quit()
		return
	if slot < 0:
		slot = int(cmd.slot)
		control = cmd.control
		if not session.start(slot):
			get_tree().quit(1)
			return
	for packet: String in cmd.packets:
		if not session.receive(packet.hex_decode()):
			get_tree().quit(1)
			return
	var input := PackedByteArray()
	input.resize(4)
	input.encode_u32(0, (game.frame + 1) * (slot + 17))
	if control == "encoding":
		input.reverse()
	var start := Time.get_ticks_usec()
	var status := session.step(input, self)
	var elapsed := Time.get_ticks_usec() - start
	var outgoing: Array[String] = []
	for packet: PackedByteArray in session.drain_packets():
		outgoing.append(packet.hex_encode())
	report = {
		"frame": game.frame,
		"state": game.bytes().hex_encode(),
		"loads": loads,
		"history": history,
		"confirmed": session.confirmed_frame(),
		"corrected_fault": corrected_fault,
		"checkpoint": checkpoint,
		"status": status,
		"packets": outgoing,
		"step_us": elapsed
	}
	_send.call_deferred()


func save_state(_frame: int) -> PackedByteArray:
	return game.bytes()


func load_state(frame: int, state: PackedByteArray) -> bool:
	if frame >= game.frame:
		return false
	loads += 1
	for old_frame: int in range(frame, game.frame):
		replaced[old_frame] = history[old_frame]
	if not game.restore(state).is_empty() or game.frame != frame:
		return false
	if control == "restore":
		game.accumulators[slot] += 1
	history.resize(frame)
	return true


func advance_game(bytes: PackedByteArray, statuses: PackedByteArray) -> bool:
	var rows: Array = []
	var sample: Array = []
	for index: int in range(statuses.size()):
		var part := bytes.slice(4 * index, 4 * index + 4)
		rows.append({"player": index, "bytes": part.hex_encode(), "status": ["confirmed", "predicted", "disconnected"][statuses[index]]})
		sample.append(part.decode_u32(0))
	if game.frame >= 8 and game.frame < 12 and replaced.has(game.frame) and replaced[game.frame] != sample:
		corrected_fault = true
	replaced.erase(game.frame)
	history.append(sample)
	if not game.advance(rows).is_empty():
		return false
	if game.frame == 40:
		checkpoint = game.bytes().hex_encode()
	return true
