class_name FortressPeerDrop
extends RefCounted

## The coordinated drop of the departed peers of one mesh. When more than one
## survivor is left, the survivors agree the frame that every one of them can
## still freeze before any of them freezes the departed slot, and they certify
## the value they freeze on. The peer session owns the transport, the simulation
## and the publication; this class owns the agreement state and the decisions
## it makes.
##
## The barrier follows the pinned source's vocabulary: one operation identity, a
## prepare, an inventory report, a backfill of the frozen value, an all-survivor
## certificate and an irreversible commit. The Godot tier keeps its own rule for
## choosing the frame: the survivor that owns the lowest surviving slot proposes
## the cut and every survivor answers with the frame window it can still freeze.
## The agreed frame is the input of the pinned certificate, so the survivors
## freeze one frame and one value.
##
## Every field that decides the agreement is derived locally. The wire carries
## the operation identity and the frozen value, but the target set, the eras and
## the coordinator are re-derived, so a peer cannot move the agreed frame or
## the certified value with a message of its own.

enum Phase { PREPARE = 1, REPORT = 2, BACKFILL = 3, COMMIT = 4, ABORT = 5 }
enum Stage { NONE = 0, INVENTORY = 1, READY = 2, COMMITTED = 3, NEEDS_VALUE = 4 }
enum Role { FOLLOWER = 0, PROPOSER = 1 }
enum Abort { SUPERSEDED = 1, MISSING_HISTORY = 2, CONFLICTING_HISTORY = 3, PARTICIPANT_LOST = 4, TIMEOUT = 5, GENERATION_CHANGED = 6, RESOURCE_LIMIT = 7 }
const PENDING: String = "pending"
const COMMITTED: String = "committed"
const FAILED: String = "failed"
const RETRY_US: int = 50000
## The frozen value travels in bounded chunks.
const CHUNK_BYTES: int = 1024
const MAX_CHUNKS: int = 64
## A digest is never zero, so a prepare that carries one is the final candidate.
const DIGEST_MASK: int = 0x3fffffffffffffff
const FNV_OFFSET: int = 0x14650fb0739d0383
const FNV_PRIME: int = 1099511628211
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const L = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")


class Barrier:
	extends RefCounted
	var index: int = -1
	var slots: PackedInt32Array = PackedInt32Array()
	var generations: PackedInt32Array = PackedInt32Array()
	var operation: int = 0
	var coordinator: int = 0
	var coordinator_generation: int = 0
	var target_set_digest: int = 0
	var role: int = Role.FOLLOWER
	var cut: int = -1
	var upper: int = -1
	var lower: int = -1
	var available_through: int = -1
	var digest: int = 0
	var value: PackedByteArray = PackedByteArray()
	var state: String = PENDING
	var answers: Dictionary = {}
	var certificates: Dictionary = {}
	var acknowledged: Dictionary = {}
	var chunks: Dictionary = {}
	var chunk_count: int = 0
	var certified: bool = false
	var adopted: bool = false
	var sent_us: int = -1
	var sent_digest: int = 0
	var started_us: int = 0


var _departed: Dictionary = {}
var _dropped: Dictionary = {}
var _barriers: Dictionary = {}
var _prepares: Dictionary = {}
var _operations: Dictionary = {}


## Forget every departure and barrier; a fresh session starts empty.
func reset() -> void:
	_departed.clear()
	_dropped.clear()
	_barriers.clear()
	_prepares.clear()
	_operations.clear()


## A dropped peer left the match and its slot is frozen at an agreed frame.
func is_dropped(key: String) -> bool:
	return _dropped.has(key)


## A departed peer left the match; a dropped peer is gone and frozen.
func is_gone(key: String) -> bool:
	return _dropped.has(key) or _departed.has(key)


## The frame a dropped peer's slots are frozen at.
func freeze_frame(key: String) -> int:
	return _dropped[key].frame if _dropped.has(key) else -1


