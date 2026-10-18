extends RefCounted

# Value: protects=actual public engine seam; fails_when=fakes invent methods or channel typo is forwarded; why_new=browser RCA; seam=engine extensions
const F = preload("res://tests/unit/test_signalfish_webrtc.gd")
const W = preload("res://addons/fortress_rollback/transport/signalfish_webrtc.gd")
const Connection = preload("res://addons/fortress_rollback/transport/signalfish_webrtc_connection.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(
		["public_peer", "channel_options", "forwarding", "initialize_lifetime", "candidate_media_ids", "description_reentry", "delayed_callbacks", "initialize_reentry"]
	)


func run_case(name: String, context: RefCounted) -> void:
	if name == "public_peer":
		_public_peer(context)
	elif name == "candidate_media_ids":
		_candidate_media_ids(context)
	elif name == "initialize_reentry":
		_initialize_reentry(context)
	elif name == "delayed_callbacks":
		_delayed_callbacks(context)
	elif name == "description_reentry":
		_description_reentry(context)
	elif name == "initialize_lifetime":
		_initialize_lifetime(context)
	else:
		_wrapper(context, name)
	context.finish()


func _public_peer(context: RefCounted) -> void:
	var fixture: Dictionary = F.new().build(context)
	fixture.direct.detach()
	var mesh: PublicMesh = PublicMesh.new()
	context.equal(mesh.transport.create_mesh(fixture.membership.uuid_to_peer_id(F.U)), OK, "actual native MP initialized without WebRTC plugin")
	context.equal(mesh.transport.has_method("get_max_packet_size"), false, "C++ maximum is not a public Godot method")
	context.equal(fixture.direct.configure(mesh, fixture.membership, fixture.adapter, fixture.peer), W.Code.OK, "configure actual bound engine peer")
	context.equal(fixture.direct.poll(0).code, W.Code.OK, "actual public idle peer poll")
	mesh.transport.close()
	context.equal(fixture.direct.poll(0).code, W.Code.WRONG_STATE, "closed peer rejected before get_unique_id engine error")
	F.new().destroy(fixture)


func _wrapper(context: RefCounted, name: String) -> void:
	var inner: Inner = Inner.new()
	var wrapper: WebRTCPeerConnectionExtension = Connection.new(inner)
	if name == "channel_options":
		var config: Dictionary = {"id": 3, "negotiated": true, "ordered": false, "maxPacketLifetime": 1}
		wrapper.create_data_channel("unreliable", config)
		context.equal(inner.config, {"id": 3, "negotiated": true, "ordered": false, "maxPacketLifetime": 1, "maxPacketLifeTime": 1}, "browser standard lifetime spelling added")
		context.equal(config.has("maxPacketLifeTime"), false, "SDK configuration never mutated")
		wrapper.create_data_channel("reliable", {"id": 1, "ordered": true})
		context.equal(inner.config.has("maxPacketLifeTime"), false, "reliable channel retains policy")
	else:
		var sink: Sink = Sink.new()
		var channel: WebRTCDataChannelExtension = WebRTCDataChannelExtension.new()
		wrapper.data_channel_received.connect(sink.channel)
		inner.data_channel_received.emit(channel)
		context.equal(sink.received_channel, channel, "in-band channel forwarded with ownership")
		wrapper.session_description_created.connect(sink.description)
		wrapper.ice_candidate_created.connect(sink.candidate)
		inner.session_description_created.emit("offer", "owned-sdp")
		inner.ice_candidate_created.emit("mid", 2, "owned-ice")
		context.equal(sink.values, ["offer", "owned-sdp", "mid", 2, "owned-ice"], "engine events forwarded exactly")
		context.equal(wrapper.initialize({"iceServers": []}), OK, "initialize delegated")
		context.equal(wrapper.poll(), ERR_BUSY, "delegate poll failure preserved")
		context.equal(wrapper.add_ice_candidate("mid", 2, "ice"), ERR_INVALID_DATA, "candidate error preserved")
		wrapper.close()
		context.equal(inner.closed, true, "close delegated")


