extends RefCounted

# Value: protects=plain-language terminal causes in every example label; fails_when=raw numeric codes reach users;
# why_new=example scenes showed bare "code %d" for terminal reasons; seam=none
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Endpoint = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const RelayTypes = preload("res://addons/fortress_rollback/transport/signalfish_relay_types.gd")
const Viewer = preload("res://examples/online/replay_viewer.gd")
const PeerScene = preload("res://examples/peer/peer.gd")
const OnlineMatch = preload("res://examples/online/match.gd")


## A transport that refuses queued batches and refuses polls, so the online
## example's real service path renders its stop lines.
class RefusingFallback extends OnlineMatch.Fallback:
	const _Relay = preload("res://addons/fortress_rollback/transport/signalfish_relay_types.gd")

	func enqueue_batch(_packets) -> int:
		return _Relay.Code.WRONG_STATE

	func poll(_now_us: int, _next_token_factory: Callable = Callable()) -> _Relay.Result:
		return _Relay.Result.new(_Relay.Code.SDK_FAILURE)


## A protocol endpoint that refuses polls, so the online example's real poll
## path renders its stop line.
class RefusingPeer extends OnlineMatch.Peer:
	const _Endpoint = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")

	func poll(_now_us: Variant, _tokens: Variant = []) -> int:
		return _Endpoint.Code.WRONG_CONNECTION


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


## The online example's real service and poll paths name the stop cause and keep
## the numeric code beside it for tooling parity. Each path renders through its
## own enum space, pinned by codes that exist in only one of the two enums.
func _online_stops(context: RefCounted) -> void:
	var match_scene: OnlineMatch = OnlineMatch.new()
	match_scene.has_started = true
	match_scene.fallback = RefusingFallback.new()
	match_scene._pending = [OnlineMatch.Peer.Packet.new(PackedByteArray(), PackedByteArray())]
	match_scene._service(0)
	context.equal(
		match_scene.failure,
		"Transport queue stopped: transport is not configured for this call (code %d). Leave and create a new room." % RelayTypes.Code.WRONG_STATE,
		"the transport queue stop names its transport cause beside its code"
	)
	match_scene.failure = ""
	match_scene._pending = []
	match_scene._service(0)
	context.equal(
		match_scene.failure,
		"Transport stopped: the transport sdk failed (code %d). Leave and create a new room." % RelayTypes.Code.SDK_FAILURE,
		"the transport stop names its transport cause beside its code"
	)
	match_scene.failure = ""
	match_scene.peer = RefusingPeer.new()
	match_scene._poll_protocol(0)
	context.equal(
		match_scene.failure,
		"Protocol stopped: packet on the wrong connection (code %d). Leave and create a new room." % Endpoint.Code.WRONG_CONNECTION,
		"the protocol stop names its endpoint cause beside its code"
	)
