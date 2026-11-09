extends RefCounted

# Value: protects=plain-language terminal causes in every example label; fails_when=raw numeric codes reach users;
# why_new=example scenes showed bare "code %d" for terminal reasons; seam=none
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Endpoint = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const RelayTypes = preload("res://addons/fortress_rollback/transport/signalfish_relay_types.gd")
const Viewer = preload("res://examples/online/replay_viewer.gd")
const PeerScene = preload("res://examples/peer/peer.gd")
const OnlineMatch = preload("res://examples/online/match.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["known_reasons", "unknown_reasons", "scene_messages", "peer_failures", "spectator_stops", "endpoint_reasons",
		"transport_reasons", "online_stops"])


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


## The shared endpoint helper covers every protocol endpoint code; unknown codes keep their number.
func _endpoint_reasons(context: RefCounted) -> void:
	for code: int in Endpoint.Code.values():
		var text: String = Endpoint.reason_text(code)
		context.equal(text.is_empty(), false, "endpoint code %d has readable text" % code)
		context.equal(text.contains(str(code)), false, "endpoint code %d does not show its raw number" % code)
		context.equal(text, text.to_lower(), "endpoint code %d text stays plain" % code)
	context.equal(Endpoint.reason_text(Endpoint.Code.OK), "no failure", "healthy endpoints keep a readable cause")
	context.equal(Endpoint.reason_text(Endpoint.Code.TOKEN_REUSED), "transport token reused", "token reuse names its cause")
	context.equal(Endpoint.reason_text(Endpoint.Code.TERMINATED), "session terminated", "endpoint termination stays distinct from input failure")
	context.equal(Endpoint.reason_text(999), "failure code 999", "unknown endpoint codes keep their number")


## The transport helper covers the relay/fallback enum; the fallback coordinator reuses this space.
func _transport_reasons(context: RefCounted) -> void:
	for code: int in RelayTypes.Code.values():
		var text: String = RelayTypes.reason_text(code)
		context.equal(text.is_empty(), false, "transport code %d has readable text" % code)
		context.equal(text.contains(str(code)), false, "transport code %d does not show its raw number" % code)
		context.equal(text, text.to_lower(), "transport code %d text stays plain" % code)
	context.equal(RelayTypes.reason_text(RelayTypes.Code.OK), "no failure", "healthy transports keep a readable cause")
	context.equal(RelayTypes.reason_text(RelayTypes.Code.WRONG_SESSION), "packet from another match", "foreign-match packets name their cause")
	context.equal(RelayTypes.reason_text(RelayTypes.Code.SDK_FAILURE), "the transport sdk failed", "SDK failure names its layer")
	context.equal(RelayTypes.reason_text(-3), "failure code -3", "unknown transport codes keep their number")


## The online example's protocol and transport stop lines name the cause and keep
## the numeric code beside it for tooling parity.
func _online_stops(context: RefCounted) -> void:
	var match_scene: OnlineMatch = OnlineMatch.new()
	var protocol: String = match_scene._stopped_text("Protocol stopped", Endpoint.reason_text(Endpoint.Code.TOKEN_REUSED), Endpoint.Code.TOKEN_REUSED)
	context.equal(protocol.contains("transport token reused"), true, "protocol stop names its cause")
	context.equal(protocol.contains("code %d" % Endpoint.Code.TOKEN_REUSED), true, "protocol stop retains its code for tooling")
	var queue: String = match_scene._stopped_text("Transport queue stopped", RelayTypes.reason_text(RelayTypes.Code.BACKPRESSURE), RelayTypes.Code.BACKPRESSURE)
	context.equal(queue.contains("transport queues are full"), true, "transport queue stop names its cause")
	context.equal(queue.contains("code %d" % RelayTypes.Code.BACKPRESSURE), true, "transport queue stop retains its code for tooling")
	var transport: String = match_scene._stopped_text("Transport stopped", RelayTypes.reason_text(RelayTypes.Code.SDK_FAILURE), RelayTypes.Code.SDK_FAILURE)
	context.equal(transport.contains("the transport sdk failed"), true, "transport stop names its layer")
	context.equal(transport.contains("code %d" % RelayTypes.Code.SDK_FAILURE), true, "transport stop retains its code for tooling")
