class_name FortressProtocolReader
extends RefCounted

var stream: StreamPeerBuffer = StreamPeerBuffer.new()
var valid: bool = true


func _init(bytes: PackedByteArray) -> void:
	stream.big_endian = false
	stream.data_array = bytes.duplicate()


func take(width: int) -> PackedByteArray:
	if not valid or width < 0 or width > stream.get_available_bytes():
		valid = false
		return PackedByteArray()
	return stream.get_data(width)[1].duplicate()


func number(width: int, signed_value: bool = false) -> int:
	if not valid or width > stream.get_available_bytes():
		valid = false
		return 0
	match width:
		1:
			return stream.get_u8()
		2:
			return stream.get_16() if signed_value else stream.get_u16()
		4:
			return stream.get_32() if signed_value else stream.get_u32()
	valid = false
	return 0
