class_name FortressPeerDrop
extends RefCounted

## The coordinated drop of the departed peers of one mesh. When more than one
## survivor is left, the survivors agree the frame that every one of them can
## still freeze before any of them freezes the departed slot. The peer session
## owns the transport, the simulation and the publication; this class owns the
## agreement state and the decisions it makes.
##
## The survivor that owns the lowest surviving slot proposes the cut, because the
## roster is fixed and every survivor reads the same owner from the same slot
## list. Every other survivor answers with the frame window it can still freeze,
## and the proposer commits the frame that all of them can retain.

enum Phase { PROPOSE = 1, ACK = 2, COMMIT = 3 }
enum Role { FOLLOWER = 0, PROPOSER = 1 }
const PENDING: String = "pending"
const COMMITTED: String = "committed"
const FAILED: String = "failed"
const RETRY_US: int = 50000
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const L = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")


class Barrier:
	extends RefCounted
	var index: int = -1
	var slots: PackedInt32Array = PackedInt32Array()
	var operation: int = 0
	var role: int = Role.FOLLOWER
	var cut: int = -1
	var upper: int = -1
	var lower: int = -1
	var adopted: bool = false
	var sent_us: int = -1
	var started_us: int = 0
	var state: String = PENDING
	var answers: Dictionary = {}


var _departed: Dictionary = {}
var _dropped: Dictionary = {}
var _barriers: Dictionary = {}
var _proposals: Dictionary = {}
var _commits: Dictionary = {}
var _operation: int = 0


## Forget every departure and barrier; a fresh session starts empty.
func reset() -> void:
	_departed.clear()
	_dropped.clear()
	_barriers.clear()
	_proposals.clear()
	_commits.clear()
	_operation = 0


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
		return _freeze(host, index, upper)
	_operation = (_operation + 1) & 0xffffffff
	var barrier: Barrier = Barrier.new()
	barrier.index = index
	barrier.slots = slots
	barrier.operation = _operation
	barrier.role = Role.PROPOSER if _proposes(host, index) else Role.FOLLOWER
	barrier.cut = upper
	barrier.upper = upper
	barrier.lower = lower
	barrier.started_us = host._now
	_barriers[key] = barrier
	host._publish_event({"kind": "peer_drop_pending", "peer": host._ids[index].duplicate(), "frame": upper})
	if _proposals.has(key):
		# The proposer reached this survivor before it observed the departure itself.
		barrier.operation = _proposals[key]["operation"]
		barrier.cut = _proposals[key]["cut"]
		barrier.adopted = true
	if _commits.has(key):
		# The commit reached this survivor before it observed the departure itself.
		_commit(host, index, _commits[key]["cut"])
	return true


## Drive the coordinated drops: propose, collect the survivor windows and commit.
func service(host: Variant, now_us: int) -> void:
	for key: String in _barriers.keys():
		var barrier: Barrier = _barriers[key]
		if barrier.state != PENDING:
			continue
		if now_us - barrier.started_us >= host._lifecycle.drop_barrier_timeout_us:
			_fail(host, barrier, "timeout")
			continue
		if barrier.role == Role.FOLLOWER and not barrier.adopted:
			# The follower answers the proposer once it knows the operation.
			continue
		if barrier.sent_us < 0 or now_us - barrier.sent_us >= RETRY_US:
			_send(host, barrier, Phase.PROPOSE if barrier.role == Role.PROPOSER else Phase.ACK)
			barrier.sent_us = now_us
		if barrier.role != Role.PROPOSER or barrier.answers.size() < _live_survivors(host):
			continue
		var cut: int = barrier.cut
		var lower: int = barrier.lower
		for identity: String in barrier.answers:
			cut = mini(cut, int(barrier.answers[identity]["cut"]))
			lower = maxi(lower, int(barrier.answers[identity]["bound"]))
		if cut < lower:
			# No frame is retained by every survivor, so they cannot freeze the same value.
			_fail(host, barrier, "no_common_window")
			continue
		barrier.cut = cut
		barrier.state = COMMITTED
		_send(host, barrier, Phase.COMMIT)
		_freeze(host, barrier.index, cut)


