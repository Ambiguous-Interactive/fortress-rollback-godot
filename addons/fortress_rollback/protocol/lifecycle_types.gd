class_name FortressLifecycleTypes
extends RefCounted

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

static func valid_options(value: Variant) -> bool:
	if not value is Options:
		return false
	if value.quality_report_interval_us < 1000 or value.keepalive_interval_us < 1000:
		return false
	if value.disconnect_notify_us < 0 or value.disconnect_timeout_us < value.disconnect_notify_us:
		return false
	for bound: int in [value.max_pending_quality, value.time_sync_window, value.max_checksum_frames, value.max_events]:
		if bound < 1 or bound > 4096:
			return false
	return true

static func copy_options(value: Options) -> Options:
	var result: Options = Options.new()
	for field: String in ["enabled", "quality_report_interval_us", "keepalive_interval_us", "disconnect_notify_us", "disconnect_timeout_us",
		"max_pending_quality", "time_sync_window", "max_checksum_frames", "max_events"]:
		result.set(field, value.get(field))
	return result
