extends RefCounted

const SDK_SOCKET_PATH: String = "res://addons/signal_fish/transport/sf_websocket_transport.gd"
# The optional SDK transport creates and connects the socket in one call.
const NATIVE_TRANSPORT_SOURCE: String = """
extends "%s"

func _make_peer() -> SFWebSocketPeerAdapterScript:
	var socket: WebSocketPeer = WebSocketPeer.new()
	socket.inbound_buffer_size = 1048576
	# The SDK's soft queue and frame caps must fit below the engine's hard limit.
	socket.outbound_buffer_size = 1048576
	return SFWebSocketPeerAdapterScript.new(socket)
"""


static func is_available() -> bool:
	return ResourceLoader.exists(SDK_SOCKET_PATH)


static func create() -> RefCounted:
	var script: GDScript = GDScript.new()
	script.source_code = NATIVE_TRANSPORT_SOURCE % SDK_SOCKET_PATH
	if script.reload() != OK:
		return null
	return script.new()
