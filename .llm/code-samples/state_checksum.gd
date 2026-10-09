# State checksum sample (FNV-1a over a byte stream).
#
# Godot's built-in hash() is NOT a checksum contract: the algorithm can
# change between engine versions/platforms. A desync detector needs a
# checksum that is stable forever - see
# .llm/skills/determinism/SKILL.md and
# .llm/skills/networking-transport/SKILL.md.
class_name StateChecksum
extends RefCounted

const OFFSET_BASIS: int = 0x1DC91FA97C4A0ED1  # FNV-1a 64 basis, top bit cleared
const PRIME: int = 0x2DD7E1CFAF5FDD           # FNV-1a 64 prime, masked to 63 bits
const MASK: int = 0x7FFFFFFFFFFFFFFF

var _hash: int = OFFSET_BASIS


func update_bytes(data: PackedByteArray) -> void:
	for byte in data:
		_hash ^= byte
		_hash = (_hash * PRIME) & MASK


func update_int(value: int) -> void:
	# Canonical int encoding: fixed-width little-endian u64 (sign-extended
	# values are encoded via two's complement bytes).
	var v := value
	for i in 8:
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
