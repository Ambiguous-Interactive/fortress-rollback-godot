extends RefCounted

# Value: protects=confirmed saved checksum ownership; fails_when=predicted snapshots escape; why_new=P4 exchange; seam=none
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const Fixture = preload("res://tests/unit/test_peer_session.gd")
const L = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const Game = preload("res://tests/oracle/p2p_game.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(
		[
			"checksum_export",
			"healthy_exchange",
			"real_desync",
			"terminal_timeout",
			"close",
			"checksum_conflict",
			"checksum_future",
			"stale_checksum",
			"interrupted_resume",
			"checksum_capacity",
			"event_capacity",
			"statistics",
			"lockstep_checksums"
		]
	)


func run_case(name: String, context: RefCounted) -> void:
	if name == "lockstep_checksums":
		_lockstep(context)
		context.finish()
		return
	if name == "statistics":
		_statistics(context)
		context.finish()
		return
	if name in ["checksum_conflict", "checksum_future", "stale_checksum", "interrupted_resume", "checksum_capacity", "event_capacity"]:
		_report_case(name, context)
		context.finish()
		return
	if name != "checksum_export":
		_mesh_case(name, context)
		context.finish()
		return
	var core: Session = Session.new()
	context.equal(core.has_method("confirmed_checksums"), true, "core exports only completed confirmed snapshot checksums")
	if not core.has_method("confirmed_checksums"):
		context.finish()
		return
	var config: Config = Config.new()
	config.sync_test = false
	config.check_distance = 0
	config.local_players = PackedInt32Array([0])
	config.input_width = 4
	config.neutral_input = PackedByteArray([0, 0, 0, 0])
	config.max_snapshot_bytes = 20
	config.storage_budget_bytes = 1048576
	context.equal(core.configure(config), Types.Code.OK, "configure checksum core")
	var game: RefCounted = Game.new(2)
	var driver: Driver = Driver.new()
	context.equal(driver.configure(core, game), Types.Code.OK, "configure checksum driver")
	context.equal(core.receive_input(1, 0, PackedByteArray([1, 0, 0, 0])).code, Types.Code.OK, "actual input zero")
	context.equal(driver.step(0, [Driver.LocalInput.new(0, 0, config.neutral_input)]).code, Types.Code.OK, "save boundary zero")
	context.equal(core.confirmed_checksums().size(), 0, "strictly below confirmed excludes boundary zero")
	context.equal(driver.step(1, [Driver.LocalInput.new(0, 1, config.neutral_input)]).code, Types.Code.OK, "advance predicted remote")
	context.equal(core.receive_input(1, 1, PackedByteArray([2, 0, 0, 0])).code, Types.Code.OK, "actual correction arrives")
	context.equal(core.confirmed_checksums().size(), 1, "pending correction preserves earlier unaffected state")
	context.equal(driver.step(2, [Driver.LocalInput.new(0, 2, config.neutral_input)]).code, Types.Code.OK, "repair and save")
	var reports: Array[Dictionary] = core.confirmed_checksums()
	context.equal(reports.size(), 1, "only boundary zero below confirmed one")
	if not reports.is_empty():
		context.equal(reports[0].frame, 0, "saved frame identity")
		reports[0].checksum.fill(0)
		context.equal(core.confirmed_checksums()[0].checksum != reports[0].checksum, true, "checksum export owns bytes")
	context.finish()


