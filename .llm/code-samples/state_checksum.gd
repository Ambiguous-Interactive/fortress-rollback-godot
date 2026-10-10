# State checksum sample (FNV-1a over a byte stream).
#
# Godot's built-in hash() is NOT a checksum contract: the algorithm can
# change between engine versions/platforms. A desync detector needs a
# checksum with an explicit byte contract - see
# .llm/skills/determinism/SKILL.md and
# .llm/skills/networking-transport/SKILL.md.
class_name StateChecksum
extends RefCounted

# Standard FNV-1a64 offset 0xcbf29ce484222325 as a signed64 bit pattern.
# Signed overflow supplies modulo-2^64 multiplication in the measured Godot
# native/Web matrix; independent Rust known answers guard that assumption.
# This 8-byte sample does not implement Fortress's 16-byte checksum domain.
const OFFSET_BASIS: int = -3750763034362895579
const PRIME: int = 1099511628211

var _hash: int = OFFSET_BASIS


func update_bytes(data: PackedByteArray) -> void:
	for byte: int in data:
		_hash ^= byte
		_hash = _hash * PRIME


func update_int(value: int) -> void:
	# Canonical int encoding: fixed-width little-endian u64 (sign-extended
	# values are encoded via two's complement bytes).
	var v: int = value
	for _i: int in range(8):
		update_bytes(PackedByteArray([v & 0xFF]))
		v >>= 8


func update_bool(value: bool) -> void:
	update_int(1 if value else 0)


func update_frame(frame: int) -> void:
	# Always checksum the frame number FIRST so a divergence is localized to
	# the exact tick before any state bytes are compared.
	update_int(frame)


func digest() -> int:
	return _hash


func reset() -> void:
	_hash = OFFSET_BASIS
