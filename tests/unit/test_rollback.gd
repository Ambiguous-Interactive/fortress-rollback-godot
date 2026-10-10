extends RefCounted

# Value: protects=corrected canonical replay and full state capture; fails_when=rollback skips state, input or ordered callbacks;
# why_new=queue tests do not execute a game; seam=none
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")


class Game:
	extends RefCounted
	var frame: int = 0
	var rng: int = 8173
	var pending: int = 0
	var total: int = 0

	func bytes() -> PackedByteArray:
		var state: PackedByteArray = PackedByteArray()
		state.resize(16)
		state.encode_u32(0, frame)
		state.encode_u32(4, rng)
		state.encode_u32(8, pending)
		state.encode_u32(12, total)
		return state

	func restore(state: PackedByteArray, omit_rng: bool = false, omit_pending: bool = false) -> void:
		frame = state.decode_u32(0)
		if not omit_rng:
			rng = state.decode_u32(4)
		if not omit_pending:
			pending = state.decode_u32(8)
		total = state.decode_u32(12)

	func simulate(values: PackedByteArray) -> void:
		rng = (rng * 1664525 + 1013904223) & 4294967295
		total = (total + pending + (rng & 255)) & 4294967295
		pending = 0
		for player: int in range(values.size()):
			pending += (player + 1) * values[player]
		frame += 1


func cases() -> PackedStringArray:
	return PackedStringArray(["sync_wrap", "snapshot_omissions", "external_corrections", "lockstep", "configuration", "snapshot_failure"])


func run_case(name: String, context: RefCounted) -> void:
	match name:
		"sync_wrap":
			for players: int in range(2, 9):
				for distance: int in [0, 1, 2, 7]:
					_sync(context, players, distance, false, false)
		"snapshot_omissions":
			_sync(context, 3, 2, true, false)
			_sync(context, 3, 2, false, true)
		"external_corrections":
			_external(context)
		"lockstep":
			_lockstep(context)
		"configuration":
			_configuration(context)
		"snapshot_failure":
			_snapshot_failure(context)
	context.finish()


func _settings(players: int, distance: int) -> RefCounted:
	var config: RefCounted = Config.new()
	config.player_count = players
	config.local_players.clear()
	for player: int in range(players):
		config.local_players.append(player)
	config.max_prediction_frames = 8
	config.check_distance = distance
	config.queue_capacity = 11
	config.max_snapshot_bytes = 16
	config.storage_budget_bytes = 65536
	return config


func _sync(context: RefCounted, players: int, distance: int, omit_rng: bool, omit_pending: bool) -> void:
	var session: RefCounted = Session.new()
	context.equal(session.configure(_settings(players, distance)), Session.Code.OK, "sync config")
	var game: Game = Game.new()
	var baseline: Game = Game.new()
	var failed: bool = false
	for frame: int in range(40):
		var values: PackedByteArray = PackedByteArray()
		for player: int in range(players):
			var value: int = (frame * 17 + player * 7 + 1) & 255
			values.append(value)
			context.equal(session.submit_local_input(player, frame, PackedByteArray([value])).code, Session.Code.OK, "sync sample")
		var result: RefCounted = session.begin_advance()
		if result.code == Session.Code.DESYNC:
			context.equal(omit_rng or omit_pending, true, "real divergence only")
			context.equal(session.status().failure_frame >= 0, true, "localized divergence")
			failed = true
			break
		context.equal(result.code, Session.Code.READY, "sync ready")
		_consume(context, session, result.batch, game, omit_rng, omit_pending)
		baseline.simulate(values)
		if not omit_rng and not omit_pending:
			context.bytes_equal(game.bytes(), baseline.bytes(), frame + 1, "uninterrupted state including RNG/events")
	context.equal(failed, omit_rng or omit_pending, "checksum collision still detects canonical difference")
	if not failed:
		context.state(game.frame, game.bytes())