## A survivor answered, proposed or committed a coordinated drop.
func received(host: Variant, index: int, event: Dictionary) -> void:
	var peer_index: int = _peer_for(host, event.get("slots", PackedByteArray()))
	if peer_index == -1:
		return
	var key: String = host._ids[peer_index].hex_encode()
	if is_dropped(key):
		return
	var operation: int = int(event.get("operation", 0))
	var cut: int = int(event.get("cut", -1))
	match int(event.get("phase", 0)):
		Phase.PROPOSE:
			if not _owns_lowest(host, index, peer_index):
				# Only the survivor that owns the lowest surviving slot may propose.
				return
			if not _barriers.has(key):
				# This survivor has not observed the departure yet; it answers once it does.
				_proposals[key] = {"operation": operation, "cut": cut}
				return
			var barrier: Barrier = _barriers[key]
			barrier.operation = operation
			barrier.cut = cut
			barrier.adopted = true
			barrier.sent_us = -1
		Phase.ACK:
			var barrier: Barrier = _barriers.get(key, null)
			if barrier == null or barrier.role != Role.PROPOSER or barrier.operation != operation:
				return
			barrier.answers[host._ids[index].hex_encode()] = {"cut": cut, "bound": int(event.get("bound", -1))}
		Phase.COMMIT:
			_commit(host, peer_index, cut)


## Freeze the departed peer's slots at an agreed frame and keep the match running.
func _commit(host: Variant, index: int, cut: int) -> void:
	var key: String = host._ids[index].hex_encode()
	var barrier: Barrier = _barriers.get(key, null)
	if barrier == null:
		# The commit arrived before this survivor observed the departure; keep it for later.
		_commits[key] = {"cut": cut}
		return
	if cut < 0 or cut > barrier.upper or cut < barrier.lower:
		_fail(host, barrier, "outside_window")
		return
	barrier.state = COMMITTED
	_freeze(host, index, cut)


## Freeze the departed peer's slots and publish the agreed frame.
func _freeze(host: Variant, index: int, cut: int) -> bool:
	var key: String = host._ids[index].hex_encode()
	for slot: int in host._slots_by_peer[index]:
		if host._core.freeze_player(slot, cut) != Types.Code.OK:
			# Without an agreed value the survivors would freeze on different bytes.
			host._publish_event({"kind": "peer_dropped", "peer": host._ids[index].duplicate(), "frame": cut})
			host._core.terminate(Types.Code.PROTOCOL_FAILED)
			return false
	_dropped[key] = {"frame": cut, "slots": host._slots_by_peer[index].duplicate()}
	# The departed peer never reports another checksum and must not hold the window back.
	host._checksums.abandon(host._ids[index])
	host._publish_event({"kind": "peer_dropped", "peer": host._ids[index].duplicate(), "frame": cut})
	return true


## A barrier that cannot agree leaves the survivors on their own confirmed frontier.
func _fail(host: Variant, barrier: Barrier, reason: String) -> void:
	barrier.state = FAILED
	host._publish_event({"kind": "peer_drop_unconfirmed", "peer": host._ids[barrier.index].duplicate(), "reason": reason})
	_freeze(host, barrier.index, barrier.upper)


## Send one barrier phase to every survivor that still takes part in the match.
func _send(host: Variant, barrier: Barrier, phase: int) -> void:
	var slots: PackedByteArray = PackedByteArray()
	for slot: int in barrier.slots:
		slots.append(slot)
	var cut: int = barrier.cut
	var bound: int = barrier.lower
	if phase == Phase.ACK:
		# The answer carries the window this survivor can still freeze.
		cut = barrier.upper
	for index: int in range(host._ids.size()):
		if index == barrier.index:
			continue
		var key: String = host._ids[index].hex_encode()
		if is_gone(key):
			continue
		host._endpoint(index).send_drop_barrier(phase, barrier.operation, cut, bound, slots, host._now)


## The peers that still take part in the match besides this survivor.
func _live_survivors(host: Variant) -> int:
	var count: int = 0
	for index: int in range(host._ids.size()):
		if not is_gone(host._ids[index].hex_encode()):
			count += 1
	return count


## The lowest surviving slot decides which survivor proposes the coordinated drop.
func _lowest_slot(host: Variant, dropped: int) -> int:
	var lowest: int = 2147483647
	for slot: int in host._config.local_players:
		lowest = mini(lowest, slot)
	for index: int in range(host._ids.size()):
		if index == dropped:
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


## The departed peer's slots, matched against the roster.
func _peer_for(host: Variant, slots: PackedByteArray) -> int:
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
