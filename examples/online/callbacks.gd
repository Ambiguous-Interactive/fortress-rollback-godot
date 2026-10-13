extends RefCounted

var _owner: WeakRef
var _revision: int


func _init(owner: RefCounted, revision: int) -> void:
	_owner = weakref(owner)
	_revision = revision


func on_info(info: RefCounted) -> void:
	_dispatch("_on_info", [info])


func on_room(info: RefCounted) -> void:
	_dispatch("_on_room", [info])


func on_lobby(value: int, players: PackedStringArray, ready: bool) -> void:
	_dispatch("_on_lobby", [value, players, ready])


# Variant arguments preserve the optional SDK's different failure signal payloads.
func on_failure(first: Variant = null, second: Variant = null, third: Variant = null) -> void:
	_dispatch("_on_failure", [first, second, third])


func on_protocol_error(reason: String) -> void:
	_dispatch("_on_protocol_error", [reason])


func _dispatch(method: String, arguments: Array) -> void:
	var owner: RefCounted = _owner.get_ref()
	if owner != null and owner.get("_connection_revision") == _revision:
		owner.callv(method, arguments)
