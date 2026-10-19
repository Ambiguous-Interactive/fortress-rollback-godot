class_name FortressSpectatorDemo
extends RefCounted

## Local host and delayed viewer exchange bounded spectator bytes in the same process.
const Host = preload("res://examples/integration/demo.gd")
const Game = preload("res://examples/integration/game.gd")
const Stream = preload("res://addons/fortress_rollback/core/spectator_stream.gd")
const Publisher = preload("res://addons/fortress_rollback/core/spectator_publisher.gd")
const Spectator = preload("res://addons/fortress_rollback/core/spectator_session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const SEND_BUDGET: int = 16

var host: Host
var publisher: Publisher
var stream: Stream
var viewer: Spectator
var game: Game
var driver: Driver
var is_paused: bool = false
var viewer_code: int = Types.Code.OK
var next_host_frame: int = 0


func start() -> int:
	host = Host.new()
	var code: int = host.start(3)
	if code != Types.Code.OK:
		return code
	var config: Config = Config.new()
	config.spectator = true
	config.sync_test = false
	config.local_players = PackedInt32Array()
	config.check_distance = 0
	config.max_prediction_frames = 0
	config.history_slots = 1
	config.max_snapshot_bytes = Game.SNAPSHOT_BYTES
	config.storage_budget_bytes = config.required_storage_bytes()
	stream = Stream.new()
	# A local fixture identity; network integrations supply a fresh agreed lifetime.
	var identity: PackedByteArray = PackedByteArray()
	identity.resize(32)
	code = stream.configure(config, identity, 0, 10000000, 256)
	if code != Types.Code.OK:
		return code
	publisher = Publisher.new()
	code = publisher.configure(host.loop.session, identity, 256)
	if code != Types.Code.OK:
		return code
	viewer = stream.playback_session()
	code = viewer.set_playback(12, 4, 4)
	if code != Types.Code.OK:
		return code
	game = Game.new()
	driver = Driver.new(viewer, game)
	is_paused = false
	viewer_code = Types.Code.OK
	next_host_frame = 0
	return Types.Code.OK


## Host continues when the viewer pauses, falls behind or fails. All loops have explicit work bounds.
func tick(buttons: int) -> int:
	if host == null:
		return Types.Code.NOT_CONFIGURED
	var code: int = host.tick(buttons)
	if code != Types.Code.OK and code != Types.Code.PREDICTION_STALL:
		viewer.terminate(code)
		viewer_code = code
		return code
	if viewer_code not in [Types.Code.OK, Types.Code.PREDICTION_STALL, Types.Code.NETWORK_BACKPRESSURE]:
		return code
	viewer_code = stream.poll(host.tick_count * Host.TICK_US)
	if viewer_code != Types.Code.OK:
		return code
	var first_host_frame: int = next_host_frame
	for _work: int in range(SEND_BUDGET):
		var packet: Types.InputResult = publisher.prepare_packet()
		if packet.code == Types.Code.PREDICTION_STALL:
			break
		if packet.code != Types.Code.OK:
			viewer_code = packet.code
			viewer.terminate(viewer_code)
			return code
		viewer_code = stream.receive_packet(packet.bytes, host.tick_count * Host.TICK_US)
		if viewer_code != Types.Code.OK:
			break
		viewer_code = publisher.acknowledge_packet(packet.bytes)
		if viewer_code != Types.Code.OK:
			viewer.terminate(viewer_code)
			return code
		next_host_frame = publisher.next_frame()
	if next_host_frame == first_host_frame:
		var keepalive_code: int = stream.receive_packet(publisher.encode_keepalive(), host.tick_count * Host.TICK_US)
		if keepalive_code != Types.Code.OK:
			viewer_code = keepalive_code
			return code
	if not is_paused:
		var samples: Array[Driver.LocalInput] = []
		for _step: int in range(viewer.recommended_steps()):
			viewer_code = driver.step(host.tick_count * Host.TICK_US, samples).code
			if viewer_code != Types.Code.OK:
				break
	return code
