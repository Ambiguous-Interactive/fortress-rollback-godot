extends RefCounted

# Value: protects=manual peers own ordered callbacks and transport completion; fails_when=hidden callbacks or early controls run;
# why_new=existing P2P comparison replaced a private driver; seam=none
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Fixture = preload("res://tests/unit/test_peer_session.gd")
const Parity = preload("res://tests/unit/test_driver_peer_parity.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const L = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")
const Snapshot = preload("res://addons/fortress_rollback/core/snapshot_status.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["public_api", "batch_ownership", "callback_failures", "recovery", "pressure", "capture"])


func run_case(name: String, context: RefCounted) -> void:
	for method: String in ["configure_expert", "begin_step", "begin_recovery", "begin_capture_replay_boundary", "complete_request"]:
		context.equal(Peer.new().has_method(method), true, "manual peer request API: " + method)
	if Peer.new().has_method("configure_expert"):
		call("_" + name, context)
	context.finish()


func _build(context: RefCounted, pending: int = 128, count: int = 2, multiple: bool = false, start: bool = true) -> Dictionary:
	return Fixture.new()._build(context, count, 0, multiple, pending, start, false, 8, L.Options.new(), 2, 0, null, 128, 8, true)


func _public_api(context: RefCounted) -> void:
	var empty: Peer = Peer.new()
	context.equal(empty.begin_step(0, []).code, Types.Code.NOT_CONFIGURED, "manual request before configuration")
	context.equal(empty.complete_request(0, 0, true).code, Types.Code.NOT_CONFIGURED, "acknowledgement before configuration")
	var driven: Dictionary = Fixture.new()._build(context, 2)
	context.equal(driven.peers[0].begin_step(0, []).code, Types.Code.UNSUPPORTED, "callback mode does not mix request ownership")
	context.equal(driven.peers[0].complete_request(0, 0, true).code, Types.Code.UNSUPPORTED, "callback mode refuses manual acknowledgements")
	var mesh: Dictionary = _build(context, 128, 2, false, false)
	context.equal(mesh.peers[0].begin_step(0, []).code, Types.Code.NOT_SYNCHRONIZED, "manual mode cannot bypass handshake")
	mesh = _build(context)
	var peer: Peer = mesh.peers[0]
	context.equal(peer.step(0, []).code, Types.Code.UNSUPPORTED, "manual configuration installs no callback consumer")
	context.equal(peer.recover(0).code, Types.Code.UNSUPPORTED, "manual recovery requires request consumption")
	context.equal(peer.capture_replay_boundary().code, Types.Code.UNSUPPORTED, "manual capture requires request consumption")
	context.equal(mesh.games[0].requests.size(), 0, "callback-only calls dispatch nothing in manual mode")
	context.equal(peer.begin_step(0, []).code, Types.Code.MISSING_LOCAL_INPUT, "manual mode enforces local sampling")
	for operation: String in ["step", "recovery", "capture"]:
		mesh = _build(context)
		peer = mesh.peers[0]
		peer._core._batch_id = 9223372036854775807
		var result: Types.Result = peer.begin_step(1, []) if operation == "step" else (peer.begin_recovery(1) if operation == "recovery" else peer.begin_capture_replay_boundary())
		context.equal(result.code, Types.Code.FRAME_EXHAUSTED, "manual request identity exhaustion precedes " + operation)
		context.equal(peer.status().lifecycle, Types.Lifecycle.TERMINATED, "manual identity exhaustion is terminal")
		context.equal(mesh.games[0].requests.size(), 0, "manual identity exhaustion dispatches no game work")


func _batch_ownership(context: RefCounted) -> void:
	var fixture: RefCounted = Fixture.new()
	var mesh: Dictionary = _build(context, 128, 4, true)
	var peer: Peer = mesh.peers[0]
	var notices: Array[int] = []
	var codes: Array[int] = []
	var peer_ref: WeakRef = weakref(peer)
	peer.step_completed.connect(
		func(code: int, _before: int, _after: int) -> void:
			notices.append(code)
			codes.append(peer_ref.get_ref().begin_recovery(1).code)
	)
	var opened: Types.Result = peer.begin_step(1, fixture._inputs(mesh, 0))
	context.equal(opened.code, Types.Code.READY, "publication opens manual ordered batch")
	context.equal(mesh.games[0].requests.size(), 0, "opening requests dispatches no hidden game callbacks")
	context.equal(peer.status().current_frame, 0, "opening requests does not publish a frame")
	var request: Types.Request = opened.batch.next_request()
	context.equal(request.kind, Types.Kind.SAVE, "first manual request saves the original boundary")
	context.equal(opened.batch.next_request(), request, "active request remains stable until acknowledgement")
	context.equal(peer.complete_request(request.batch_id + 1, request.request_id, true).code, Types.Code.STALE_REQUEST, "foreign acknowledgement leaves batch live")
	context.equal(peer.complete_request(request.batch_id, request.request_id + 1, true).code, Types.Code.STALE_REQUEST, "out-of-order acknowledgement leaves batch live")
	context.equal(peer.poll(2), I.Code.BUSY, "manual batch fences transport polling")
	context.equal(peer.receive(PackedByteArray(), peer.peer_ids()[0], 2), I.Code.BUSY, "manual batch fences delivery")
	context.equal(peer.begin_step(2, []).code, Types.Code.BUSY, "manual batch fences another step")
	context.equal(peer.begin_recovery(2).code, Types.Code.BUSY, "manual batch fences recovery")
	context.equal(peer.drain_outbox().size(), 0, "manual batch retains publication until completion")
	context.equal(peer.set_input_delay(0, 1), Types.Code.BUSY, "manual batch fences delay changes")
	var first_batch: int = request.batch_id
	var first_request: int = request.request_id
	context.equal(_ack(peer, mesh.games[0], request).code, Types.Code.READY, "SAVE acknowledgement reports remaining ADVANCE")
	context.equal(request.writer.status(), Snapshot.Code.EXPIRED_VIEW, "acknowledged SAVE expires its writer")
	context.equal(peer.complete_request(first_batch, first_request, true).code, Types.Code.STALE_REQUEST, "duplicate acknowledgement cannot consume ADVANCE")
	request = opened.batch.next_request()
	context.equal(request.kind, Types.Kind.ADVANCE, "manual second request advances")
	var inputs: RefCounted = request.inputs
	var completed: Driver.StepResult = _ack(peer, mesh.games[0], request)
	context.equal(completed.code, Types.Code.OK, "final acknowledgement completes peer controls")
	context.equal(completed.frame_before, 0, "final result identifies whole batch start")
	context.equal(completed.frame_after, 1, "final acknowledgement commits exactly one frame")
	context.equal(inputs.player_count(), -1, "acknowledged ADVANCE expires borrowed input view")
	context.equal(opened.batch.next_request(), null, "completed manual batch expires")
	context.equal(notices, [Types.Code.OK], "manual completion emits once after every request")
	context.equal(codes, [Types.Code.BUSY], "manual completion notification holds shared ownership")
	context.equal(peer.drain_outbox().is_empty(), false, "completed manual batch releases actual published bytes")
	opened = peer.begin_step(1, fixture._inputs(mesh, 0))
	context.equal(opened.code, Types.Code.READY, "a later manual frame opens a fresh batch")
	context.equal(peer.complete_request(first_batch, first_request, true).code, Types.Code.STALE_REQUEST, "previous lifetime cannot acknowledge a new batch")
	context.equal(_consume(peer, mesh.games[0], opened).code, Types.Code.OK, "stale old acknowledgement leaves new frame usable")


func _callback_failures(context: RefCounted) -> void:
	for failure: String in ["save", "overflow", "advance", "close"]:
		var mesh: Dictionary = _build(context)
		var peer: Peer = mesh.peers[0]
		var opened: Types.Result = peer.begin_step(1, Fixture.new()._inputs(mesh, 0))
		var request: Types.Request = opened.batch.next_request()
		var writer: RefCounted = request.writer
		var result: Driver.StepResult
		if failure == "close":
			context.equal(peer.close(0), I.Code.INVALID_ARGUMENT, "backdated cancellation preserves the pending request")
			context.equal(opened.batch.next_request(), request, "refused close leaves active request usable")
			context.equal(peer.close(1), I.Code.OK, "explicit close cancels pending manual batch")
			context.equal(writer.status(), Snapshot.Code.EXPIRED_VIEW, "close expires pending writer")
			context.equal(opened.batch.next_request(), null, "close expires manual batch")
			context.equal(peer.complete_request(request.batch_id, request.request_id, true).code, Types.Code.STALE_REQUEST, "cancelled request cannot be acknowledged")
			context.equal(peer.begin_recovery(2).code, Types.Code.TERMINATED, "cancelled peer cannot recover")
			continue
		if failure == "advance":
			context.equal(_ack(peer, mesh.games[0], request).code, Types.Code.READY, "failure control first saves normally")
			request = opened.batch.next_request()
			result = peer.complete_request(request.batch_id, request.request_id, false)
		elif failure == "overflow":
			var bytes: PackedByteArray = PackedByteArray()
			bytes.resize(1024)
			context.equal(writer.write_bytes(bytes), Snapshot.Code.OVERFLOW, "bounded manual writer rejects oversized state")
			result = peer.complete_request(request.batch_id, request.request_id, true, mesh.games[0].game.checksum().hex_decode())
		else:
			result = peer.complete_request(request.batch_id, request.request_id, false)
		context.equal(result.code, Types.Code.SNAPSHOT_FAILED if failure == "overflow" else Types.Code.CALLBACK_FAILED, "manual failure completes with exact cause")
		context.equal(result.failure_frame, 0, "manual failure identifies request boundary")
		context.equal(result.failure_kind, Types.Kind.ADVANCE if failure == "advance" else Types.Kind.SAVE, "manual failure identifies request kind")
		context.equal(peer.status().current_frame, 0, "failed manual batch publishes no frame")
		context.equal(writer.status(), Snapshot.Code.EXPIRED_VIEW, "failed batch expires retained writer")
		context.equal(opened.batch.next_request(), null, "failed manual batch expires")
		context.equal(peer.drain_outbox().is_empty(), false, "failed manual batch releases final lifecycle packets")


func _recovery(context: RefCounted) -> void:
	var fixture: RefCounted = Fixture.new()
	for fail_load: bool in [false, true]:
		var mesh: Dictionary = _build(context)
		for frame: int in range(3):
			mesh.now += 1000
			for index: int in range(2):
				context.equal(
					Parity.new()._manual(mesh.peers[index], mesh.games[index], mesh.now, fixture._inputs(mesh, index), true).code,
					Types.Code.OK,
					"manual peers predict changing remote history"
				)
		fixture._deliver(context, mesh, fixture._drain(mesh))
		fixture._deliver(context, mesh, fixture._drain(mesh))
		var peer: Peer = mesh.peers[0]
		var opened: Types.Result = peer.begin_recovery(4000)
		context.equal(opened.code, Types.Code.READY, "late original input opens manual correction")
		var request: Types.Request = opened.batch.next_request()
		context.equal(request.kind, Types.Kind.LOAD, "manual correction starts with LOAD")
		if fail_load:
			var reader: RefCounted = request.reader
			var result: Driver.StepResult = peer.complete_request(request.batch_id, request.request_id, false)
			context.equal(result.failure_kind, Types.Kind.LOAD, "manual failed LOAD preserves first callback cause")
			context.equal(reader.status(), Snapshot.Code.EXPIRED_VIEW, "failed LOAD expires reader")
		else:
			var result: Driver.StepResult = _consume(peer, mesh.games[0], opened)
			context.equal(result.code, Types.Code.OK, "manual recovery applies every ordered request")
			context.equal(result.frame_before, 3, "manual recovery starts at existing frame")
			context.equal(result.frame_after, 3, "manual recovery adds no new frame")
			context.equal(peer.status().pending_rollback_frame, -1, "manual recovery repairs pending history")


func _pressure(context: RefCounted) -> void:
	var fixture: RefCounted = Fixture.new()
	var mesh: Dictionary = _build(context, 1)
	mesh.now = 1
	for index: int in range(2):
		context.equal(Parity.new()._manual(mesh.peers[index], mesh.games[index], 1, fixture._inputs(mesh, index), true).code, Types.Code.OK, "manual initial publication")
	var packets: Array[Dictionary] = fixture._drain(mesh)
	var peer: Peer = mesh.peers[0]
	context.equal(peer.begin_step(2, fixture._inputs(mesh, 0)).code, Types.Code.NETWORK_BACKPRESSURE, "manual pending-input cap refuses new request batch")
	context.equal(peer.status().current_frame, 1, "manual publication pressure preserves frame")
	var retained: Types.InputResult = peer.scheduled_local_input(0)
	context.equal(retained.bytes, fixture._sample(0, 1), "manual backpressure retains exact sampled buttons")
	mesh.now = 2
	fixture._deliver(context, mesh, packets)
	fixture._deliver(context, mesh, fixture._drain(mesh))
	context.equal(Parity.new()._manual(peer, mesh.games[0], 2, fixture._inputs(mesh, 0), true).code, Types.Code.OK, "same manual retained sample retries after ACK")
	context.equal(peer.status().current_frame, 2, "manual retry advances only once")
	context.equal(peer.scheduled_local_input(0).code, Types.Code.MISSING_LOCAL_INPUT, "manual successful advance releases retained sample")


func _capture(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context)
	var peer: Peer = mesh.peers[0]
	var before: Dictionary = peer.network_status()
	var opened: Types.Result = peer.begin_capture_replay_boundary()
	context.equal(opened.code, Types.Code.READY, "manual empty-prefix capture requests SAVE")
	context.equal(mesh.games[0].requests.size(), 0, "manual capture invokes no hidden callback")
	var result: Driver.StepResult = _consume(peer, mesh.games[0], opened)
	context.equal(result.code, Types.Code.OK, "manual capture completes")
	context.equal(result.frame_after, 0, "manual capture advances no simulation frame")
	context.equal(peer.network_status(), before, "manual capture polls and publishes no transport controls")
	context.equal(peer.replay().checksum(0), mesh.games[0].game.checksum().hex_decode(), "manual capture binds the finalized prefix")


func _ack(peer: Peer, game: RefCounted, request: Types.Request) -> Driver.StepResult:
	var ok: bool = false
	var checksum: PackedByteArray = PackedByteArray()
	match request.kind:
		Types.Kind.SAVE:
			var saved: Driver.SaveResult = game.save_state(request.frame, request.writer)
			ok = saved.ok
			checksum = saved.checksum
		Types.Kind.LOAD:
			ok = game.load_state(request.frame, request.reader)
		Types.Kind.ADVANCE:
			ok = game.simulate_frame(request.frame, request.inputs)
	return peer.complete_request(request.batch_id, request.request_id, ok, checksum)


func _consume(peer: Peer, game: RefCounted, opened: Types.Result) -> Driver.StepResult:
	var result: Driver.StepResult = Driver.StepResult.new(opened.code, peer.status().current_frame, peer.status().current_frame)
	while true:
		var request: Types.Request = opened.batch.next_request()
		if request == null:
			break
		result = _ack(peer, game, request)
		if result.code != Types.Code.READY:
			break
	return result