## True while a coordinated drop still waits for the survivors.
func pending() -> bool:
	for key: String in _barriers.keys():
		if _barriers[key].state == PENDING:
			return true
	return false


## The barrier of a departed peer, or null when it has none.
func barrier(key: String) -> Barrier:
	return _barriers.get(key, null)


## True when the departed peer has a coordinated drop barrier.
func has_barrier(key: String) -> bool:
	return _barriers.has(key)


## A peer went silent. The survivors agree the frozen frame before they freeze it.
func observed(host: Variant, index: int) -> bool:
	if host._lifecycle.disconnect_behavior != L.Disconnect.CONTINUE:
		host._core.terminate(Types.Code.PROTOCOL_FAILED)
		return false
	var key: String = host._ids[index].hex_encode()
	if is_gone(key):
		return true
	_departed[key] = true
	var slots: PackedInt32Array = host._slots_by_peer[index]
	var upper: int = host._core.status().confirmed_frame
	var lower: int = host._core.rollback_floor()
	if upper < lower:
		# Every frame this survivor could freeze is already released, so the survivors
		# cannot agree on a value and the match cannot continue safely.
		host._publish_event({"kind": "peer_dropped", "peer": host._ids[index].duplicate(), "frame": upper})
		host._core.terminate(Types.Code.PROTOCOL_FAILED)
		return false
	if _live_survivors(host) == 0:
		# The last survivor freezes the slot itself; there is nobody left to agree with.
		return _freeze(host, index, upper, PackedByteArray(), false)
	var barrier: Barrier = Barrier.new()
	barrier.index = index
	barrier.slots = slots
	barrier.generations = _generations(host, index)
	barrier.operation = _sequence(barrier.generations)
	barrier.role = Role.PROPOSER if _proposes(host, index) else Role.FOLLOWER
	barrier.cut = upper
	barrier.upper = upper
	barrier.lower = lower
	barrier.started_us = host._now
	barrier.coordinator = _lowest_slot(host, index)
	barrier.coordinator_generation = _era_of_slot(host, barrier.coordinator)
	barrier.target_set_digest = _target_digest(barrier.slots, barrier.generations)
	barrier.available_through = _available_through(host, barrier)
	_barriers[key] = barrier
	_operations[key] = _identity(barrier)
	host._publish_event({"kind": "peer_drop_pending", "peer": host._ids[index].duplicate(), "frame": upper})
	if _prepares.has(key):
		# The proposer reached this survivor before it observed the departure itself.
		var stored: Dictionary = _prepares[key]
		_prepares.erase(key)
		_receive_prepare(host, int(stored["sender"]), key, barrier, stored["event"])
	return true


## Drive the coordinated drops: propose, collect the survivor windows, certify and commit.
func service(host: Variant, now_us: int) -> void:
	for key: String in _barriers.keys():
		var barrier: Barrier = _barriers[key]
		if barrier.state == COMMITTED:
			if barrier.role == Role.PROPOSER and not _acknowledged_by_all(host, barrier):
				# The commit is irreversible, so it is retried until every survivor
				# acknowledges it. A lost commit must not leave a survivor behind.
				if now_us - barrier.started_us < host._lifecycle.drop_barrier_timeout_us:
					_retry(host, barrier, now_us, Phase.COMMIT)
			continue
		if barrier.state != PENDING:
			continue
		if now_us - barrier.started_us >= host._lifecycle.drop_barrier_timeout_us:
			_fail(host, barrier, "timeout")
			continue
		if barrier.role == Role.PROPOSER:
			_drive_proposer(host, barrier, now_us)
		else:
			_drive_follower(host, barrier, now_us)