func _initialize_lifetime(context: RefCounted) -> void:
	for first_code: Error in [OK, ERR_INVALID_PARAMETER]:
		var inner: Inner = Inner.new()
		inner.initialize_code = first_code
		var wrapper: WebRTCPeerConnectionExtension = Connection.new(inner)
		context.equal(wrapper.initialize({}), first_code, "initial native result preserved")
		context.equal(inner.live_connections, 1 if first_code == OK else 0, "initial setup closes implicit browser handle")
		context.equal(wrapper.initialize({}), ERR_ALREADY_IN_USE, "reinitialization requires a fresh wrapper")
		context.equal(inner.live_connections, 0, "refused reinitialization closes old native lifetime")
		context.equal(
			inner.operations,
			["close", "initialize", "close"] if first_code == OK else ["close", "initialize", "close", "close"],
			"failed setup and refused reuse close their native resources"
		)


# Value: resolves SignalFish string-only ICE candidates; Firefox rejects empty mids even when Chromium accepts them.
func _candidate_media_ids(context: RefCounted) -> void:
	var inner: Inner = Inner.new()
	var wrapper: WebRTCPeerConnectionExtension = Connection.new(inner)
	var sdp: String = "v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=mid:data_7\r\n"
	context.equal(wrapper.set_remote_description("offer", sdp), OK, "remote SDP forwarded")
	context.equal(wrapper.add_ice_candidate("", 0, "host-candidate"), ERR_INVALID_DATA, "native candidate error preserved")
	context.equal(inner.candidate_values, ["data_7", 0, "host-candidate"], "SDK missing mid resolves actual SDP identity")
	wrapper.add_ice_candidate("explicit", 2, "explicit-candidate")
	context.equal(inner.candidate_values, ["explicit", 2, "explicit-candidate"], "explicit native media identity preserved")
	context.equal(wrapper.add_ice_candidate("", -1, "invalid"), ERR_INVALID_PARAMETER, "negative media index refused")
	context.equal(wrapper.add_ice_candidate("", 1, "invalid"), ERR_INVALID_PARAMETER, "missing media index refused")
	wrapper.set_remote_description("answer", sdp.replace("data_7", "replacement"))
	wrapper.add_ice_candidate("", 0, "replacement-candidate")
	context.equal(inner.candidate_values, ["replacement", 0, "replacement-candidate"], "new SDP replaces prior media mapping")
	inner.description_code = ERR_INVALID_DATA
	context.equal(wrapper.set_remote_description("offer", sdp), ERR_INVALID_DATA, "native SDP refusal preserved")
	context.equal(wrapper.add_ice_candidate("", 0, "stale"), ERR_INVALID_PARAMETER, "rejected SDP cannot reuse old mapping")
	inner.description_code = OK
	var many: String = ""
	for section: int in 64:
		many += "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\na=mid:media_%d\n" % section
	wrapper.set_remote_description("offer", many)
	wrapper.add_ice_candidate("", 63, "last-section")
	context.equal(inner.candidate_values, ["media_63", 63, "last-section"], "maximum section inventory preserves media indices")
	wrapper.set_remote_description("offer", sdp.replace("data_7", "x".repeat(256)))
	wrapper.add_ice_candidate("", 0, "maximum-mid")
	context.equal(inner.candidate_values, ["x".repeat(256), 0, "maximum-mid"], "maximum media ID retained")
	wrapper.set_remote_description("offer", sdp + "x".repeat(65536 - sdp.length()))
	wrapper.add_ice_candidate("", 0, "maximum-sdp")
	context.equal(inner.candidate_values, ["data_7", 0, "maximum-sdp"], "maximum lookup SDP retained")
	for invalid: String in [
		"v=0\n",
		"m=application 9 UDP/DTLS/SCTP webrtc-datachannel\na=mid:\n",
		sdp + "a=mid:duplicate\n",
		"x".repeat(65537),
		sdp.replace("data_7", "x".repeat(257)),
		sdp.replace("data_7", "contains space"),
		many + "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\na=mid:media_64\n"
	]:
		wrapper.set_remote_description("offer", invalid)
		context.equal(wrapper.add_ice_candidate("", 0, "invalid"), ERR_INVALID_PARAMETER, "ambiguous or oversized mapping refused")
	wrapper.set_remote_description("offer", sdp)
	wrapper.initialize({})
	context.equal(wrapper.add_ice_candidate("", 0, "stale"), ERR_INVALID_PARAMETER, "initialize fences old media IDs")
	wrapper.set_remote_description("offer", sdp)
	wrapper.close()
	context.equal(wrapper.add_ice_candidate("", 0, "stale"), ERR_UNCONFIGURED, "close fences old media IDs")


