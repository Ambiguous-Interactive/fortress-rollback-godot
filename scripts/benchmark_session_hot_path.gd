extends SceneTree

# Measures the production session hot path: steady frames, the maximum
# rollback, the snapshot write and protocol codec work, for 2, 4 and 8
# players. Every workload reports p50, p95, p99 and a canonical checksum, so a
# faster path can never change the simulated result.
#
# The snapshot workload measures the production writer and an embedded control
# that keeps the previous per-byte copy, in the same process, so the difference
# is not a machine-state artifact.
#
# The checksums are the published baseline. A change in the simulated result
# fails the benchmark until the baseline is reviewed and updated.
#
# The results are published in docs/experiments/session-hot-path-performance.md.

const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
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
const HASH_OFFSET: int = 1469598103934665
const HASH_PRIME: int = 1099511628211
const HASH_MASK: int = 9223372036854775807

# The published baseline. A changed checksum means the simulated result
# changed, which is a reviewed change and not a benchmark repair.
const BASELINE: Dictionary = {
	"snapshot": 4150103641047209673,
	"steady": {2: 1276642125363926553, 4: 193693954048565353, 8: 167760427949277961},
	"rollback": {2: 804470947006420549, 4: 8216305103245225058, 8: 7771464832153107854},
	"codec": {2: 1009799064992073792, 4: 5039977378390133760, 8: 8583044641210005760},
}


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


class DriverGame:
	extends RefCounted
	var state: PackedByteArray = PackedByteArray()
	var checksum_bytes: PackedByteArray = PackedByteArray()
	var checksum: int = HASH_OFFSET

	func _init() -> void:
		state.resize(STATE_BYTES)
		state.fill(1)
		checksum_bytes.resize(16)
		checksum_bytes[15] = 255

	func save_state(_frame: int, writer: RefCounted) -> Driver.SaveResult:
		return Driver.SaveResult.new(writer.write_bytes(state) == Status.Code.OK, checksum_bytes)

	func load_state(_frame: int, reader: RefCounted) -> bool:
		return reader.read_into(state) == Status.Code.OK and reader.is_complete()

	func simulate_frame(_frame: int, inputs: Types.FrameInputs) -> bool:
		for player: int in range(inputs.player_count()):
			var input: RefCounted = inputs.read(player)
			for byte: int in input.bytes:
				checksum = ((checksum ^ byte) * HASH_PRIME) & HASH_MASK
			checksum = ((checksum ^ input.status) * HASH_PRIME) & HASH_MASK
		return true


func _initialize() -> void:
	var snapshot: Dictionary = _snapshot()
	var reports: Array[Dictionary] = []
	for players: int in PLAYER_COUNTS:
		reports.append({
			"players": players,
			"steady": _steady(players),
			"driver": _driver(players),
			"rollback": _rollback(players),
			"codec": _codec(players),
		})
	var report: Dictionary = {"engine": Engine.get_version_info().string, "state_bytes": STATE_BYTES,
		"frames": FRAMES, "samples": SAMPLES, "window": WINDOW, "snapshot": snapshot, "reports": reports}
	if not _matches_baseline(report):
		push_error("the measured result differs from the published baseline")
		print(JSON.stringify(report))
		quit(1)
		return
	print(JSON.stringify(report))
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


# The public driver runs the same inputs and game work as the expert steady workload.
func _driver(players: int) -> Dictionary:
	var samples: Array[int] = []
	var checksum: int = 0
	for sample: int in range(SAMPLES):
		var session: RefCounted = _session(players)
		var game: DriverGame = DriverGame.new()
		var driver: RefCounted = Driver.new(session, game)
		var local: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, 0, PackedByteArray(LOCAL))]
		var start: int = Time.get_ticks_usec()
		for frame: int in range(FRAMES):
			for player: int in range(1, players):
				if session.receive_input(player, frame, PackedByteArray([(frame + player) & 255])).code != Types.Code.OK:
					_fail("driver remote input rejected")
					return {}
			local[0].sample_frame = frame
			var result: RefCounted = driver.step(frame, local)
			if result.code != Types.Code.OK or result.frame_before != frame or result.frame_after != frame + 1:
				_fail("driver frame did not complete")
				return {}
		samples.append(Time.get_ticks_usec() - start)
		checksum = game.checksum
		if checksum != BASELINE.steady[players]:
			_fail("driver state differs from the expert workload")
			return {}
	return _summary(samples, checksum, FRAMES)