## A survivor prepared, answered, backfilled, committed or aborted a coordinated drop.
func received(host: Variant, index: int, event: Dictionary) -> void:
	var slots: PackedByteArray = event.get("slots", PackedByteArray())
	var peer_index: int = _peer_for(host, slots)
	if peer_index == -1:
		return
	var key: String = host._ids[peer_index].hex_encode()
	if is_dropped(key):
		return
	var barrier: Barrier = _barriers.get(key, null)
	match int(event.get("phase", 0)):
		Phase.PREPARE:
			_receive_prepare(host, index, key, barrier, event)
		Phase.REPORT:
			_receive_report(host, index, key, barrier, event)
		Phase.BACKFILL:
			_receive_backfill(host, key, barrier, event)
		Phase.COMMIT:
			_receive_commit(host, peer_index, key, barrier, event)
		Phase.ABORT:
			_receive_abort(host, key, barrier, event)


## The proposer collects the survivor windows, certifies the value and commits.
func _drive_proposer(host: Variant, barrier: Barrier, now_us: int) -> void:
	var live: int = _live_survivors(host)
	if _answered(barrier) < live:
		# The other survivors have not answered yet; the prepare is retried.
		_retry(host, barrier, now_us, Phase.PREPARE)
		return
	var cut: int = barrier.upper
	var bound: int = barrier.lower
	for identity: String in barrier.answers:
		if is_gone(identity):
			# A survivor that left after its answer does not hold the agreement back.
			continue
		cut = mini(cut, int(barrier.answers[identity]["cut"]))
		bound = maxi(bound, int(barrier.answers[identity]["bound"]))
	if cut < bound:
		# No frame is retained by every survivor, so they cannot freeze the same value.
		_fail(host, barrier, "no_common_window")
		return
	if barrier.digest == 0:
		var value: PackedByteArray = _frozen_value(host, barrier, cut)
		if value.is_empty():
			# This survivor cannot read the value it would freeze.
			_fail(host, barrier, "missing_history")
			return
		barrier.value = value
		barrier.digest = _digest(value)
		barrier.cut = cut
	_retry(host, barrier, now_us, Phase.PREPARE)
	var certified: int = 0
	for identity: String in barrier.certificates:
		if is_gone(identity):
			continue
		var certificate: Dictionary = barrier.certificates[identity]
		if int(certificate["cut"]) != barrier.cut or int(certificate["digest"]) != barrier.digest:
			# Two survivors certified different values, so they cannot freeze one value.
			_abort(host, barrier, Abort.CONFLICTING_HISTORY)
			return
		certified += 1
	if certified < live:
		# The all-survivor certificate is not complete yet.
		return
	barrier.state = COMMITTED
	_send(host, barrier, Phase.COMMIT)
	_freeze(host, barrier.index, barrier.cut, barrier.value, true)


## The follower answers the proposer and certifies the agreed frame and value.
func _drive_follower(host: Variant, barrier: Barrier, now_us: int) -> void:
	if not barrier.adopted:
		# The proposer has not reached this survivor yet.
		return
	if barrier.digest == 0:
		# The first prepare only proposes the frame; the answer carries the window.
		_retry(host, barrier, now_us, Phase.REPORT)
		return
	if barrier.certified:
		# The certificate is retried until the proposer commits it.
		if barrier.sent_us < 0 or now_us - barrier.sent_us >= RETRY_US:
			barrier.sent_us = now_us
			_send(host, barrier, Phase.REPORT, Stage.READY)
		return
	if barrier.value.is_empty():
		barrier.value = _frozen_value(host, barrier, barrier.cut)
	if barrier.value.is_empty():
		# The row was released, so the proposer sends the certified value.
		_send(host, barrier, Phase.REPORT, Stage.NEEDS_VALUE)
		return
	var digest: int = _digest(barrier.value)
	if digest != barrier.digest:
		# This survivor holds a different value for the departed slot.
		_abort(host, barrier, Abort.CONFLICTING_HISTORY)
		return
	barrier.digest = digest
	barrier.certified = true
	barrier.sent_us = now_us
	_send(host, barrier, Phase.REPORT, Stage.READY)


