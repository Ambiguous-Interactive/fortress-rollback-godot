extends RefCounted

# Value: protects=plain-language terminal causes in every example label; fails_when=raw numeric codes reach users;
# why_new=example scenes showed bare "code %d" for terminal reasons; seam=none
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["known_reasons", "unknown_reasons", "scene_messages"])


func run_case(name: String, context: RefCounted) -> void:
	call("_" + name, context)
	context.finish()


func _known_reasons(context: RefCounted) -> void:
	for reason: int in Types.Code.values():
		var text: String = Types.reason_text(reason)
		context.equal(text.is_empty(), false, "reason %d has readable text" % reason)
		context.equal(text.contains(str(reason)), false, "reason %d does not show its raw number" % reason)
		context.equal(text, text.to_lower(), "reason %d text stays plain" % reason)
	context.equal(Types.reason_text(Types.Code.OK), "no failure", "healthy sessions keep a readable cause")
	context.equal(Types.reason_text(Types.Code.DESYNC), "state checksum mismatch", "desync names the failed comparison")
	context.equal(Types.reason_text(Types.Code.HISTORY_UNAVAILABLE), "required history is no longer retained", "history loss names its cause")
	context.equal(Types.reason_text(Types.Code.TERMINATED), "terminated", "cancellation stays distinct from failure")


func _unknown_reasons(context: RefCounted) -> void:
	context.equal(Types.reason_text(999), "reason code 999", "unknown reasons keep their number")
	context.equal(Types.reason_text(-1), "reason code -1", "sentinel reasons keep their number")


func _scene_messages(context: RefCounted) -> void:
	var viewer: RefCounted = load("res://examples/online/replay_viewer.gd").new()
	var message: String = viewer._failure_message(3, Types.Code.HISTORY_UNAVAILABLE, PackedByteArray(), PackedByteArray())
	context.equal(message.contains("required history is no longer retained"), true, "replay stop names the missing history")
	context.equal(message.contains("code %d" % Types.Code.HISTORY_UNAVAILABLE), true, "replay stop retains its code for tooling")
	var corrupt: String = viewer._failure_message(5, Types.Code.DESYNC, PackedByteArray([1]), PackedByteArray([2]))
	context.equal(corrupt.contains("state checksum mismatch"), true, "checksum stop names the failed comparison")
