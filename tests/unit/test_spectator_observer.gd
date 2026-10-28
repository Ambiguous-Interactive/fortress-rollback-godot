extends RefCounted

# Value: protects=zero-callback startup evidence; fails_when=rejected simulation calls remain unobserved; why_new=frame checks miss failed calls; seam=actual fixture callback
const Game = preload("res://scripts/reference/spectator_live_game.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["rejected_callbacks"])


func run_case(_name: String, context: RefCounted) -> void:
	var game: Game = Game.new()
	var original: PackedByteArray = game.canonical_bytes()
	for count: int in range(1, 3):
		context.equal(game.simulate_frame(1, null), false, "wrong-frame callback is rejected")
		context.equal(game.simulation_calls, count, "each rejected callback remains observed")
		context.bytes_equal(game.canonical_bytes(), original, 0, "observation does not change canonical game bytes")
	context.finish()