## The proposer opened the operation and named the frame it proposes.
func _receive_prepare(host: Variant, index: int, key: String, barrier: Barrier, event: Dictionary) -> void:
	if barrier == null:
		# This survivor has not observed the departure yet; it adopts the operation
		# and answers once it observes the departure itself. The sender is kept, so
		# the replayed prepare is still checked against the coordinator.
		if _prepares.size() >= 8:
			_prepares.clear()
		_prepares[key] = {"event": event.duplicate(true), "sender": index}
		return
	if not _owns_lowest(host, index, barrier.index):
		# Only the survivor that owns the lowest surviving slot may propose.
		return
	if not _accept_operation(key, barrier, event):
		return
	if _read_generations(event.get("slots", PackedByteArray())) != barrier.generations:
		# The prepare belongs to another era of the departed peer.
		return
	if int(event.get("target_set_digest", 0)) != barrier.target_set_digest:
		# The target set is derived locally, so a foreign digest is refused.
		return
	var digest: int = int(event.get("cut_digest", 0))
	if barrier.certified:
		# A certified survivor keeps the frame and the value it certified.
		return
	if digest != 0:
		var cut: int = int(event.get("cut", barrier.cut))
		if cut > barrier.upper or cut < barrier.lower:
			# The agreed frame is outside this survivor's window.
			return
		barrier.cut = cut
		barrier.digest = digest
	barrier.operation = int(event.get("operation", barrier.operation))
	barrier.coordinator = int(event.get("coordinator", barrier.coordinator))
	barrier.coordinator_generation = int(event.get("coordinator_generation", barrier.coordinator_generation))
	barrier.adopted = true
	barrier.sent_us = -1
	_operations[key] = _identity(barrier)


## A survivor reported its window, its certificate or its need for the value.
func _receive_report(host: Variant, index: int, key: String, barrier: Barrier, event: Dictionary) -> void:
	if barrier == null or barrier.role != Role.PROPOSER:
		return
	if int(event.get("operation", -1)) != barrier.operation:
		# A stale operation never joins the agreement.
		return
	var identity: String = host._ids[index].hex_encode()
	var stage: int = int(event.get("stage", Stage.NONE))
	if stage == Stage.INVENTORY:
		var reported_cut: int = int(event.get("cut", -1))
		var reported_bound: int = int(event.get("bound", -1))
		if reported_cut < 0 or reported_bound < 0 or reported_bound > reported_cut:
			# A survivor's window cannot be inverted or empty.
			return
		barrier.answers[identity] = {
			"cut": reported_cut,
			"bound": reported_bound,
			"available_through": int(event.get("available_through", -1)),
		}
		return
	if stage == Stage.NEEDS_VALUE:
		if barrier.digest != 0 and not barrier.value.is_empty():
			# The survivor released the row, so it receives the certified value.
			_send_backfill(host, barrier, identity)
		return
	if stage == Stage.READY:
		if barrier.certificates.has(identity):
			# A duplicated certificate never counts twice.
			return
		barrier.certificates[identity] = {"cut": int(event.get("cut", -1)), "digest": int(event.get("cut_digest", 0))}
		return
	if stage == Stage.COMMITTED:
		barrier.acknowledged[identity] = true


## The frozen value arrived in a bounded chunk.
func _receive_backfill(host: Variant, key: String, barrier: Barrier, event: Dictionary) -> void:
	if barrier == null or barrier.certified:
		# A certified survivor keeps the value it certified.
		return
	if int(event.get("operation", -1)) != barrier.operation:
		return
	var index: int = int(event.get("chunk_index", -1))
	var count: int = int(event.get("chunk_count", 0))
	var bytes: PackedByteArray = event.get("bytes", PackedByteArray())
	if index < 0 or count < 1 or count > MAX_CHUNKS or index >= count or bytes.size() > CHUNK_BYTES:
		return
	barrier.chunk_count = count
	barrier.chunks[index] = bytes
	if barrier.chunks.size() < count:
		return
	var value: PackedByteArray = PackedByteArray()
	for chunk: int in count:
		if not barrier.chunks.has(chunk):
			return
		value.append_array(barrier.chunks[chunk])
	if barrier.digest != 0 and _digest(value) != barrier.digest:
		# The certified value does not match the value the proposer sent.
		_abort(host, barrier, Abort.CONFLICTING_HISTORY)
		return
	barrier.value = value


