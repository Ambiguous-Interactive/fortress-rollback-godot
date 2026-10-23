class_name FortressSpectatorSession
extends "res://addons/fortress_rollback/core/session.gd"

# gdlint: disable=max-returns

## Single trusted host's confirmed input stream, played by the shared expert/driver engine.
## The caller authenticates host/session identity before delivering atomic rows. No network protocol is implied.
## Start from the host's initial game state; admission at a later frame requires separate state transfer.

enum EventKind { WAITING_FOR_HOST, SYNCHRONIZED, HOST_FINISHED, TERMINATED }


class Event:
	extends RefCounted
	var kind: int
	var frame: int
	var reason: int

	func _init(event_kind: int, event_frame: int, event_reason: int = Code.OK) -> void:
		kind = event_kind
		frame = event_frame
		reason = event_reason


var _events: Array[RefCounted] = []
var _has_host_prefix: bool = false
var _host_rows: Array[PackedByteArray] = []
var _host_statuses: Array[PackedByteArray] = []
var _host_tags: PackedInt64Array = PackedInt64Array()
var _host_frontier: int = -1
var _host_finished: bool = false
var _stream_delay: int = 0
var _max_frames_behind: int = 1
var _catchup_speed: int = 1


func configure(config: Config) -> int:
	if config == null or not config.spectator:
		return Code.INVALID_CONFIGURATION
	var code: int = super.configure(config)
	if code != Code.OK:
		return code
	_host_rows.clear()
	_host_rows.resize(config.queue_capacity)
	_host_statuses.clear()
	_host_statuses.resize(config.queue_capacity)
	_host_tags.resize(config.queue_capacity)
	_host_tags.fill(-1)
	_host_frontier = -1
	_host_finished = false
	_stream_delay = 0
	_max_frames_behind = 1
	_catchup_speed = 1
	_has_host_prefix = false
	_events = [Event.new(EventKind.WAITING_FOR_HOST, 0)]
	return Code.OK


## Delay trails the contiguous host frontier. Catch-up is a caller-owned loop of at most catchup_speed steps.
## Each step still consumes one ordinary shared-engine batch. All limits fit the configured input ring.
## The engine enforces the delay even when the caller exceeds the advice; the catch-up rate stays the
## caller's, because recommended_steps() already reports the exact per-cycle bound.
func set_playback(stream_delay: int, max_frames_behind: int, catchup_speed: int) -> int:
	var code: int = _mutation_code()
	if code != Code.OK:
		return code
	var capacity: int = _host_tags.size()
	if stream_delay < 0 or stream_delay >= capacity or max_frames_behind < 0 or max_frames_behind > capacity or catchup_speed < 1 or catchup_speed > capacity:
		return Code.INVALID_CONFIGURATION
	_stream_delay = stream_delay
	_max_frames_behind = max_frames_behind
	_catchup_speed = catchup_speed
	return Code.OK


## Current playback policy as [stream_delay, max_frames_behind, catchup_speed].
## A reconfigured viewer keeps these values when they still fit the new ring.
func playback_policy() -> PackedInt64Array:
	return PackedInt64Array([_stream_delay, _max_frames_behind, _catchup_speed])


## Accepts owned complete rows, including out-of-order arrivals within queue_capacity of the next frame.
## Statuses are finalized per-player values; omission means every slot is CONFIRMED.
## Refusal leaves every row and the contiguous frontier unchanged; retry backpressure after playback.
## Identical retained duplicates are idempotent. Conflicting duplicates never replace accepted input.
func receive_host_frame(frame: int, inputs: Array[PackedByteArray], statuses: PackedByteArray = PackedByteArray()) -> Types.Result:
	var code: int = _mutation_code()
	if code != Code.OK:
		return Types.Result.new(code)
	if _host_finished:
		return Types.Result.new(Code.TERMINATED)
	if frame < 0 or frame >= Queue.FRAME_MAX:
		return Types.Result.new(Code.INVALID_FRAME)
	if inputs.size() != _config.player_count:
		return Types.Result.new(Code.INVALID_CONFIGURATION)
	for bytes: PackedByteArray in inputs:
		if bytes.size() != _config.input_width:
			return Types.Result.new(Code.INPUT_WIDTH)
	var finalized: PackedByteArray = finalized_statuses(statuses, _config.player_count)
	if finalized.is_empty():
		return Types.Result.new(Code.INVALID_CONFIGURATION)
	if frame >= _current + _host_tags.size():
		return Types.Result.new(Code.NETWORK_BACKPRESSURE)
	var index: int = frame % _host_tags.size()
	if frame < _current and _host_tags[index] != frame:
		return Types.Result.new(Code.INVALID_FRAME)
	var row: PackedByteArray = PackedByteArray()
	for bytes: PackedByteArray in inputs:
		row.append_array(bytes)
	if _host_tags[index] == frame:
		return Types.Result.new(Code.OK if row == _host_rows[index] and finalized == _host_statuses[index] else Code.INPUT_ALREADY_SUBMITTED)
	_host_tags[index] = frame
	_host_rows[index] = row
	_host_statuses[index] = finalized
	while _host_frontier + 1 < Queue.FRAME_MAX and _host_tags[(_host_frontier + 1) % _host_tags.size()] == _host_frontier + 1:
		_host_frontier += 1
	if not _has_host_prefix and _host_frontier >= 0:
		_has_host_prefix = true
		_events.append(Event.new(EventKind.SYNCHRONIZED, _current))
	return Types.Result.new(Code.OK)


