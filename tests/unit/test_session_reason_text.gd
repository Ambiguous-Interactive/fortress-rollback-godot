extends RefCounted

# Value: protects=plain-language terminal causes in every example label; fails_when=raw numeric codes reach users;
# why_new=example scenes showed bare "code %d" for terminal reasons; seam=none
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Viewer = preload("res://examples/online/replay_viewer.gd")
const PeerScene = preload("res://examples/peer/peer.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["known_reasons", "unknown_reasons", "scene_messages", "peer_failures", "spectator_stops"])


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
	var viewer: Viewer = Viewer.new()
	var message: String = viewer._failure_message(3, Types.Code.HISTORY_UNAVAILABLE, PackedByteArray(), PackedByteArray())
	context.equal(message.contains("required history is no longer retained"), true, "replay stop names the missing history")
	context.equal(message.contains("code %d" % Types.Code.HISTORY_UNAVAILABLE), true, "replay stop retains its code for tooling")
	var corrupt: String = viewer._failure_message(5, Types.Code.DESYNC, PackedByteArray([1]), PackedByteArray([2]))
	context.equal(corrupt.contains("state checksum mismatch"), true, "checksum stop names the failed comparison")


## The peer example's failure line shows the protocol endpoint enum, which is a
## different numeric space from session reasons, so it keeps its own wording.
func _peer_failures(context: RefCounted) -> void:
	var scene: PeerScene = PeerScene.new()
	const Endpoint = PeerScene.Match.I
	context.equal(scene._endpoint_failure_text(Endpoint.Code.OK), "none", "healthy peer match names no failure")
	context.equal(scene._endpoint_failure_text(Endpoint.Code.INPUT_FAILED), "confirmed input failed", "peer input failure names its cause")
	context.equal(scene._endpoint_failure_text(Endpoint.Code.BACKPRESSURE), "blocked packets", "blocked packets keep their injected-fault name")
	context.equal(scene._endpoint_failure_text(Endpoint.Code.TERMINATED), "session terminated", "peer termination stays distinct from input failure")
	for code: int in Endpoint.Code.values():
		var text: String = scene._endpoint_failure_text(code)
		context.equal(text.is_empty(), false, "endpoint code %d has readable text" % code)
		context.equal(text.contains(str(code)), false, "endpoint code %d does not show its raw number" % code)
	context.equal(scene._endpoint_failure_text(999), "failure code 999", "unknown endpoint codes keep their number")
	scene.free()


## The spectator scene's mapped stop wordings keep their domain phrasing and
## gain the numeric code; unmapped reasons fall back to the shared text.
func _spectator_stops(context: RefCounted) -> void:
	var scene: Node2D = load("res://examples/spectator/spectator.gd").new()
	var status: Types.Status = Types.Status.new()
	status.reason = Types.Code.TERMINATED
	context.equal(scene._stop_reason(status), "viewing canceled (code %d)" % Types.Code.TERMINATED, "spectator stop keeps its wording beside its code")
	status.reason = Types.Code.NOT_SYNCHRONIZED
	context.equal(
		scene._stop_reason(status), "waiting for synchronization (code %d)" % Types.Code.NOT_SYNCHRONIZED,
		"unmapped spectator reasons use the shared text"
	)
	scene.free()
