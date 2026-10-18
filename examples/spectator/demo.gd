class_name FortressSpectatorDemo
extends RefCounted

## Local host and delayed viewer. Transport is injected in this process, without a spectator network protocol.
const Host = preload("res://examples/integration/demo.gd")
const Game = preload("res://examples/integration/game.gd")
const Spectator = preload("res://addons/fortress_rollback/core/spectator_session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const SEND_BUDGET: int = 16

var host: Host
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
	viewer = Spectator.new()
	code = viewer.configure(config)
	if code != Types.Code.OK:
		return code
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
	var status: Types.Status = host.loop.session.status()
	var last: int = mini(status.confirmed_frame, status.current_frame - 1)
	for _work: int in range(SEND_BUDGET):
		if next_host_frame > last:
			break
		var inputs: Types.FrameInputs = host.loop.session.confirmed_inputs(next_host_frame)
		if inputs == null:
			viewer_code = Types.Code.HISTORY_UNAVAILABLE
			viewer.terminate(viewer_code)
			return code
		var row: Array[PackedByteArray] = [inputs.read(0).bytes, inputs.read(1).bytes]
		viewer_code = viewer.receive_host_frame(next_host_frame, row).code
		if viewer_code != Types.Code.OK:
			break
		next_host_frame += 1
	if not is_paused:
		var samples: Array[Driver.LocalInput] = []
		for _step: int in range(viewer.recommended_steps()):
			viewer_code = driver.step(host.tick_count * Host.TICK_US, samples).code
			if viewer_code != Types.Code.OK:
				break
	return code
