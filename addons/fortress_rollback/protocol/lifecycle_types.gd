class_name FortressLifecycleTypes
extends RefCounted

## What a session does when a peer stops answering. Every peer of a mesh must use the same
## behavior: Halt ends the match for everybody, Continue freezes the departed player's slot
## at the agreed confirmed frame and keeps the survivors playing.
enum Disconnect { HALT, CONTINUE }


class Options:
	extends RefCounted
	var enabled: bool = true
	var quality_report_interval_us: int = 200000
	var keepalive_interval_us: int = 200000
	var disconnect_notify_us: int = 500000
	var disconnect_timeout_us: int = 2000000
	var max_pending_quality: int = 128
	var time_sync_window: int = 30
	var max_checksum_frames: int = 128
	var max_events: int = 1024
	var disconnect_behavior: int = Disconnect.HALT
	var drop_barrier_timeout_us: int = 250000

static func valid_options(value: Variant) -> bool:
	if not value is Options:
		return false
	if value.quality_report_interval_us < 1000 or value.keepalive_interval_us < 1000:
		return false
	if value.disconnect_notify_us < 0 or value.disconnect_timeout_us < value.disconnect_notify_us:
		return false
	if value.disconnect_behavior < Disconnect.HALT or value.disconnect_behavior > Disconnect.CONTINUE:
		return false
	if value.drop_barrier_timeout_us < 1000 or value.drop_barrier_timeout_us > maxi(value.disconnect_timeout_us, 1000):
		return false
	for bound: int in [value.max_pending_quality, value.time_sync_window, value.max_checksum_frames, value.max_events]:
		if bound < 1 or bound > 4096:
			return false
	return true

static func copy_options(value: Options) -> Options:
	var result: Options = Options.new()
	for field: String in ["enabled", "quality_report_interval_us", "keepalive_interval_us", "disconnect_notify_us", "disconnect_timeout_us",
		"max_pending_quality", "time_sync_window", "max_checksum_frames", "max_events", "disconnect_behavior", "drop_barrier_timeout_us"]:
		result.set(field, value.get(field))
	return result
