extends RefCounted

# Value: protects=integer/LE domain boundaries; fails_when=rounding/endian/wrap drift;
# why_new=Rust oracle differs from Godot implementation; seam=none
const Codec = preload("res://tests/determinism/integer_codec.gd")
const Context = preload("res://tests/runner/test_context.gd")
const Checksum = preload("res://.llm/code-samples/state_checksum.gd")
const VECTORS: String = "res://tests/determinism/integer_vectors.json"


func cases() -> PackedStringArray:
	return PackedStringArray(["arithmetic", "binary", "bounds", "checksum"])


func run_case(name: String, context: RefCounted) -> void:
	# JSON is used only to read oracle metadata, never as a protocol encoding.
	# All wide integers in the fixture are decimal strings, not JSON numbers.
	var document: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(VECTORS))
	match name:
		"arithmetic":
			_arithmetic(document["arithmetic"], context)
		"binary":
			_binary(document["binary"], context)
		"bounds":
			_bounds(context)
		"checksum":
			_checksum(document["checksums"], context)
	context.finish()


func _arithmetic(rows: Array, context: RefCounted) -> void:
	context.equal(rows.size(), 116, "independent arithmetic inventory")
	for index: int in range(rows.size()):
		var row: Dictionary = rows[index]
		var a: int = str(row["a"]).to_int()
		var b: int = str(row["b"]).to_int()
		var expected: int = str(row["value"]).to_int()
		var actual: int = 0
		match row["op"]:
			"add":
				actual = a + b
			"sub":
				actual = a - b
			"mul":
				actual = a * b
			"div":
				actual = a / b
			"rem":
				actual = a % b
			"shl":
				actual = a << b
			"shr":
				actual = a >> b
			_:
				context.equal(row["op"], "known operation", "unknown oracle operation")
		context.equal(actual, expected, "Rust %s[%d] %s,%s" % [row["op"], index, row["a"], row["b"]])
		var bytes: PackedByteArray = PackedByteArray()
		bytes.resize(8)
		bytes.encode_s64(0, actual)
		context.state(index, bytes)


func _binary(rows: Array, context: RefCounted) -> void:
	context.equal(rows.size(), 28, "independent binary inventory")
	for index: int in range(rows.size()):
		var row: Dictionary = rows[index]
		var expected: PackedByteArray = str(row["bytes"]).hex_decode()
		var encoded: Dictionary
		var decoded: Dictionary
		var limbs: PackedInt64Array = PackedInt64Array()
		if row["kind"] == "i32":
			var value: int = str(row["value"]).to_int()
			encoded = Codec.encode_i32(value)
			decoded = Codec.decode_i32(expected, 0)
			context.equal(decoded["value"], value, "signed decode %d" % index)
		else:
			for text: String in row["limbs"]:
				limbs.append(text.to_int())
			encoded = Codec.encode_unsigned(limbs, expected.size())
			decoded = Codec.decode_unsigned(expected, 0, expected.size())
			context.equal(decoded["limbs"], limbs, "unsigned decode %d" % index)
		context.equal(encoded["ok"], true, "encode status %d" % index)
		context.equal(decoded["ok"], true, "decode status %d" % index)
		context.bytes_equal(encoded["bytes"], expected, index, "Rust fixed-width %s" % row["kind"])
		context.equal(decoded["next_offset"], expected.size(), "exact consumption")
		# Prefix/suffix placement checks a real parser offset, not only offset zero.
		var framed: PackedByteArray = PackedByteArray([91])
		framed.append_array(expected)
		framed.append(92)
		var offset_result: Dictionary = Codec.decode_unsigned(framed, 1, expected.size())
		context.equal(offset_result["ok"], true, "embedded value")
		context.equal(offset_result["next_offset"], 1 + expected.size(), "embedded consumption")
		context.state(index, encoded["bytes"])