## The commit is irreversible, but only after this survivor certified the value.
func _receive_commit(host: Variant, index: int, key: String, barrier: Barrier, event: Dictionary) -> void:
	if barrier == null:
		return
	if int(event.get("operation", -1)) != barrier.operation:
		return
	if barrier.state == COMMITTED:
		# The acknowledgement is repeated, so a lost one does not stall the proposer.
		_send(host, barrier, Phase.REPORT, Stage.COMMITTED)
		return
	if barrier.state != PENDING:
		return
	if not barrier.certified:
		# A commit without the local certificate is refused.
		return
	var cut: int = int(event.get("cut", -1))
	var digest: int = int(event.get("cut_digest", 0))
	if cut != barrier.cut or digest != barrier.digest:
		# The commit names another frame or another value.
		return
	barrier.state = COMMITTED
	_freeze(host, index, cut, barrier.value, true)
	_send(host, barrier, Phase.REPORT, Stage.COMMITTED)


## Another survivor closed the operation without committing.
func _receive_abort(host: Variant, key: String, barrier: Barrier, event: Dictionary) -> void:
	if barrier == null or barrier.state != PENDING:
		return
	if int(event.get("operation", -1)) != barrier.operation:
		return
	_fail(host, barrier, _abort_reason(int(event.get("reason", Abort.TIMEOUT))), false)


## The operation identity of a barrier, in the pinned comparison order.
func _identity(barrier: Barrier) -> Dictionary:
	return {
		"target_set_digest": barrier.target_set_digest,
		"coordinator": barrier.coordinator,
		"coordinator_generation": barrier.coordinator_generation,
		"sequence": barrier.operation,
	}


## A message of an older operation never joins the agreement.
func _accept_operation(key: String, barrier: Barrier, event: Dictionary) -> bool:
	var candidate: Dictionary = {
		"target_set_digest": int(event.get("target_set_digest", 0)),
		"coordinator": int(event.get("coordinator", 0)),
		"coordinator_generation": int(event.get("coordinator_generation", 0)),
		"sequence": int(event.get("operation", 0)),
	}
	return not _operations.has(key) or _compare(candidate, _operations[key]) >= 0


## The pinned comparison order of two operation identities.
func _compare(left: Dictionary, right: Dictionary) -> int:
	for field: String in ["target_set_digest", "coordinator", "coordinator_generation", "sequence"]:
		if int(left[field]) < int(right[field]):
			return -1
		if int(left[field]) > int(right[field]):
			return 1
	return 0


## The operation sequence of a departure. The pinned source derives it from the
## target's era, so every survivor computes the same sequence.
func _sequence(generations: PackedInt32Array) -> int:
	var highest: int = 0
	for era: int in generations:
		highest = maxi(highest, era)
	return highest + 1


## The number of survivors that answered and still take part in the match.
func _answered(barrier: Barrier) -> int:
	var count: int = 0
	for identity: String in barrier.answers:
		if not is_gone(identity):
			count += 1
	return count


## The frozen value of the departed slots at the agreed frame.
func _frozen_value(host: Variant, barrier: Barrier, cut: int) -> PackedByteArray:
	if cut < 0:
		return PackedByteArray()
	var value: PackedByteArray = PackedByteArray()
	for slot: int in barrier.slots:
		var bytes: PackedByteArray = host._core.retained_input(slot, cut)
		if bytes.is_empty():
			# The row was released, so this survivor needs the certified value.
			return PackedByteArray()
		value.append_array(bytes)
	return value