# The maximum rollback: the remote inputs arrive one window late, so every
# correction loads a snapshot and resimulates the whole prediction window.
func _rollback(players: int) -> Dictionary:
	var samples: Array[int] = []
	var checksum: int = 0
	for sample: int in range(SAMPLES):
		var run: Dictionary = _rollback_run(players)
		samples.append(run["usec"])
		checksum = run["checksum"]
	return _summary(samples, checksum, FRAMES)


# The snapshot path: the production writer and the previous per-byte control.
func _snapshot() -> Dictionary:
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
				_fail("codec encode failed")
				return {}
			var decoded: RefCounted = Codec.decode(encoded.bytes, limits)
			if decoded.code != PTypes.Code.OK:
				_fail("codec decode failed")
				return {}
			checksum = _hash_bytes(decoded.message.data, checksum)
		samples.append(Time.get_ticks_usec() - start)
	return _summary(samples, checksum, FRAMES)


func _steady_run(players: int) -> Dictionary:
	var session: RefCounted = _session(players)
	var state: PackedByteArray = PackedByteArray()
	state.resize(STATE_BYTES)
	state.fill(1)
	var checksum: int = HASH_OFFSET
	var start: int = Time.get_ticks_usec()
	var frame: int = 0
	while frame < FRAMES:
		# Every remote input is confirmed before its frame is simulated.
		for player: int in range(1, players):
			var remote: PackedByteArray = PackedByteArray([(frame + player) & 255])
			if session.receive_input(player, frame, remote).code != Types.Code.OK:
				_fail("remote input rejected")
				return {}
		checksum = _advance(session, state, checksum)
		frame = session.status().current_frame
	if session.status().current_frame != FRAMES:
		_fail("the steady run did not reach the last frame")
		return {}
	var usec: int = Time.get_ticks_usec() - start
	return {"usec": usec, "checksum": checksum}


func _rollback_run(players: int) -> Dictionary:
	var session: RefCounted = _session(players)
	var state: PackedByteArray = PackedByteArray()
	state.resize(STATE_BYTES)
	state.fill(1)
	var checksum: int = HASH_OFFSET
	var start: int = Time.get_ticks_usec()
	var delivered: int = 0
	var steps: int = 0
	while session.status().current_frame < FRAMES and steps < FRAMES * 4:
		steps += 1
		var current: int = session.status().current_frame
		if current >= delivered + WINDOW - 1:
			# The remote inputs arrive one window late, so the session corrects
			# its prediction and resimulates the whole window.
			for pending: int in range(WINDOW):
				for player: int in range(1, players):
					var remote: PackedByteArray = PackedByteArray([(delivered + player) & 255])
					if session.receive_input(player, delivered, remote).code != Types.Code.OK:
						_fail("remote input rejected")
						return {}
				delivered += 1
		checksum = _advance(session, state, checksum)
	if session.status().current_frame != FRAMES:
		_fail("the rollback run did not reach the last frame")
		return {}
	var statistics: RefCounted = session.statistics()
	# The session predicts WINDOW frames ahead of the last confirmed frame, so
	# the deepest correction it can reach rewinds WINDOW - 1 frames.
	if statistics.rollback_count == 0 or statistics.max_rollback_depth != WINDOW - 1:
		_fail("the rollback run did not correct the window: %d rollbacks, depth %d" % [statistics.rollback_count, statistics.max_rollback_depth])
		return {}
	var usec: int = Time.get_ticks_usec() - start
	return {"usec": usec, "checksum": checksum}


