# Input frame serialization sample.
#
# Every byte on the wire is explicit, fixed-width, little-endian. Never
# put_var()/get_var(): the encoding is engine-version-dependent and breaks
# replays - see .llm/skills/networking-transport/SKILL.md.
class_name InputFrameCodec
extends RefCounted

const PACKET_MAGIC: int = 0x4652  # "FR"
const PACKET_VERSION: int = 1
const TYPE_INPUT: int = 1

const BUTTON_COUNT: int = 16


## Serialize one player's input frame into exact bytes.
static func encode(frame: int, buttons: PackedInt64Array) -> PackedByteArray:
	assert(buttons.size() == BUTTON_COUNT)
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	buf.put_u16(PACKET_MAGIC)
	buf.put_u8(PACKET_VERSION)
	buf.put_u8(TYPE_INPUT)
	buf.put_u32(frame)
	# Buttons packed bitmask-first: 16 buttons = u16. Extending the layout
	# requires bumping PACKET_VERSION and a replay converter.
	var mask: int = 0
	for i in BUTTON_COUNT:
		if buttons[i] != 0:
			mask |= 1 << i
	buf.put_u16(mask)
	buf.put_u16(0)  # reserved for analog axis 0 (quantized u16)
	buf.put_u16(0)  # reserved for analog axis 1 (quantized u16)
	return buf.data_array


## Inverse of [encode]. Returns an empty dictionary on any framing error.
static func decode(data: PackedByteArray) -> Dictionary:
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	buf.data_array = data
	if data.size() < 12:
		push_error("input packet truncated (%d bytes)" % data.size())
		return {}
	if buf.get_u16() != PACKET_MAGIC or buf.get_u8() != PACKET_VERSION:
		push_error("input packet magic/version mismatch")
		return {}
	var type := buf.get_u8()
	if type != TYPE_INPUT:
		push_error("unexpected packet type %d" % type)
		return {}
	var frame := buf.get_u32()
	var mask := buf.get_u16()
	var buttons := PackedInt64Array()
	buttons.resize(BUTTON_COUNT)
	for i in BUTTON_COUNT:
		buttons[i] = 1 if (mask & (1 << i)) != 0 else 0
	return {"frame": frame, "buttons": buttons}
