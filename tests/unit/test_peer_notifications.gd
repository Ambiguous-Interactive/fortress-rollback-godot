extends RefCounted

# Value: protects=peer completion after controls and guarded reentry; fails_when=notice is absent, early or recursive; why_new=driver signal precedes peer controls; seam=none
const Fixture = preload("res://tests/unit/test_peer_session.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const L = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Protocol = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["completion", "stall_and_repair", "failure", "callback_failure", "shared_engine", "handler_stop", "external_facade"])


func run_case(name: String, context: RefCounted) -> void:
	if name in ["shared_engine", "handler_stop", "external_facade"]:
		call("_" + name, context)
		context.finish()
		return
	var fixture: RefCounted = Fixture.new()
	var mesh: Dictionary = fixture._build(context, 2, 0, false, 128, true, false, 2, L.Options.new())
	var peer: Peer = mesh.peers[0]
	context.equal(peer.has_signal("step_completed"), true, "peer offers a completed outer-step notice")
	if not peer.has_signal("step_completed"):
		context.finish()
		return
	var notices: Array[PackedInt32Array] = []
	var reference: WeakRef = weakref(peer)
	var game: RefCounted = mesh.games[0]
	peer.connect(
		"step_completed",
		func(code: int, before: int, after: int) -> void:
			var target: Peer = reference.get_ref()
			notices.append(PackedInt32Array([code, before, after]))
			context.equal(target.status().current_frame, after, "final corrected frame visible")
			context.equal(game.game.frame, after, "all game callbacks completed")
			context.equal(target.poll(999), I.Code.BUSY, "signal cannot poll")
			context.equal(target.close(999), I.Code.BUSY, "signal cannot close")
			context.equal(target.begin(999, []), I.Code.BUSY, "signal cannot begin")
			context.equal(target.configure(null, null, null, null, null), I.Code.BUSY, "signal cannot configure")
			context.equal(target.step(999, []).code, Types.Code.BUSY, "signal cannot recursively step")
			context.equal(target.receive(PackedByteArray(), target.peer_ids()[0], 999), I.Code.BUSY, "signal cannot receive")
			context.equal(target.drain_outbox().size(), 0, "signal cannot drain unpublished work")
	)
	if name == "completion":
		for round_index: int in 7:
			mesh.now += 1000
			var before: int = peer.status().current_frame
			var result: RefCounted = peer.step(mesh.now, fixture._inputs(mesh, 0))
			context.equal(notices[-1], PackedInt32Array([result.code, before, result.frame_after]), "notice matches returned outcome")
			context.equal(notices.size(), round_index + 1, "one notice per outer step")
			context.equal(mesh.peers[1].step(mesh.now, fixture._inputs(mesh, 1)).code, Types.Code.OK, "remote step")
			fixture._deliver(context, mesh, fixture._drain(mesh))
			fixture._deliver(context, mesh, fixture._drain(mesh))
	elif name == "stall_and_repair":
		for frame: int in 2:
			context.equal(peer.step(frame, fixture._inputs(mesh, 0)).code, Types.Code.OK, "predict remote")
		context.equal(peer.step(2, fixture._inputs(mesh, 0)).code, Types.Code.PREDICTION_STALL, "window stalls")
		context.equal(mesh.peers[1].step(2, fixture._inputs(mesh, 1)).code, Types.Code.OK, "actual remote correction")
		mesh.now = 2
		fixture._deliver(context, mesh, fixture._drain(mesh))
		fixture._deliver(context, mesh, fixture._drain(mesh))
		var result: RefCounted = peer.step(3, fixture._inputs(mesh, 0))
		context.equal(result.code, Types.Code.PREDICTION_STALL, "repair completes while new frame still stalls")
		context.equal(peer.statistics().rollback_count, 1, "notice follows actual rollback")
		context.equal(notices[-1], PackedInt32Array([result.code, 2, 2]), "repair-only final outcome")
		context.equal(notices.size(), 4, "reentry never emits another notice")
	elif name == "callback_failure":
		game.game.accumulators.resize(0)
		var result: RefCounted = peer.step(1, fixture._inputs(mesh, 0))
		context.equal(result.code, Types.Code.CALLBACK_FAILED, "invalid application state fails simulation callback")
		context.equal(notices[-1], PackedInt32Array([Types.Code.CALLBACK_FAILED, 0, 0]), "final peer notification retains callback failure")
		context.equal(peer.network_status().state, "terminated", "peer controls finish terminal cleanup before return")
		context.equal(notices.size(), 1, "one failed-batch notice")
	else:
		context.equal(peer.close(0), I.Code.OK, "explicit terminal outcome")
		var result: RefCounted = peer.step(1, fixture._inputs(mesh, 0))
		context.equal(notices[-1], PackedInt32Array([result.code, 0, 0]), "terminal result is visible")
		context.equal(notices.size(), 1, "one terminal notice")
	context.finish()


# Value: protects=stable peer notification boundary; fails_when=another facade mutates it;
# why_new=signal tests only reenter the peer; seam=existing expert engine
func _shared_engine(context: RefCounted) -> void:
	for operation: String in ["step", "recover", "capture"]:
		for action: String in ["driver", "configure", "cancel_configure"]:
			var fixture: RefCounted = Fixture.new()
			var mesh: Dictionary = fixture._build(context, 2, 0, false, 128, true, false, 8, L.Options.new(), 60, 0, null, 128, 4)
			var peer: Peer = mesh.peers[0]
			var alternate: Driver = Driver.new(peer._core, mesh.games[0])
			var alternate_ref: WeakRef = weakref(alternate)
			var core: RefCounted = peer._core
			var config: RefCounted = peer._config
			var codes: Array[int] = []
			var frames: Array[int] = []
			peer.step_completed.connect(
				func(_code: int, _before: int, _after: int) -> void:
					if action == "driver":
						var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, core.status().current_frame, PackedByteArray([2, 0, 0, 0]))]
						codes.append(alternate_ref.get_ref().step(1, samples).code)
					else:
						if action == "cancel_configure":
							core.terminate(Types.Code.DESYNC)
						codes.append(core.configure(config))
			)
			peer.step_completed.connect(func(_code: int, _before: int, _after: int) -> void: frames.append(core.status().current_frame))
			var result: Driver.StepResult = _invoke(peer, fixture, mesh, operation)
			context.equal(codes, [Types.Code.BUSY], "peer notification protects shared engine: " + operation + "/" + action)
			context.equal(frames, [result.frame_after], "later peer handler sees completed frontier: " + operation + "/" + action)
			context.equal(core._has_driver_guard(), false, "peer notification releases shared guard")
			if action == "cancel_configure":
				context.equal(result.reason, Types.Code.DESYNC, "handler cancellation survives rejected replacement")
			else:
				context.equal(core.poll(1).code, Types.Code.OK, "expert mutation resumes after all peer handlers")


