extends RefCounted

# Value: protects=fresh lobby lifetime; fails_when=retained old SDK callbacks mutate new state; seam=production connection callback routing
const Lobby = preload("res://examples/online/lobby.gd")
const Bridge = preload("res://scripts/reference/browser/online_bridge.gd")
const Callbacks = preload("res://examples/online/callbacks.gd")


class Client:
	extends Node
	signal protocol_info(info: RefCounted)
	signal room_joined(info: RefCounted)
	signal lobby_state_changed(value: int, players: PackedStringArray, ready: bool)
	signal protocol_error(reason: String)
	signal connection_failed()
	signal authentication_error(reason: String)
	signal room_join_failed(code: int, reason: String)
	signal server_error(code: int, reason: String, extra: String)
	signal reconnection_failed()
	signal disconnected(code: int, reason: String)
	signal going_away()
	signal room_left()
	signal reconnected()
	func close(_code: int, _reason: String) -> Error:
		return OK


class Scene:
	extends Node2D
	var controller: Lobby = Lobby.new()


func cases() -> PackedStringArray:
	return PackedStringArray(["stale_callbacks", "current_failure_payloads", "released_owner", "captured_target"])


func run_case(name: String, context: RefCounted) -> void:

	if name == "captured_target":
		var bridge: Bridge = Bridge.new()
		var scene: Scene = Scene.new()
		bridge.scene = scene
		var lobby: Lobby = scene.controller
		lobby.client = Client.new()
		lobby._info = RefCounted.new()
		lobby._connect_callbacks()
		var unrelated: Callbacks = Callbacks.new(lobby, lobby._connection_revision)
		lobby.client.protocol_info.connect(unrelated.on_info)
		bridge._command({"kind": "capture_callbacks"})
		context.equal(bridge.old_callbacks.size(), 4, "actual observer captures all required SDK callback kinds")
		lobby.disconnect_room()
		lobby.client = Client.new()
		lobby._connect_callbacks()
		lobby.state = "playing"
		for callback: Dictionary in bridge.old_callbacks:
			context.equal(callback.callable.is_valid(), true, "actual capture retains the old callback target after replacement")
			if callback.kind == "protocol_error" and callback.callable.is_valid():
				callback.callable.call("retained old error")
		context.equal(lobby.state, "playing", "the retained old callback executes but cannot stop the fresh lifetime")
		lobby.disconnect_room()
		bridge.free()
		scene.free()
	elif name == "released_owner":
		var owner: Lobby = Lobby.new()
		var weak: WeakRef = weakref(owner)
		var callback: Callbacks = Callbacks.new(owner, 0)
		owner = null
		context.equal(weak.get_ref(), null, "callback routing does not keep the owning controller alive")
		callback.on_protocol_error("released")
		context.equal(weak.get_ref(), null, "late delivery to a released owner is inert")
	elif name == "stale_callbacks":
		var lobby: Lobby = Lobby.new()
		lobby.client = Client.new()
		lobby._connect_callbacks()
		var old: Callbacks = lobby._callbacks
		var old_revision: int = lobby._connection_revision
		lobby.disconnect_room()
		context.equal(lobby._connection_revision > old_revision, true, "Leave invalidates callbacks before freeing the client")
		lobby.client = Client.new()
		lobby._connect_callbacks()
		lobby.state = "playing"
		lobby.message = "fresh game"
		lobby.has_readied = true
		lobby.all_ready = true
		lobby._joined = true
		var current_info: RefCounted = RefCounted.new()
		lobby._info = current_info
		old.on_info(RefCounted.new())
		old.on_room(null)
		old.on_lobby(0, PackedStringArray(), false)
		old.on_failure("stale", 23, "old room")
		old.on_protocol_error("stale protocol error")
		context.equal(lobby.state, "playing", "old room and error callbacks cannot stop a fresh game")
		context.equal(lobby.message, "fresh game", "old error cannot overwrite the current message")
		context.equal(lobby.has_readied and lobby.all_ready, true, "old ready state cannot change fresh readiness")
		context.equal(lobby._info, current_info, "old protocol info cannot replace the new configuration")
		lobby.client.protocol_error.emit("current failure")
		context.equal(lobby.state, "failed", "current lifetime failure still stops the game")
		context.equal(lobby.message.begins_with("SignalFish: current failure"), true, "current failure retains its actual reason")
		lobby.disconnect_room()
	else:
		for count: int in 4:
			var lobby: Lobby = Lobby.new()
			var client: Client = Client.new()
			lobby.client = client
			lobby._connect_callbacks()
			lobby.state = "connecting"
			match count:
				0:
					client.connection_failed.emit()
				1:
					client.authentication_error.emit("failed")
				2:
					client.room_join_failed.emit(23, "failed")
				3:
					client.server_error.emit(23, "failed", "payload")
			context.equal(lobby.state, "failed", "current SDK failure preserves arity %d" % count)
			lobby.disconnect_room()
	context.finish()
