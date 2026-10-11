extends RefCounted

# Real SDK decoder and mesh factory witness for a numeric alias introduced by NewPeer alone.
const SDKMesh = preload("res://addons/signal_fish/webrtc/sf_webrtc_mesh.gd")
const M = preload("res://addons/fortress_rollback/transport/signalfish_membership.gd")
const A = preload("res://addons/fortress_rollback/transport/signalfish_adapter.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const LOCAL: String = "00000000-0000-0000-0000-000000000001"
const REMOTE: String = "4afb61dd-c090-dd2c-6bc6-5eaf3da7eb69"
const COLLISION: String = "47a5d0e7-f0f0-053e-880f-5fb4defc9ecf"
var initialized: int = 0


func check(client: Object, wire: Object, session: PackedByteArray) -> bool:
	var roster: Array[Dictionary] = []
	for uuid: String in [LOCAL, REMOTE]:
		roster.append({"id": uuid, "name": "probe", "is_authority": false, "is_ready": true, "epoch": 7})
	wire.server_event("RoomJoined", {
		"room_id": LOCAL, "room_code": "PROBE", "player_id": LOCAL, "game_name": "probe", "max_players": 2,
		"supports_authority": false, "current_players": roster, "is_authority": false,
		"lobby_state": "finalized", "ready_players": [LOCAL, REMOTE], "relay_type": "WebSocket"
	})
	var membership: M = M.new()
	if membership.configure(LOCAL, PackedStringArray([LOCAL, REMOTE]), session, PackedByteArray([7, 0, 0, 0, 0, 0, 0, 0]), T.Config.new()) != OK:
		return false
	var mesh: SDKMesh = SDKMesh.new()
	mesh.peer_connection_factory = _connection
	mesh.multiplayer_peer_factory = func() -> Object: return MultiplayerStub.new()
	var adapter: A = A.new()
	if adapter.attach(client, mesh, membership) != OK:
		mesh.free()
		return false
	var plan: Dictionary = {"generation": LOCAL, "topology": "mesh", "transport": "webrtc", "fallback": "relay",
		"peers": [{"player_id": REMOTE, "player_name": "probe", "is_authority": false, "initiate": false}], "ice_servers": []}
	wire.server_event("SessionPlan", plan)
	var passed: bool = adapter.status().route == "mesh" and initialized == 1 and mesh.get_peer_ids().is_empty()
	# The first connection refused initialization; a valid known additive retry must still reach SDK mesh.
	wire.server_event("NewPeer", {"peer_id": REMOTE, "you_initiate": false})
	passed = passed and initialized == 2 and mesh.get_peer_ids().size() == 1 and mesh.get_peer_ids()[0] == REMOTE and adapter.status().route == "mesh"
	wire.server_event("NewPeer", {"peer_id": COLLISION, "you_initiate": false})
	passed = passed and initialized == 2 and mesh.get_peer_ids().is_empty() and adapter.status().route == "restart_required"
	passed = passed and adapter.receive_mesh(null, PackedByteArray(), M.uuid_to_peer_id(COLLISION), 0) == I.Code.WRONG_STATE
	wire.server_event("SessionPlan", plan)
	passed = passed and adapter.status().route == "restart_required"
	adapter.detach()
	mesh.free()
	return passed


func _connection() -> Object:
	initialized += 1
	var connection: ConnectionStub = ConnectionStub.new()
	connection.refused = initialized == 1
	return connection


class ConnectionStub:
	extends RefCounted
	signal session_description_created(type: String, sdp: String)
	signal ice_candidate_created(media: String, index: int, candidate: String)
	var refused: bool = false
	func initialize(_options: Dictionary) -> Error:
		return ERR_CANT_CREATE if refused else OK
	func close() -> void:
		pass


class MultiplayerStub:
	extends RefCounted
	func create_mesh(_id: int) -> Error:
		return OK
	func add_peer(_connection: Object, _id: int) -> Error:
		return OK
	func remove_peer(_id: int) -> void:
		pass
	func close() -> void:
		pass
