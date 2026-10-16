class_name FortressIntegrationDemo
extends RefCounted

## Deterministic controller for the playable example. Call tick() once per physics tick.
## Lag measures controller ticks; a stalled simulation does not stop queued delivery.

const Loop = preload("res://examples/integration/loop.gd")
const Game = preload("res://examples/integration/game.gd")
const Effects = preload("res://examples/integration/effects.gd")
const Reader = preload("res://addons/fortress_rollback/core/snapshot_reader.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const RECENT_EFFECT_LIMIT: int = 32
const MAX_PENDING_INPUTS: int = 13
const TICK_US: int = 16667

var loop: Loop
var effects: DemoEffects
var tick_count: int = 0
var stall_count: int = 0
var lag_ticks: int = 3
var _remote_sample_frame: int = -1
var _pending: Array[RemoteInput] = []


class DemoEffects:
	extends Effects
	var recent_ids: PackedInt64Array = PackedInt64Array()
	var total_count: int = 0

	func play(id: int) -> void:
		total_count += 1
		recent_ids.append(id)
		if recent_ids.size() > RECENT_EFFECT_LIMIT:
			recent_ids.remove_at(0)


class DemoGame:
	extends Game
	var loads: int = 0

	func load_state(saved_frame: int, reader: Reader) -> bool:
		var loaded: bool = super.load_state(saved_frame, reader)
		if loaded:
			loads += 1
		return loaded


class RemoteInput:
	extends RefCounted
	var frame: int
	var due_tick: int
	var buttons: int

	func _init(input_frame: int, delivery_tick: int, input_buttons: int) -> void:
		frame = input_frame
		due_tick = delivery_tick
		buttons = input_buttons


## Starts a fresh match. Invalid lag leaves the current match untouched.
func start(delay_ticks: int = 3) -> int:
	if delay_ticks not in [0, 3, 12]:
		return Types.Code.INVALID_CONFIGURATION
	lag_ticks = delay_ticks
	tick_count = 0
	stall_count = 0
	_remote_sample_frame = -1
	_pending.clear()
	effects = DemoEffects.new()
	loop = Loop.new(0, effects)
	loop.game = DemoGame.new()
	return loop.start()


## Clears snapshots, samples, pending deliveries and presentation history.
func reset() -> int:
	return start(lag_ticks)


## Changes lag for new samples; already queued inputs retain their delivery times.
func set_lag(delay_ticks: int) -> int:
	if delay_ticks not in [0, 3, 12]:
		return Types.Code.INVALID_CONFIGURATION
	lag_ticks = delay_ticks
	return Types.Code.OK


## OK advances; PREDICTION_STALL retains the original local input for this frame.
func tick(buttons: int) -> int:
	if loop == null:
		return Types.Code.INVALID_CONFIGURATION
	var code: int = _deliver_ready()
	if code != Types.Code.OK:
		return code
	var frame: int = loop.session.status().current_frame
	if frame != _remote_sample_frame:
		_remote_sample_frame = frame
		var due_tick: int = tick_count + lag_ticks
		# Keep input ordered when lag decreases, without rewriting queued deliveries.
		if not _pending.is_empty():
			due_tick = maxi(due_tick, _pending.back().due_tick)
		_pending.append(RemoteInput.new(frame, due_tick, remote_buttons(frame)))
	code = _deliver_ready()
	if code != Types.Code.OK:
		return code
	code = loop.tick(tick_count * TICK_US, buttons)
	tick_count += 1
	if code == Types.Code.PREDICTION_STALL:
		stall_count += 1
	return code


func load_count() -> int:
	return (loop.game as DemoGame).loads if loop != null else 0


func pending_input_count() -> int:
	return _pending.size()


## Reversible shots still awaiting confirmation. Read again after every tick.
func predicted_shot_ids() -> PackedInt64Array:
	var result: PackedInt64Array = PackedInt64Array()
	if loop == null:
		return result
	var status: Types.Status = loop.session.status()
	var final_frame: int = status.confirmed_frame
	if status.pending_rollback_frame != -1:
		final_frame = mini(final_frame, status.pending_rollback_frame - 1)
	for index: int in range(maxi(0, loop.game.shot_total - Game.SHOT_SLOTS), loop.game.shot_total):
		var id: int = loop.game.shot_ids[index % Game.SHOT_SLOTS]
		if Game.shot_frame(id) > final_frame:
			result.append(id)
	return result


static func remote_buttons(frame: int) -> int:
	# Releasing fire during cooldown exposes phantom predicted shots after rollback.
	return (Game.FIRE if frame % 8 < 4 else 0) | (Game.LEFT if frame % 7 < 3 else Game.RIGHT)


func _deliver_ready() -> int:
	while not _pending.is_empty() and _pending[0].due_tick <= tick_count:
		var sample: RemoteInput = _pending[0]
		var code: int = loop.session.receive_input(1, sample.frame, PackedByteArray([sample.buttons])).code
		if code != Types.Code.OK:
			return code
		_pending.pop_front()
	return Types.Code.OK
