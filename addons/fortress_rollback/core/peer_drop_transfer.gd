class_name FortressPeerDropTransfer
extends RefCounted

const History = preload("res://addons/fortress_rollback/core/peer_drop_history.gd")
const Inventory = preload("res://addons/fortress_rollback/core/peer_drop_inventory.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")


## The inventory carries the largest 16-byte chunk unit every local link accepts.
static func budget(host: Variant, slots: int) -> int:
	var bytes: int = History.MAX_CHUNK_BYTES
	for index: int in host._ids.size():
		var endpoint: RefCounted = host._endpoint(index)
		var packet: int = mini(endpoint._limits.max_packet_bytes, endpoint._handshake.remote_packet_bytes())
		bytes = mini(bytes, packet - Codec.HEADER_BYTES - 54 - slots * 3)
	return (bytes / 16) * 16


## Select one survivor retaining the entire missing interval for every target.
static func select(owner: RefCounted, host: Variant, barrier: RefCounted, cut: int) -> int:
	var first: int = _missing(barrier.receipts, barrier.slots, barrier.lower, cut)
	var chunk_bytes: int = barrier.chunk_budget
	for identity: String in barrier.answers:
		var answer: Dictionary = barrier.answers[identity]
		var missing: int = _missing(answer.receipts, barrier.slots, answer.bound, cut)
		if missing >= 0:
			first = missing if first < 0 else mini(first, missing)
		chunk_bytes = mini(chunk_bytes, answer.chunk_budget)
	if first < 0:
		return Types.Code.OK
	var donor: int = -1
	if Inventory.covers(barrier.receipts, barrier.slots, first, cut):
		donor = _local_slot(host)
	for index: int in host._ids.size():
		var identity: String = host._ids[index].hex_encode()
		if barrier.answers.has(identity) and Inventory.covers(barrier.answers[identity].receipts, barrier.slots, first, cut):
			var slot: int = host._slots_by_peer[index][0]
			donor = slot if donor < 0 else mini(donor, slot)
	if donor < 0:
		return Types.Code.HISTORY_UNAVAILABLE
	if not barrier.history.configure(first, cut, donor, host._config.input_width, barrier.slots.size(), chunk_bytes):
		return Types.Code.INPUT_FAILED
	return Types.Code.OK


static func adopt(host: Variant, barrier: RefCounted, event: Dictionary) -> bool:
	var bytes: PackedByteArray = event.get("bytes", PackedByteArray())
	if bytes.size() != 3:
		return false
	var donor: int = bytes[0]
	var member: bool = host._config.local_players.has(donor)
	for index: int in host._ids.size():
		if barrier.participants.has(host._ids[index].hex_encode()) and host._slots_by_peer[index].has(donor):
			member = true
	if not member or int(event.cut) < barrier.upper or int(event.cut) < Inventory.highest(barrier.receipts):
		return false
	var chunk_bytes: int = bytes.decode_u16(1)
	if chunk_bytes > barrier.chunk_budget or int(event.bound) > int(event.cut):
		return false
	return barrier.history.configure(int(event.bound), int(event.cut), donor, host._config.input_width, barrier.slots.size(), chunk_bytes)


static func service(owner: RefCounted, host: Variant, barrier: RefCounted, now_us: int) -> int:
	var history: History = barrier.history
	if history.first < 0:
		return Types.Code.OK
	if barrier.role == owner.Role.PROPOSER and (barrier.history_plan_us < 0 or now_us - barrier.history_plan_us >= History.RETRY_US):
		barrier.history_plan_us = now_us
		var plan: Dictionary = owner._payload(barrier, owner.Phase.PREPARE, owner.Stage.HISTORY, 0)
		plan.cut = history.cut
		plan.bound = history.first
		plan.bytes = PackedByteArray([history.donor, 0, 0])
		plan.bytes.encode_u16(1, history.chunk_bytes)
		for index: int in host._ids.size():
			if barrier.participants.has(host._ids[index].hex_encode()):
				host._endpoint(index).send_drop_barrier(plan, host._now)
	if not host._config.local_players.has(history.donor):
		return Types.Code.OK
	if not history.prepare(host._core, barrier.slots, host._config.input_width):
		return Types.Code.HISTORY_UNAVAILABLE
	if history.retry_us >= 0 and now_us - history.retry_us < History.RETRY_US:
		return Types.Code.OK
	var work: int = 0
	var complete: bool = true
	for index: int in host._ids.size():
		if not barrier.participants.has(host._ids[index].hex_encode()):
			continue
		var cursor: int = history.cursors.get(index, 0)
		while cursor < history.journal.size() and work < History.WORK:
			var payload: Dictionary = owner._payload(barrier, owner.Phase.BACKFILL, owner.Stage.HISTORY, 0)
			payload.cut = history.cut
			payload.bound = history.first
			payload.available_through = history.donor
			payload.chunk_index = cursor
			payload.chunk_count = history.journal.size()
			payload.bytes = history.journal[cursor]
			work += 1
			if host._endpoint(index).send_drop_barrier(payload, host._now) != I.Code.OK:
				break
			cursor += 1
		history.cursors[index] = cursor
		complete = complete and cursor == history.journal.size()
	if complete:
		history.retry_us = now_us
		history.cursors.clear()
	return Types.Code.OK


static func receive(host: Variant, barrier: RefCounted, source: int, event: Dictionary) -> int:
	var history: History = barrier.history
	if history.first < 0 or barrier.certified:
		return Types.Code.OK
	if not host._slots_by_peer[source].has(history.donor):
		return Types.Code.PROTOCOL_FAILED
	if int(event.cut) != history.cut or int(event.bound) != history.first or int(event.available_through) != history.donor:
		return Types.Code.PROTOCOL_FAILED
	if not history.accept(int(event.chunk_index), int(event.chunk_count), event.bytes, host._config.input_width, barrier.slots.size()):
		return Types.Code.INPUT_ALREADY_SUBMITTED
	return history.install(host._core, barrier.slots, host._config.input_width)


static func _missing(receipts: Dictionary, slots: PackedInt32Array, lower: int, cut: int) -> int:
	var first: int = -1
	for slot: int in slots:
		var retained: Vector2i = receipts[slot]
		var missing: int = lower if retained.x < 0 or retained.x > lower else retained.y + 1
		if missing <= cut:
			first = missing if first < 0 else mini(first, missing)
	return first


static func _local_slot(host: Variant) -> int:
	var slot: int = 2147483647
	for local: int in host._config.local_players:
		slot = mini(slot, local)
	return slot
