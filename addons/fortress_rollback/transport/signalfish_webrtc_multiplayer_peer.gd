class_name FortressSignalFishWebRTCMultiplayerPeer
extends WebRTCMultiplayerPeer


## Install as SFWebRTCMesh.multiplayer_peer_factory before its first plan.
static func create() -> WebRTCMultiplayerPeer:
	var script: Script = load("res://addons/fortress_rollback/transport/signalfish_webrtc_multiplayer_peer.gd")
	return script.new()


## Godot can remove a failed channel's peer before the SDK tears down its entry.
@warning_ignore("native_method_override")
func remove_peer(peer_id: int) -> void:
	if has_peer(peer_id):
		super.remove_peer(peer_id)