func _mesh_case(name: String, context: RefCounted) -> void:
	if name in ["healthy_exchange", "real_desync"]:
		_minimum_checksums(context, name == "real_desync")
	if name == "real_desync":
		_mismatch_with_backpressure(context)
	var fixture: RefCounted = Fixture.new()
	var options: L.Options = L.Options.new()
	options.max_checksum_frames = 2
	var mesh: Dictionary = fixture._build(context, 2, 0, false, 128, true, false, 8, options)
	if name == "real_desync":
		mesh.games[1].game.accumulators[0] += 1
	if name == "terminal_timeout":
		context.equal(mesh.peers[0].poll(500001), I.Code.OK, "partition interruption boundary")
		var events: Array[Dictionary] = mesh.peers[0].drain_events()
		context.equal(events.any(func(event: Dictionary) -> bool: return event.kind == "network_interrupted"), true, "visible interruption")
		context.equal(mesh.peers[0].status().lifecycle, Types.Lifecycle.RUNNING, "interruption alone remains recoverable")
		mesh.peers[0].poll(2000001)
		context.equal(mesh.peers[0].status().lifecycle, Types.Lifecycle.TERMINATED, "fixed membership timeout terminal")
		context.equal(mesh.peers[0].step(2000001, fixture._inputs(mesh, 0)).code, Types.Code.TERMINATED, "terminal peer cannot advance")
		return
	if name == "close":
		context.equal(mesh.peers[0].close(1, 7), I.Code.OK, "queue actual goodbye")
		context.equal(mesh.peers[0].status().lifecycle, Types.Lifecycle.TERMINATED, "local close halts game")
		var packets: Array[Dictionary] = fixture._drain(mesh)
		context.equal(packets.size(), 3, "three redundant source goodbye packets")
		mesh.now = 1
		var packet: Dictionary = packets[0]
		context.equal(mesh.peers[1].receive(packet.bytes, fixture._id(0), 1), I.Code.OK, "receive actual goodbye")
		context.equal(mesh.peers[1].status().lifecycle, Types.Lifecycle.TERMINATED, "remote fixed membership close halts game")
		_disconnect_during_rollback(context)
		return
	var detected: Dictionary = {}
	for frame: int in range(210):
		mesh.now += 1000
		for index: int in range(2):
			var advanced: RefCounted = mesh.peers[index].step(mesh.now, fixture._inputs(mesh, index))
			if mesh.peers[index].status().lifecycle == Types.Lifecycle.RUNNING:
				context.equal(advanced.code, Types.Code.OK, "healthy gameplay advances")
		var packets: Array[Dictionary] = fixture._drain(mesh)
		for packet: Dictionary in packets:
			if mesh.peers[packet.to].status().lifecycle == Types.Lifecycle.RUNNING:
				mesh.peers[packet.to].receive(packet.bytes, fixture._id(packet.from), mesh.now)
		for peer: RefCounted in mesh.peers:
			for event: Dictionary in peer.drain_events():
				if event.kind == "desync_detected":
					detected = event
			peer.drain_transitions()
		if not detected.is_empty():
			break
	if name == "real_desync":
		context.equal(detected.is_empty(), false, "real game saved checksum mismatch detected")
		if not detected.is_empty():
			context.equal(detected.frame, 60, "first actual scheduled saved boundary")
			context.equal(detected.local_checksum.size(), 16, "owned negotiated local checksum")
			context.equal(detected.remote_checksum.size(), 16, "owned negotiated remote checksum")
			context.equal(detected.local_checksum != detected.remote_checksum, true, "diagnostic contains both different byte domains")
		context.equal(mesh.peers[0].status().reason == Types.Code.DESYNC or mesh.peers[1].status().reason == Types.Code.DESYNC, true, "mismatch halts session explicitly")
		for peer: RefCounted in mesh.peers:
			if peer.status().reason == Types.Code.DESYNC:
				context.equal(peer.status().failure_frame, 60, "terminal status localizes actual mismatching boundary")
	else:
		context.equal(detected.is_empty(), true, "confirmed repaired histories agree")
		for peer: RefCounted in mesh.peers:
			context.equal(peer.status().current_frame, 210, "bounded checksum history sustains gameplay")
			context.equal(peer.network_status().checksums.local_frames <= 2, true, "local report retention bounded before allocation")
			context.equal(peer.network_status().checksums.next_frame > 180, true, "nonvacuous three actual checksum report intervals")
	context.state(mesh.games[0].game.frame, mesh.games[0].game.bytes())