## Freeze the departed peer's slots at the agreed frame and publish the agreed value.
func _freeze(host: Variant, index: int, cut: int, value: PackedByteArray, certified: bool) -> bool:
	var key: String = host._ids[index].hex_encode()
	var offset: int = 0
	var width: int = host._config.input_width
	for slot: int in host._slots_by_peer[index]:
		var bytes: PackedByteArray = PackedByteArray()
		if value.size() >= (offset + 1) * width:
			bytes = value.slice(offset * width, (offset + 1) * width)
		offset += 1
		var code: int = Types.Code.OK
		if certified and not bytes.is_empty():
			# The certified value is installed, so the survivors freeze the same bytes.
			code = host._core.freeze_player_with_value(slot, cut, bytes)
		else:
			code = host._core.freeze_player(slot, cut)
		if code != Types.Code.OK:
			# Without an agreed value the survivors would freeze on different bytes.
			host._publish_event({"kind": "peer_dropped", "peer": host._ids[index].duplicate(), "frame": cut})
			host._core.terminate(Types.Code.PROTOCOL_FAILED)
			return false
	_dropped[key] = {"frame": cut, "slots": host._slots_by_peer[index].duplicate()}
	# The departed peer never reports another checksum and must not hold the window back.
	host._checksums.abandon(host._ids[index])
	host._publish_event({"kind": "peer_dropped", "peer": host._ids[index].duplicate(), "frame": cut})
	return true


## A barrier that cannot agree leaves the survivors on the frame they certified,
## or on their own confirmed frontier when no frame was certified. A conflicting
## history ends the match: the survivors would freeze different values.
func _fail(host: Variant, barrier: Barrier, reason: String, notify: bool = true) -> void:
	barrier.state = FAILED
	host._publish_event({"kind": "peer_drop_unconfirmed", "peer": host._ids[barrier.index].duplicate(), "reason": reason})
	if reason == "conflicting_history":
		host._core.terminate(Types.Code.PROTOCOL_FAILED)
		return
	if notify:
		# The other survivors stop waiting instead of timing out on their own.
		_send(host, barrier, Phase.ABORT, Stage.NONE, Abort.TIMEOUT)
	if barrier.digest != 0 and not barrier.value.is_empty():
		# The candidate was published, so every survivor freezes the certified value.
		_freeze(host, barrier.index, barrier.cut, barrier.value, true)
		return
	_freeze(host, barrier.index, barrier.upper, PackedByteArray(), false)


## A conflicting history closes the operation and ends the match.
func _abort(host: Variant, barrier: Barrier, reason: int) -> void:
	if barrier.state != PENDING:
		return
	barrier.state = FAILED
	_send(host, barrier, Phase.ABORT, Stage.NONE, reason)
	host._publish_event({"kind": "peer_drop_unconfirmed", "peer": host._ids[barrier.index].duplicate(), "reason": _abort_reason(reason)})
	host._core.terminate(Types.Code.PROTOCOL_FAILED)


## The published reason of an aborted operation.
func _abort_reason(reason: int) -> String:
	match reason:
		Abort.SUPERSEDED:
			return "superseded"
		Abort.MISSING_HISTORY:
			return "missing_history"
		Abort.CONFLICTING_HISTORY:
			return "conflicting_history"
		Abort.PARTICIPANT_LOST:
			return "participant_lost"
		Abort.GENERATION_CHANGED:
			return "generation_changed"
		Abort.RESOURCE_LIMIT:
			return "resource_limit"
	return "timeout"


## Send one barrier phase to every survivor that still takes part in the match.
func _send(host: Variant, barrier: Barrier, phase: int, stage: int = Stage.NONE, reason: int = 0) -> bool:
	var payload: Dictionary = _payload(barrier, phase, stage, reason)
	var sent: bool = true
	for index: int in range(host._ids.size()):
		if index == barrier.index:
			continue
		var key: String = host._ids[index].hex_encode()
		if is_gone(key):
			continue
		var code: int = host._endpoint(index).send_drop_barrier(payload, host._now)
		if code != I.Code.OK:
			# A refused barrier message never reaches the survivor.
			sent = false
	return sent


