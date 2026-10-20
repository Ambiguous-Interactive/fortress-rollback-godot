extends SceneTree

# Measures the production session hot path: steady frames, snapshot save and
# restore, the maximum rollback and protocol codec work, for 2, 4 and 8
# players. Every workload reports a canonical checksum, so a faster path can
# never change the simulated result.
#
# The snapshot workload measures the production writer and an embedded control
# that keeps the previous per-byte copy, in the same process, so the difference
# is not a machine-state artifact.
#
# The results are published in docs/experiments/session-hot-path-performance.md.

const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Status = preload("res://addons/fortress_rollback/core/snapshot_status.gd")
const Writer = preload("res://addons/fortress_rollback/core/snapshot_writer.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
const PTypes = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")

const STATE_BYTES: int = 4096
const FRAMES: int = 400
const SAMPLES: int = 15
const WINDOW: int = 8
const PLAYER_COUNTS: Array[int] = [2, 4, 8]
const LOCAL: Array[int] = [7]


# The previous snapshot writer: a preallocated buffer filled one byte at a time.
class ControlWriter:
	extends RefCounted

	var _bytes: PackedByteArray = PackedByteArray()
	var _cursor: int = 0
	var _error: int = Status.Code.OK

	func _init(capacity: int) -> void:
		_bytes.resize(capacity)

	func write_bytes(bytes: PackedByteArray) -> int:
		if bytes.size() > _bytes.size() - _cursor:
			_error = Status.Code.OVERFLOW
			return _error
		for index: int in range(bytes.size()):
			_bytes[_cursor + index] = bytes[index]
		_cursor += bytes.size()
		return Status.Code.OK

	func written() -> PackedByteArray:
		return _bytes.slice(0, _cursor)


func _initialize() -> void:
	var reports: Array[Dictionary] = []
	for players: int in PLAYER_COUNTS:
		reports.append({
			"players": players,
			"steady": _steady(players),
			"rollback": _rollback(players),
			"snapshot": _snapshot(players),
			"codec": _codec(players),
		})
	print(JSON.stringify({"engine": Engine.get_version_info().string, "state_bytes": STATE_BYTES,
		"frames": FRAMES, "samples": SAMPLES, "window": WINDOW, "reports": reports}))
	quit()


# Steady frames: every remote input is confirmed before the frame is simulated.
func _steady(players: int) -> Dictionary:
	var samples: Array[int] = []
	var checksum: int = 0
	for sample: int in range(SAMPLES):
		var run: Dictionary = _steady_run(players)
		samples.append(run["usec"])
		checksum = run["checksum"]
	return _summary(samples, checksum, FRAMES)


# The maximum rollback: the remote inputs arrive one window late, so every
# correction resimulates the whole prediction window.
func _rollback(players: int) -> Dictionary:
	var samples: Array[int] = []
	var checksum: int = 0
	for sample: int in range(SAMPLES):
		var run: Dictionary = _rollback_run(players)
		samples.append(run["usec"])
		checksum = run["checksum"]
	return _summary(samples, checksum, FRAMES)


# The snapshot path: the production writer and the previous per-byte control.
func _snapshot(players: int) -> Dictionary:
	var payload: PackedByteArray = PackedByteArray()
	payload.resize(STATE_BYTES)
	payload.fill(9)
	var production: Array[int] = []
	var control: Array[int] = []
	var checksum: int = 0
	for sample: int in range(SAMPLES):
		var run: Dictionary = _snapshot_run(payload)
		production.append(run["production_us"])
		control.append(run["control_us"])
		checksum = run["checksum"]
	var result: Dictionary = _summary(production, checksum, FRAMES)
	result["control_p50_us"] = _percentile(control, 50)
	result["control_p95_us"] = _percentile(control, 95)
	return result


# The protocol codec: one input packet with every player's input.
func _codec(players: int) -> Dictionary:
	var limits: RefCounted = PTypes.Limits.new()
	limits.player_count = players
	limits.input_width = 1
	limits.max_packet_bytes = 65536
	var message: RefCounted = PTypes.Message.new()
	message.kind = PTypes.Kind.INPUT
	message.start_frame = 0
	message.ack_frame = -1
	message.frame_count = 1
	var slots: PackedByteArray = PackedByteArray()
	slots.resize(players)
	var data: PackedByteArray = PackedByteArray()
	data.resize(players)
	for player: int in range(players):
		slots[player] = player
		data[player] = player
	message.players = slots
	message.data = data
	for player: int in range(players):
		var status: RefCounted = PTypes.Status.new()
		status.last_frame = -1
		status.epoch = 0
		message.statuses.append(status)
	var samples: Array[int] = []
	var checksum: int = 0
	for sample: int in range(SAMPLES):
		var start: int = Time.get_ticks_usec()
		for index: int in range(FRAMES):
			var encoded: RefCounted = Codec.encode(message, limits)
			if encoded.code != PTypes.Code.OK:
				push_error("codec encode failed")
				quit(1)
				return {}
			var decoded: RefCounted = Codec.decode(encoded.bytes, limits)
			if decoded.code != PTypes.Code.OK:
				push_error("codec decode failed")
				quit(1)
				return {}
			checksum += decoded.message.data[0] + encoded.bytes.size()
		samples.append(Time.get_ticks_usec() - start)
	return _summary(samples, checksum, FRAMES)


func _steady_run(players: int) -> Dictionary:
	var session: RefCounted = _session(players)
	var state: PackedByteArray = PackedByteArray()
	state.resize(STATE_BYTES)
	state.fill(1)
	var checksum: int = 0
	var start: int = Time.get_ticks_usec()
	var frame: int = 0
	while frame < FRAMES:
		# Every remote input is confirmed before its frame is simulated.
		for player: int in range(1, players):
			var remote: PackedByteArray = PackedByteArray([(frame + player) & 255])
			if session.receive_input(player, frame, remote).code != Types.Code.OK:
				push_error("remote input rejected")
				quit(1)
				return {}
		checksum += _advance(session, state)
		frame = session.status().current_frame
	var usec: int = Time.get_ticks_usec() - start
	return {"usec": usec, "checksum": checksum}


func _rollback_run(players: int) -> Dictionary:
	var session: RefCounted = _session(players)
	var state: PackedByteArray = PackedByteArray()
	state.resize(STATE_BYTES)
	state.fill(1)
	var checksum: int = 0
	var start: int = Time.get_ticks_usec()
	var delivered: int = 0
	var steps: int = 0
	while session.status().current_frame < FRAMES and steps < FRAMES * 4:
		steps += 1
		var current: int = session.status().current_frame
		if current >= delivered + WINDOW:
			# The remote inputs arrive one window late, so the session corrects
			# its prediction and resimulates the whole window.
			for pending: int in range(WINDOW):
				for player: int in range(1, players):
					var remote: PackedByteArray = PackedByteArray([(delivered + player) & 255])
					if session.receive_input(player, delivered, remote).code != Types.Code.OK:
						push_error("remote input rejected")
						quit(1)
						return {}
				delivered += 1
		checksum += _advance(session, state)
	var usec: int = Time.get_ticks_usec() - start
	return {"usec": usec, "checksum": checksum}


func _snapshot_run(payload: PackedByteArray) -> Dictionary:
	var checksum: int = 0
	var start: int = Time.get_ticks_usec()
	for index: int in range(FRAMES):
		var writer: RefCounted = Writer.new(STATE_BYTES)
		if writer.write_bytes(payload) != Status.Code.OK:
			push_error("production writer failed")
			quit(1)
			return {}
		checksum += writer._written_copy()[0]
	var production: int = Time.get_ticks_usec() - start
	start = Time.get_ticks_usec()
	for index: int in range(FRAMES):
		var writer: RefCounted = ControlWriter.new(STATE_BYTES)
		if writer.write_bytes(payload) != Status.Code.OK:
			push_error("control writer failed")
			quit(1)
			return {}
		checksum += writer.written()[0]
	var control: int = Time.get_ticks_usec() - start
	return {"production_us": production, "control_us": control, "checksum": checksum}


# Advances the session by one batch and returns the canonical checksum.
func _advance(session: RefCounted, state: PackedByteArray) -> int:
	var current: int = session.status().current_frame
	if session.submit_local_input(0, current, PackedByteArray(LOCAL)).code != Types.Code.OK:
		push_error("local input rejected")
		quit(1)
		return 0
	var result: RefCounted = session.begin_advance()
	if result.code != Types.Code.READY:
		return 0
	var checksum: int = 0
	while true:
		var request: RefCounted = result.batch.next_request()
		if request == null:
			break
		match request.kind:
			Types.Kind.SAVE:
				if request.writer.write_bytes(state) != Status.Code.OK:
					push_error("save failed")
					quit(1)
					return 0
			Types.Kind.LOAD:
				var restored: RefCounted = request.reader.read_bytes(STATE_BYTES)
				if restored.code != Status.Code.OK:
					push_error("load failed")
					quit(1)
					return 0
				state = restored.bytes
			Types.Kind.ADVANCE:
				for player: int in range(request.inputs.player_count()):
					var sample: RefCounted = request.inputs.read(player)
					checksum += sample.bytes[0] + sample.status
		if session.complete_request(request.batch_id, request.request_id, true, _checksum()).code != Types.Code.OK:
			push_error("request completion rejected")
			quit(1)
			return 0
	return checksum


func _session(players: int) -> RefCounted:
	var config: RefCounted = Config.new()
	config.player_count = players
	config.local_players = PackedInt32Array([0])
	config.input_width = 1
	config.neutral_input = PackedByteArray([0])
	config.input_delay = 0
	config.max_prediction_frames = WINDOW
	config.check_distance = 0
	config.queue_capacity = 128
	config.history_slots = WINDOW + 1
	config.max_snapshot_bytes = STATE_BYTES
	config.storage_budget_bytes = 16 * 1024 * 1024
	config.checksums_enabled = true
	config.sync_test = false
	var session: RefCounted = Session.new()
	if session.configure(config) != Types.Code.OK:
		push_error("session configuration failed")
		quit(1)
	return session


func _checksum() -> PackedByteArray:
	var checksum: PackedByteArray = PackedByteArray()
	checksum.resize(16)
	checksum[15] = 255
	return checksum


func _summary(samples: Array[int], checksum: int, iterations: int) -> Dictionary:
	return {
		"p50_us": _percentile(samples, 50),
		"p95_us": _percentile(samples, 95),
		"p99_us": _percentile(samples, 99),
		"min_us": samples[0],
		"max_us": samples[samples.size() - 1],
		"iterations": iterations,
		"checksum": checksum,
	}


func _percentile(samples: Array[int], percentile: int) -> int:
	var sorted: Array[int] = samples.duplicate()
	sorted.sort()
	var index: int = int(ceil(percentile / 100.0 * sorted.size())) - 1
	return sorted[clampi(index, 0, sorted.size() - 1)]