# Value: protects=minimum inventory comparison before eviction; fails_when=cap one prunes eligible pairs; why_new=existing exchange uses cap two; seam=none
func _minimum_checksums(context: RefCounted, divergent: bool) -> void:
	var fixture: RefCounted = Fixture.new()
	var limits: T.Limits = T.Limits.new()
	limits.input_width = 4
	for window: int in [0, 8]:
		for delayed: bool in ([false] if divergent else [false, true]):
			var options: L.Options = L.Options.new()
			options.max_checksum_frames = 1
			var mesh: Dictionary = fixture._build(context, 2, 0, false, 128, true, false, window, options, 1)
			if divergent:
				mesh.games[1].game.accumulators[0] += 1
			var held: Array[Dictionary] = []
			var reports: int = 0
			var detected: Dictionary = {}
			for tick: int in range(30):
				mesh.now += 1000
				for index: int in range(2):
					if mesh.peers[index].status().lifecycle == Types.Lifecycle.RUNNING:
						var result: RefCounted = mesh.peers[index].step(mesh.now, fixture._inputs(mesh, index))
						var allowed: Array[int] = [Types.Code.OK, Types.Code.PREDICTION_STALL, Types.Code.TERMINATED]
						if divergent:
							allowed.append(Types.Code.DESYNC)
						context.equal(result.code in allowed, true, "minimum inventory advances or detects divergence")
				var packets: Array[Dictionary] = fixture._drain(mesh)
				if delayed:
					packets.reverse()
				for packet: Dictionary in packets:
					if Codec.decode(packet.bytes, limits).message.kind == T.Kind.CHECKSUM_REPORT:
						reports += 1
						if delayed and tick < 8:
							held.append(packet)
							continue
					if mesh.peers[packet.to].status().lifecycle == Types.Lifecycle.RUNNING:
						context.equal(mesh.peers[packet.to].receive(packet.bytes, fixture._id(packet.from), mesh.now), I.Code.OK, "deliver real minimum-inventory traffic")
				if delayed and tick == 12:
					held.reverse()
					for packet: Dictionary in held:
						context.equal(mesh.peers[packet.to].receive(packet.bytes, fixture._id(packet.from), mesh.now), I.Code.OK, "expired reordered report follows explicit stale policy")
				for peer: RefCounted in mesh.peers:
					for event: Dictionary in peer.drain_events():
						if event.kind == "desync_detected":
							detected = event
					peer.drain_transitions()
			context.equal(reports > (0 if divergent else 4), true, "minimum inventory sends actual scheduled checksum reports")
			context.equal(not detected.is_empty(), divergent, "minimum inventory detects real divergence")
			if divergent and not detected.is_empty():
				context.equal(detected.frame, 1, "first retained eligible boundary identifies mismatch")
				context.equal(detected.local_checksum != detected.remote_checksum, true, "minimum inventory preserves actual differing checksum bytes")
			if not divergent:
				for peer: RefCounted in mesh.peers:
					context.equal(peer.status().lifecycle, Types.Lifecycle.RUNNING, "healthy minimum inventory remains live")
					var verified: Dictionary = peer.network_status().checksums.get("verified_reports", {})
					var comparisons: int = 0
					for count: int in verified.values():
						comparisons += count
					context.equal(comparisons > 0, true, "healthy equality verification remains nonvacuous after eviction")

# Value: protects=known mismatch under report send pressure; fails_when=backpressure hides retained divergence; why_new=minimum test drains every outbox; seam=none
func _mismatch_with_backpressure(context: RefCounted) -> void:
	var fixture: RefCounted = Fixture.new()
	var options: L.Options = L.Options.new()
	options.max_checksum_frames = 1
	var mesh: Dictionary = fixture._build(context, 2, 0, false, 128, true, false, 8, options, 1)
	mesh.games[1].game.accumulators[0] += 1
	var limits: T.Limits = T.Limits.new()
	limits.input_width = 4
	var contact: PackedByteArray = PackedByteArray()
	var armed: bool = false
	for tick: int in range(10):
		mesh.now += 1000
		for index: int in range(2):
			mesh.peers[index].step(mesh.now, fixture._inputs(mesh, index))
		for packet: Dictionary in fixture._drain(mesh):
			if packet.from == 1:
				contact = packet.bytes.duplicate()
			mesh.peers[packet.to].receive(packet.bytes, fixture._id(packet.from), mesh.now)
		if mesh.peers[0].status().confirmed_frame > 2 and mesh.peers[0].network_status().checksums.next_frame == 2:
			armed = true
			break
	context.equal(armed, true, "actual retained mismatch reaches strict comparison boundary")
	if not armed:
		return
	mesh.peers[0].drain_outbox()
	var report: T.Message = Codec.decode(contact, limits).message
	report.kind = T.Kind.QUALITY_REPORT
	report.token.resize(16)
	var bytes: PackedByteArray = Codec.encode(report, limits).bytes
	for packet: int in range(128):
		context.equal(mesh.peers[0].receive(bytes, fixture._id(1), mesh.now), I.Code.OK, "real control replies saturate bounded outbox")
	var result: RefCounted = mesh.peers[0].step(mesh.now, fixture._inputs(mesh, 0))
	context.equal(result.code, Types.Code.DESYNC, "known divergence wins over outgoing report pressure")
	var events: Array[Dictionary] = mesh.peers[0].drain_events()
	var mismatches: Array = events.filter(func(event: Dictionary) -> bool: return event.kind == "desync_detected")
	context.equal(mismatches.size(), 1, "primary checksum diagnostic survives failed report and goodbye sends")
	if not mismatches.is_empty():
		context.equal(mismatches[0].frame, 1, "pressure retains precise mismatching boundary")
		context.equal(mismatches[0].local_checksum != mismatches[0].remote_checksum, true, "pressure retains both owned differing checksums")

