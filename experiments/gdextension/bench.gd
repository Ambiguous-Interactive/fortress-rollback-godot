extends SceneTree

const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const STEPS := 256
var frame := 0
var state := PackedByteArray()
var trace := PackedStringArray()
var ticks: Array[int] = []
var copies: Array[int] = []
var players: int
var native := FortressNativeSession.new()
var port := Session.new()


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	players = int(args[1])
	state.resize(4096)
	var cfg := Config.new()
	cfg.player_count = players
	cfg.local_players = PackedInt32Array(range(players))
	cfg.input_width = 4
	cfg.neutral_input = PackedByteArray([0, 0, 0, 0])
	cfg.max_snapshot_bytes = state.size()
	cfg.storage_budget_bytes = 1048576
	cfg.checksums_enabled = false
	if not native.start_sync(players) or port.configure(cfg) != Types.Code.OK:
		quit(1)
		return
	for step: int in range(STEPS):
		var data := PackedByteArray()
		data.resize(4 * players)
		for player: int in range(players):
			data.encode_u32(4 * player, (1 + player) * (1 + step))
		var start := Time.get_ticks_usec()
		var ok := native.step_sync(data, self) if args[0] == "native" else port_step(data)
		ticks.append(Time.get_ticks_usec() - start)
		if not ok or frame != step + 1:
			quit(1)
			return
	print("BENCH ", JSON.stringify({"state": state.hex_encode(), "trace": trace, "ticks": ticks, "copies": copies}))
	quit()


func port_step(data: PackedByteArray) -> bool:
	for i: int in range(players):
		if port.submit_local_input(i, frame, data.slice(4 * i, 4 * i + 4)).code != Types.Code.OK:
			return false
	var batch := port.begin_advance()
	if batch.code != Types.Code.READY:
		return false
	var request: RefCounted = batch.batch.next_request()
	while request != null:
		var ok := false
		match request.kind:
			Types.Kind.SAVE:
				ok = request.writer.write_bytes(save_state(request.frame)) == 0
			Types.Kind.LOAD:
				var result: RefCounted = request.reader.read_bytes(state.size())
				ok = result.code == 0 and load_state(request.frame, result.bytes)
			Types.Kind.ADVANCE:
				var bytes := PackedByteArray()
				var statuses := PackedByteArray()
				for i: int in range(players):
					var input: RefCounted = request.inputs.read(i)
					bytes.append_array(input.bytes)
					statuses.append(input.status - 1)
				ok = advance_game(bytes, statuses)
		if not ok or port.complete_request(request.batch_id, request.request_id, ok).code != Types.Code.OK:
			return false
		request = batch.batch.next_request()
	return true


func save_state(which: int) -> PackedByteArray:
	trace.append("S%d" % which)
	var start := Time.get_ticks_usec()
	var bytes := state.duplicate()
	copies.append(Time.get_ticks_usec() - start)
	return bytes


func load_state(which: int, bytes: PackedByteArray) -> bool:
	trace.append("L%d" % which)
	var start := Time.get_ticks_usec()
	state = bytes.duplicate()
	copies.append(Time.get_ticks_usec() - start)
	frame = state.decode_u32(0)
	return which == frame


func advance_game(bytes: PackedByteArray, statuses: PackedByteArray) -> bool:
	trace.append("A%d" % frame)
	for i: int in range(players):
		if statuses[i] != 0:
			return false
		var offset := 4 + 4 * i
		state.encode_u32(offset, state.decode_u32(offset) + bytes.decode_u32(4 * i))
	frame += 1
	state.encode_u32(0, frame)
	return true
