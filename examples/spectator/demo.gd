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
const REPLAY_FRAMES: int = Host.Loop.REPLAY_FRAMES

var host: Host
var publisher: Publisher
var stream: Stream
var viewer: Spectator
var game: Game
var driver: Driver
var is_paused: bool = false
var viewer_code: int = Types.Code.OK
var next_host_frame: int = 0
var is_finishing: bool = false
var is_host_finished: bool = false
var is_host_connection_lost: bool = false
var _tick_count: int = 0


## Starts a fresh match after retiring prior owned playback and player sessions.
## Active requests and callbacks retain their match until the current operation completes.
func start() -> int:
	if _mutation_code() == Types.Code.BUSY:
		return Types.Code.BUSY
	var next_host: Host = Host.new()
	var code: int = next_host.start(3)
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
	config.replay_max_frames = REPLAY_FRAMES
	config.diagnostic_version = Game.REPLAY_VERSION
	config.diagnostic_seed = Game.REPLAY_SEED
	config.storage_budget_bytes = config.required_storage_bytes()
	var next_stream: Stream = Stream.new()
	# A local fixture identity; network integrations supply a fresh agreed lifetime.
	var identity: PackedByteArray = PackedByteArray()
	identity.resize(32)
	# The local fixture shares one key and one agreed configuration with the host.
	# A network integration must replace this fixture key with a fresh shared secret.
	var key: PackedByteArray = PackedByteArray()
	key.resize(Stream.KEY_BYTES)
	var digest: PackedByteArray = Stream.configuration_digest(config, "demo-seed", "demo-rules")
	code = next_stream.configure(config, identity, key, digest, 0, 10000000, 256)
	if code != Types.Code.OK:
		return code
	var next_publisher: Publisher = Publisher.new()
	code = next_publisher.configure(next_host.loop.session, identity, key, digest, 256)
	if code != Types.Code.OK:
		return code
	code = _negotiate_envelope(next_publisher, next_stream)
	if code != Types.Code.OK:
		return code
	var next_viewer: Spectator = next_stream.playback_session()
	code = next_viewer.set_playback(12, 4, 4)
	if code != Types.Code.OK:
		return code
	var next_game: Game = Game.new()
	var next_driver: Driver = Driver.new(next_viewer, next_game)
	if viewer != null:
		viewer.terminate()
	if host != null:
		host.loop.session.terminate()
		host.stop_replay()
	host = next_host
	publisher = next_publisher
	stream = next_stream
	viewer = next_viewer
	game = next_game
	driver = next_driver
	is_paused = false
	viewer_code = Types.Code.OK
	next_host_frame = 0
	is_finishing = false
	is_host_finished = false
	is_host_connection_lost = false
	_tick_count = 0
	return Types.Code.OK


## The local transport delivers the startup exchange before the first row.
func _negotiate_envelope(next_publisher: Publisher, next_stream: Stream) -> int:
	var offer: PackedByteArray = next_publisher.encode_offer()
	if offer.is_empty():
		return Types.Code.INVALID_CONFIGURATION
	var code: int = next_stream.receive_packet(offer, 0)
	if code != Types.Code.OK:
		return code
	var accept: PackedByteArray = next_stream.encode_accept()
	if accept.is_empty():
		return Types.Code.INVALID_CONFIGURATION
	return next_publisher.receive_accept(accept)


## Pause continuous viewing and attempt exactly one ordinary confirmed playback step.
## Delay and missing input still stall; this never advances or samples the host.
func step_viewer() -> int:
	if _mutation_code() == Types.Code.BUSY:
		return Types.Code.BUSY
	if viewer == null:
		return Types.Code.NOT_CONFIGURED
	is_paused = true
	viewer_code = _viewer_result(viewer_code)
	if viewer_code not in [Types.Code.OK, Types.Code.PREDICTION_STALL, Types.Code.NETWORK_BACKPRESSURE]:
		return viewer_code
	var samples: Array[Driver.LocalInput] = []
	viewer_code = _advance_viewer(samples)
	return viewer_code