func _external(context: RefCounted) -> void:
	var config: RefCounted = _settings(3, 0)
	config.sync_test = false
	config.local_players = PackedInt32Array([0])
	config.max_prediction_frames = 4
	config.history_slots = 5
	config.queue_capacity = 6
	var session: RefCounted = Session.new()
	context.equal(session.configure(config), Session.Code.OK, "external config")
	var game: Game = Game.new()
	var baseline: Game = Game.new()
	var expected: Array[PackedByteArray] = [baseline.bytes()]
	for frame: int in range(40):
		baseline.simulate(PackedByteArray([_value(0, frame), _value(1, frame), _value(2, frame)]))
		expected.append(baseline.bytes())
	var delivered: PackedInt32Array = PackedInt32Array([-1, -1, -1])
	for frame: int in range(40):
		for player: int in [1, 2]:
			var target: int = frame - player
			while delivered[player] < target:
				delivered[player] += 1
				context.equal(session.receive_input(player, delivered[player], PackedByteArray([_value(player, delivered[player])])).code, Session.Code.OK, "delayed arrival")
		context.equal(session.submit_local_input(0, frame, PackedByteArray([_value(0, frame)])).code, Session.Code.OK, "local sample")
		var result: RefCounted = session.begin_advance()
		context.equal(result.code, Session.Code.READY, "bounded delayed recovery")
		_consume(context, session, result.batch, game, false, false, expected, session.status().confirmed_frame)
		context.equal(session.status().current_frame, frame + 1, "one new frame after recovery")
		context.equal(session.status().confirmed_frame, maxi(-1, frame - 2), "asymmetric minimum")
	# Deliver the tail; recovery must reach the exact pre-next-tick canonical bytes.
	for player: int in [1, 2]:
		while delivered[player] < 39:
			delivered[player] += 1
			session.receive_input(player, delivered[player], PackedByteArray([_value(player, delivered[player])]))
	session.submit_local_input(0, 40, PackedByteArray([_value(0, 40)]))
	var batch: RefCounted = session.begin_advance().batch
	_consume(context, session, batch, game, false, false, expected, 39)
	context.equal(session.receive_input(1, 0, PackedByteArray([1])).code, Session.Code.INVALID_FRAME, "stale history rejected")
	context.state(game.frame, game.bytes())


func _lockstep(context: RefCounted) -> void:
	for limit: int in [0, 1]:
		var config: RefCounted = _settings(2, 0)
		config.sync_test = false
		config.local_players = PackedInt32Array([0])
		config.max_prediction_frames = limit
		var session: RefCounted = Session.new()
		session.configure(config)
		var game: Game = Game.new()
		for frame: int in range(8):
			session.submit_local_input(0, frame, PackedByteArray([1]))
			if limit == 0 or frame > 0:
				context.equal(session.begin_advance().code, Session.Code.PREDICTION_STALL, "no actual remote at boundary")
			session.receive_input(1, frame, PackedByteArray([2]))
			context.equal(session.status().confirmed_frame, frame, "actual current is confirmed")
			var result: RefCounted = session.begin_advance()
			context.equal(result.code, Session.Code.READY, "actual permits advance")
			_consume(context, session, result.batch, game)


func _configuration(context: RefCounted) -> void:
	var session: RefCounted = Session.new()
	var config: RefCounted = _settings(2, 2)
	context.equal(session.poll(0).code, Session.Code.NOT_CONFIGURED, "unconfigured")
	for field: String in ["player_count", "input_width", "queue_capacity", "history_slots", "max_snapshot_bytes", "storage_budget_bytes"]:
		var original: int = config.get(field)
		config.set(field, 0)
		context.equal(session.configure(config), Session.Code.INVALID_CONFIGURATION, "invalid " + field)
		config.set(field, original)
	context.equal(session.configure(config), Session.Code.OK, "owned config")
	config.neutral_input[0] = 99
	config.local_players.clear()
	config.input_width = 99
	context.equal(session.submit_local_input(1, 0, PackedByteArray([1])).code, Session.Code.OK, "caller config mutation isolated")
	session.terminate(Session.Code.INPUT_FAILED)
	session.terminate(Session.Code.DESYNC)
	context.equal(session.status().reason, Session.Code.INPUT_FAILED, "original terminal reason")
	context.equal(session.begin_advance().code, Session.Code.TERMINATED, "no resume")