func _bounds(context: RefCounted) -> void:
	for width: int in [2, 4, 8, 16]:
		for size: int in range(width):
			var short: PackedByteArray = PackedByteArray()
			short.resize(size)
			context.equal(Codec.decode_unsigned(short, 0, width)["error"], "SHORT_BUFFER", "short width=%d size=%d" % [width, size])
		var bytes: PackedByteArray = PackedByteArray()
		bytes.resize(width)
		for offset: int in [-1, 1, width, Codec.I64_MAX]:
			context.equal(Codec.decode_unsigned(bytes, offset, width)["ok"], false, "invalid offset")
	for width: int in [-1, 0, 1, 3, 5, 7, 17, Codec.I64_MAX]:
		context.equal(Codec.decode_unsigned(PackedByteArray(), 0, width)["error"], "WIDTH", "invalid decode width")
		context.equal(Codec.encode_unsigned(PackedInt64Array(), width)["error"], "WIDTH", "invalid encode width")
	for limbs: PackedInt64Array in [PackedInt64Array(), PackedInt64Array([1, 2])]:
		context.equal(Codec.encode_unsigned(limbs, 4)["error"], "WIDTH", "wrong limb count")
	for value: int in [-1, 65536, Codec.I64_MAX]:
		context.equal(Codec.encode_unsigned(PackedInt64Array([value]), 2)["error"], "RANGE", "u16 range")
	for value: int in [-1, 4294967296, Codec.I64_MAX]:
		context.equal(Codec.encode_unsigned(PackedInt64Array([value]), 4)["error"], "RANGE", "u32 range")
	for width: int in [8, 16]:
		for value: int in [-1, 4294967296]:
			var wide: PackedInt64Array = PackedInt64Array()
			wide.resize(width / 4)
			wide[wide.size() - 1] = value
			context.equal(Codec.encode_unsigned(wide, width)["error"], "RANGE", "wide high-limb range")
	for value: int in [-2147483649, 2147483648]:
		context.equal(Codec.encode_i32(value)["error"], "RANGE", "i32 range")
	context.equal(Codec.checked_add(Codec.I64_MAX, 1)["error"], "OVERFLOW", "positive overflow")
	context.equal(Codec.checked_add(Codec.I64_MIN, -1)["error"], "OVERFLOW", "negative overflow")
	context.equal(Codec.checked_add(Codec.I64_MAX, Codec.I64_MIN)["value"], -1, "mixed extremes")
	context.equal(Codec.checked_divrem(1, 0)["error"], "ZERO_DIVISOR", "zero divisor")
	context.equal(Codec.checked_divrem(Codec.I64_MIN, -1)["error"], "OVERFLOW", "division overflow")
	context.equal(Codec.checked_divrem(-7, 3)["quotient"], -2, "truncation toward zero")
	context.equal(Codec.checked_divrem(-7, 3)["remainder"], -1, "remainder sign")
	for count: int in [-1, 64, 65, Codec.I64_MAX]:
		context.equal(Codec.checked_shift(-1, count, true)["error"], "SHIFT_RANGE", "invalid shift")
	context.equal(Codec.checked_shift(-1, 63, true)["value"], -1, "arithmetic right shift")
	context.equal(Codec.advance_frame(0)["value"], 1, "first frame")
	context.equal(Codec.advance_frame(Codec.FRAME_MAX - 1)["value"], Codec.FRAME_MAX, "last representable frame")
	for frame: int in [-1, Codec.FRAME_MAX, Codec.I64_MAX]:
		context.equal(Codec.advance_frame(frame)["error"], "FRAME_RANGE", "no sentinel/overflow advancement")
	context.equal(Codec.increment_sequence16(65535)["value"], 0, "u16 explicit wrap")
	context.equal(Codec.increment_sequence16(0)["value"], 1, "u16 first epoch")
	for value: int in [-1, 65536, Codec.I64_MAX]:
		context.equal(Codec.increment_sequence16(value)["error"], "SEQUENCE_RANGE", "sequence range")
	context.equal(Codec.increment_sequence32(4294967294)["value"], 4294967295, "last u32 sequence")
	for value: int in [-1, 4294967295, 4294967296, Codec.I64_MAX]:
		context.equal(Codec.increment_sequence32(value)["error"], "SEQUENCE_RANGE", "monotonic u32 exhaustion")
	# Verify the oracle can detect swapped byte order without accepting self-roundtrip.
	var probe: RefCounted = Context.new(context.seed)
	probe.bytes_equal(PackedByteArray([0x12, 0x34]), PackedByteArray([0x34, 0x12]), 0, "endian mutant")
	context.equal(probe.failures.size(), 1, "independent negative control")


func _checksum(rows: Array, context: RefCounted) -> void:
	context.equal(rows.size(), 8, "independent FNV inventory")
	for index: int in range(rows.size()):
		var row: Dictionary = rows[index]
		var input: PackedByteArray = str(row["input"]).hex_decode()
		var expected: int = str(row["digest"]).to_int()
		var checksum: RefCounted = Checksum.new()
		checksum.update_bytes(input)
		context.equal(checksum.digest(), expected, "Rust FNV vector %d" % index)
		var bytes: PackedByteArray = PackedByteArray()
		bytes.resize(8)
		bytes.encode_s64(0, checksum.digest())
		context.bytes_equal(bytes, str(row["bytes"]).hex_decode(), index, "Rust FNV bit pattern")
		checksum.reset()
		for byte: int in input:
			checksum.update_bytes(PackedByteArray([byte]))
		context.equal(checksum.digest(), expected, "incremental FNV")
		if input.size() == 8:
			checksum.reset()
			checksum.update_int(input.decode_s64(0))
			context.equal(checksum.digest(), expected, "signed64 LE update")
		context.state(index, bytes)
