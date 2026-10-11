extends RefCounted

# Value: protects=actual public engine seam; fails_when=fakes invent methods or channel typo is forwarded; why_new=browser RCA; seam=engine extensions
const F = preload("res://tests/unit/test_signalfish_webrtc.gd")
const W = preload("res://addons/fortress_rollback/transport/signalfish_webrtc.gd")
const Connection = preload("res://addons/fortress_rollback/transport/signalfish_webrtc_connection.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["public_peer", "channel_options", "forwarding", "initialize_lifetime"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "public_peer":
		_public_peer(context)
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
	var inner: Inner = Inner.new()
	var wrapper: WebRTCPeerConnectionExtension = Connection.new(inner)
	for attempt: int in 2:
		context.equal(wrapper.initialize({"iceServers": []}), OK, "SDK reinitialize succeeds")
		context.equal(inner.live_connections, 1, "each initialize replaces default connection without orphan " + str(attempt))
	context.equal(inner.operations, ["close", "initialize", "close", "initialize"], "close precedes every initialize")
	inner.initialize_code = ERR_INVALID_PARAMETER
	context.equal(wrapper.initialize({}), ERR_INVALID_PARAMETER, "initialize failure preserved")
	context.equal(inner.live_connections, 0, "failed initialization closes previous connection too")


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

	func _initialize(_config: Dictionary) -> Error:
		operations.append("initialize")
		if initialize_code == OK:
			live_connections += 1
		return initialize_code

	func _create_data_channel(_label: String, options: Dictionary) -> WebRTCDataChannel:
		config = options.duplicate(true)
		return null

	func _poll() -> Error:
		return ERR_BUSY

	func _add_ice_candidate(_mid: String, _index: int, _candidate: String) -> Error:
		return ERR_INVALID_DATA

	func _close() -> void:
		operations.append("close")
		live_connections = 0
		closed = true