func _report_case(name: String, context: RefCounted) -> void:
	var fixture: RefCounted = Fixture.new()
	var options: L.Options = L.Options.new()
	options.max_checksum_frames = 2
	if name == "event_capacity":
		options.max_events = 2
	var mesh: Dictionary = fixture._build(context, 2, 0, false, 128, true, false, 8, options, 1)
	if name in ["interrupted_resume", "event_capacity"]:
		context.equal(mesh.peers[0].poll(500001), I.Code.OK, "observe actual partition interruption")
		if name != "event_capacity":
			mesh.peers[0].drain_events()
		context.equal(mesh.peers[1].poll(500001), I.Code.OK, "peer sends genuine keepalive and quality")
		mesh.now = 500001
		for packet: Dictionary in fixture._drain(mesh):
			if packet.from == 1:
				context.equal(mesh.peers[0].receive(packet.bytes, fixture._id(1), mesh.now), I.Code.OK, "authenticated peer contact resumes")
		if name == "event_capacity":
			mesh.peers[0].drain_outbox()
			mesh.peers[0].poll(1000003)
			var overflow: Array[Dictionary] = mesh.peers[0].drain_events()
			context.equal(overflow.size(), 3, "bounded event publication plus one reserved fatal slot")
			context.equal(overflow.any(func(event: Dictionary) -> bool: return event.kind == "event_capacity_exceeded"), true, "overflow remains visible")
			context.equal(mesh.peers[0].status().reason, Types.Code.PROTOCOL_FAILED, "event overflow cannot hide correctness")
			for count: int in [2, 3]:
				_overflow_timeout(context, count)
				_overflow_timeout(context, count, true)
			return
		var events: Array[Dictionary] = mesh.peers[0].drain_events()
		context.equal(events.filter(func(event: Dictionary) -> bool: return event.kind == "network_resumed").size(), 1, "exactly one resume notification")
		context.equal(mesh.peers[0].status().lifecycle, Types.Lifecycle.RUNNING, "healthy contact remains live")
		context.equal(mesh.peers[1].poll(2500000), I.Code.OK, "peer produces contact just before renewed timeout")
		for packet: Dictionary in fixture._drain(mesh):
			if packet.from == 1:
				context.equal(mesh.peers[0].receive(packet.bytes, fixture._id(1), 2500000), I.Code.OK, "authenticated recovery one microsecond before deadline")
		context.equal(mesh.peers[0].poll(4500000), I.Code.OK, "renewed exact timeout boundary remains live")
		context.equal(mesh.peers[0].status().lifecycle, Types.Lifecycle.RUNNING, "contact resets timeout at strict boundary")
		mesh.peers[0].poll(4500001)
		context.equal(mesh.peers[0].status().lifecycle, Types.Lifecycle.TERMINATED, "timeout plus one microsecond terminates renewed partition")
		return
	var retained: PackedByteArray = PackedByteArray()
	var limits: T.Limits = T.Limits.new()
	limits.input_width = 4
	var ticks: int = 20 if name == "stale_checksum" else 5
	for frame: int in range(ticks):
		mesh.now += 1000
		for index: int in range(2):
			context.equal(mesh.peers[index].step(mesh.now, fixture._inputs(mesh, index)).code, Types.Code.OK, "real report schedule step")
		for packet: Dictionary in fixture._drain(mesh):
			var decoded: RefCounted = Codec.decode(packet.bytes, limits)
			context.equal(decoded.code, T.Code.OK, "actual wire packet decodes")
			if packet.from == 1 and decoded.message.kind == T.Kind.CHECKSUM_REPORT and retained.is_empty():
				retained = packet.bytes.duplicate()
				if name != "stale_checksum":
					continue
			context.equal(mesh.peers[packet.to].receive(packet.bytes, fixture._id(packet.from), mesh.now), I.Code.OK, "deliver other genuine packets")
		for peer: RefCounted in mesh.peers:
			peer.drain_events()
			peer.drain_transitions()
		if not retained.is_empty() and name != "stale_checksum":
			break
	context.equal(retained.is_empty(), false, "actual saved-boundary report captured")
	if retained.is_empty():
		return
	var report: RefCounted = Codec.decode(retained, limits).message
	if name == "checksum_capacity":
		for ahead: int in range(1, 4):
			report.frame = mesh.peers[0].status().current_frame + ahead
			var future: RefCounted = Codec.encode(report, limits)
			context.equal(future.code, T.Code.OK, "bounded future report encodes")
			context.equal(mesh.peers[0].receive(future.bytes, fixture._id(1), mesh.now), I.Code.OK, "retain attributed report before cap")
		context.equal(mesh.peers[0].status().reason, Types.Code.PROTOCOL_FAILED, "remote checksum cap is terminal")
		var overflow: Array[Dictionary] = mesh.peers[0].drain_events()
		context.equal(overflow.any(func(event: Dictionary) -> bool: return event.kind == "checksum_capacity_exceeded"), true, "report overflow diagnosis survives")
		return
	if name == "checksum_conflict":
		report.frame = mesh.peers[0].status().current_frame + 1
		retained = Codec.encode(report, limits).bytes
		context.equal(mesh.peers[0].receive(retained, fixture._id(1), mesh.now), I.Code.OK, "first pending report retained")
		context.equal(mesh.peers[0].receive(retained, fixture._id(1), mesh.now), I.Code.OK, "identical duplicate report idempotent")
		report.checksum[0] ^= 1
	elif name == "checksum_future":
		report.frame = 1000
	else:
		report.checksum[0] ^= 1
	var encoded: RefCounted = Codec.encode(report, limits)
	context.equal(encoded.code, T.Code.OK, "altered report remains real valid encoded control")
	context.equal(mesh.peers[0].receive(encoded.bytes, fixture._id(1), mesh.now), I.Code.OK, "deliver attributed report")
	if name == "stale_checksum":
		context.equal(mesh.peers[0].status().lifecycle, Types.Lifecycle.RUNNING, "expired report cannot compare against overwritten history")
	else:
		context.equal(mesh.peers[0].status().reason, Types.Code.PROTOCOL_FAILED, "conflicting or far-future report terminates safely")
		var events: Array[Dictionary] = mesh.peers[0].drain_events()
		var expected: String = "conflicting_checksum_report" if name == "checksum_conflict" else "future_checksum_report"
		context.equal(events.any(func(event: Dictionary) -> bool: return event.kind == expected), true, "precise report failure evidence survives drain")


