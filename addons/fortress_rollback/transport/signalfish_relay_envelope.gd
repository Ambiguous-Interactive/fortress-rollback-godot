class_name FortressSignalFishRelayEnvelope
extends RefCounted

const HEADER_BYTES: int = 57
const MAGIC: Array[int] = [70, 83, 82, 49]
const M = preload("res://addons/fortress_rollback/transport/signalfish_membership.gd")
const R = preload("res://addons/fortress_rollback/transport/signalfish_relay_types.gd")


class Decoded:
	extends RefCounted
	var code: int = R.Code.INVALID_ENVELOPE
	var sender: String = ""
	var recipient: String = ""
	var session: PackedByteArray = PackedByteArray()
	var payload: PackedByteArray = PackedByteArray()


static func encode(session: PackedByteArray, sender_uuid: String, recipient_uuid: String, payload: PackedByteArray) -> PackedByteArray:
	if session.size() != 16 or not M.valid_uuid(sender_uuid) or not M.valid_uuid(recipient_uuid) or payload.is_empty() or payload.size() > 65479:
		return PackedByteArray()
	var writer: StreamPeerBuffer = StreamPeerBuffer.new()
	writer.big_endian = false
	writer.put_data(PackedByteArray(MAGIC))
	writer.put_u8(1)
	writer.put_data(session)
	writer.put_data(sender_uuid.replace("-", "").hex_decode())
	writer.put_data(recipient_uuid.replace("-", "").hex_decode())
	writer.put_u32(payload.size())
	writer.put_data(payload)
	return writer.data_array.duplicate()


static func decode(bytes: PackedByteArray, maximum_payload: int) -> Decoded:
	var result: Decoded = Decoded.new()
	result.code = _shape_code(bytes, maximum_payload)
	if result.code != R.Code.OK:
		return result
	result.session = bytes.slice(5, 21)
	result.sender = _uuid(bytes.slice(21, 37))
	result.recipient = _uuid(bytes.slice(37, 53))
	result.payload = bytes.slice(HEADER_BYTES)
	return result


## Validate an envelope against identities already frozen by the room.
static func address_code(bytes: PackedByteArray, maximum_payload: int, sender: PackedByteArray, session: PackedByteArray, recipient: PackedByteArray) -> int:
	var code: int = _shape_code(bytes, maximum_payload)
	if code != R.Code.OK:
		return code
	if bytes.slice(21, 37) != sender:
		return R.Code.WRONG_SOURCE
	if bytes.slice(5, 21) != session:
		return R.Code.WRONG_SESSION
	if bytes.slice(37, 53) != recipient:
		return R.Code.NOT_RECIPIENT
	return R.Code.OK


static func _shape_code(bytes: PackedByteArray, maximum_payload: int) -> int:
	if maximum_payload < 1 or maximum_payload > 65479 or bytes.size() < HEADER_BYTES + 1:
		return R.Code.INVALID_ENVELOPE
	if bytes.size() > HEADER_BYTES + maximum_payload:
		return R.Code.TOO_LARGE
	if bytes.slice(0, 4) != PackedByteArray(MAGIC) or bytes[4] != 1:
		return R.Code.INVALID_ENVELOPE
	var size: int = bytes.decode_u32(53)
	if size < 1 or size != bytes.size() - HEADER_BYTES:
		return R.Code.INVALID_ENVELOPE
	return R.Code.OK


static func _uuid(bytes: PackedByteArray) -> String:
	var text: String = bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [text.substr(0, 8), text.substr(8, 4), text.substr(12, 4), text.substr(16, 4), text.substr(20, 12)]
