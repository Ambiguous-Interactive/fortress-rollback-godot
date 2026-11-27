extends SceneTree

const Context = preload("res://tests/runner/test_context.gd")

class Fixture:
	extends "res://tests/unit/test_peer_drop_barrier.gd"

	const Backfill = preload("res://tests/unit/test_peer_drop_backfill.gd")
	const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")
	var schedule: Dictionary

	func _sample(player: int, frame: int) -> PackedByteArray:
		var sample: PackedByteArray = PackedByteArray()
		for index: int in range(4):
			sample.append((frame * 11 + player * 7 + index) % 251)
		return sample

	func run(context: RefCounted, shared_schedule: Dictionary) -> Dictionary:
		schedule = shared_schedule
		var timeouts: Array[int] = []
		timeouts.resize(int(schedule.peers))
		timeouts.fill(int(schedule.disconnect_us))
		var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE, 8, int(schedule.peers), timeouts, int(schedule.deadline_us), 64, 96)
		for peer_index: int in range(5):
			var game: Backfill.WideGame = Backfill.WideGame.new(5)
			var peer: Peer = mesh.peers[peer_index]
			context.equal(peer._driver.configure(peer._core, game), Types.Code.OK, "install matching byte-game callbacks")
			mesh.games[peer_index] = game
		_play(context, mesh, int(schedule.warmup), true)
		var base_us: int = mesh.now
		var expectation: Dictionary = _expected_prefix()
		var starting: Array[Dictionary] = []
		for peer_index: int in range(5):
			starting.append(_snapshot(context, mesh, peer_index, expectation))
		var bank: Dictionary = {}
		var emissions: Array[Dictionary] = []
		var receipts: Array[Dictionary] = []
		var withheld_ready: Array[int] = []
		var barriers: Array[Dictionary] = []
		var terminal: Dictionary = {}
		var drops: Array[Dictionary] = []
		var failures: Array[Dictionary] = []
		var before_cut: Array[Dictionary] = []
		var transport: Dictionary = {"scheduled": 0, "delivered": 0, "discard_emit": 0, "discard_delivery": 0}
		for tick: int in range(0, int(schedule.through_us) + int(schedule.tick_us), int(schedule.tick_us)):
			mesh.now = base_us + tick
			if tick == int(schedule.coordinator_silence_us):
				before_cut = _barriers(mesh, base_us)
			var packets: Array = bank.get(tick, [])
			bank.erase(tick)
			for packet: Dictionary in packets:
				if not _route_open(packet.from, packet.to, tick):
					transport.discard_delivery += 1
					continue
				var peer: Peer = mesh.peers[packet.to]
				var result: int = peer.receive(packet.bytes, _id(packet.from), mesh.now)
				transport.delivered += 1
				context.equal(result in [I.Code.OK, I.Code.TERMINATED], true, "deliver original encoded bytes")
				if packet.has("control"):
					var record: Dictionary = packet.control.duplicate()
					record["at_us"] = tick
					record["code"] = result
					receipts.append(record)
			for peer_index: int in range(4):
				if _live(peer_index, tick) and not terminal.has(peer_index):
					var peer: Peer = mesh.peers[peer_index]
					var result: int = peer.poll(mesh.now)
					context.equal(result in [I.Code.OK, I.Code.TERMINATED], true, "poll surviving peer")
					if result == I.Code.TERMINATED:
						terminal[peer_index] = {"at_us": tick, "reason": peer.status().reason}
			for peer_index: int in range(4):
				var peer: Peer = mesh.peers[peer_index]
				for event: Dictionary in peer.drain_events():
					if event.kind == "peer_dropped":
						drops.append({"at_us": tick, "peer": peer_index, "target": event.peer[0] - 1, "cut": event.frame})
					elif event.kind == "peer_drop_unconfirmed":
						failures.append({"at_us": tick, "peer": peer_index, "target": event.peer[0] - 1, "reason": event.reason})
				peer.drain_transitions()
				for packet: Peer.Packet in peer.drain_outbox():
					var target: int = packet.to[0] - 1
					var transit: Dictionary = {"from": peer_index, "to": target, "bytes": packet.bytes}
					var decoded: T.Result = Codec.decode(packet.bytes, _limits(5))
					if decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER:
						var control: Dictionary = _control(decoded.message, peer_index, target, tick, emissions.size(), packet.bytes)
						emissions.append(control)
						transit["control"] = control
						if _hold_ready(control, tick):
							withheld_ready.append(control.ordinal)
							continue
					if not _route_open(peer_index, target, tick):
						transport.discard_emit += 1
						continue
					var due: int = tick + int(schedule.delay_us)
					if not bank.has(due):
						bank[due] = []
					bank[due].append(transit)
					transport.scheduled += 1
			var latest: Array[Dictionary] = _barriers(mesh, base_us)
			if not latest.is_empty() and (barriers.is_empty() or barriers[-1].barriers != latest):
				barriers.append({"at_us": tick, "barriers": latest})
		var ending: Array[Dictionary] = []
		for peer_index: int in range(1, 4):
			var snapshot: Dictionary = _snapshot(context, mesh, peer_index, expectation)
			context.equal(snapshot.rows, starting[peer_index].rows, "every exposed input row survived")
			context.equal(snapshot.game_bytes, starting[peer_index].game_bytes, "game bytes are preserved without new samples")
			ending.append(snapshot)

		return {
			"schedule": schedule,
			"starting": starting, "ending": ending, "before_cut": before_cut, "barriers": barriers, "emissions": emissions,
			"receipts": receipts, "withheld_ready": withheld_ready, "transport": transport, "terminal": terminal, "drops": drops, "failures": failures,
		}

	func _live(peer: int, now: int) -> bool:
		return (peer != int(schedule.target) or now < int(schedule.target_silence_us)) \
			and (peer != int(schedule.coordinator) or now < int(schedule.coordinator_silence_us))

	func _route_open(sender: int, recipient: int, now: int) -> bool:
		return _live(sender, now) and _live(recipient, now)

	func _hold_ready(control: Dictionary, now: int) -> bool:
		return now < int(schedule.coordinator_silence_us) and control.to == int(schedule.coordinator) and control.from in [1, 2, 3] \
			and control.phase == Backfill.Drop.Phase.REPORT and control.stage == Backfill.Drop.Stage.READY

	func _control(message: T.Message, sender: int, recipient: int, now: int, ordinal: int, bytes: PackedByteArray) -> Dictionary:
		return {
			"ordinal": ordinal, "emitted_at_us": now, "from": sender, "to": recipient, "phase": message.phase, "stage": message.stage,
			"operation": str(message.operation), "coordinator": message.coordinator, "coordinator_generation": message.coordinator_generation,
			"sender_id": _id(sender).hex_encode(), "recipient_id": _id(recipient).hex_encode(),
			"target_set_digest": str(message.target_set_digest), "cut": message.cut, "cut_digest": str(message.cut_digest), "bytes": bytes.hex_encode(),
		}

	func _barriers(mesh: Dictionary, base_us: int) -> Array[Dictionary]:
		var result: Array[Dictionary] = []
		for peer_index: int in range(4):
			var peer: Peer = mesh.peers[peer_index]
			var barrier: Backfill.Drop.Barrier = peer._drops.barrier(_id(4).hex_encode())
			if barrier != null:
				result.append({"peer": peer_index, "state": barrier.state, "cut": barrier.cut, "started_at_us": barrier.started_us - base_us,
					"operation": str(barrier.operation), "coordinator": barrier.coordinator, "coordinator_generation": barrier.coordinator_generation, "receipts": barrier.receipts.size(),
					"certificates": barrier.certificates.size(), "adopted": barrier.adopted})
		return result

	func _expected_prefix() -> Dictionary:
		var result: Dictionary = {}
		var sums: PackedInt64Array = PackedInt64Array([0, 0, 0, 0, 0])
		for frame: int in range(5):
			var inputs: Array[String] = []
			var bytes: PackedByteArray = PackedByteArray()
			bytes.resize(48)
			bytes.encode_s64(0, frame + 1)
			for slot: int in range(5):
				var sample: PackedByteArray = _sample(slot, frame)
				inputs.append(sample.hex_encode())
				for value: int in sample:
					sums[slot] += value
				bytes.encode_s64(8 * (slot + 1), sums[slot])
			result[frame] = {"inputs": inputs, "bytes": bytes.hex_encode()}
		return result

	func _snapshot(context: RefCounted, mesh: Dictionary, peer_index: int, expectation: Dictionary) -> Dictionary:
		var peer: Peer = mesh.peers[peer_index]
		var game: Backfill.WideGame = mesh.games[peer_index]
		var rows: Array[Dictionary] = []
		for frame: int in range(5):
			var inputs: Types.FrameInputs = peer.confirmed_inputs(frame)
			var original: Array[String] = []
			context.equal(inputs != null, true, "confirmed prefix is exposed")
			if inputs != null:
				for slot: int in range(5):
					var result: Types.InputResult = inputs.read(slot)
					context.equal(result.code, Types.Code.OK, "read original slot")
					context.equal(result.status, Queue.Status.CONFIRMED, "retained original status")
					original.append(result.bytes.hex_encode())
			context.equal(original, expectation[frame].inputs, "original five-slot sample row")
			var state: PackedByteArray = game.states.get(frame, PackedByteArray())
			context.equal(state.hex_encode(), expectation[frame].bytes, "independent canonical bytes")
			rows.append({"frame": frame, "inputs": original, "bytes": state.hex_encode()})
		var game_bytes: String = game.bytes().hex_encode()
		return {"peer": peer_index, "rows": rows, "game_bytes": game_bytes, "frame": peer.status().current_frame,
			"confirmed": peer.status().confirmed_frame, "frozen_frame": peer._core.frozen_frame(4)}


func _initialize() -> void:
	var context: RefCounted = Context.new(1701)
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() != 1:
		push_error("expected the shared schedule path")
		quit(2)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	if not parsed is Dictionary:
		push_error("expected a JSON schedule object")
		quit(2)
		return
	var schedule: Dictionary = {}
	for key: String in parsed:
		var value: Variant = parsed[key]
		if not (value is int or value is float) or value != int(value):
			push_error("expected an integer schedule value for " + key)
			quit(2)
			return
		schedule[key] = int(value)
	var result: Dictionary = Fixture.new().run(context, schedule)
	context.finish()
	result["assertions"] = context.assertions
	result["assertion_failures"] = context.failures
	print("GODOT_FAILOVER " + JSON.stringify(result))
	quit(0 if context.failures.is_empty() else 1)