# Value: protects=terminal causes after recoverable overflow; fails_when=reserved fatal slot hides timeout; why_new=event cap checks only first overflow; seam=none
func _overflow_timeout(context: RefCounted, count: int, local_close: bool = false) -> void:
	var fixture: RefCounted = Fixture.new()
	var options: L.Options = L.Options.new()
	options.max_events = 2 * (count - 1)
	var mesh: Dictionary = fixture._build(context, count, 0, false, 128, true, false, 8, options)
	for peer: RefCounted in mesh.peers:
		context.equal(peer.poll(500001), I.Code.OK, "every link observes real interruption")
	for packet: Dictionary in fixture._drain(mesh):
		if packet.to == 0:
			context.equal(mesh.peers[0].receive(packet.bytes, fixture._id(packet.from), 500001), I.Code.OK, "real authenticated contact fills resume publication")
	mesh.peers[0].drain_outbox()
	if local_close:
		context.equal(mesh.peers[0].close(500002, 7), I.Code.OK, "local close publishes every terminal link cause")
	else:
		context.equal(mesh.peers[0].poll(2500002), I.Code.OK, "renewed timeout produces ordered interruption and disconnect")
	var events: Array[Dictionary] = mesh.peers[0].drain_events()
	context.equal(events.size(), options.max_events + 1, "ordinary bound plus one owned fatal slot")
	var fatal: Dictionary = events[-1]
	context.equal(fatal.kind, "event_capacity_exceeded", "first overflow reason retained")
	context.equal(fatal.terminal_cause[0].kind, "disconnected" if local_close else "network_interrupted", "first dropped publication remains diagnostic")
	var causes: Array = fatal.terminal_cause.filter(
		func(event: Dictionary) -> bool: return event.kind == "disconnected" and event.get("reason") == (7 if local_close else "timeout")
	)
	context.equal(causes.size(), count - 1, "actual terminal reason survives for every remote peer")
	context.equal(fatal.terminal_cause.size() <= count, true, "reserved causes bounded by membership plus first overflow")
	for event: Dictionary in causes:
		context.equal(event.peer in [fixture._id(1), fixture._id(2)], true, "timeout preserves attributed owned peer bytes")
		event.peer.fill(0)
	context.equal(mesh.peers[0].network_status().peers.has(fixture._id(1).hex_encode()), true, "drained cause mutation preserves session identity")
	context.equal(mesh.peers[0].drain_events().size(), 0, "fatal cause drains once without duplicate close events")