# Value: public forwarded SDP signals can reenter lifecycle calls before native description setup returns.
func _description_reentry(context: RefCounted) -> void:
	var sdp: String = "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\na=mid:obsolete\n"
	for action: String in ["close", "initialize", "nested", "nested_failure"]:
		for outer_code: Error in [OK, ERR_INVALID_DATA]:
			var inner: Inner = Inner.new()
			var wrapper: WebRTCPeerConnectionExtension = Connection.new(inner)
			var owner: WeakRef = weakref(wrapper)
			var callback: Callable = func(_kind: String, _description: String) -> void:
				var active: WebRTCPeerConnection = owner.get_ref()
				if action == "close":
					active.close()
				elif action == "initialize":
					context.equal(active.initialize({}), OK, "reentrant initialize succeeds")
				else:
					inner.description_code = ERR_INVALID_DATA if action == "nested_failure" else OK
					context.equal(active.set_remote_description("answer", sdp.replace("obsolete", "replacement")), inner.description_code, "nested native result preserved")
			wrapper.session_description_created.connect(callback)
			inner.emit_description = true
			inner.description_code = outer_code
			context.equal(wrapper.set_remote_description("offer", sdp), outer_code, "outer native result preserved after reentry")
			wrapper.session_description_created.disconnect(callback)
			if action == "nested":
				context.equal(wrapper.add_ice_candidate("", 0, "current"), ERR_INVALID_DATA, "newest successful SDP remains usable")
				context.equal(inner.candidate_values, ["replacement", 0, "current"], "obsolete outer SDP never replaces nested mapping")
			else:
				context.equal(
					wrapper.add_ice_candidate("", 0, "stale"),
					ERR_UNCONFIGURED if action == "close" else ERR_INVALID_PARAMETER,
					"lifecycle and rejected nested SDP keep mapping cleared"
				)


# Value: protects=closed native callback ownership; fails_when=old ICE, SDP or channels reach the replacement mesh; seam=public native signals
func _delayed_callbacks(context: RefCounted) -> void:
	for transition: String in ["close", "initialize"]:
		var inner: Inner = Inner.new()
		var wrapper: WebRTCPeerConnectionExtension = Connection.new(inner)
		var sink: Sink = Sink.new()
		wrapper.session_description_created.connect(sink.description)
		wrapper.ice_candidate_created.connect(sink.candidate)
		wrapper.data_channel_received.connect(sink.channel)
		context.equal(wrapper.initialize({}), OK, "initial connection lifetime starts")
		var channel: WebRTCDataChannelExtension = WebRTCDataChannelExtension.new()
		inner.session_description_created.emit("offer", "current")
		context.equal(sink.values, ["offer", "current"], "active connection forwards current SDP")
		sink.values.clear()
		if transition == "close":
			wrapper.close()
		else:
			context.equal(wrapper.initialize({}), ERR_ALREADY_IN_USE, "replacement requires a fresh native wrapper")
		inner.session_description_created.emit("answer", "obsolete")
		inner.ice_candidate_created.emit("old-mid", 0, "obsolete")
		inner.data_channel_received.emit(channel)
		context.equal(sink.values.is_empty(), true, "delayed old SDP and ICE stay fenced after " + transition)
		context.equal(sink.received_channel == null, true, "delayed old channels stay fenced after " + transition)
		context.equal(wrapper.add_ice_candidate("explicit", 0, "obsolete"), ERR_UNCONFIGURED, "ended lifetime refuses explicit ICE too")
		context.equal(wrapper.set_remote_description("answer", "obsolete"), ERR_UNCONFIGURED, "ended lifetime refuses delayed signaling")
		var fresh_inner: Inner = Inner.new()
		var fresh: WebRTCPeerConnectionExtension = Connection.new(fresh_inner)
		context.equal(fresh.initialize({}), OK, "fresh wrapper starts replacement lifetime")
		fresh.session_description_created.connect(sink.description)
		fresh.ice_candidate_created.connect(sink.candidate)
		fresh.data_channel_received.connect(sink.channel)
		fresh_inner.session_description_created.emit("answer", "replacement")
		fresh_inner.ice_candidate_created.emit("new-mid", 0, "replacement")
		fresh_inner.data_channel_received.emit(channel)
		context.equal(sink.values, ["answer", "replacement", "new-mid", 0, "replacement"], "replacement SDP and ICE still reach SDK")
		context.equal(sink.received_channel == channel, true, "replacement channel still reaches SDK")
		fresh.close()
		wrapper.close()


