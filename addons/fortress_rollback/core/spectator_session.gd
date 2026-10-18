class_name FortressSpectatorSession
extends "res://addons/fortress_rollback/core/session.gd"

# gdlint: disable=max-returns

## Single trusted host's confirmed input stream, played by the shared expert/driver engine.
## The caller authenticates host/session identity before delivering atomic rows. No network protocol is implied.
## Start from the host's initial game state; admission at a later frame requires separate state transfer.

var _host_rows: Array[PackedByteArray] = []
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
	_host_tags.resize(config.queue_capacity)
	_host_tags.fill(-1)
	_host_frontier = -1
	_host_finished = false
	_stream_delay = 0
	_max_frames_behind = 1
	_catchup_speed = 1
	return Code.OK


## Delay trails the contiguous host frontier. Catch-up is a caller-owned loop of at most catchup_speed steps.
## Each step still consumes one ordinary shared-engine batch. All limits fit the configured input ring.
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


## Accepts owned complete rows, including out-of-order arrivals within queue_capacity of the next frame.
## Refusal leaves every row and the contiguous frontier unchanged; retry backpressure after playback.
## Identical retained duplicates are idempotent. Conflicting duplicates never replace accepted input.
func receive_host_frame(frame: int, inputs: Array[PackedByteArray]) -> Types.Result:
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
	if frame >= _current + _host_tags.size():
		return Types.Result.new(Code.NETWORK_BACKPRESSURE)
	var index: int = frame % _host_tags.size()
	if frame < _current and _host_tags[index] != frame:
		return Types.Result.new(Code.INVALID_FRAME)
	var row: PackedByteArray = PackedByteArray()
	for bytes: PackedByteArray in inputs:
		row.append_array(bytes)
	if _host_tags[index] == frame:
		return Types.Result.new(Code.OK if row == _host_rows[index] else Code.INPUT_ALREADY_SUBMITTED)
	_host_tags[index] = frame
	_host_rows[index] = row
	while _host_frontier + 1 < Queue.FRAME_MAX and _host_tags[(_host_frontier + 1) % _host_tags.size()] == _host_frontier + 1:
		_host_frontier += 1
	return Types.Result.new(Code.OK)


## Number of single-frame driver/expert steps to attempt now; zero waits for complete host history.
## Recompute after each service cycle. The driver still enforces delay if callers exceed this advice.
func recommended_steps() -> int:
	if _config == null or _reason != Code.OK:
		return 0
	var available: int = _host_frontier - (0 if _host_finished else _stream_delay) - _current + 1
	if available <= 0:
		return 0
	return mini(available, _catchup_speed if available > _max_frames_behind else 1)


## Clean end releases the delayed contiguous tail, then terminates. Gaps remain unavailable.
## For unexpected host loss use terminate(PROTOCOL_FAILED), which stops immediately.
func finish_host() -> int:
	var code: int = _mutation_code()
	if code != Code.OK:
		return code
	_host_finished = true
	return Code.OK


func begin_advance() -> Types.Result:
	var code: int = _mutation_code()
	if code != Code.OK:
		return Types.Result.new(code)
	if _current == Queue.FRAME_MAX or _batch_id == 9223372036854775807:
		return super.begin_advance()
	if recommended_steps() == 0:
		if _host_finished:
			terminate(Code.TERMINATED)
			return Types.Result.new(Code.TERMINATED)
		return Types.Result.new(Code.PREDICTION_STALL)
	var row: PackedByteArray = _host_rows[_current % _host_tags.size()]
	for player: int in range(_config.player_count):
		var start: int = player * _config.input_width
		var received: Types.Result = super.receive_input(player, _current, row.slice(start, start + _config.input_width))
		if received.code != Code.OK:
			return received
	return super.begin_advance()


func submit_local_input(_player: int, _sample_frame: int, _bytes: PackedByteArray) -> Types.Result:
	return Types.Result.new(Code.UNSUPPORTED)


func receive_input(_player: int, _frame: int, _bytes: PackedByteArray) -> Types.Result:
	return Types.Result.new(Code.UNSUPPORTED)


func set_input_delay(_player: int, _delay: int) -> Types.Result:
	return Types.Result.new(Code.UNSUPPORTED)