func _statistics(context: RefCounted) -> void:
	var fixture: RefCounted = Fixture.new()
	var options: L.Options = L.Options.new()
	options.time_sync_window = 1
	var mesh: Dictionary = fixture._build(context, 2, 0, false, 128, true, false, 8, options)
	mesh.now = 1
	fixture._tick(context, mesh)
	fixture._deliver(context, mesh, fixture._drain(mesh))
	fixture._deliver(context, mesh, fixture._drain(mesh))
	context.equal(mesh.peers[0].poll(200001), I.Code.OK, "actual quality probe sent")
	mesh.now = 237001
	for packet: Dictionary in fixture._drain(mesh):
		if packet.from == 0:
			context.equal(mesh.peers[1].receive(packet.bytes, fixture._id(0), mesh.now), I.Code.OK, "deliver actual latency probe")
	for packet: Dictionary in fixture._drain(mesh):
		if packet.from == 1:
			context.equal(mesh.peers[0].receive(packet.bytes, fixture._id(1), mesh.now), I.Code.OK, "receive actual pong")
	var observed: Dictionary = mesh.peers[0].network_status().peers[fixture._id(1).hex_encode()]
	context.equal(observed.round_trip_time_ms, 37, "injected integer round-trip statistic")
	context.equal(mesh.peers[1].poll(mesh.now), I.Code.OK, "remote quality report observation")
	var limits: T.Limits = T.Limits.new()
	limits.input_width = 4
	var found: bool = false
	for packet: Dictionary in fixture._drain(mesh):
		if packet.from != 1:
			continue
		var decoded: RefCounted = Codec.decode(packet.bytes, limits)
		if decoded.message.kind == T.Kind.QUALITY_REPORT:
			decoded.message.frame_advantage = 10
			packet.bytes = Codec.encode(decoded.message, limits).bytes
			found = true
		context.equal(mesh.peers[0].receive(packet.bytes, fixture._id(1), mesh.now), I.Code.OK, "receive valid peer pacing estimate")
	context.equal(found, true, "actual quality control carries peer estimate")
	for tick: int in range(2):
		mesh.now += 1
		context.equal(mesh.peers[0].step(mesh.now, fixture._inputs(mesh, 0)).code, Types.Code.OK, "sample frame advantage without automatic skipping")
		mesh.peers[0].drain_outbox()
	var events: Array[Dictionary] = mesh.peers[0].drain_events()
	context.equal(
		events.any(func(event: Dictionary) -> bool: return event.kind == "wait_recommendation" and event.skip_frames >= 3), true, "bounded pacing recommendation published"
	)
	context.equal(mesh.peers[0].network_status().frames_ahead >= 3, true, "session exposes actual sampled skew")


func _lockstep(context: RefCounted) -> void:
	var fixture: RefCounted = Fixture.new()
	var options: L.Options = L.Options.new()
	var mesh: Dictionary = fixture._build(context, 2, 0, false, 128, true, false, 0, options, 1)
	var reports: int = 0
	var limits: T.Limits = T.Limits.new()
	limits.input_width = 4
	for tick: int in range(20):
		mesh.now += 1000
		for index: int in range(2):
			var advanced: RefCounted = mesh.peers[index].step(mesh.now, fixture._inputs(mesh, index))
			context.equal(advanced.code in [Types.Code.OK, Types.Code.PREDICTION_STALL], true, "lockstep advances or waits for actual input")
		for packet: Dictionary in fixture._drain(mesh):
			var decoded: RefCounted = Codec.decode(packet.bytes, limits)
			context.equal(decoded.code, T.Code.OK, "lockstep produces real encoded control")
			if decoded.message.kind == T.Kind.CHECKSUM_REPORT:
				reports += 1
			context.equal(mesh.peers[packet.to].receive(packet.bytes, fixture._id(packet.from), mesh.now), I.Code.OK, "lockstep packet accepted")
		for peer: RefCounted in mesh.peers:
			peer.drain_events()
			peer.drain_transitions()
	context.equal(reports > 4, true, "zero prediction still exchanges actual saved callback checksums")
	for peer: RefCounted in mesh.peers:
		context.equal(peer.status().current_frame >= 8, true, "enabled lockstep checksum mode makes progress")
	context.equal(mesh.games[0].game.bytes(), mesh.games[1].game.bytes(), "lockstep canonical states agree")
	_lockstep_desync(context)