# Value: protects=initialization cannot revive a lifetime closed by a synchronous native callback.
func _initialize_reentry(context: RefCounted) -> void:
	for stage: String in ["close", "initialize"]:
		for action: String in ["close", "initialize"]:
			var inner: Inner = Inner.new()
			var wrapper: WebRTCPeerConnectionExtension = Connection.new(inner)
			var owner: WeakRef = weakref(wrapper)
			var nested: Array[int] = []
			var callback: Callable = func() -> void:
				var active: WebRTCPeerConnection = owner.get_ref()
				if action == "close":
					active.close()
				else:
					nested.append(active.initialize({}))
			if stage == "close":
				inner.on_close = callback
			else:
				inner.on_initialize = callback
			context.equal(wrapper.initialize({}), ERR_UNAVAILABLE, "callback prevents obsolete outer initialization: " + stage)
			context.equal(inner.live_connections, 0, "callback closes native lifetime: " + stage)
			if stage == "close":
				context.equal(inner.operations, ["close", "close"], "obsolete initialization never reaches native setup")
			if action == "initialize":
				context.equal(nested, [ERR_ALREADY_IN_USE], "recursive reuse cannot open a native lifetime")
			context.equal(wrapper.create_offer(), ERR_UNCONFIGURED, "closed setup cannot publish an offer")
			context.equal(wrapper.get_connection_state(), WebRTCPeerConnection.STATE_CLOSED, "closed setup reports its actual terminal state")


class PublicMesh:
	extends RefCounted
	var transport: WebRTCMultiplayerPeer = WebRTCMultiplayerPeer.new()

	func get_multiplayer_peer() -> Object:
		return transport


class Sink:
	extends RefCounted
	# Variant records SDK signals with different public payload types.
	var values: Array[Variant] = []
	var received_channel: WebRTCDataChannel = null

	func channel(value: WebRTCDataChannel) -> void:
		received_channel = value

	func description(kind: String, sdp: String) -> void:
		values.append_array([kind, sdp])

	func candidate(mid: String, index: int, ice: String) -> void:
		values.append_array([mid, index, ice])


class Inner:
	extends WebRTCPeerConnectionExtension
	var config: Dictionary = {}
	var closed: bool = false
	var operations: Array[String] = []
	var live_connections: int = 1
	var initialize_code: Error = OK
	var description_code: Error = OK
	var emit_description: bool = false
	var on_close: Callable
	var on_initialize: Callable
	# Variant records the public candidate tuple string, index, string.
	var candidate_values: Array[Variant] = []

	func _initialize(_config: Dictionary) -> Error:
		operations.append("initialize")
		if initialize_code == OK:
			live_connections += 1
		var callback: Callable = on_initialize
		on_initialize = Callable()
		if callback.is_valid():
			callback.call()
		return initialize_code

	func _create_data_channel(_label: String, options: Dictionary) -> WebRTCDataChannel:
		config = options.duplicate(true)
		return null

	func _poll() -> Error:
		return ERR_BUSY

	func _set_remote_description(_kind: String, _sdp: String) -> Error:
		var code: Error = description_code
		if emit_description:
			emit_description = false
			session_description_created.emit("answer", "synchronous-native-answer")
		return code

	func _add_ice_candidate(mid: String, index: int, candidate: String) -> Error:
		candidate_values = [mid, index, candidate]
		return ERR_INVALID_DATA

	func _close() -> void:
		var callback: Callable = on_close
		on_close = Callable()
		operations.append("close")
		if callback.is_valid():
			callback.call()
		live_connections = 0
		closed = true
