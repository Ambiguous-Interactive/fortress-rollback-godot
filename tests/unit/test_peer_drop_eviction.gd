extends "res://tests/unit/test_peer_drop_backfill.gd"

# Value: protects=retained queues and owned journals preserve real recovery bytes; fails_when=fast arrivals evict required rows or retries reread wrapped slots;
# why_new=the earlier no-donor control changes inventory bytes instead of advancing real queues; seam=none
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const History = preload("res://addons/fortress_rollback/core/peer_drop_history.gd")
const Queue = preload("res://addons/fortress_rollback/core/input_queue.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["unequal_retained_history", "retained_history_control", "journal_after_ring_wrap"])


func run_case(name: String, context: RefCounted) -> void:
	if name == "journal_after_ring_wrap":
		_journal_wrap(context)
	else:
		_unequal_delivery(context, name == "unequal_retained_history")
	context.finish()


func _unequal_delivery(context: RefCounted, unequal: bool) -> void:
	_mode = "eviction"
	_missing_peer = 0
	_width = 4
	_seen = 0
	_donor_sources.clear()
	var mesh: Dictionary = _wide_mesh(context)
	_play(context, mesh, 6, true)
	for frame: int in range(20 if unequal else 3):
		mesh.now += 1000
		for player: int in range(3):
			var result: Driver.StepResult = mesh.peers[player].step(mesh.now, _inputs(mesh, player))
			context.equal(result.code in [Types.Code.OK, Types.Code.PREDICTION_STALL], true, "unequal delivery advances or reaches the prediction bound")
		for exchange: int in range(2):
			_deliver(context, mesh, _drain(mesh))
	var donor: RefCounted = mesh.peers[1]._core
	context.equal(mesh.peers[0]._core.received_frames()[2], 7, "the recipient truly lacks every target row from eight onward")
	context.equal(donor.received_frames()[2], 22 if unequal else 8, "the donor receives a real changing-input suffix")
	context.equal(donor.retained_input(2, 8), _sample(2, 8), "global confirmation keeps the first missing actual row readable")
	context.equal(donor.rollback_floor(), 7 if unequal else 1, "the fast recipient cannot raise the floor past missing history")
	_detect(context, mesh, [0, 1], 800000, true, [], [], true)
	var cut: int = 22 if unequal else 8
	for survivor: int in [0, 1]:
		context.equal(mesh.peers[survivor].status().lifecycle, Types.Lifecycle.RUNNING, "truthful retained inventories permit donor recovery")
		context.equal(mesh.peers[survivor]._core.frozen_frame(2), cut, "both survivors commit the highest real target receipt")
		for frame: int in range(8, cut + 1):
			context.equal(mesh.peers[survivor]._core.retained_input(2, frame), _sample(2, frame), "every missing row preserves the departed player's original bytes")
	context.equal(_seen > 0, true, "the physical missing suffix requires historical transfer")
	context.equal(_donor_sources.keys(), [1], "the coordinator recovers from the other survivor")
	_play(context, mesh, 16, true, [0, 1], 2)
	var through: int = mini(mesh.peers[0].status().confirmed_frame, mesh.peers[1].status().confirmed_frame) - 1
	context.equal(through > cut, true, "the repaired survivors continue beyond the receipt-raised cut")
	for survivor: int in [0, 1]:
		for frame: int in range(cut, through + 1):
			context.equal(mesh.games[survivor].states[frame], _expected(frame, cut), "each continuing canonical prefix equals independently reconstructed input history")


func _settings(locals: PackedInt32Array) -> Config:
	var config: Config = Config.new()
	config.player_count = 3
	config.local_players = locals
	config.input_width = _width
	config.neutral_input.resize(_width)
	config.max_prediction_frames = 8
	config.queue_capacity = 18
	config.history_slots = 9
	config.check_distance = 0
	config.sync_test = false
	config.max_snapshot_bytes = 32
	config.storage_budget_bytes = 1048576
	return config


func _journal_wrap(context: RefCounted) -> void:
	_width = 5
	var source: Session = Session.new()
	context.equal(source.configure(_settings(PackedInt32Array([0, 1, 2]))), Types.Code.OK, "configure a minimum-capacity real source session")
	var game: WideGame = WideGame.new()
	var driver: Driver = Driver.new(source, game)
	for frame: int in range(8):
		_advance_source(context, driver, frame)
	var history: History = History.new()
	var targets: PackedInt32Array = PackedInt32Array([1, 2])
	context.equal(history.configure(2, 5, 1, _width, targets.size(), 16), true, "configure a bounded multi-target donor journal")
	context.equal(history.prepare(source, targets, _width), true, "capture actual bytes while their real source rows remain available")
	context.equal(history.journal.size(), 3, "fixed chunk bounds split across frame and target boundaries")
	for frame: int in range(8, 46):
		_advance_source(context, driver, frame)
	context.equal(source.rollback_floor(), 38, "normal simulation advances the source's global reclamation floor")
	context.equal(source.retained_input(1, 2).is_empty(), true, "normal source progress evicts the original donor row")
	context.equal(source._queues[1].confirmed_input(2).code, Queue.Code.NO_CONFIRMED_INPUT, "ring reuse physically overwrites the original frame tag")
	context.equal(history.prepare(source, targets, _width), true, "a retained journal retries without reading an evicted source row")
	var unavailable: History = History.new()
	unavailable.configure(2, 5, 1, _width, targets.size(), 16)
	context.equal(unavailable.prepare(source, targets, _width), false, "a fresh donor cannot invent bytes after physical eviction")
	context.equal(unavailable.journal.is_empty(), true, "failed preparation publishes no partial journal")
	var receiver: Session = Session.new()
	context.equal(receiver.configure(_settings(PackedInt32Array([0]))), Types.Code.OK, "configure a real missing-history recipient")
	for target: int in targets:
		for frame: int in range(2):
			context.equal(receiver.receive_input(target, frame, _sample(target, frame)).code, Types.Code.OK, "retain the recipient's original prefix")
	var incoming: History = History.new()
	incoming.configure(2, 5, 1, _width, targets.size(), 16)
	for chunk: int in range(history.journal.size() - 1, -1, -1):
		context.equal(incoming.accept(chunk, history.journal.size(), history.journal[chunk], _width, targets.size()), true, "accept retained journal chunks in reverse order")
	context.equal(incoming.install(receiver, targets, _width), Types.Code.OK, "install the complete original journal after its source ring wrapped")
	for target: int in targets:
		for frame: int in range(6):
			context.equal(receiver.retained_input(target, frame), _sample(target, frame), "original prefix and journal suffix preserve exact frame and slot bytes")


func _advance_source(context: RefCounted, driver: Driver, frame: int) -> void:
	var inputs: Array[Driver.LocalInput] = []
	for player: int in range(3):
		inputs.append(Driver.LocalInput.new(player, frame, _sample(player, frame)))
	context.equal(driver.step(frame, inputs).code, Types.Code.OK, "advance the actual source through bounded ring reclamation")
