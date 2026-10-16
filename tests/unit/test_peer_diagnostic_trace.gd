extends RefCounted

# Value: protects=real desync evidence under event pressure; fails_when=trace fabricates mismatch or loses canonical payloads;
# why_new=existing desync tests only preserve checksum pairs; seam=publication bank prefilled before real mismatch
const Fixture = preload("res://tests/unit/test_peer_session.gd")
const L = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")


func cases() -> PackedStringArray:
	return PackedStringArray(["real_divergence", "healthy_equality"])


func run_case(name: String, context: RefCounted) -> void:
	var fixture: RefCounted = Fixture.new()
	var options: L.Options = L.Options.new()
	options.max_events = 2
	var mesh: Dictionary = fixture._build(context, 2, 0, false, 128, true, false, 8, options, 3, 8)
	var baseline: Dictionary = fixture._build(context, 2, 0, false, 128, true, false, 8, options, 3)
	if name == "real_divergence":
		mesh.games[1].game.accumulators[0] += 1
	var observed: bool = false
	for frame: int in range(24):
		for current: Dictionary in [mesh, baseline]:
			current.now += 1000
			for index: int in range(2):
				var advancing: RefCounted = current.peers[index]
				if name == "real_divergence" and current == mesh and advancing._checksum_confirmation > 3:
					advancing._events.append({"kind": "test_bank_full"})
					advancing._events.append({"kind": "test_bank_full"})
				current.peers[index].step(current.now, fixture._inputs(current, index))
			var packets: Array[Dictionary] = fixture._drain(current)
			for packet: Dictionary in packets:
				if current.peers[packet.to].status().lifecycle == Types.Lifecycle.RUNNING:
					current.peers[packet.to].receive(packet.bytes, fixture._id(packet.from), current.now)
		for index: int in range(2):
			var peer: RefCounted = mesh.peers[index]
			var report: Dictionary = peer.diagnostics()
			if name == "healthy_equality":
				context.equal(mesh.games[index].game.bytes(), baseline.games[index].game.bytes(), "opt-in preserves exact canonical gameplay")
				context.equal(mesh.games[index].requests, baseline.games[index].requests, "opt-in preserves exact callback trace")
				context.equal(report.trace.first_divergence, {}, "healthy corrected gameplay never claims divergence")
				context.equal(baseline.peers[index].diagnostics().has("trace"), false, "default report has no payload trace")
			if peer.status().reason == Types.Code.DESYNC:
				observed = true
				_assert_failure(context, fixture, mesh, index, report)
			peer.drain_events()
			peer.drain_transitions()
			baseline.peers[index].drain_events()
			baseline.peers[index].drain_transitions()
		if observed:
			break
	context.equal(observed, name == "real_divergence", "only genuine canonical mismatch freezes evidence")
	context.finish()


func _assert_failure(context: RefCounted, fixture: RefCounted, mesh: Dictionary, index: int, report: Dictionary) -> void:
	var trace: Dictionary = report.trace
	context.equal(trace.first_divergence.frame, 3, "first compared divergent saved boundary")
	context.equal(trace.first_divergence.local_checksum != trace.first_divergence.remote_checksum, true, "real checksum pair retained")
	context.equal(trace.first_divergence.snapshot_available, true, "divergent canonical state retained")
	context.equal(trace.seed, "2", "application seed explicitly owned")
	context.equal(trace.application_version, "p2p-reference-v1", "application version explicitly owned")
	var row: Dictionary = trace.frames.filter(func(value: Dictionary) -> bool: return value.frame == 3)[0]
	var saved: Array = mesh.games[index].requests.filter(func(value: Dictionary) -> bool: return value.kind == "save" and value.frame == 3)
	context.equal(row.state, saved[-1].state_bytes, "actual completed saved canonical bytes")
	context.equal(row.checksum, trace.first_divergence.local_checksum, "trace snapshot matches divergent checksum domain")
	for input: Dictionary in row.inputs:
		context.equal(input.bytes.hex_decode(), fixture._sample(input.player, 3), "corrected original input bytes")
	var serialized: String = JSON.stringify(report)
	for secret: PackedByteArray in [fixture._id(90, 16), fixture._id(index + 20)]:
		context.equal(serialized.contains(secret.hex_encode()), false, "session and connection identities excluded")
	var peer: RefCounted = mesh.peers[index]
	peer.drain_events()
	context.equal(peer.diagnostics().trace, trace, "reserved trace survives saturated event drain")
	trace.frames[0].state = "changed"
	context.equal(peer.diagnostics().trace.frames[0].state != "changed", true, "terminal trace returned with deep ownership")
