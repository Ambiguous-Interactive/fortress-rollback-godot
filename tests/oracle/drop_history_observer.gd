extends RefCounted

const Drop = preload("res://addons/fortress_rollback/core/peer_drop_barrier.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")

var order: int = 0
var publications: Dictionary = {}

## The barrier payload shapes the fixture records. One definition keeps the
## observer's publications and the fixture's emissions in the same set, so a
## published-but-unrouted control of any shape fails the completeness assertion.
const RECORDED_PHASES: Array[int] = [Drop.Phase.PREPARE, Drop.Phase.COMMIT]
const RECORDED_STAGES: Array[int] = [Drop.Stage.INVENTORY, Drop.Stage.COMMITTED]


static func tracked(phase: int, stage: int) -> bool:
	return phase in RECORDED_PHASES or (phase == Drop.Phase.REPORT and stage in RECORDED_STAGES)


class ObservedDrop:
	extends Drop
	var observer: WeakRef
	var source: int

	func _publish(host: Variant, index: int, payload: Dictionary) -> int:
		# The same shape set as `tracked`; an inner class cannot call the outer
		# static, so both read these shared constants.
		var phase: int = int(payload.phase)
		var stage: int = int(payload.stage)
		if phase not in RECORDED_PHASES and not (phase == Drop.Phase.REPORT and stage in RECORDED_STAGES):
			return super._publish(host, index, payload)
		var endpoint: RefCounted = host._endpoint(index)
		var before: int = endpoint._outbox.size()
		# Production publication is synchronous and runs no application callback.
		var code: int = super._publish(host, index, payload)
		if code == I.Code.OK:
			for offset: int in range(before, endpoint._outbox.size()):
				observer.get_ref().published(source, host._ids[index][0] - 1, endpoint._outbox[offset])
		return code


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
