class_name FortressIntegrationEffects
extends RefCounted

## Plays each shot's one-time effect (sound, score popup, analytics) exactly once,
## and only after its frame is confirmed. Predicted shots can still disappear
## after rollback; draw those from current state instead of playing them here.

const Game = preload("res://examples/integration/game.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")

## Highest shot ID already played. IDs increase with frame, so one number suffices.
var last_played_id: int = 0
var played_count: int = 0


## Call after a driver step returns OK or PREDICTION_STALL, never from a callback.
## Input delivered since that step can raise confirmed_frame before rollback has
## corrected the game, so frames at or after pending_rollback_frame never play.
func reconcile(game: Game, status: Types.Status) -> void:
	var final_frame: int = status.confirmed_frame
	if status.pending_rollback_frame != -1:
		final_frame = mini(final_frame, status.pending_rollback_frame - 1)
	var first: int = maxi(0, game.shot_total - Game.SHOT_SLOTS)
	for index: int in range(first, game.shot_total):
		var id: int = game.shot_ids[index % Game.SHOT_SLOTS]
		var shot_frame: int = Game.shot_frame(id)
		if id > last_played_id and shot_frame <= final_frame and shot_frame < game.frame:
			last_played_id = id
			played_count += 1
			play(id)


## Override to start audio or other effects that cannot be undone.
func play(_id: int) -> void:
	pass