# Value: protects=handler cancellation closes links and updates diagnostics; fails_when=pre-handler metadata is returned;
# why_new=driver cancellation has no peer transport; seam=existing expert cancellation
func _handler_stop(context: RefCounted) -> void:
	for operation: String in ["step", "recover", "capture"]:
		var fixture: RefCounted = Fixture.new()
		var mesh: Dictionary = fixture._build(context, 2, 0, false, 128, true, false, 8, L.Options.new(), 60, 0, null, 128, 4)
		var peer: Peer = mesh.peers[0]
		var core: RefCounted = peer._core
		var notices: Array[int] = []
		peer.step_completed.connect(
			func(code: int, _before: int, _after: int) -> void:
				notices.append(code)
				core.terminate(Types.Code.DESYNC)
				core.terminate(Types.Code.CALLBACK_FAILED)
		)
		var result: Driver.StepResult = _invoke(peer, fixture, mesh, operation)
		context.equal(result.code, Types.Code.OK, "handler cancellation preserves completed operation code")
		context.equal(notices, [Types.Code.OK], "one completed peer notification")
		context.equal(result.reason, Types.Code.DESYNC, "returned peer metadata includes first handler cancellation")
		context.equal(result.failure_frame, core.status().failure_frame, "returned terminal frame matches session")
		context.equal(result.failure_kind, -1, "explicit cancellation does not invent callback failure")
		var packets: Array[Peer.Packet] = peer.drain_outbox()
		var goodbyes: int = 0
		for packet: Peer.Packet in packets:
			if packet.bytes.decode_u16(6) == Protocol.Kind.GOODBYE:
				goodbyes += 1
		context.equal(goodbyes, 3, "handler cancellation sends one bounded goodbye burst before returning")
		context.equal(peer.recover(2).code, Types.Code.TERMINATED, "handler cancellation stops later recovery")
		context.equal(peer.drain_outbox().size(), 0, "terminal retries do not repeat goodbye")


