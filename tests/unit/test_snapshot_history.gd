extends RefCounted

# Value: protects=bounded transactional snapshots and view lifetime; fails_when=partial save publishes or tags alias; why_new=first production history; seam=none
const History = preload("res://addons/fortress_rollback/core/snapshot_history.gd")
const Writer = preload("res://addons/fortress_rollback/core/snapshot_writer.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["round_trip", "failures", "ownership", "validation", "misuse", "wide_writes", "reusable_reads"])


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
		"wide_writes":
			_wide_writes(context)
		"reusable_reads":
			_reusable_reads(context)
	context.finish()


func _history() -> RefCounted:
	var history: RefCounted = History.new()
	history.configure(3, 4, 2, 2, 1000, true)
	return history


# The writer copies the caller's bytes without interpreting one step per byte.
# Every width, chunk count and overflow boundary keeps the same written bytes.
func _wide_writes(context: RefCounted) -> void:
	for width: int in [1, 7, 64, 4096]:
		for chunks: int in [1, 3]:
			var capacity: int = width * chunks
			var writer: RefCounted = Writer.new(capacity)
			var expected: PackedByteArray = PackedByteArray()
			for chunk: int in range(chunks):
				var payload: PackedByteArray = PackedByteArray()
				payload.resize(width)
				for index: int in range(width):
					payload[index] = (chunk * 31 + index) & 255
				expected.append_array(payload)
				context.equal(writer.write_bytes(payload), History.Code.OK, "width %d chunk %d accepted" % [width, chunk])
				payload[0] = 99
			context.bytes_equal(writer._written_copy(), expected, 0, "width %d chunks %d write the exact bytes" % [width, chunks])
			context.equal(writer.position().value, capacity, "width %d chunks %d advance the cursor" % [width, chunks])
			context.equal(writer.write_bytes(PackedByteArray([1])), History.Code.OVERFLOW, "width %d chunks %d reject the overflow" % [width, chunks])
			context.bytes_equal(writer._written_copy(), expected, 0, "width %d chunks %d preserve the bytes after the overflow" % [width, chunks])
			context.equal(writer.position().value, capacity, "width %d chunks %d keep the cursor after the overflow" % [width, chunks])


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
		context.equal(load_request.reader.is_complete(), false, "unread snapshot is incomplete")
		context.bytes_equal(load_request.reader.read_bytes(4).bytes, PackedByteArray([frame, 0, 1, 2]), frame, "canonical bytes")
		context.equal(load_request.reader.is_complete(), true, "exact consumption can be checked before state publication")
		context.equal(history.finish_load(load_request.reader, true), History.Code.OK, "consume entire record")
		context.equal(load_request.reader.is_complete(), false, "expired reader is incomplete")
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
	context.equal(underflow.reader.is_complete(), false, "errored reader is incomplete")
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
	context.equal(load_request.reader.is_complete(), true, "empty live snapshot is complete")
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


# Value: protects=reusable read ownership and errors; fails_when=copy changes source, cursor or rejected destination; why_new=read_bytes allocates wrappers; seam=none
func _reusable_reads(context: RefCounted) -> void:
	var history: RefCounted = History.new()
	context.equal(history.configure(3, 4096, 2, 2, 65536, true), History.Code.OK, "reusable reader history")
	for width: int in [0, 1, 7, 64, 4096]:
		var payload: PackedByteArray = PackedByteArray()
		payload.resize(width)
		for index: int in width:
			payload[index] = (index * 31 + 7) & 255
		var saved: RefCounted = history.begin_save(0)
		context.equal(saved.writer.write_bytes(payload), History.Code.OK, "write reusable fixture")
		context.equal(history.finish_save(saved.writer, true, _checksum()), History.Code.OK, "publish reusable fixture")
		var loaded: RefCounted = history.begin_load(0)
		context.equal(loaded.reader.has_method("read_into"), true, "reader provides reusable copy")
		if not loaded.reader.has_method("read_into"):
			history.terminate_views()
			return
		var prefix: int = width / 2
		context.bytes_equal(loaded.reader.read_bytes(prefix).bytes, payload.slice(0, prefix), 0, "owned prefix shares cursor")
		var destination: PackedByteArray = PackedByteArray()
		destination.resize(width - prefix)
		destination.fill(255)
		context.equal(loaded.reader.read_into(destination), History.Code.OK, "copy remaining bytes into reusable buffer")
		context.bytes_equal(destination, payload.slice(prefix), 0, "exact reusable suffix")
		context.equal(loaded.reader.position().value, width, "shared cursor advances once")
		context.equal(loaded.reader.is_complete(), true, "reusable copy completes the snapshot")
		context.equal(loaded.reader.read_into(PackedByteArray()), History.Code.OK, "empty copy at end succeeds")
		if not destination.is_empty():
			destination[0] ^= 255
		context.equal(history.finish_load(loaded.reader, true), History.Code.OK, "ordinary completion accepts reusable read")
		context.bytes_equal(history.inspect(0).bytes, payload, 0, "destination does not alias retained snapshot")
		var sentinel: PackedByteArray = PackedByteArray([91])
		context.equal(loaded.reader.read_into(sentinel), History.Code.EXPIRED_VIEW, "completed reusable view expires")
		context.bytes_equal(sentinel, PackedByteArray([91]), 0, "expired copy preserves destination")
		loaded = history.begin_load(0)
		var too_wide: PackedByteArray = PackedByteArray()
		too_wide.resize(width + 1)
		too_wide.fill(91)
		var preserved: PackedByteArray = too_wide.duplicate()
		context.equal(loaded.reader.read_into(too_wide), History.Code.UNDERFLOW, "oversized reusable copy refuses")
		context.bytes_equal(too_wide, preserved, 0, "underflow preserves entire destination")
		context.equal(loaded.reader.position().value, 0, "underflow preserves cursor")
		context.equal(loaded.reader.read_into(PackedByteArray()), History.Code.UNDERFLOW, "reusable error is sticky")
		context.equal(loaded.reader.read_bytes(0).code, History.Code.UNDERFLOW, "sticky error crosses APIs")
		context.equal(history.finish_load(loaded.reader, true), History.Code.UNDERFLOW, "reusable underflow fails completion")
		loaded = history.begin_load(0)
		history.terminate_views()
		context.equal(loaded.reader.read_into(sentinel), History.Code.EXPIRED_VIEW, "termination expires reusable reader")
		context.bytes_equal(sentinel, PackedByteArray([91]), 0, "termination preserves caller bytes")
