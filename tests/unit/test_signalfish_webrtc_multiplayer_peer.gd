extends RefCounted

# Value: protects=SDK cleanup after engine peer removal; fails_when=missing peer removal emits engine errors; why_new=channel doubles keep peers; seam=public call
const Peer = preload("res://addons/fortress_rollback/transport/signalfish_webrtc_multiplayer_peer.gd")

class Connection:
	extends WebRTCPeerConnectionExtension

	func _get_connection_state() -> WebRTCPeerConnection.ConnectionState:
		return WebRTCPeerConnection.STATE_NEW

	func _create_data_channel(_label: String, _options: Dictionary) -> WebRTCDataChannel:
		return WebRTCDataChannelExtension.new()


func cases() -> PackedStringArray:
	return PackedStringArray(["idempotent_removal"])

func run_case(_name: String, context: RefCounted) -> void:
	var peer: WebRTCMultiplayerPeer = Peer.create()
	context.equal(peer.create_mesh(1), OK, "public factory creates real engine mesh")
	var connection: Connection = Connection.new()
	context.equal(peer.add_peer(connection, 2), OK, "real engine registers present peer")
	context.equal(peer.has_peer(2), true, "present peer exists before SDK removal")
	peer.call("remove_peer", 2)
	context.equal(peer.has_peer(2), false, "SDK removal still removes present engine peer")
	for absent: int in [2, 2, 2147483647]:
		peer.call("remove_peer", absent)
		context.equal(peer.has_peer(absent), false, "SDK removal leaves absent peer absent")
	peer.close()
	peer.call("remove_peer", 2)
	context.finish()
