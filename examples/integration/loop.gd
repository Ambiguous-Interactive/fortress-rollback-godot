class_name FortressIntegrationLoop
extends RefCounted

## One local player against one remote player. Call tick() once per physics frame.
## The transport delivers remote input through session.receive_input().

const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Game = preload("res://examples/integration/game.gd")
const Effects = preload("res://examples/integration/effects.gd")
## Ten minutes at 60 frames per second; about 200 KB for two one-byte players.
const REPLAY_FRAMES: int = 36000

var session: Session = Session.new()
var game: Game = Game.new()
var effects: Effects
var driver: Driver
var local_player: int
var _sample_frame: int = -1
var _sample: PackedByteArray = PackedByteArray()
var _inputs: Array[PackedByteArray] = [PackedByteArray()]


func _init(player: int, ledger: Effects = null) -> void:
	local_player = player
	effects = ledger if ledger != null else Effects.new()


## Starts a fresh match and retires the previous session and driver.
## First start keeps caller-assigned game/effects; later starts use fresh defaults unless replacements are supplied.
## Replacements must be at frame zero with an unused effects ledger. Rejection preserves the current match.
func start(next_game: Game = null, next_effects: Effects = null) -> int:
	if session._mutation_code() == Types.Code.BUSY:
		return Types.Code.BUSY
	var candidate_game: Game = next_game if next_game != null else (game if driver == null else Game.new())
	var candidate_effects: Effects = next_effects if next_effects != null else (effects if driver == null else Effects.new())
	if candidate_game == null or candidate_effects == null or candidate_game.frame != 0 or candidate_effects.last_played_id != 0:
		return Types.Code.INVALID_CONFIGURATION
	var config: Config = Config.new()
	config.sync_test = false
	config.local_players = PackedInt32Array([local_player])
	config.check_distance = 0
	config.max_prediction_frames = 8
	config.history_slots = 9
	config.max_snapshot_bytes = Game.SNAPSHOT_BYTES
	config.storage_budget_bytes = config.required_storage_bytes()
	config.replay_max_frames = REPLAY_FRAMES
	var candidate_session: Session = Session.new()
	var code: int = candidate_session.configure(config)
	if code != Types.Code.OK:
		return code
	var candidate_driver: Driver = Driver.new()
	code = candidate_driver.configure(candidate_session, candidate_game)
	if code != Types.Code.OK:
		return code
	session.terminate()
	session = candidate_session
	driver = candidate_driver
	game = candidate_game
	effects = candidate_effects
	_sample_frame = -1
	_sample = PackedByteArray()
	return Types.Code.OK


## Checks ownership, sample compatibility and time before any controller sample is retained.
func _tick_code(now_us: int, buttons: int) -> int:
	var code: int = session._check_advance_limits()
	if code != Types.Code.OK:
		return code
	if buttons < 0 or buttons > (Game.LEFT | Game.RIGHT | Game.FIRE):
		return Types.Code.INVALID_CONFIGURATION
	var frame: int = session.status().current_frame
	var sample: PackedByteArray = _sample if _sample_frame == frame else PackedByteArray([buttons])
	code = session.validate_local_input(local_player, frame, sample)
	return session.poll(now_us).code if code == Types.Code.OK else code


## OK advanced one frame; PREDICTION_STALL waits for remote input and may still
## have corrected earlier frames. Other codes either reject this call and leave the
## session running, or stop it: check session.status().lifecycle.
func tick(now_us: int, buttons: int) -> int:
	var code: int = _tick_code(now_us, buttons)
	if code != Types.Code.OK:
		return code
	var frame: int = session.status().current_frame
	# Sample once per frame; successful stalled attempts keep their original bytes.
	if _sample_frame != frame:
		_sample_frame = frame
		_sample = PackedByteArray([buttons])
	_inputs[0] = _sample
	code = driver.step_local(now_us, _inputs).code
	if code == Types.Code.OK or code == Types.Code.PREDICTION_STALL:
		var effect_code: int = _reconcile_effects()
		if effect_code != Types.Code.OK:
			return effect_code
	return code


func _reconcile_effects() -> int:
	# Application effect hooks must not replace or advance the match still being serviced.
	session._begin_driver_notification()
	effects.reconcile(game, session.status())
	session._end_driver_notification()
	return session.status().reason
