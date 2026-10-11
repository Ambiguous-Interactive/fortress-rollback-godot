class_name FortressHandshakeAgreement
extends RefCounted

const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")


static func mismatch(ours: T.Message, theirs: T.Message) -> Dictionary:
	var fields: Array[String] = ["min_compat_version", "player_count", "input_width", "fps", "max_prediction", "desync_interval", "features"]
	for field: String in fields:
		# Variant carries the fixed-width integer or owned bytes in a mismatch record.
		var first: Variant = ours.get(field) if field in ["min_compat_version", "features"] else ours.config.get(field)
		var second: Variant = theirs.get(field) if field in ["min_compat_version", "features"] else theirs.config.get(field)
		if first != second:
			return {"field": field, "ours": first, "theirs": second}
	for field: String in ["input_delay", "input_format", "snapshot_format", "checksum_algorithm", "neutral_input", "roster"]:
		if ours.config.get(field) != theirs.config.get(field):
			return {"field": field, "ours": _owned(ours.config.get(field)), "theirs": _owned(theirs.config.get(field))}
	if ours.config_digest != theirs.config_digest:
		return {"field": "config_digest", "ours": ours.config_digest.hex_encode(), "theirs": theirs.config_digest.hex_encode()}
	return {}


static func _owned(value: Variant) -> Variant:
	if value is PackedByteArray:
		return value.hex_encode()
	if value is Array:
		var result: Array[String] = []
		for identity: PackedByteArray in value:
			result.append(identity.hex_encode())
		return result
	return value
