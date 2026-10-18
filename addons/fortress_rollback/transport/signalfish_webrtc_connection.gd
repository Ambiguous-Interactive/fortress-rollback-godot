class_name FortressSignalFishWebRTCConnection
extends WebRTCPeerConnectionExtension

const MAX_MEDIA_SECTIONS: int = 64
const MAX_MID_CHARACTERS: int = 256
const MAX_SDP_CHARACTERS: int = 65536

var _inner: WebRTCPeerConnection = null
var _remote_media_ids: PackedStringArray = PackedStringArray()
var _remote_revision: int = 0
var _has_initialized: bool = false
var _is_active: bool = true
var _lifetime_revision: int = 0


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
	_inner.session_description_created.connect(
		func(kind: String, sdp: String) -> void:
			var target: Object = owner.get_ref()
			if is_instance_valid(target) and target._is_active:
				target.session_description_created.emit(kind, sdp)
	)
	_inner.ice_candidate_created.connect(
		func(mid: String, index: int, candidate: String) -> void:
			var target: Object = owner.get_ref()
			if is_instance_valid(target) and target._is_active:
				target.ice_candidate_created.emit(mid, index, candidate)
	)

	_inner.data_channel_received.connect(
		func(channel: WebRTCDataChannel) -> void:
			var target: Object = owner.get_ref()
			if is_instance_valid(target) and target._is_active:
				target.data_channel_received.emit(channel)
	)


## Each wrapper owns one native connection lifetime. Use create() after close or failed initialization.
func _initialize(config: Dictionary) -> Error:
	_invalidate_remote_media_ids()
	if _inner == null:
		return ERR_UNCONFIGURED
	var can_initialize: bool = not _has_initialized and _is_active
	_has_initialized = true
	_is_active = false
	_lifetime_revision += 1
	var revision: int = _lifetime_revision
	# Godot 4.3 initialize removes the old browser handle without closing its connection.
	_inner.close()
	if not can_initialize:
		return ERR_ALREADY_IN_USE
	if revision != _lifetime_revision:
		return ERR_UNAVAILABLE
	var code: Error = _inner.initialize(config)
	if revision != _lifetime_revision:
		return ERR_UNAVAILABLE
	_is_active = code == OK
	if code != OK:
		_inner.close()
	return code


func _create_data_channel(label: String, config: Dictionary) -> WebRTCDataChannel:
	if _inner == null or not _is_active:
		return null
	var owned: Dictionary = config.duplicate(true)
	# Godot 4.3 emits maxPacketLifetime; browsers require maxPacketLifeTime.
	# Retain the legacy spelling for native implementations reading that key.
	if owned.has("maxPacketLifetime"):
		owned["maxPacketLifeTime"] = owned["maxPacketLifetime"]
	return _inner.create_data_channel(label, owned)


func _get_connection_state() -> WebRTCPeerConnection.ConnectionState:
	return WebRTCPeerConnection.STATE_CLOSED if _inner == null or not _is_active else _inner.get_connection_state()


func _get_gathering_state() -> WebRTCPeerConnection.GatheringState:
	return WebRTCPeerConnection.GATHERING_STATE_NEW if _inner == null or not _is_active else _inner.get_gathering_state()


func _get_signaling_state() -> WebRTCPeerConnection.SignalingState:
	return WebRTCPeerConnection.SIGNALING_STATE_CLOSED if _inner == null or not _is_active else _inner.get_signaling_state()


func _create_offer() -> Error:
	return ERR_UNCONFIGURED if _inner == null or not _is_active else _inner.create_offer()


func _set_local_description(kind: String, sdp: String) -> Error:
	return ERR_UNCONFIGURED if _inner == null or not _is_active else _inner.set_local_description(kind, sdp)


func _set_remote_description(kind: String, sdp: String) -> Error:
	_invalidate_remote_media_ids()
	if _inner == null or not _is_active:
		return ERR_UNCONFIGURED
	var revision: int = _remote_revision
	var code: Error = _inner.set_remote_description(kind, sdp)
	# Native signals may synchronously replace or close this description's lifetime.
	if code == OK and revision == _remote_revision:
		_remote_media_ids = _media_ids(sdp)
	return code


static func _media_ids(sdp: String) -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	if sdp.length() > MAX_SDP_CHARACTERS:
		return result
	var offset: int = 0
	while offset < sdp.length():
		var end: int = sdp.find("\n", offset)
		if end == -1:
			end = sdp.length()
		var line: String = sdp.substr(offset, end - offset).trim_suffix("\r")
		offset = end + 1
		if line.begins_with("m="):
			if result.size() == MAX_MEDIA_SECTIONS:
				return PackedStringArray()
			result.append("")
		elif line.begins_with("a=mid:") and not result.is_empty():
			var mid: String = line.substr(6)
			if mid.is_empty() or mid.length() > MAX_MID_CHARACTERS or result.has(mid) or not result[-1].is_empty():
				return PackedStringArray()
			for character: int in mid.length():
				if mid.unicode_at(character) < 33 or mid.unicode_at(character) > 126:
					return PackedStringArray()
			result[-1] = mid
	return result


func _add_ice_candidate(mid: String, index: int, candidate: String) -> Error:
	if _inner == null or not _is_active:
		return ERR_UNCONFIGURED
	# SignalFish relays only candidate bytes; Firefox requires the negotiated SDP media ID.
	var resolved: String = mid
	if resolved.is_empty():
		if index < 0 or index >= _remote_media_ids.size() or _remote_media_ids[index].is_empty():
			return ERR_INVALID_PARAMETER
		resolved = _remote_media_ids[index]
	return _inner.add_ice_candidate(resolved, index, candidate)


func _poll() -> Error:
	return ERR_UNCONFIGURED if _inner == null or not _is_active else _inner.poll()


func _close() -> void:
	_is_active = false
	_lifetime_revision += 1
	_invalidate_remote_media_ids()
	if _inner != null:
		_inner.close()


func _invalidate_remote_media_ids() -> void:
	_remote_media_ids.clear()
	_remote_revision = 0 if _remote_revision == 9223372036854775807 else _remote_revision + 1
