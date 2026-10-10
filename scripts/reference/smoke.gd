# A baseline engine/byte-codec probe, independent of future addon implementation.
extends Node


func _ready() -> void:
	var buffer: StreamPeerBuffer = StreamPeerBuffer.new()
	buffer.big_endian = false
	buffer.put_u32(0x12345678)
	if buffer.data_array != PackedByteArray([0x78, 0x56, 0x34, 0x12]):
		push_error("FORTRESS_BASELINE_SMOKE_FAILED: little-endian codec")
		get_tree().quit(1)
		return
	buffer.seek(0)
	if buffer.get_u32() != 0x12345678:
		push_error("FORTRESS_BASELINE_SMOKE_FAILED: codec round trip")
		get_tree().quit(1)
		return
	print("FORTRESS_BASELINE_SMOKE_OK:78563412")
	if OS.has_feature("web"):
		JavaScriptBridge.eval("document.body.dataset.fortressBaseline = '78563412';")
	else:
		get_tree().quit(0)