func _snapshot_run(payload: PackedByteArray) -> Dictionary:
	# The written bytes are hashed after the measured region, so the checksum
	# never shares the measurement with the copy it checks.
	var production_bytes: Array[PackedByteArray] = []
	var control_bytes: Array[PackedByteArray] = []
	var start: int = Time.get_ticks_usec()
	for index: int in range(FRAMES):
		var writer: RefCounted = Writer.new(STATE_BYTES)
		if writer.write_bytes(payload) != Status.Code.OK:
			_fail("production writer failed")
			return {}
		production_bytes.append(writer._written_copy())
	var production: int = Time.get_ticks_usec() - start
	start = Time.get_ticks_usec()
	for index: int in range(FRAMES):
		var writer: RefCounted = ControlWriter.new(STATE_BYTES)
		if writer.write_bytes(payload) != Status.Code.OK:
			_fail("control writer failed")
			return {}
		control_bytes.append(writer.written())
	var control: int = Time.get_ticks_usec() - start
	var checksum: int = HASH_OFFSET
	for bytes: PackedByteArray in production_bytes:
		checksum = _hash_bytes(bytes, checksum)
	for bytes: PackedByteArray in control_bytes:
		checksum = _hash_bytes(bytes, checksum)
	return {"production_us": production, "control_us": control, "checksum": checksum}


# Advances the session by one batch and returns the updated checksum.
func _advance(session: RefCounted, state: PackedByteArray, checksum: int) -> int:
	var current: int = session.status().current_frame
	if session.submit_local_input(0, current, PackedByteArray(LOCAL)).code != Types.Code.OK:
		_fail("local input rejected")
		return checksum
	var result: RefCounted = session.begin_advance()
	if result.code != Types.Code.READY:
		_fail("the session did not accept the advance")
		return checksum
	while true:
		var request: RefCounted = result.batch.next_request()
		if request == null:
			break
		match request.kind:
			Types.Kind.SAVE:
				if request.writer.write_bytes(state) != Status.Code.OK:
					_fail("save failed")
					return checksum
			Types.Kind.LOAD:
				var restored: RefCounted = request.reader.read_bytes(STATE_BYTES)
				if restored.code != Status.Code.OK:
					_fail("load failed")
					return checksum
				state = restored.bytes
			Types.Kind.ADVANCE:
				for player: int in range(request.inputs.player_count()):
					var sample: RefCounted = request.inputs.read(player)
					checksum = _hash_bytes(sample.bytes, checksum)
					checksum = _hash_bytes(PackedByteArray([sample.status]), checksum)
		if session.complete_request(request.batch_id, request.request_id, true, _checksum()).code != Types.Code.OK:
			_fail("request completion rejected")
			return checksum
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
		_fail("session configuration failed")
	return session


func _hash_bytes(bytes: PackedByteArray, seed: int) -> int:
	var value: int = seed
	for index: int in range(bytes.size()):
		value = ((value ^ bytes[index]) * HASH_PRIME) & HASH_MASK
	return value


func _checksum() -> PackedByteArray:
	var checksum: PackedByteArray = PackedByteArray()
	checksum.resize(16)
	checksum[15] = 255
	return checksum


func _summary(samples: Array[int], checksum: int, iterations: int) -> Dictionary:
	var sorted: Array[int] = samples.duplicate()
	sorted.sort()
	return {
		"p50_us": _percentile(samples, 50),
		"p95_us": _percentile(samples, 95),
		"p99_us": _percentile(samples, 99),
		"min_us": sorted[0],
		"max_us": sorted[sorted.size() - 1],
		"iterations": iterations,
		"checksum": checksum,
	}


func _percentile(samples: Array[int], percentile: int) -> int:
	var sorted: Array[int] = samples.duplicate()
	sorted.sort()
	var index: int = int(ceil(percentile / 100.0 * sorted.size())) - 1
	return sorted[clampi(index, 0, sorted.size() - 1)]


func _matches_baseline(report: Dictionary) -> bool:
	if report["snapshot"]["checksum"] != BASELINE["snapshot"]:
		return false
	for entry: Dictionary in report["reports"]:
		var players: int = entry["players"]
		if entry["driver"]["checksum"] != BASELINE["steady"][players]:
			return false
		for name: String in ["steady", "rollback", "codec"]:
			if entry[name]["checksum"] != BASELINE[name][players]:
				return false
	return true


func _fail(reason: String) -> void:
	push_error(reason)
	quit(1)
