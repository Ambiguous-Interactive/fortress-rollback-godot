extends RefCounted

const Drop = preload("res://addons/fortress_rollback/core/peer_drop_barrier.gd")

var order: int = 0
var publications: Dictionary = {}


class ObservedDrop:
	extends Drop
	var observer: WeakRef
	var source: int

	func _send(host: Variant, barrier: Barrier, phase: int, stage: int = Stage.NONE, reason: int = 0, retry: bool = false) -> bool:
		if phase != Phase.COMMIT and not (phase == Phase.REPORT and stage in [Stage.INVENTORY, Stage.COMMITTED]):
			return super._send(host, barrier, phase, stage, reason, retry)
		var before: PackedInt32Array = PackedInt32Array()
		for index: int in host._ids.size():
			before.append(host._endpoint(index)._outbox.size())
		# Production publication is synchronous and runs no application callback.
		var result: bool = super._send(host, barrier, phase, stage, reason, retry)
		for index: int in host._ids.size():
			var endpoint: RefCounted = host._endpoint(index)
			for offset: int in range(before[index], endpoint._outbox.size()):
				observer.get_ref().published(source, host._ids[index][0] - 1, endpoint._outbox[offset])
		return result


func install(peer: RefCounted, source: int) -> void:
	var drop: ObservedDrop = ObservedDrop.new()
	drop.observer = weakref(self)
	drop.source = source
	peer._drops = drop


func next_order() -> int:
	if order >= 8192:
		return -1
	order += 1
	return order


func published(source: int, recipient: int, bytes: PackedByteArray) -> void:
	var key: String = "%d:%d:%s" % [source, recipient, bytes.hex_encode()]
	if not publications.has(key):
		publications[key] = []
	publications[key].append(next_order())


func take(source: int, recipient: int, bytes: PackedByteArray) -> int:
	var key: String = "%d:%d:%s" % [source, recipient, bytes.hex_encode()]
	if not publications.has(key) or publications[key].is_empty():
		return -1
	var result: int = publications[key].pop_front()
	if publications[key].is_empty():
		publications.erase(key)
	return result
