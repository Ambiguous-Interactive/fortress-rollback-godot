extends "res://tests/unit/test_peer_drop_backfill.gd"

var _inventory_emissions: Array[Dictionary] = []
var _inventory_receipts: Array[Dictionary] = []
var _lost_inventory: Array[Dictionary] = []
var _drop_first_inventory: bool = false
var _history_receipts: Array[Dictionary] = []
var _history_emissions: Array[Dictionary] = []
var _lost_history: Array[Dictionary] = []
var _commit_emissions: Array[Dictionary] = []
var _commit_receipts: Array[Dictionary] = []
const Observation = preload("res://tests/oracle/drop_history_observer.gd")
var _observation: Observation = Observation.new()
var _ack_emissions: Array[Dictionary] = []
var _ack_receipts: Array[Dictionary] = []
var _lost_ack: Array[Dictionary] = []
var _drop_first_ack: bool = false
var _lost_commit: Array[Dictionary] = []
var _drop_first_commit: bool = false
var _drop_first_history: bool = false
var _corrupt_interior_history: bool = false

const Base = preload("res://tests/unit/test_peer_drop_backfill.gd")

const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")


class ObservedGame:
	extends Base.WideGame
	const InputQueue = preload("res://addons/fortress_rollback/core/input_queue.gd")
	var applied: Dictionary = {}

	static func status_name(status: int) -> String:
		match status:
			InputQueue.Status.NONE:
				return "none"
			InputQueue.Status.CONFIRMED:
				return "confirmed"
			InputQueue.Status.PREDICTED:
				return "predicted"
			InputQueue.Status.DISCONNECTED:
				return "disconnected"
		return "unknown:" + str(status)

	func simulate_frame(at: int, inputs: S.FrameInputs) -> bool:
		var row: Array[Dictionary] = []
		for player: int in range(values.size()):
			var input: S.InputResult = inputs.read(player)
			if input.code != S.Code.OK:
				return false
			row.append({"bytes": input.bytes.hex_encode(), "status": status_name(input.status)})
		if not super.simulate_frame(at, inputs):
			return false
		applied[at] = row
		return true


func observe(
	context: RefCounted,
	status_control: int = -1,
	drop_first_history: bool = false,
	missing_rows: int = 1,
	corrupt_interior: bool = false,
	target_slots: int = 1,
	unequal: bool = false,
	drop_first_commit: bool = false,
	drop_first_ack: bool = false,
	drop_first_inventory: bool = false
) -> Dictionary:
	_drop_first_inventory = drop_first_inventory
	_drop_first_ack = drop_first_ack
	_drop_first_commit = drop_first_commit
	_drop_first_history = drop_first_history
	_corrupt_interior_history = corrupt_interior
	_mode = "remote_donor"
	_missing_peer = 0
	_width = 4
	_window = 8
	_slots = target_slots
	_seen = 0
	_donor_sources.clear()
	var mesh: Dictionary = _wide_mesh(context)
	for peer: int in range(3):
		_observation.install(mesh.peers[peer], peer)
		var game: ObservedGame = ObservedGame.new(3 * _slots)
		context.equal(mesh.peers[peer]._driver.configure(mesh.peers[peer]._core, game), Types.Code.OK, "install actual request observer")
		mesh.games[peer] = game
	_play(context, mesh, 6, true)
	_leave(context, mesh, 2)
	if missing_rows == 4:
		_leave(context, mesh, 2)
	if unequal:
		_play(context, mesh, 1, true, [0])
	var before: Array[Dictionary] = []
	for peer: int in range(2):
		var targets: Array[Dictionary] = []
		for slot: int in range(2 * _slots, 3 * _slots):
			var interval: PackedInt64Array = mesh.peers[peer]._core.retained_input_range(slot)
			targets.append({"slot": slot, "first": interval[0], "last": interval[1]})
		before.append({"confirmed": mesh.peers[peer].status().confirmed_frame, "targets": targets})
	_detect(context, mesh, [0, 1], 800000, true, [], [], true)
	var cuts: Array = []
	for peer: int in range(2):
		var target_cuts: Array[int] = []
		for slot: int in range(2 * _slots, 3 * _slots):
			target_cuts.append(mesh.peers[peer]._core.frozen_frame(slot))
		cuts.append(target_cuts)
	_play(context, mesh, 16, true, [0, 1], 2)
	var survivors: Array[Dictionary] = []
	for peer: int in range(2):
		var rows: Array[Dictionary] = []
		for frame: int in range(20):
			var row: Types.FrameInputs = mesh.peers[peer]._core.confirmed_inputs(frame)
			var inputs: Array[String] = []
			if status_control >= 0 and peer == 0 and frame == 0:
				row._statuses[0] = status_control
			for player: int in range(3 * _slots):
				var input: Types.InputResult = row.read(player)
				context.equal(input.code, Types.Code.OK, "export actual finalized original input")
				if input.code != Types.Code.OK:
					break
				inputs.append(input.bytes.hex_encode())
				var expected: int = Queue.Status.DISCONNECTED if player >= 2 * _slots and frame > 7 + missing_rows else Queue.Status.CONFIRMED
				context.equal(ObservedGame.status_name(input.status), ObservedGame.status_name(expected), "observed finalized export status")
			rows.append(
				{"frame": frame, "inputs": inputs, "state": {"frame": frame, "bytes": mesh.games[peer].states[frame].hex_encode(), "inputs": mesh.games[peer].applied[frame]}}
			)
		survivors.append({"peer": peer, "current_frame": mesh.peers[peer].status().current_frame, "confirmed_frame": mesh.peers[peer].status().confirmed_frame, "rows": rows})
	context.equal(_observation.publications.is_empty(), true, "every accepted observed control reaches owned routing")
	return {
		"format": 6,
		"complete": true,
		"missing_rows": missing_rows,
		"target_slots": _slots,
		"before": before,
		"cuts": cuts,
		"history_packets": _seen,
		"donors": _donor_sources.keys(),
		"inventory_emissions": _inventory_emissions,
		"inventory_receipts": _inventory_receipts,
		"lost_inventory": _lost_inventory,
		"lost_history": _lost_history,
		"lost_commit": _lost_commit,
		"lost_ack": _lost_ack,
		"ack_emissions": _ack_emissions,
		"ack_receipts": _ack_receipts,
		"commit_emissions": _commit_emissions,
		"commit_receipts": _commit_receipts,
		"history_emissions": _history_emissions,
		"history_receipts": _history_receipts,
		"survivors": survivors,
		"failures": context.failures
	}