## Pause and play all currently buffered rows allowed by the viewing delay in one bounded action.
## Preserves the selected delay/rate, never samples the host, and stops immediately on playback failure.
func catch_up_viewer() -> int:
	if _mutation_code() == Types.Code.BUSY:
		return Types.Code.BUSY
	if viewer == null:
		return Types.Code.NOT_CONFIGURED
	is_paused = true
	viewer_code = _viewer_result(viewer_code)
	if viewer_code not in [Types.Code.OK, Types.Code.PREDICTION_STALL, Types.Code.NETWORK_BACKPRESSURE]:
		return viewer_code
	var playback: Dictionary = viewer.playback_status()
	var work: int = maxi(1, int(playback.playable_frames) + (1 if playback.input_closed else 0))
	var samples: Array[Driver.LocalInput] = []
	for _step: int in range(work):
		viewer_code = _advance_viewer(samples)
		if viewer_code != Types.Code.OK:
			break
	return viewer_code


## Changes the confirmed-frame cushion without stepping, rewinding or changing pause/catch-up policy.
## Raising the delay waits for more input; clean host endings always release the complete tail.
func set_viewing_delay(frames: int) -> int:
	if _mutation_code() == Types.Code.BUSY:
		return Types.Code.BUSY
	if viewer == null:
		return Types.Code.NOT_CONFIGURED
	var policy: PackedInt64Array = viewer.playback_policy()
	return viewer.set_playback(frames, policy[1], policy[2])


## Resume with zero viewing delay and catch-up threshold, at the maximum bounded catch-up rate.
## Later ticks play every delivered contiguous row; this action never steps either game or skips history.
func follow_live() -> int:
	if _mutation_code() == Types.Code.BUSY:
		return Types.Code.BUSY
	if viewer == null:
		return Types.Code.NOT_CONFIGURED
	var capacity: int = viewer.playback_status().capacity_frames
	var code: int = viewer.set_playback(0, 0, capacity)
	if code == Types.Code.OK:
		is_paused = false
	return code


## Changes the maximum playback steps per tick while preserving delay, threshold and pause.
## The viewer rejects speeds outside one through its configured queue capacity.
func set_catchup_speed(frames_per_tick: int) -> int:
	if _mutation_code() == Types.Code.BUSY:
		return Types.Code.BUSY
	if viewer == null:
		return Types.Code.NOT_CONFIGURED
	var policy: PackedInt64Array = viewer.playback_policy()
	return viewer.set_playback(policy[0], policy[1], frames_per_tick)


## Report a known unexpected loss of the viewer's host link, without stopping the player session.
## Buffered rows stop immediately; restart creates a fresh host and viewer from their initial state.
func lose_host_connection() -> int:
	if viewer == null:
		return Types.Code.NOT_CONFIGURED
	if viewer.status().lifecycle == Types.Lifecycle.TERMINATED:
		viewer_code = viewer.status().reason
		return viewer_code
	is_host_connection_lost = true
	viewer.terminate(Types.Code.PROTOCOL_FAILED)
	viewer_code = Types.Code.PROTOCOL_FAILED
	return viewer_code


## Stop at the current host frame, correct outstanding predictions and send the complete clean tail.
## A paused viewer can resume and drain that tail before its normal terminal notification.
func finish_host() -> int:
	if _mutation_code() == Types.Code.BUSY:
		return Types.Code.BUSY
	if host == null:
		return Types.Code.NOT_CONFIGURED
	if host.loop.session.status().lifecycle == Types.Lifecycle.TERMINATED:
		return Types.Code.TERMINATED
	is_finishing = true
	return Types.Code.OK


