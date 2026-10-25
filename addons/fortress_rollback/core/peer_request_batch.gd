class_name FortressPeerRequestBatch
extends RefCounted

const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
var _peer: WeakRef
var _identity: int


func _init(peer: RefCounted, identity: int) -> void:
	_peer = weakref(peer)
	_identity = identity


## Returns the same active request until acknowledged; null after completion, cancellation or owner release.
func next_request() -> Types.Request:
	var peer: RefCounted = _peer.get_ref()
	return peer._next_manual_request(_identity) if peer != null else null
