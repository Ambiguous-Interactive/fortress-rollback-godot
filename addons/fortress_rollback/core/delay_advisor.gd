class_name FortressDelayAdvisor
extends RefCounted

## Suggests a higher local input delay from measured round-trip time.
## The suggestion is advisory: RTT comes from the application's clock and never feeds simulation.

## Consecutive observations a raise must hold before it is suggested; also the gap between suggestions.
const SUSTAIN_STEPS: int = 60
const MAX_ROUND_TRIP_MS: int = 1 << 30

var _last_suggested: int = -1
var _streak: int = 0
var _window_min: int = 0


## Frames that cover one-way latency, rounded up. Zero for a missing or zero measurement.
static func one_way_frames(round_trip_ms: int, fps: int) -> int:
	if round_trip_ms <= 0 or fps <= 0:
		return 0
	# The cap keeps the product within signed 64 bits for any valid fps.
	var capped: int = mini(round_trip_ms, MAX_ROUND_TRIP_MS)
	return (capped * mini(fps, 4294967295) + 1999) / 2000


## Returns a delay above both current and the last suggestion, at most limit, or -1.
## A raise must hold for SUSTAIN_STEPS observations; the smallest target in that window is suggested.
## Several local players get no suggestion, since a peer session cannot raise their delay.
func observe(local_players: int, current: int, limit: int, round_trip_ms: int, fps: int) -> int:
	var floor_delay: int = maxi(current, _last_suggested)
	var target: int = mini(one_way_frames(round_trip_ms, fps), limit)
	if local_players != 1 or target <= floor_delay:
		_streak = 0
		return -1
	_window_min = target if _streak == 0 else mini(_window_min, target)
	_streak += 1
	if _streak < SUSTAIN_STEPS:
		return -1
	_streak = 0
	_last_suggested = _window_min
	return _window_min
