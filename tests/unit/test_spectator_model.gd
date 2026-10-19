extends RefCounted

const Publisher = preload("res://addons/fortress_rollback/core/spectator_publisher.gd")
const Stream = preload("res://addons/fortress_rollback/core/spectator_stream.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Fixture = preload("res://tests/unit/test_spectator_session.gd")
const GameFixture = preload("res://tests/unit/test_driver.gd")
const CODE = Types.Code
const FRAMES: int = 12


class TranscriptGame:
	extends GameFixture.Game
	var transcript: PackedByteArray = PackedByteArray()

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		transcript.append(frame)
		for player: int in range(inputs.size().value):
			transcript.append_array(inputs.read(player).bytes)
			value += inputs.read(player).bytes[0]
		return true


# This finite model knows only an ordered input log and which rows were delivered.
# It deliberately has no physical ring, core queues, packet decoder or session requests.
class Model:
	extends RefCounted
	var received: Dictionary = {}
	var played: int = 0
	var transcript: PackedByteArray = PackedByteArray()

	func ready(delay: int, closed: bool) -> int:
		var playable: Array[int] = []
		for frame: int in range(played, FRAMES):
			if not received.has(frame):
				break
			playable.append(frame)
		if not closed:
			for _held: int in range(delay):
				if not playable.is_empty():
					playable.pop_back()
		return playable.size()

	func consume() -> void:
		transcript.append(played)
		transcript.append_array(Fixture.new()._row(played)[0])
		transcript.append_array(Fixture.new()._row(played)[1])
		played += 1


func cases() -> PackedStringArray:
	return PackedStringArray(["bounded_delivery_model", "caller_bounded_catchup_model", "loss_and_conflict_model", "transcript_mutation_control"])


func run_case(name: String, context: RefCounted) -> void:
	call("_" + name, context)
	context.finish()


func _identity() -> PackedByteArray:
	var identity: PackedByteArray = PackedByteArray()
	identity.resize(32)
	return identity


func _config(capacity: int) -> RefCounted:
	var config: RefCounted = Fixture.new()._config()
	config.queue_capacity = capacity
	config.storage_budget_bytes = config.required_storage_bytes()
	return config


# Value: protects=canonical playback; fails_when=delay/gaps/retries corrupt history; why_new=no independent playback model; seam=none
func _bounded_delivery_model(context: RefCounted) -> void:
	for seed_value: int in range(12):
		for capacity: int in [2, 3, 5]:
			for delay: int in [0, capacity - 1]:
				_explore(context, seed_value, capacity, delay)


func _explore(context: RefCounted, seed_value: int, capacity: int, delay: int) -> void:
	var label: String = "seed=%d capacity=%d delay=%d" % [seed_value, capacity, delay]
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed_value
	var config: RefCounted = _config(capacity)
	config.spectator = false
	config.local_players = PackedInt32Array([0, 1])
	var host: RefCounted = Session.new()
	context.equal(host.configure(config), CODE.OK, label + " host configuration")
	var host_game: TranscriptGame = TranscriptGame.new()
	var host_driver: RefCounted = Driver.new(host, host_game)
	var publisher: RefCounted = Publisher.new()
	context.equal(publisher.configure(host, _identity(), 50), CODE.OK, label + " publisher configuration")
	# The fixture transport owns a finite twelve-row backlog, independently of host retention.
	var packets: Array[PackedByteArray] = []
	for frame: int in range(FRAMES):
		var inputs: Array[Driver.LocalInput] = []
		for player: int in range(2):
			inputs.append(Driver.LocalInput.new(player, frame, Fixture.new()._row(frame)[player]))
		context.equal(host_driver.step(frame, inputs).code, CODE.OK, label + " host input")
		var packet: Types.InputResult = publisher.prepare_packet()
		context.equal(packet.code, CODE.OK, label + " publish confirmed original")
		packets.append(packet.bytes)
		context.equal(publisher.acknowledge_packet(packet.bytes), CODE.OK, label + " transport owns row")
	context.equal(publisher.finish_host(), CODE.OK, label + " freeze original history")
	var end: PackedByteArray = publisher.prepare_packet().bytes
	context.equal(publisher.acknowledge_packet(end), CODE.OK, label + " transport owns end")
	var stream: RefCounted = Stream.new()
	context.equal(stream.configure(_config(capacity), _identity(), 0, 10000, 50), CODE.OK, label + " viewer configuration")
	var viewer: RefCounted = stream.playback_session()
	var game: TranscriptGame = TranscriptGame.new()
	var driver: RefCounted = Driver.new(viewer, game)
	context.equal(viewer.set_confirmation_limit(-1).code, CODE.UNSUPPORTED, label + " player confirmation policy is unavailable")
	var model: Model = Model.new()
	var end_first: bool = seed_value % 2 == 0
	context.equal(viewer.set_playback(delay, 1, capacity), CODE.OK, label + " playback configuration")
	if end_first:
		context.equal(stream.receive_packet(end, 0), CODE.OK, label + " END overtakes complete backlog")
	context.equal(stream.receive_packet(packets[FRAMES - 1], 1), CODE.NETWORK_BACKPRESSURE, label + " far future retains caller ownership")
	var now_us: int = 1
	var duplicates: int = 0
	var pressures: int = 1
	while model.played < FRAMES and now_us < 500:
		now_us += 1
		var frame: int = rng.randi_range(model.played, FRAMES - 1)
		# A fair scheduler eventually services the missing head, including after a long pause.
		if now_us % 7 == 0:
			frame = model.played
		var code: int = stream.receive_packet(packets[frame], now_us)
		if frame - model.played >= capacity:
			context.equal(code, CODE.NETWORK_BACKPRESSURE, label + " bounded future refusal")
			pressures += 1
		else:
			context.equal(code, CODE.TERMINATED if end_first and model.received.size() == FRAMES else CODE.OK, label + " delivered complete row")
			model.received[frame] = true
			context.equal(
				stream.receive_packet(packets[frame], now_us),
				CODE.TERMINATED if end_first and model.received.size() == FRAMES else CODE.OK,
				label + " retained duplicate cannot reopen closed input"
			)
			duplicates += 1
		var closed: bool = end_first and model.received.size() == FRAMES
		var ready: int = model.ready(delay, closed)
		var advice: int = 0
		if ready > 0:
			advice = mini(ready, capacity) if ready > 1 else 1
		context.equal(viewer.recommended_steps(), advice, label + " model service advice")
		# Sometimes ignore advice and call directly: stream delay and gaps still must hold.
		var attempts: int = advice if now_us % 3 != 0 else 1
		for _attempt: int in range(attempts):
			var can_play: bool = model.ready(delay, closed) > 0
			var empty: Array[Driver.LocalInput] = []
			context.equal(driver.step(now_us, empty).code, CODE.OK if can_play else CODE.PREDICTION_STALL, label + " model advance eligibility")
			if can_play:
				model.consume()
			context.bytes_equal(game.transcript, model.transcript, model.played, label + " canonical prefix")
			context.equal(viewer.status().current_frame, model.played, label + " playback boundary")
		# Late END releases a delayed tail only after every original row has arrived.
		if not end_first and model.received.size() == FRAMES:
			context.equal(stream.receive_packet(end, now_us), CODE.OK, label + " delayed END releases tail")
			end_first = true
	context.equal(model.played, FRAMES, label + " bounded schedule completes")
	context.equal(duplicates > 0 and pressures > 0, true, label + " required hostile schedule witnesses")
	context.equal(game.transcript, host_game.transcript, label + " exact original host transcript")
	context.equal(viewer.statistics().rollback_count, 0, label + " confirmed-only playback")
	var empty: Array[Driver.LocalInput] = []
	context.equal(viewer.recommended_steps(), 1, label + " final lifecycle service")
	context.equal(driver.step(now_us + 1, empty).code, CODE.TERMINATED, label + " clean final boundary")
	context.equal(viewer.recommended_steps(), 0, label + " terminal viewer is idle")
	context.equal(host.status().current_frame, FRAMES, label + " viewer never advances host")
	context.equal(host.status().confirmed_frame, FRAMES - 1, label + " viewer never changes player confirmation")
	context.equal(host.status().reason, CODE.OK, label + " viewer lifecycle never terminates host")


# Value: protects=caller catchup bound; fails_when=speed clamp or strict threshold is lost; why_new=seeded schedules use speed=capacity; seam=none
func _caller_bounded_catchup_model(context: RefCounted) -> void:
	var stream: RefCounted = Stream.new()
	context.equal(stream.configure(_config(5), _identity(), 0, 10000, 50), CODE.OK, "catchup model configuration")
	var viewer: RefCounted = stream.playback_session()
	var game: TranscriptGame = TranscriptGame.new()
	var driver: RefCounted = Driver.new(viewer, game)
	var model: Model = Model.new()
	context.equal(viewer.set_playback(1, 2, 3), CODE.OK, "catchup speed is smaller than ring capacity")
	context.equal(viewer.recommended_steps(), 0, "catchup waits for history")
	# Withhold service to cross both the strict threshold and the caller's speed bound.
	var expected_ready: PackedInt32Array = PackedInt32Array([0, 1, 2, 3, 4])
	var expected_advice: PackedInt32Array = PackedInt32Array([0, 1, 1, 3, 3])
	for frame: int in range(5):
		context.equal(stream.receive_packet(stream.encode_row(frame, Fixture.new()._row(frame)), frame), CODE.OK, "accumulate catchup backlog")
		model.received[frame] = true
		context.equal(model.ready(1, false), expected_ready[frame], "independent delayed backlog frame=%d" % frame)
		context.equal(viewer.recommended_steps(), expected_advice[frame], "catchup boundary ready=%d threshold=2 speed=3" % expected_ready[frame])
		context.equal(viewer.status().current_frame, 0, "advice never advances caller's game")
	context.equal(stream.receive_packet(stream.encode_end(5), 6), CODE.OK, "closed stream releases delayed row")
	# A caller services three, then one at the exact threshold, then the remaining row.
	for advice: int in [3, 1, 1]:
		context.equal(viewer.recommended_steps(), advice, "caller recomputes bounded catchup after each cycle")
		for _attempt: int in range(advice):
			var empty: Array[Driver.LocalInput] = []
			context.equal(driver.step(7, empty).code, CODE.OK, "caller owns each catchup advance")
			model.consume()
			context.bytes_equal(game.transcript, model.transcript, model.played, "catchup preserves canonical prefix")
			context.equal(viewer.status().current_frame, model.played, "catchup exposes exact caller progress")
	context.equal(model.played, 5, "caller drains entire bounded history")
	context.equal(viewer.recommended_steps(), 1, "catchup services final lifecycle")
	var empty: Array[Driver.LocalInput] = []
	context.equal(driver.step(8, empty).code, CODE.TERMINATED, "catchup reaches clean completion")
	context.equal(viewer.recommended_steps(), 0, "completed catchup is idle")


# Value: protects=host-loss precedence; fails_when=keepalives fill gaps or failures play history; why_new=clean model excludes host loss; seam=none
func _loss_and_conflict_model(context: RefCounted) -> void:
	for failure: String in ["deadline", "foreign", "conflict"]:
		var stream: RefCounted = Stream.new()
		context.equal(stream.configure(_config(3), _identity(), 0, 10, 50), CODE.OK, failure + " configuration")
		var viewer: RefCounted = stream.playback_session()
		var game: TranscriptGame = TranscriptGame.new()
		var driver: RefCounted = Driver.new(viewer, game)
		context.equal(stream.receive_packet(stream.encode_end(3), 0), CODE.OK, "END cannot fill missing history")
		context.equal(stream.receive_packet(stream.encode_row(2, Fixture.new()._row(2)), 1), CODE.OK, "future tail waits behind gap")
		context.equal(stream.receive_packet(stream.encode_keepalive(), 9), CODE.OK, "liveness does not supply rows")
		context.equal(viewer.recommended_steps(), 0, "live gap remains unplayable")
		if failure == "conflict":
			var conflict: PackedByteArray = stream.encode_row(2, Fixture.new()._row(2))
			conflict[48] ^= 1
			context.equal(stream.receive_packet(conflict, 10), CODE.PROTOCOL_FAILED, "conflict is terminal before expiry")
		else:
			if failure == "foreign":
				var foreign: PackedByteArray = stream.encode_keepalive()
				foreign[12] ^= 1
				context.equal(stream.receive_packet(foreign, 18), CODE.PROTOCOL_FAILED, "foreign traffic does not extend liveness")
			context.equal(stream.poll(18), CODE.OK, "strictly before authenticated deadline")
			context.equal(stream.receive_packet(stream.encode_row(0, Fixture.new()._row(0)), 19), CODE.PROTOCOL_FAILED, "deadline wins over gap repair")
		var empty: Array[Driver.LocalInput] = []
		context.equal(driver.step(20, empty).code, CODE.TERMINATED, "failure stops buffered game history")
		context.equal(game.transcript.is_empty(), true, "no callback runs on failed stream")
		context.equal(viewer.status().reason, CODE.PROTOCOL_FAILED, "exact committed failure reason")


# Value: protects=temporal-corruption detection; fails_when=only final totals are checked; why_new=green schedules cannot prove observer sensitivity; seam=none
func _transcript_mutation_control(context: RefCounted) -> void:
	var totals: PackedInt64Array = PackedInt64Array()
	for mutate: bool in [false, true]:
		var stream: RefCounted = Stream.new()
		context.equal(stream.configure(_config(3), _identity(), 0, 100, 50), CODE.OK, "mutation fixture configured")
		var game: TranscriptGame = TranscriptGame.new()
		var driver: RefCounted = Driver.new(stream.playback_session(), game)
		var model: Model = Model.new()
		for frame: int in range(2):
			var packet: PackedByteArray = stream.encode_row(frame, Fixture.new()._row(frame))
			if mutate:
				# Change actual encoded body bytes while preserving frame, identity and dimensions.
				var replacement: Array[PackedByteArray] = Fixture.new()._row(1 - frame)
				packet[48] = replacement[0][0]
				packet[49] = replacement[1][0]
			context.equal(stream.receive_packet(packet, frame), CODE.OK, "well-formed temporal mutation reaches real decoder")
			var empty: Array[Driver.LocalInput] = []
			context.equal(driver.step(frame, empty).code, CODE.OK, "well-formed temporal mutation reaches real callback")
			model.consume()
			context.equal(game.transcript == model.transcript, not mutate, "original-log prefix observer detects changed body at frame=%d" % frame)
		totals.append(game.value)
	context.equal(totals[0], totals[1], "temporal mutation preserves final gameplay total; a final checksum alone would miss it")