## The wire payload of one barrier phase.
func _payload(barrier: Barrier, phase: int, stage: int, reason: int) -> Dictionary:
	var cut: int = barrier.cut
	var bound: int = barrier.lower
	var digest: int = 0
	if phase == Phase.REPORT and stage == Stage.INVENTORY:
		# The inventory report carries this survivor's own window.
		cut = barrier.upper
	elif phase == Phase.PREPARE or phase == Phase.COMMIT or stage == Stage.READY or stage == Stage.COMMITTED:
		# A prepare that carries a digest is the final candidate; the commit names
		# the certified frame and value.
		digest = barrier.digest
	return {
		"phase": phase,
		"stage": stage,
		"reason": reason,
		"coordinator": barrier.coordinator,
		"coordinator_generation": barrier.coordinator_generation,
		"operation": barrier.operation,
		"target_set_digest": barrier.target_set_digest,
		"cut": cut,
		"bound": bound,
		"available_through": barrier.available_through,
		"cut_digest": digest,
		"chunk_index": 0,
		"chunk_count": barrier.chunk_count,
		"data": _targets(barrier),
		"bytes": PackedByteArray(),
	}


## The wire payload of the frozen value's backfill chunks.
func _send_backfill(host: Variant, barrier: Barrier, identity: String) -> void:
	if barrier.value.is_empty():
		return
	var count: int = maxi(1, (barrier.value.size() + CHUNK_BYTES - 1) / CHUNK_BYTES)
	barrier.chunk_count = count
	for peer: int in range(host._ids.size()):
		if host._ids[peer].hex_encode() != identity:
			continue
		for chunk: int in count:
			var payload: Dictionary = _payload(barrier, Phase.BACKFILL, Stage.NONE, 0)
			payload["chunk_index"] = chunk
			payload["chunk_count"] = count
			payload["bytes"] = barrier.value.slice(chunk * CHUNK_BYTES, mini((chunk + 1) * CHUNK_BYTES, barrier.value.size()))
			host._endpoint(peer).send_drop_barrier(payload, host._now)
		return


## The target list of a barrier: the departed peer's slots and their eras.
func _targets(barrier: Barrier) -> PackedByteArray:
	var result: PackedByteArray = PackedByteArray()
	for index: int in barrier.slots.size():
		result.append(barrier.slots[index])
		result.append(barrier.generations[index] & 255)
		result.append((barrier.generations[index] >> 8) & 255)
	return result


## The eras of a departed peer's slots.
func _generations(host: Variant, index: int) -> PackedInt32Array:
	var era: int = host._era(index)
	var result: PackedInt32Array = PackedInt32Array()
	for slot: int in host._slots_by_peer[index]:
		result.append(era)
	return result


## The eras named by a received target list.
func _read_generations(data: PackedByteArray) -> PackedInt32Array:
	var result: PackedInt32Array = PackedInt32Array()
	var index: int = 0
	while index + 2 < data.size():
		result.append(data[index + 1] | (data[index + 2] << 8))
		index += 3
	return result


## The slots named by a received target list.
func _read_slots(data: PackedByteArray) -> PackedInt32Array:
	var result: PackedInt32Array = PackedInt32Array()
	var index: int = 0
	while index + 2 < data.size():
		result.append(data[index])
		index += 3
	return result


## The digest of the departed slots' target set.
func _target_digest(slots: PackedInt32Array, generations: PackedInt32Array) -> int:
	var bytes: PackedByteArray = PackedByteArray()
	for index: int in slots.size():
		bytes.append(slots[index])
		bytes.append(generations[index] & 255)
		bytes.append((generations[index] >> 8) & 255)
	return _digest(bytes)


## The deterministic digest of the frozen value. It is a consistency check, not
## an integrity primitive: the value is agreed by the survivors, not authenticated.
func _digest(bytes: PackedByteArray) -> int:
	var value: int = FNV_OFFSET
	for byte: int in bytes:
		value = ((value ^ byte) * FNV_PRIME) & DIGEST_MASK
	if value == 0:
		value = 1
	return value