func _snapshot_failure(context: RefCounted) -> void:
	for failure: String in ["overflow", "checksum", "trailing", "underflow"]:
		var session: RefCounted = Session.new()
		session.configure(_settings(2, 1))
		var game: Game = Game.new()
		for frame: int in range(3):
			for player: int in range(2):
				session.submit_local_input(player, frame, PackedByteArray([1]))
			var batch: RefCounted = session.begin_advance().batch
			var request: RefCounted = batch.next_request()
			while request != null:
				var inject: bool = (
					(frame == 0 and request.kind == Session.Kind.SAVE and failure in ["overflow", "checksum"])
					or (frame == 2 and request.kind == Session.Kind.LOAD and failure in ["trailing", "underflow"])
				)
				var checksum: PackedByteArray = _checksum()
				if request.kind == Session.Kind.SAVE:
					request.writer.write_bytes(game.bytes())
					if inject and failure == "overflow":
						request.writer.write_bytes(PackedByteArray([1]))
					if inject and failure == "checksum":
						checksum = PackedByteArray()
				elif request.kind == Session.Kind.LOAD:
					var count: int = 17 if inject and failure == "underflow" else (15 if inject else 16)
					var restored: RefCounted = request.reader.read_bytes(count)
					if not inject:
						game.restore(restored.bytes)
				else:
					game.simulate(PackedByteArray([1, 1]))
				var code: int = session.complete_request(request.batch_id, request.request_id, true, checksum).code
				context.equal(code, Session.Code.SNAPSHOT_FAILED if inject else Session.Code.OK, "sticky " + failure)
				if inject:
					context.equal(session.status().current_frame, frame, "failed batch not committed")
				request = batch.next_request()
			if session.status().lifecycle == Session.Lifecycle.TERMINATED:
				break
		context.equal(session.status().reason, Session.Code.SNAPSHOT_FAILED, "fatal snapshot error")


func _consume(
	context: RefCounted,
	session: RefCounted,
	batch: RefCounted,
	game: Game,
	omit_rng: bool = false,
	omit_pending: bool = false,
	expected: Array[PackedByteArray] = [],
	confirmed: int = -1
) -> void:
	context.equal(batch != null, true, "available batch")
	if batch == null:
		return
	var request: RefCounted = batch.next_request()
	while request != null:
		context.equal(request.frame, game.frame if request.kind != Session.Kind.LOAD else request.frame, "callback frame")
		if request.kind == Session.Kind.SAVE:
			request.writer.write_bytes(game.bytes())
		elif request.kind == Session.Kind.LOAD:
			game.restore(request.reader.read_bytes(16).bytes, omit_rng, omit_pending)
		else:
			var values: PackedByteArray = PackedByteArray()
			for player: int in range(request.inputs.size().value):
				var input: RefCounted = request.inputs.read(player)
				context.equal(input.code, Session.Code.OK, "input view")
				values.append(input.bytes[0])
			game.simulate(values)
			if game.frame <= confirmed + 1 and game.frame < expected.size():
				context.bytes_equal(game.bytes(), expected[game.frame], game.frame, "confirmed correction equals uninterrupted history")
		var view: RefCounted = request.inputs
		context.equal(session.complete_request(request.batch_id, request.request_id, true, _checksum()).code, Session.Code.OK, "ordered completion")
		if view != null:
			context.equal(view.read(0).code, Session.Code.EXPIRED_VIEW, "expired input")
		request = batch.next_request()


func _checksum() -> PackedByteArray:
	# Constant checksum is a deliberate collision control; canonical comparison must catch drift.
	var checksum: PackedByteArray = PackedByteArray()
	checksum.resize(16)
	return checksum


func _value(player: int, frame: int) -> int:
	return (frame * 17 + player * 7 + 1) & 255
