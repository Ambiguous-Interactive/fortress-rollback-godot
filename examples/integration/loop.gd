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

var session: Session = Session.new()
var game: Game = Game.new()
var effects: Effects
var driver: Driver
var local_player: int
var _sample_frame: int = -1
var _sample: PackedByteArray = PackedByteArray()


func _init(player: int, ledger: Effects = null) -> void:
	local_player = player
	effects = ledger if ledger != null else Effects.new()


## Returns OK when ready. Any other code is a configuration error.
func start() -> int:
	var config: Config = Config.new()
	config.sync_test = false
	config.local_players = PackedInt32Array([local_player])
	config.check_distance = 0
	config.max_prediction_frames = 8
	config.history_slots = 9
	config.max_snapshot_bytes = Game.SNAPSHOT_BYTES
	config.storage_budget_bytes = config.required_storage_bytes()
	var code: int = session.configure(config)
	if code == Types.Code.OK:
		driver = Driver.new(session, game)
	return code


## OK advanced one frame; PREDICTION_STALL waits for remote input and may still
## have corrected earlier frames. Other codes either reject this call and leave the
## session running, or stop it: check session.status().lifecycle.
func tick(now_us: int, buttons: int) -> int:
	var frame: int = session.status().current_frame
	# Sample once per frame. While stalled, resubmit the same bytes: new keys would
	# be rejected with INPUT_ALREADY_SUBMITTED.
	if _sample_frame != frame:
		_sample_frame = frame
		_sample = PackedByteArray([buttons])
	var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(local_player, frame, _sample)]
	var code: int = driver.step(now_us, samples).code
	if code == Types.Code.OK or code == Types.Code.PREDICTION_STALL:
		effects.reconcile(game, session.status())
	return code