## Retry a barrier phase on the bounded interval.
func _retry(host: Variant, barrier: Barrier, now_us: int, phase: int) -> void:
	var changed: bool = phase == Phase.PREPARE and barrier.sent_digest != barrier.digest
	if not changed and barrier.sent_us >= 0 and now_us - barrier.sent_us < RETRY_US:
		return
	barrier.sent_us = now_us
	barrier.sent_digest = barrier.digest
	if phase == Phase.REPORT:
		_send_report(host, barrier)
		return
	_send(host, barrier, phase)


## The inventory report of this survivor: its window and the frame through which
## it retains the departed slot's inputs.
func _send_report(host: Variant, barrier: Barrier) -> void:
	barrier.available_through = _available_through(host, barrier)
	var payload: Dictionary = _payload(barrier, Phase.REPORT, Stage.INVENTORY, 0)
	for index: int in range(host._ids.size()):
		if index == barrier.index:
			continue
		var key: String = host._ids[index].hex_encode()
		if is_gone(key):
			continue
		host._endpoint(index).send_drop_barrier(payload, host._now)


## The frame through which this survivor retains the departed slot's inputs.
func _available_through(host: Variant, barrier: Barrier) -> int:
	var frames: PackedInt64Array = host._core.received_frames()
	var through: int = 2147483647
	for slot: int in barrier.slots:
		if slot >= frames.size():
			return -1
		through = mini(through, frames[slot])
	return through


## True when every survivor that still takes part in the match acknowledged the commit.
func _acknowledged_by_all(host: Variant, barrier: Barrier) -> bool:
	var live: int = 0
	for identity: String in barrier.acknowledged:
		if not is_gone(identity):
			live += 1
	return live >= _live_survivors(host)


## The peers that still take part in the match besides this survivor.
func _live_survivors(host: Variant) -> int:
	var count: int = 0
	for index: int in range(host._ids.size()):
		if not is_gone(host._ids[index].hex_encode()):
			count += 1
	return count


## The lowest surviving slot decides which survivor proposes the coordinated drop.
## A peer that already left does not own a surviving slot, so it never proposes.
func _lowest_slot(host: Variant, dropped: int) -> int:
	var lowest: int = 2147483647
	for slot: int in host._config.local_players:
		lowest = mini(lowest, slot)
	for index: int in range(host._ids.size()):
		if index == dropped or is_gone(host._ids[index].hex_encode()):
			continue
		for slot: int in host._slots_by_peer[index]:
			lowest = mini(lowest, slot)
	return lowest


## The survivor that owns the lowest surviving slot proposes the drop.
func _proposes(host: Variant, dropped: int) -> bool:
	return host._config.local_players.has(_lowest_slot(host, dropped))


## The sender of a proposal owns the lowest surviving slot.
func _owns_lowest(host: Variant, sender: int, dropped: int) -> bool:
	return host._slots_by_peer[sender].has(_lowest_slot(host, dropped))


## The connected era of one slot: the peer that owns it.
func _era_of_slot(host: Variant, slot: int) -> int:
	if host._config.local_players.has(slot):
		return host._era(-1)
	for index: int in range(host._ids.size()):
		if host._slots_by_peer[index].has(slot):
			return host._era(index)
	return 0


## The departed peer's slots, matched against the roster.
func _peer_for(host: Variant, data: PackedByteArray) -> int:
	var slots: PackedInt32Array = _read_slots(data)
	if slots.is_empty():
		return -1
	for index: int in range(host._ids.size()):
		var owned: PackedInt32Array = host._slots_by_peer[index]
		if owned.size() != slots.size():
			continue
		var same: bool = true
		for position: int in range(owned.size()):
			if owned[position] != slots[position]:
				same = false
				break
		if same:
			return index
	return -1
