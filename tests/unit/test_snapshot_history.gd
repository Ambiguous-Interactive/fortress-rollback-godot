extends RefCounted

# Value: protects=bounded transactional snapshots and view lifetime; fails_when=partial save publishes or tags alias; why_new=first production history; seam=none
const History = preload("res://addons/fortress_rollback/core/snapshot_history.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["round_trip", "failures", "ownership", "validation", "misuse"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"round_trip":
			_round_trip(context)
		"failures":
			_failures(context)
		"ownership":
			_ownership(context)
		"validation":
			_validation(context)
		"misuse":
			_misuse(context)
	context.finish()


func _history() -> RefCounted:
	var history: RefCounted = History.new()
	history.configure(3, 4, 2, 2, 1000, true)
	return history


func _checksum() -> PackedByteArray:
	var checksum: PackedByteArray = PackedByteArray()
	checksum.resize(16)
	checksum[15] = 255
	return checksum


func _round_trip(context: RefCounted) -> void:
	var history: RefCounted = _history()
	for frame: int in range(10):
		var save: RefCounted = history.begin_save(frame)
		context.equal(save.code, History.Code.OK, "begin save")
		context.equal(save.writer.write_bytes(PackedByteArray([frame, 0, 1, 2])), History.Code.OK, "exact capacity")
		context.equal(history.finish_save(save.writer, true, _checksum()), History.Code.OK, "publish")
		context.equal(save.writer.status(), History.Code.EXPIRED_VIEW, "writer expires")
		var load_request: RefCounted = history.begin_load(frame, save.generation)
		context.equal(load_request.code, History.Code.OK, "exact tag")
		context.bytes_equal(load_request.reader.read_bytes(4).bytes, PackedByteArray([frame, 0, 1, 2]), frame, "canonical bytes")
		context.equal(history.finish_load(load_request.reader, true), History.Code.OK, "consume entire record")
		context.equal(history.begin_load(frame, save.generation + 1).code, History.Code.HISTORY_UNAVAILABLE, "generation required")
		if frame >= 3:
			context.equal(history.begin_load(frame - 3).code, History.Code.HISTORY_UNAVAILABLE, "overwritten frame")


func _failures(context: RefCounted) -> void:
	var history: RefCounted = _history()
	var initial: RefCounted = history.begin_save(0)
	initial.writer.write_bytes(PackedByteArray([7]))
	history.finish_save(initial.writer, true, _checksum())
	for failure: String in ["overflow", "callback", "checksum"]:
		var save: RefCounted = history.begin_save(3)
		save.writer.write_bytes(PackedByteArray([1]))
		var expected: int = History.Code.CALLBACK_FAILED
		if failure == "overflow":
			context.equal(save.writer.write_bytes(PackedByteArray([1, 2, 3, 4])), History.Code.OVERFLOW, "overflow")
			context.equal(save.writer.write_bytes(PackedByteArray()), History.Code.OVERFLOW, "sticky overflow")
			expected = History.Code.OVERFLOW
		elif failure == "checksum":
			expected = History.Code.CHECKSUM_WIDTH
		context.equal(history.finish_save(save.writer, failure != "callback", _checksum() if failure != "checksum" else PackedByteArray()), expected, "save failure")
		context.equal(history.begin_load(3).code, History.Code.HISTORY_UNAVAILABLE, "failed save unavailable")
		var load_request: RefCounted = history.begin_load(0)
		context.bytes_equal(load_request.reader.read_bytes(1).bytes, PackedByteArray([7]), 0, "prior slot preserved")
		history.finish_load(load_request.reader, true)
	for width: int in [15, 17]:
		var invalid_checksum: PackedByteArray = PackedByteArray()
		invalid_checksum.resize(width)
		var bad_save: RefCounted = history.begin_save(3)
		context.equal(history.finish_save(bad_save.writer, true, invalid_checksum), History.Code.CHECKSUM_WIDTH, "exact checksum width")
		context.equal(history.inspect(0).code, History.Code.OK, "checksum rejection preserves prior snapshot")
	var trailing: RefCounted = history.begin_load(0)
	context.equal(history.finish_load(trailing.reader, true), History.Code.TRAILING_BYTES, "trailing bytes")
	var underflow: RefCounted = history.begin_load(0)
	context.equal(underflow.reader.read_bytes(2).code, History.Code.UNDERFLOW, "underflow")
	context.equal(underflow.reader.read_bytes(0).code, History.Code.UNDERFLOW, "sticky underflow")
	context.equal(history.finish_load(underflow.reader, true), History.Code.UNDERFLOW, "failed load")


func _ownership(context: RefCounted) -> void:
	var history: RefCounted = _history()
	var save: RefCounted = history.begin_save(0)
	var bytes: PackedByteArray = PackedByteArray([3, 4])
	save.writer.write_bytes(bytes)
	bytes[0] = 99
	var checksum: PackedByteArray = _checksum()
	history.finish_save(save.writer, true, checksum)
	checksum[15] = 0
	context.equal(save.writer.write_bytes(bytes), History.Code.EXPIRED_VIEW, "retained writer")
	context.equal(save.writer.position().code, History.Code.EXPIRED_VIEW, "expired cursor")
	var load_request: RefCounted = history.begin_load(0)
	context.equal(history.begin_save(1).code, History.Code.BUSY, "one active view")
	context.equal(load_request.checksum[15], 255, "owned checksum")
	var result: RefCounted = load_request.reader.read_bytes(2)
	result.bytes[0] = 77
	history.finish_load(load_request.reader, true)
	context.equal(load_request.reader.read_bytes(0).code, History.Code.EXPIRED_VIEW, "retained reader")
	context.equal(load_request.reader.position().code, History.Code.EXPIRED_VIEW, "expired reader cursor")
	var again: RefCounted = history.begin_load(0)
	context.bytes_equal(again.reader.read_bytes(2).bytes, PackedByteArray([3, 4]), 0, "owned reads")
	history.terminate_views()
	context.equal(again.reader.status(), History.Code.EXPIRED_VIEW, "termination expires")


func _validation(context: RefCounted) -> void:
	var history: RefCounted = History.new()
	context.equal(history.begin_save(0).code, History.Code.NOT_CONFIGURED, "unconfigured")
	for values: Array in [[0, 4, 0, 0, 100], [2, 4, 2, 1, 100], [3, 0, 2, 1, 100], [3, 4, 2, 3, 100], [3, 4, 2, 2, 1], [9223372036854775807, 4, 0, 0, 100]]:
		context.equal(history.configure(values[0], values[1], values[2], values[3], values[4]), History.Code.INVALID_CONFIGURATION, "bounds")
	context.equal(history.configure(3, 4, 2, 2, 1000, false), History.Code.OK, "valid")
	for frame: int in [-1, 2147483648]:
		context.equal(history.begin_save(frame).code, History.Code.FRAME_RANGE, "frame bounds")
	var save: RefCounted = history.begin_save(2147483647)
	save.writer.write_bytes(PackedByteArray())
	context.equal(history.configure(3, 4, 2, 2, 1000), History.Code.BUSY, "configure during view")
	context.equal(history.finish_save(save.writer, true), History.Code.OK, "checksum disabled permits empty snapshot")
	var load_request: RefCounted = history.begin_load(2147483647)
	context.equal(history.finish_load(load_request.reader, true), History.Code.OK, "empty record")


# Value: protects=stale completion isolation and reconfiguration ownership; fails_when=wrong view closes a live request; why_new=round-trip omits misuse; seam=none
func _misuse(context: RefCounted) -> void:
	var history: RefCounted = _history()
	var initial: RefCounted = history.begin_save(0)
	initial.writer.write_bytes(PackedByteArray([11, 12]))
	context.equal(history.finish_save(initial.writer, true, _checksum()), History.Code.OK, "initial save")
	var replacement: RefCounted = history.begin_save(3)
	context.equal(history.inspect(0).code, History.Code.BUSY, "inspection while request active")
	context.equal(history.finish_save(initial.writer, true, _checksum()), History.Code.EXPIRED_VIEW, "old completion rejected")
	replacement.frame = 999
	replacement.generation = 999
	replacement.writer.write_bytes(PackedByteArray([13]))
	context.equal(history.finish_save(replacement.writer, true, _checksum()), History.Code.OK, "active survives stale completion")
	context.equal(history.inspect(999).code, History.Code.HISTORY_UNAVAILABLE, "metadata mutation not authoritative")
	var owned: RefCounted = history.inspect(3)
	owned.bytes[0] = 99
	owned.checksum[15] = 0
	context.bytes_equal(history.inspect(3).bytes, PackedByteArray([13]), 3, "owned inspection bytes")
	context.equal(history.inspect(3).checksum[15], 255, "owned inspection checksum")
	context.equal(history.configure(0, 4, 2, 2, 1000), History.Code.INVALID_CONFIGURATION, "invalid config")
	context.bytes_equal(history.inspect(3).bytes, PackedByteArray([13]), 3, "invalid config preserves state")
	var failed_load: RefCounted = history.begin_load(3)
	failed_load.reader.read_bytes(1)
	context.equal(history.finish_load(failed_load.reader, false), History.Code.CALLBACK_FAILED, "load callback failure")
	var load_request: RefCounted = history.begin_load(3)
	context.equal(history.finish_load(failed_load.reader, true), History.Code.EXPIRED_VIEW, "stale reader rejected")
	context.equal(load_request.reader.read_bytes(-1).code, History.Code.UNDERFLOW, "negative read")
	context.equal(history.finish_load(load_request.reader, true), History.Code.UNDERFLOW, "negative read sticky")
	var previous_generation: int = owned.generation
	context.equal(history.configure(3, 4, 2, 2, 1000), History.Code.OK, "reconfigure")
	context.equal(history.inspect(3).code, History.Code.HISTORY_UNAVAILABLE, "reconfigure clears history")
	var renewed: RefCounted = history.begin_save(3)
	renewed.writer.write_bytes(PackedByteArray([14]))
	history.finish_save(renewed.writer, true, _checksum())
	context.equal(history.begin_load(3, previous_generation).code, History.Code.HISTORY_UNAVAILABLE, "generation persists across config")
	var final_load: RefCounted = history.begin_load(3)
	final_load.reader.read_bytes(1)
	history.finish_load(final_load.reader, true)