## Omitted statuses preserve the byte-only API's all-confirmed behavior.
## Supplied statuses must describe every player and contain only finalized values.
static func finalized_statuses(statuses: PackedByteArray, players: int) -> PackedByteArray:
	if players < Config.MIN_PLAYERS or players > Config.MAX_PLAYERS:
		return PackedByteArray()
	if statuses.is_empty():
		var confirmed: PackedByteArray = PackedByteArray()
		confirmed.resize(players)
		confirmed.fill(Queue.Status.CONFIRMED)
		return confirmed
	if statuses.size() != players:
		return PackedByteArray()
	for status: int in statuses:
		if status not in [Queue.Status.CONFIRMED, Queue.Status.DISCONNECTED]:
			return PackedByteArray()
	return statuses.duplicate()


func _input_status(player: int, frame: int, _queue_status: int) -> int:
	return _host_statuses[frame % _host_tags.size()][player]


func confirmed_inputs(frame: int) -> Types.FrameInputs:
	if _config == null or frame < 0 or _host_tags[frame % _host_tags.size()] != frame:
		return null
	return super.confirmed_inputs(frame)


## Highest complete contiguous host input, independent of playback delay.
func host_frontier() -> int:
	return _host_frontier


## Number of driver/expert calls to attempt now; zero waits for complete host history.
## After a clean tail, one final call publishes termination without simulating a frame.
## Recompute after each service cycle. The driver still enforces delay if callers exceed this advice.
func recommended_steps() -> int:
	if _config == null or _reason != Code.OK:
		return 0
	var available: int = _host_frontier - (0 if _host_finished else _stream_delay) - _current + 1
	if available <= 0:
		return 1 if _host_finished else 0
	return mini(available, _catchup_speed if available > _max_frames_behind else 1)


## Clean end releases the delayed contiguous tail, then terminates. Gaps remain unavailable.
## For unexpected host loss use terminate(PROTOCOL_FAILED), which stops immediately.
func finish_host() -> int:
	var code: int = _mutation_code()
	if code != Code.OK:
		return code
	if not _host_finished:
		_host_finished = true
		_events.append(Event.new(EventKind.HOST_FINISHED, _current))
	return Code.OK


func begin_advance() -> Types.Result:
	var code: int = _mutation_code()
	if code != Code.OK:
		return Types.Result.new(code)
	if _current == Queue.FRAME_MAX or _batch_id == 9223372036854775807:
		return super.begin_advance()
	if _host_finished and _host_frontier < _current:
		terminate(Code.TERMINATED)
		return Types.Result.new(Code.TERMINATED)
	if recommended_steps() == 0:
		return Types.Result.new(Code.PREDICTION_STALL)
	var index: int = _current % _host_tags.size()
	if _host_tags[index] != _current:
		# The retained row for this frame is gone. Never simulate a stale row as confirmed host input.
		return Types.Result.new(Code.HISTORY_UNAVAILABLE)
	var row: PackedByteArray = _host_rows[index]
	for player: int in range(_config.player_count):
		var start: int = player * _config.input_width
		var received: Types.Result = super.receive_input(player, _current, row.slice(start, start + _config.input_width))
		if received.code != Code.OK:
			return received
	return super.begin_advance()


func validate_local_input(_player: int, _sample_frame: int, _bytes: PackedByteArray) -> int:
	return Code.UNSUPPORTED


func submit_local_input(_player: int, _sample_frame: int, _bytes: PackedByteArray) -> Types.Result:
	return Types.Result.new(Code.UNSUPPORTED)


func receive_input(_player: int, _frame: int, _bytes: PackedByteArray) -> Types.Result:
	return Types.Result.new(Code.UNSUPPORTED)


func set_input_delay(_player: int, _delay: int) -> Types.Result:
	return Types.Result.new(Code.UNSUPPORTED)


## Only the host's confirmed rows may determine a viewer slot's input.
func freeze_player(_player: int, _frame: int) -> int:
	return Code.UNSUPPORTED


func freeze_player_with_value(_player: int, _frame: int, _bytes: PackedByteArray) -> int:
	return Code.UNSUPPORTED


## Viewer confirmation follows complete host rows; player-mesh confirmation gates do not apply.
func set_confirmation_limit(_frame: int) -> Types.Result:
	return Types.Result.new(Code.UNSUPPORTED)


## At most four owned events per configured lifetime. Driver results drain these after completed calls.
## SYNCHRONIZED means a contiguous input prefix, not a transport handshake; HOST_FINISHED releases the tail.
## TERMINATED reports actual playback completion or failure. Active batches and callbacks preserve the queue.
func drain_events() -> Array[RefCounted]:
	if _batch != null or _is_driver_callback:
		return []
	var events: Array[RefCounted] = _events
	_events = []
	return events


func _fatal(code: int, frame: int = -1, kind: int = -1) -> Types.Result:
	var first_failure: bool = _reason == Code.OK and _config != null
	var result: Types.Result = super._fatal(code, frame, kind)
	if first_failure:
		_events.append(Event.new(EventKind.TERMINATED, frame if frame >= 0 else _current, _reason))
	return result
