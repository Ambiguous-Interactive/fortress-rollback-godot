extends RefCounted

const Fixture = preload("res://tests/unit/test_spectator_session.gd")
const Wire = preload("res://tests/unit/test_spectator_stream.gd")
const GameFixture = preload("res://tests/unit/test_driver.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Stream = preload("res://addons/fortress_rollback/core/spectator_stream.gd")
const Publisher = preload("res://addons/fortress_rollback/core/spectator_publisher.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
const Code = Types.Code
const FRAMES: int = 24


class Game:
	extends GameFixture.Game

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		for player: int in range(inputs.size().value):
			var input: Types.InputResult = inputs.read(player)
			value = (value * 17 + frame + player + input.status * 31) % 1000000007
			for byte: int in input.bytes:
				value = (value * 257 + byte) % 1000000007
		return true


func cases() -> PackedStringArray:
	return PackedStringArray(["authenticated_history", "history_controls"])


func run_case(name: String, context: RefCounted) -> void:
	call("_" + name, context)
	context.finish()


# Value: protects=all roster slots and sample bytes survive authenticated delayed delivery and ring reuse;
# fails_when=publication, reordering or pressure rewrites finalized history; why_new=wire shape checks stop before reuse; seam=none
func _authenticated_history(context: RefCounted) -> void:
	for players: int in range(2, 9):
		for width: int in [1, 4]:
			for delay: int in [0, 2]:
				_history(context, players, width, delay, false)


# Value: protects=canonical witness detects lost disconnected statuses; fails_when=reference ignores status;
# why_new=authentication rejects forged packets but cannot establish application checksum sensitivity; seam=none
func _history_controls(context: RefCounted) -> void:
	_history(context, 3, 4, 2, true)


func _history(context: RefCounted, players: int, width: int, delay: int, erase_status: bool) -> void:
	var wire: RefCounted = Wire.new()
	var config: RefCounted = Fixture.new()._config()
	config.player_count = players
	config.input_width = width
	config.neutral_input.resize(width)
	config.replay_max_frames = FRAMES
	config.storage_budget_bytes = config.required_storage_bytes()
	var stream: Stream = Stream.new()
	var digest: PackedByteArray = wire._digest(config)
	context.equal(stream.configure(config, wire._identity(), wire._key(), digest, 0, 10000, 256), Code.OK, "viewer shape")
	var viewer: RefCounted = stream.playback_session()
	context.equal(viewer.set_playback(delay, 1, 3), Code.OK, "bounded delay and catchup")
	var game: Game = Game.new()
	var viewer_driver: Driver = Driver.new(viewer, game)
	var host_config: RefCounted = Fixture.new().host_config()
	host_config.player_count = players
	host_config.input_width = width
	host_config.neutral_input.resize(width)
	host_config.local_players = PackedInt32Array()
	for player: int in range(players - 1):
		host_config.local_players.append(player)
	host_config.storage_budget_bytes = host_config.required_storage_bytes()
	var host: Session = Session.new()
	context.equal(host.configure(host_config), Code.OK, "player host shape")
	var host_game: Game = Game.new()
	var host_driver: Driver = Driver.new(host, host_game)
	var publisher: Publisher = Publisher.new()
	context.equal(publisher.configure(host, wire._identity(), wire._key(), digest, 256), Code.OK, "source publisher")
	context.equal(Fixture.new().negotiate(publisher, stream), Code.OK, "authenticated startup")
	var expected: PackedInt64Array = PackedInt64Array()
	var pressure_count: int = 0
	for base: int in range(0, FRAMES, 4):
		var packets: Array[PackedByteArray] = []
		for frame: int in range(base, base + 4):
			var samples: Array[Driver.LocalInput] = []
			for player: int in range(players - 1):
				samples.append(Driver.LocalInput.new(player, frame, _sample(frame, player, width)))
			if frame == 0:
				context.equal(host.receive_input(players - 1, 0, _sample(0, players - 1, width)).code, Code.OK, "remote original input")
			context.equal(host_driver.step(frame, samples).code, Code.OK, "source advances original row")
			expected.append(_reference(expected[frame - 1] if frame > 0 else 0, frame, players, width))
			context.equal(_state(host_game.value), _state(expected[frame]), "source canonical original history")
			var packet: PackedByteArray = publisher.prepare_packet().bytes
			context.equal(publisher.prepare_packet().bytes, packet, "refused publication retains exact bytes")
			packets.append(packet)
			context.equal(publisher.acknowledge_packet(packet), Code.OK, "accepted source packet")
			if frame == 0:
				context.equal(host.freeze_player(players - 1, 0), Code.OK, "finalized disconnected suffix")
		var refused: Array[PackedByteArray] = []
		for index: int in [3, 1, 0, 2]:
			var packet: PackedByteArray = packets[index]
			var forged: PackedByteArray = packet.duplicate()
			forged[Stream.HEADER_BYTES + width - 1] ^= 1
			context.equal(stream.receive_packet(forged, base + 99), Code.PROTOCOL_FAILED, "tampered bytes refused before clock commitment")
			context.equal(viewer.status().reason, Code.OK, "forgery cannot terminate authenticated playback")
			if erase_status:
				packet = _without_status(packet, wire)
			var received: int = stream.receive_packet(packet, base + 1)
			if received == Code.NETWORK_BACKPRESSURE:
				refused.append(packet)
				pressure_count += 1
			else:
				context.equal(received, Code.OK, "reordered row accepted")
				context.equal(stream.receive_packet(packet, base + 1), Code.OK, "retained duplicate is idempotent")
		_service(context, viewer_driver, viewer, game, expected, base + 1, erase_status)
		for packet: PackedByteArray in refused:
			context.equal(stream.receive_packet(packet, base + 1), Code.OK, "exact pressure retry recovers after playback")
		_service(context, viewer_driver, viewer, game, expected, base + 1, erase_status)
		context.equal(viewer.status().current_frame, base + 4 - delay, "delay holds exact bounded tail")
	context.equal(pressure_count, 5 if delay == 2 else 0, "pressure injection exercised after startup")
	context.equal(host.confirmed_inputs(0), null, "source ring reused original history slots")
	context.equal(viewer.confirmed_inputs(0), null, "viewer ring reused original history slots")
	context.equal(publisher.finish_host(), Code.OK, "freeze exact confirmed source ending")
	var ending: PackedByteArray = publisher.prepare_packet().bytes
	context.equal(stream.receive_packet(ending, FRAMES), Code.OK, "authenticated END releases delayed tail")
	context.equal(publisher.acknowledge_packet(ending), Code.OK, "source ending accepted")
	_service(context, viewer_driver, viewer, game, expected, FRAMES, erase_status)
	context.equal(viewer.is_complete(), true, "ordinary service completes clean input")
	context.equal(viewer.status().current_frame, FRAMES, "no row skipped through final boundary")
	context.equal(game.value != expected[FRAMES - 1], erase_status, "negative control detects authenticated status erasure")
	context.equal(viewer.replay().frame_count(), FRAMES, "all played rows remain exportable in bounded recording")
	var recording: RefCounted = viewer.replay()
	for frame: int in range(FRAMES):
		for player: int in range(players):
			var input: Types.InputResult = recording.inputs(frame).read(player)
			context.equal(input.bytes, _sample(0 if player == players - 1 else frame, player, width), "recorded original bytes")
			context.equal(input.status, Queue.Status.DISCONNECTED if not erase_status and frame > 0 and player == players - 1 else Queue.Status.CONFIRMED,
				"recorded finalized status")


func _service(context: RefCounted, driver: Driver, viewer: RefCounted, game: Game, expected: PackedInt64Array, now_us: int, erase_status: bool) -> void:
	for _cycle: int in range(5):
		var steps: int = viewer.recommended_steps()
		if steps == 0:
			return
		for _step: int in range(steps):
			var frame: int = viewer.status().current_frame
			var empty: Array[Driver.LocalInput] = []
			var code: int = driver.step(now_us, empty).code
			if code == Code.TERMINATED:
				context.equal(viewer.is_complete(), true, "clean completion owns the final service call")
				return
			context.equal(code, Code.OK, "advised service advances confirmed input")
			if not erase_status:
				context.equal(_state(game.value), _state(expected[frame]), "independent canonical boundary after every played row")


func _sample(frame: int, player: int, width: int) -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray()
	for index: int in range(width):
		bytes.append((frame * 13 + player * 29 + index * 7) % 256)
	return bytes


func _reference(value: int, frame: int, players: int, width: int) -> int:
	for player: int in range(players):
		var disconnected: bool = frame > 0 and player == players - 1
		value = (value * 17 + frame + player + (Queue.Status.DISCONNECTED if disconnected else Queue.Status.CONFIRMED) * 31) % 1000000007
		for index: int in range(width):
			value = (value * 257 + ((0 if player == players - 1 else frame) * 13 + player * 29 + index * 7) % 256) % 1000000007
	return value


func _state(value: int) -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(8)
	bytes.encode_s64(0, value)
	return bytes


func _without_status(packet: PackedByteArray, wire: RefCounted) -> PackedByteArray:
	var unsigned: PackedByteArray = wire._unsigned(packet)
	for index: int in range(unsigned.size() - packet[6], unsigned.size()):
		unsigned[index] = Queue.Status.CONFIRMED
	return Stream.authenticate(unsigned, wire._key())