func _deliver(context: RefCounted, mesh: Dictionary, packets: Array[Dictionary], terminated: bool = false) -> void:
	for packet: Dictionary in packets:
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
		if decoded.code == T.Code.OK and decoded.message.kind == T.Kind.INPUT and packet.from == 2 and packet.to == 0:
			if decoded.message.start_frame + decoded.message.frame_count - 1 > 7:
				continue
		var inventory_emission: Dictionary = {}
		var history_emission: Dictionary = {}
		var commit_emission: Dictionary = {}
		var ack_emission: Dictionary = {}
		if decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER:
			var publication_order: int = -1
			if decoded.message.phase == Drop.Phase.COMMIT or (decoded.message.phase == Drop.Phase.REPORT and decoded.message.stage in [Drop.Stage.INVENTORY, Drop.Stage.COMMITTED]):
				publication_order = _observation.take(packet.from, packet.to, packet.bytes)
				context.equal(publication_order > 0, true, "match actual accepted barrier publication before routing")
			if decoded.message.phase == Drop.Phase.REPORT and decoded.message.stage == Drop.Stage.INVENTORY:
				inventory_emission = {
					"from": packet.from, "to": packet.to, "packet": packet.bytes.hex_encode(), "emission": _inventory_emissions.size(), "order": publication_order
				}
				_inventory_emissions.append(inventory_emission)
			if decoded.message.phase == Drop.Phase.REPORT and decoded.message.stage == Drop.Stage.COMMITTED:
				ack_emission = {"from": packet.from, "to": packet.to, "packet": packet.bytes.hex_encode(), "emission": _ack_emissions.size(), "order": publication_order}
				_ack_emissions.append(ack_emission)
			if decoded.message.phase == Drop.Phase.COMMIT:
				commit_emission = {"from": packet.from, "to": packet.to, "packet": packet.bytes.hex_encode(), "emission": _commit_emissions.size(), "order": publication_order}
				_commit_emissions.append(commit_emission)
			if decoded.message.phase == Drop.Phase.BACKFILL and decoded.message.stage == Drop.Stage.HISTORY:
				history_emission = {
					"from": packet.from, "to": packet.to, "bytes": decoded.message.bytes.hex_encode(), "packet": packet.bytes.hex_encode(), "emission": _history_emissions.size()
				}
				_history_emissions.append(history_emission)
		if _drop_first_inventory and _lost_inventory.is_empty() and not inventory_emission.is_empty():
			_lost_inventory.append(inventory_emission)
			continue
		if _drop_first_ack and _lost_ack.is_empty() and not ack_emission.is_empty():
			_lost_ack.append(ack_emission)
			continue
		if _drop_first_commit and _lost_commit.is_empty() and not commit_emission.is_empty():
			_lost_commit.append(commit_emission)
			continue
		if _drop_first_history and _lost_history.is_empty() and not history_emission.is_empty():
			_lost_history.append(history_emission)
			continue
		if _corrupt_interior_history and not history_emission.is_empty() and packet.to == 0:
			decoded.message.bytes = decoded.message.bytes.duplicate()
			var original: int = decoded.message.bytes[4 * _slots]
			decoded.message.bytes[4 * _slots] = decoded.message.bytes[8 * _slots]
			decoded.message.bytes[8 * _slots] = original
			var altered: T.Result = Codec.encode(decoded.message, _limits(mesh.count))
			context.equal(altered.code, T.Code.OK, "interior corruption preserves valid packet dimensions")
			packet = packet.duplicate(true)
			packet.bytes = altered.bytes
			history_emission = history_emission.duplicate(true)
			history_emission.bytes = decoded.message.bytes.hex_encode()
			history_emission.packet = packet.bytes.hex_encode()
		var receipt_order: int = -1
		if not inventory_emission.is_empty() or not commit_emission.is_empty() or not ack_emission.is_empty():
			receipt_order = _observation.next_order()
		var code: int = mesh.peers[packet.to].receive(packet.bytes, _id(packet.from), mesh.now)
		if terminated and code == I.Code.TERMINATED:
			continue
		context.equal(code, I.Code.OK, "deliver actual encoded packet")
		if code == I.Code.OK and not inventory_emission.is_empty():
			_inventory_receipts.append(_received(inventory_emission, receipt_order))
		if code == I.Code.OK and not ack_emission.is_empty():
			_ack_receipts.append(_received(ack_emission, receipt_order))
		if code == I.Code.OK and not commit_emission.is_empty():
			_commit_receipts.append(_received(commit_emission, receipt_order))
		if code == I.Code.OK and decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER:
			if decoded.message.phase == Drop.Phase.BACKFILL and decoded.message.stage == Drop.Stage.HISTORY:
				_seen += 1
				_donor_sources[packet.from] = true
				_history_receipts.append(history_emission)


func _received(emission: Dictionary, order: int) -> Dictionary:
	var result: Dictionary = emission.duplicate(true)
	result.order = order
	return result
