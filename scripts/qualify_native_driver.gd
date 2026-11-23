extends SceneTree

const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Writer = preload("res://addons/fortress_rollback/core/snapshot_writer.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const TARGET_FRAME: int = 48
const HOLD_TICKS: int = 24
var _control: bool = false


class ObservedGame extends Simulation:
	var at_target: PackedByteArray
	var wrong_rows: Dictionary = {}
	var abort_driver: WeakRef
	var expired_inside_save: bool = false
	var aborted_save_frame: int = -1
	var aborted_save_state: PackedByteArray
	var aborted_save_calls: int = 0

	func save_state(saved_frame: int, writer: Writer) -> Driver.SaveResult:
		if abort_driver == null:
			return super(saved_frame, writer)
		aborted_save_frame = saved_frame
		aborted_save_state = canonical_bytes()
		aborted_save_calls += 1
		var owner: Driver = abort_driver.get_ref()
		owner.terminate()
		expired_inside_save = writer.write_bytes(PackedByteArray([4])) == Writer.Code.EXPIRED_VIEW
		return Driver.SaveResult.new(false)

	func simulate_frame(input_frame: int, inputs: Types.FrameInputs) -> bool:
		if not super(input_frame, inputs):
			return false
		var exact: bool = true
		for slot: int in inputs.player_count():
			if inputs.read(slot).bytes != sample(slot, input_frame):
				exact = false
		if exact:
			wrong_rows.erase(input_frame)
		else:
			wrong_rows[input_frame] = true
		if frame == TARGET_FRAME:
			at_target = canonical_bytes()
		return true

	static func sample(slot: int, frame: int) -> PackedByteArray:
		var bytes: PackedByteArray = PackedByteArray([0, 0, 0, 0])
		bytes.encode_u32(0, (slot * 5 + frame * 3) % 16)
		return bytes


func _initialize() -> void:
	_control = "--wrong-sample" in OS.get_cmdline_user_args()
	if not Driver.Native.available():
		printerr("Native driver qualification requires the installed addon")
		quit(1)
		return
	for players: int in range(2, 9):
		var addresses: PackedInt32Array = PackedInt32Array()
		for slot: int in players:
			addresses.append(slot + 1)
		if not _qualify(addresses):
			quit(1)
			return
	for layout: Array in [[1, 1, 1, 1, 1, 1, 1, 2], [8, 2, 5, 8, 5, 2, 8, 5]]:
		if not _qualify(PackedInt32Array(layout)):
			quit(1)
			return
	if not _qualify(PackedInt32Array([1, 2]), true):
		quit(1)
		return
	quit(0)


func _qualify(addresses: PackedInt32Array, abort_on_correction: bool = false) -> bool:
	var players: int = addresses.size()
	var endpoints: PackedInt32Array = PackedInt32Array()
	for address: int in addresses:
		if address not in endpoints:
			endpoints.append(address)
	var drivers: Array[Driver] = []
	var games: Array[ObservedGame] = []
	for endpoint: int in endpoints:
		var roster: PackedInt32Array = addresses.duplicate()
		var local_slots: PackedInt32Array = PackedInt32Array()
		for slot: int in players:
			if roster[slot] == endpoint:
				roster[slot] = 0
				local_slots.append(slot)
		var game: ObservedGame = ObservedGame.new(players, Driver.Native.INPUT_BYTES)
		var driver: Driver = Driver.new()
		if driver.configure_native(roster, game, game.snapshot_bytes()) != Types.Code.OK:
			return _failed(addresses, "native driver configuration")
		if driver.local_players() != local_slots:
			return _failed(addresses, "incorrect local slot order at endpoint %d" % endpoint)
		games.append(game)
		drivers.append(driver)
	var expected: PackedByteArray = _expected_state(players)
	var held: Array[Dictionary] = []
	var hold_from: int = -1
	var conflict_checked: bool = false
	for tick: int in 500:
		# Stock Fortress retransmits on its real monotonic clock. Input and fault order are tick-based.
		OS.delay_msec(2)
		if hold_from < 0 and _all_confirmed(drivers, 4):
			hold_from = tick
		var holding: bool = hold_from >= 0 and tick - hold_from < HOLD_TICKS
		if not holding and not held.is_empty():
			for packet: Dictionary in held:
				if not drivers[packet.to].receive_native(packet.from, packet.bytes):
					return _failed(addresses, "could not release held packet")
			held.clear()
			if abort_on_correction:
				if not _qualify_termination(drivers[0], games[0], tick):
					return _failed(addresses, "callback termination during correction")
				return true
		for endpoint: int in drivers.size():
			var driver: Driver = drivers[endpoint]
			var frame: int = driver.status().current_frame
			var row: Array[PackedByteArray] = []
			var local_slots: PackedInt32Array = driver.local_players()
			for slot: int in local_slots:
				var retained: Types.InputResult = driver.scheduled_local_input(slot)
				var sample: PackedByteArray = ObservedGame.sample(slot, frame)
				if _control and frame == 12 and slot == 0:
					sample[0] ^= 1
				if retained.code == Types.Code.OK:
					if retained.bytes != sample or retained.frame != frame:
						return _failed(addresses, "stalled sample changed")
					sample = PackedByteArray()
				row.append(sample)
			var step: Driver.StepResult = driver.step_local(tick, row)
			if step.code not in [Types.Code.OK, Types.Code.NOT_SYNCHRONIZED, Types.Code.PREDICTION_STALL]:
				return _failed(addresses, "step failed (%s)" % Types.reason_text(step.code))
			if step.code == Types.Code.PREDICTION_STALL and not conflict_checked:
				row[0] = ObservedGame.sample(local_slots[0], frame + 1)
				var conflict: Driver.StepResult = driver.step_local(tick, row)
				if conflict.code != Types.Code.INPUT_ALREADY_SUBMITTED or conflict.frame_after != frame:
					return _failed(addresses, "conflicting stalled sample was accepted")
				conflict_checked = true
			for packet: Dictionary in driver.drain_native_packets():
				var destination: int = packet.endpoint
				var to: int = endpoints.find(destination)
				var sender: int = endpoints[endpoint]
				if to < 0 or to == endpoint:
					return _failed(addresses, "invalid destination %d from endpoint %d" % [destination, sender])
				if holding and (to == drivers.size() - 1 or endpoint == drivers.size() - 1):
					held.append({"to": to, "from": sender, "bytes": packet.bytes})
				elif not drivers[to].receive_native(sender, packet.bytes):
					return _failed(addresses, "could not route native packet")
		if _all_confirmed(drivers, TARGET_FRAME - 1):
			if abort_on_correction:
				return _failed(addresses, "no held packets released for corrective termination")
			var restores: int = 0
			var stalls: int = 0
			for endpoint: int in drivers.size():
				var game: ObservedGame = games[endpoint]
				var counts: Types.Statistics = drivers[endpoint].statistics()
				restores += counts.rollback_count
				stalls += counts.prediction_stalls
				for wrong: int in game.wrong_rows:
					if wrong < TARGET_FRAME:
						return _failed(addresses, "incorrect confirmed input at frame %d (endpoint %d)" % [wrong, endpoints[endpoint]])
				if game.at_target != expected:
					return _failed(addresses, "canonical state differs at frame %d (endpoint %d)" % [TARGET_FRAME, endpoints[endpoint]])
			if restores == 0 or stalls == 0 or not conflict_checked:
				return _failed(addresses, "missing restore, stall or conflicting-input control")
			print("Native driver slots=%s confirmed=%d restores=%d stalls=%d conflicting_sample=rejected sha256=%s" % [
				addresses, TARGET_FRAME - 1, restores, stalls, _sha256(expected)])
			return true
	return _failed(addresses, "confirmation deadline")


func _qualify_termination(driver: Driver, game: ObservedGame, now_us: int) -> bool:
	var before: Types.Status = driver.status()
	var frontier: int = before.current_frame
	var retained: Types.InputResult = driver.scheduled_local_input(0)
	var row: Array[PackedByteArray] = [PackedByteArray() if retained.code == Types.Code.OK else ObservedGame.sample(0, frontier)]
	game.abort_driver = weakref(driver)
	var ended: Driver.StepResult = driver.step_local(now_us, row)
	var later: Driver.StepResult = driver.step_local(now_us + 1, row)
	var after: Types.Status = driver.status()
	var saved: int = game.aborted_save_frame
	if saved < 0 or saved >= frontier or game.aborted_save_calls != 1 or not game.expired_inside_save:
		return false
	if game.frame != saved or game.canonical_bytes() != game.aborted_save_state:
		return false
	for result: Driver.StepResult in [ended, later]:
		if result.code != Types.Code.TERMINATED or result.reason != Types.Code.TERMINATED or result.failure_kind != Types.Kind.SAVE:
			return false
		if result.failure_frame != saved or result.frame_before != frontier or result.frame_after != frontier:
			return false
	if after.lifecycle != Types.Lifecycle.TERMINATED or after.current_frame != frontier or after.confirmed_frame != before.confirmed_frame:
		return false
	print("Native driver corrective termination save=%d frontier=%d writer_expired=true" % [saved, frontier])
	return true


func _all_confirmed(drivers: Array[Driver], frame: int) -> bool:
	for driver: Driver in drivers:
		if driver.status().confirmed_frame < frame:
			return false
	return true


func _expected_state(players: int) -> PackedByteArray:
	var game: Simulation = Simulation.new(players, Driver.Native.INPUT_BYTES)
	for frame: int in TARGET_FRAME:
		var row: Array[PackedByteArray] = []
		var statuses: PackedInt32Array = PackedInt32Array()
		for slot: int in players:
			row.append(ObservedGame.sample(slot, frame))
			statuses.append(Types.Queue.Status.CONFIRMED)
		if not game.simulate_frame(frame, Types.FrameInputs.new(row, statuses)):
			return PackedByteArray()
	return game.canonical_bytes()


func _sha256(bytes: PackedByteArray) -> String:
	var hash: HashingContext = HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	return hash.finish().hex_encode()


func _failed(addresses: PackedInt32Array, reason: String) -> bool:
	printerr("Native driver slots=%s: %s" % [addresses, reason])
	return false