func _invoke(peer: Peer, fixture: RefCounted, mesh: Dictionary, operation: String) -> Driver.StepResult:
	if operation == "step":
		return peer.step(1, fixture._inputs(mesh, 0))
	if operation == "recover":
		return peer.recover(1)
	return peer.capture_replay_boundary()


# Value: protects=peer queues during another facade's notification; fails_when=only the peer busy flag is checked;
# why_new=shared-engine case starts from peer notice; seam=existing shared engine
func _external_facade(context: RefCounted) -> void:
	for action: String in ["poll", "receive", "receive_and_poll", "close", "step", "recover", "capture", "delay", "drain"]:
		var fixture: RefCounted = Fixture.new()
		var mesh: Dictionary = fixture._build(context, 2, 0, false, 128, true, false, 8, L.Options.new(), 60, 0, null, 128, 4)
		var peer: Peer = mesh.peers[0]
		var alternate: Driver = Driver.new(peer._core, mesh.games[0])
		var peer_ref: WeakRef = weakref(peer)
		var observations: Array[int] = []
		var notices: Array[int] = []
		peer.step_completed.connect(func(code: int, _before: int, _after: int) -> void: notices.append(code))
		# Keep actual peer controls queued while another facade completes a SAVE-only batch.
		context.equal(peer.poll(200000), I.Code.OK, "queue controls before shared facade completion")
		var before: Dictionary = peer.network_status()
		alternate.step_completed.connect(
			func(_code: int, _before: int, _after: int) -> void:
				var target: Peer = peer_ref.get_ref()
				var code: int = -1
				match action:
					"poll":
						code = target.poll(200001)
					"receive":
						code = target.receive(PackedByteArray(), target.peer_ids()[0], 200001)
					"receive_and_poll":
						code = target.receive_and_poll(PackedByteArray(), target.peer_ids()[0], 200001)
					"close":
						code = target.close(200001)
					"step":
						code = target.step(200001, []).code
					"recover":
						code = target.recover(200001).code
					"capture":
						code = target.capture_replay_boundary().code
					"delay":
						code = target.set_input_delay(0, 0)
					"drain":
						observations.append(target.drain_outbox().size())
						observations.append(target.drain_events().size())
						observations.append(target.drain_transitions().size())
				if action != "drain":
					observations.append(code)
				context.equal(target._core.begin_recovery().code, Types.Code.BUSY, "peer attempt cannot release another facade's notification guard")
		)
		context.equal(alternate.capture_replay_boundary().code, Types.Code.OK, "shared driver completes original capture")
		context.equal(
			observations,
			[0, 0, 0] if action == "drain" else [I.Code.BUSY if action in ["poll", "receive", "receive_and_poll", "close"] else Types.Code.BUSY],
			"peer ownership crosses alternate facade: " + action
		)
		context.equal(notices.size(), 0, "BUSY peer attempts emit no completion")
		context.equal(peer.network_status(), before, "blocked shared-facade attempt preserves endpoints and clock")
		context.equal(peer.status().lifecycle, Types.Lifecycle.RUNNING, "blocked shared-facade attempt preserves session")
		context.equal(peer.poll(200001), I.Code.OK, "peer ownership releases after shared notification")
