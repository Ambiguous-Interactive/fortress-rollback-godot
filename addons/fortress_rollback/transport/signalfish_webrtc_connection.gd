class_name FortressSignalFishWebRTCConnection
extends WebRTCPeerConnectionExtension

var _inner: WebRTCPeerConnection = null


## Install as SFWebRTCMesh.peer_connection_factory before its first plan.
## Native WebRTC still requires a separately installed implementation.
static func create() -> WebRTCPeerConnection:
	var script: Script = load("res://addons/fortress_rollback/transport/signalfish_webrtc_connection.gd")
	return script.new(WebRTCPeerConnection.new())


func _init(inner: WebRTCPeerConnection = null) -> void:
	_inner = inner
	if _inner == null:
		return
	# Weak forwarding avoids a connection -> signal callback -> wrapper cycle.
	var owner: WeakRef = weakref(self)
	_inner.session_description_created.connect(func(kind: String, sdp: String) -> void:
		var target: Object = owner.get_ref()
		if is_instance_valid(target):
			target.session_description_created.emit(kind, sdp))
	_inner.ice_candidate_created.connect(func(mid: String, index: int, candidate: String) -> void:
		var target: Object = owner.get_ref()
		if is_instance_valid(target):
			target.ice_candidate_created.emit(mid, index, candidate))

	_inner.data_channel_received.connect(func(channel: WebRTCDataChannel) -> void:
		var target: Object = owner.get_ref()
		if is_instance_valid(target):
			target.data_channel_received.emit(channel))

func _initialize(config: Dictionary) -> Error:
	if _inner == null:
		return ERR_UNCONFIGURED
	# Godot 4.3 initialize removes the old browser handle without closing its connection.
	_inner.close()
	return _inner.initialize(config)


func _create_data_channel(label: String, config: Dictionary) -> WebRTCDataChannel:
	if _inner == null:
		return null
	var owned: Dictionary = config.duplicate(true)
	# Godot 4.3 emits maxPacketLifetime; browsers require maxPacketLifeTime.
	# Retain the legacy spelling for native implementations reading that key.
	if owned.has("maxPacketLifetime"):
		owned["maxPacketLifeTime"] = owned["maxPacketLifetime"]
	return _inner.create_data_channel(label, owned)


func _get_connection_state() -> WebRTCPeerConnection.ConnectionState:
	return WebRTCPeerConnection.STATE_CLOSED if _inner == null else _inner.get_connection_state()


func _get_gathering_state() -> WebRTCPeerConnection.GatheringState:
	return WebRTCPeerConnection.GATHERING_STATE_NEW if _inner == null else _inner.get_gathering_state()


func _get_signaling_state() -> WebRTCPeerConnection.SignalingState:
	return WebRTCPeerConnection.SIGNALING_STATE_CLOSED if _inner == null else _inner.get_signaling_state()


func _create_offer() -> Error:
	return ERR_UNCONFIGURED if _inner == null else _inner.create_offer()


func _set_local_description(kind: String, sdp: String) -> Error:
	return ERR_UNCONFIGURED if _inner == null else _inner.set_local_description(kind, sdp)


func _set_remote_description(kind: String, sdp: String) -> Error:
	return ERR_UNCONFIGURED if _inner == null else _inner.set_remote_description(kind, sdp)


func _add_ice_candidate(mid: String, index: int, candidate: String) -> Error:
	if _inner == null:
		return ERR_UNCONFIGURED
	return _inner.add_ice_candidate(mid, index, candidate)


func _poll() -> Error:
	return ERR_UNCONFIGURED if _inner == null else _inner.poll()


func _close() -> void:
	if _inner != null:
		_inner.close()