## Host continues when the viewer pauses, falls behind or fails. All loops have explicit work bounds.
func tick(buttons: int) -> int:
	if _mutation_code() == Types.Code.BUSY:
		return Types.Code.BUSY
	if host == null:
		return Types.Code.NOT_CONFIGURED
	_tick_count += 1
	var code: int = Types.Code.OK
	if not is_host_finished:
		code = host.finish_tick() if is_finishing else host.tick(buttons)
		if is_finishing and code == Types.Code.OK:
			code = publisher.finish_host()
			is_host_finished = code == Types.Code.OK
	if code != Types.Code.OK and code != Types.Code.PREDICTION_STALL:
		viewer.terminate(code)
		viewer_code = _viewer_result(code)
		return code
	viewer_code = _viewer_result(viewer_code)
	if viewer_code not in [Types.Code.OK, Types.Code.PREDICTION_STALL, Types.Code.NETWORK_BACKPRESSURE]:
		return code
	viewer_code = stream.poll(_tick_count * Host.TICK_US)
	if viewer_code != Types.Code.OK:
		return code
	var first_host_frame: int = next_host_frame
	for _work: int in range(SEND_BUDGET):
		var packet: Types.InputResult = publisher.prepare_packet()
		if packet.code == Types.Code.PREDICTION_STALL or (is_host_finished and packet.code == Types.Code.TERMINATED):
			break
		if packet.code != Types.Code.OK:
			viewer_code = packet.code
			viewer.terminate(viewer_code)
			return code
		viewer_code = stream.receive_packet(packet.bytes, _tick_count * Host.TICK_US)
		if viewer_code != Types.Code.OK:
			break
		viewer_code = publisher.acknowledge_packet(packet.bytes)
		if viewer_code != Types.Code.OK:
			viewer.terminate(viewer_code)
			return code
		next_host_frame = publisher.next_frame()
	if next_host_frame == first_host_frame:
		var keepalive: PackedByteArray = publisher.encode_keepalive()
		if not keepalive.is_empty():
			var keepalive_code: int = stream.receive_packet(keepalive, _tick_count * Host.TICK_US)
			if keepalive_code != Types.Code.OK:
				viewer_code = keepalive_code
				return code
	if not is_paused:
		var samples: Array[Driver.LocalInput] = []
		for _step: int in range(viewer.recommended_steps()):
			viewer_code = _advance_viewer(samples)
			if viewer_code != Types.Code.OK:
				break
	return code


## Save the displayed confirmed prefix, with its current boundary checksum when available.
## Empty while callbacks or expert work own state, or before any usable evidence exists.
## A stopped viewer keeps its existing recording; capture never revives failed playback.
func replay_bytes() -> PackedByteArray:
	if viewer == null or _mutation_code() == Types.Code.BUSY:
		return PackedByteArray()
	if viewer.status().lifecycle != Types.Lifecycle.TERMINATED:
		var captured: Driver.StepResult = driver.capture_replay_boundary()
		if captured.reason != Types.Code.OK:
			viewer_code = captured.reason
	var recording: RefCounted = driver.replay()
	if recording == null or (recording.frame_count() == 0 and recording.checksum(0).is_empty()):
		return PackedByteArray()
	return recording.to_bytes()


func _advance_viewer(samples: Array[Driver.LocalInput]) -> int:
	# Completion retires the session; save its exact final boundary while callbacks are still allowed.
	if is_host_finished and viewer.status().current_frame == next_host_frame and viewer.recommended_steps() > 0:
		var captured: Driver.StepResult = driver.capture_replay_boundary()
		if captured.reason != Types.Code.OK:
			return captured.reason
	return _viewer_result(driver.step(_tick_count * Host.TICK_US, samples).code)


func _viewer_result(code: int) -> int:
	var status: Types.Status = viewer.status()
	return status.reason if status.lifecycle == Types.Lifecycle.TERMINATED else code


func _mutation_code() -> int:
	if (viewer != null and viewer._mutation_code() == Types.Code.BUSY) or (host != null and host._mutation_code() == Types.Code.BUSY):
		return Types.Code.BUSY
	return Types.Code.OK