func _lockstep_desync(context: RefCounted) -> void:
	var fixture: RefCounted = Fixture.new()
	var mesh: Dictionary = fixture._build(context, 2, 0, false, 128, true, false, 0, L.Options.new(), 1)
	mesh.games[1].game.accumulators[0] += 1
	var detected: Dictionary = {}
	for tick: int in range(20):
		mesh.now += 1000
		for index: int in range(2):
			if mesh.peers[index].status().lifecycle == Types.Lifecycle.RUNNING:
				mesh.peers[index].step(mesh.now, fixture._inputs(mesh, index))
		for packet: Dictionary in fixture._drain(mesh):
			if mesh.peers[packet.to].status().lifecycle == Types.Lifecycle.RUNNING:
				mesh.peers[packet.to].receive(packet.bytes, fixture._id(packet.from), mesh.now)
		for peer: RefCounted in mesh.peers:
			for event: Dictionary in peer.drain_events():
				if event.kind == "desync_detected":
					detected = event
			peer.drain_transitions()
		if not detected.is_empty():
			break
	context.equal(detected.is_empty(), false, "lockstep real saved game divergence is not vacuous")
	if not detected.is_empty():
		context.equal(detected.frame, 1, "first scheduled lockstep checksum boundary")
		context.equal(detected.local_checksum != detected.remote_checksum, true, "lockstep mismatch preserves both game checksums")


func _disconnect_during_rollback(context: RefCounted) -> void:
	var fixture: RefCounted = Fixture.new()
	var mesh: Dictionary = fixture._build(context, 2, 0, false, 128, true, false, 8, L.Options.new(), 1)
	mesh.now = 1
	for index: int in range(2):
		context.equal(mesh.peers[index].step(1, fixture._inputs(mesh, index)).code, Types.Code.OK, "predict before late changing input")
	var limits: T.Limits = T.Limits.new()
	limits.input_width = 4
	for packet: Dictionary in fixture._drain(mesh):
		if packet.from == 1 and Codec.decode(packet.bytes, limits).message.kind == T.Kind.INPUT:
			context.equal(mesh.peers[0].receive(packet.bytes, fixture._id(1), 1), I.Code.OK, "actual input arms real pending rollback")
	context.equal(mesh.peers[0].status().pending_rollback_frame, 0, "actual queue mismatch exists before goodbye")
	var before: PackedByteArray = mesh.games[0].game.bytes().duplicate()
	var callbacks: int = mesh.games[0].requests.size()
	var confirmed: int = mesh.peers[0].status().confirmed_frame
	mesh.peers[0].drain_outbox()
	context.equal(mesh.peers[1].close(2, 7), I.Code.OK, "remote close during armed repair")
	for packet: Dictionary in fixture._drain(mesh):
		if packet.from == 1 and Codec.decode(packet.bytes, limits).message.kind == T.Kind.GOODBYE:
			context.equal(mesh.peers[0].receive(packet.bytes, fixture._id(1), 2), I.Code.OK, "receive terminal contact before repair callbacks")
			break
	context.equal(mesh.peers[0].status().lifecycle, Types.Lifecycle.TERMINATED, "goodbye halts pending rollback")
	context.equal(mesh.peers[0].step(2, fixture._inputs(mesh, 0)).code, Types.Code.TERMINATED, "terminated pending rollback cannot start callbacks")
	context.equal(mesh.games[0].game.bytes(), before, "disconnect preserves complete frozen game bytes")
	context.equal(mesh.games[0].requests.size(), callbacks, "no save load or advance after terminal loss")
	context.equal(mesh.peers[0].status().confirmed_frame, confirmed, "terminal loss preserves published confirmation")
