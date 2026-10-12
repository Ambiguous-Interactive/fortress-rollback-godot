extends SceneTree

# gdlint: disable=max-returns

# Value: protects=live transport retry deadlines; fails_when=render turns replace elapsed time; why_new=CI slow polling; seam=probe clock ticks
const Fixture = preload("res://clock_fixture.gd")
const H = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const L = preload("res://addons/fortress_rollback/protocol/lifecycle_types.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const Game = preload("res://webrtc_game.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")

class ClockProbe:
	extends "res://host.gd"
	var ticks_us: int = 10000000
	var service_calls: int = 0
	var failed_service_call: int = -1
	var diagnostic_snapshots: Array[Dictionary] = []

	func _service() -> bool:
		service_calls += 1
		return false if service_calls == failed_service_call else super._service()

	func _wait_diagnostic(attempt: int) -> void:
		for peer: Peer in peers:
			diagnostic_snapshots.append(_wait_snapshot(peer, attempt))
		super._wait_diagnostic(attempt)

	func _ticks_usec() -> int:
		return ticks_us

func _initialize() -> void:
	var probe: ClockProbe = ClockProbe.new()
	probe.service_calls = 0
	if not _check(await probe._wait(func() -> bool: return true, true), "actual wait services an immediately ready condition"): return
	if not _check(probe.service_calls == 8, "actual wait selects the tested bounded eight-poll schedule"): return
	probe.service_calls = 0
	probe.failed_service_call = 3
	if not _check(not await probe._wait(func() -> bool: return true, true), "wait preserves a failed transport service"): return
	if not _check(probe.service_calls == 3, "failed service stops the remaining bounded polls"): return
	probe.failed_service_call = -1
	probe.player_count = 8
	var transport_options: RefCounted = probe._direct_options()
	# Bind the actual host selection to the independently exercised eight-peer FIFO workload.
	if not _check(transport_options.max_receives_per_poll == 32,
		"actual host selects the tested slow-mesh receive budget"): return
	if not _check(probe._service(), "initial empty transport service"): return
	var fixture: Fixture = Fixture.new()
	var sink: Fixture.Sink = Fixture.Sink.new()
	var endpoint: RefCounted = fixture._ready(sink)
	if not _check(endpoint.submit(0, PackedByteArray([7]), fixture._statuses(), 2) == I.Code.OK, "retain original input"): return
	endpoint.drain_outbox() # Deliberately lose the first actual INPUT publication.
	var retries: int = 0
	for turn: int in 100:
		probe.ticks_us += 16000 # A slow rendered timer turn is 16ms, not the requested 2ms.
		if not _check(probe._service(), "empty transport service"): return
		if not _check(endpoint.poll(probe.transport_us) == I.Code.OK, "monotonic endpoint poll"): return
		retries += endpoint.drain_outbox().size()
		if turn == 12 and not _check(retries == 1, "lost INPUT must retry after 208ms elapsed, despite only 13 render turns"): return
	if not _check(retries >= 7, "100 slow render turns retain real 1.6s retry progress"): return
	if not _check(endpoint.status().pending_frames == 1, "retry never acknowledges the lost original input"): return
	probe.ticks_us += 9000000 # SDK setup before the next owned handshake epoch must not age its deadlines.
	probe._reset_transport_clock()
	if not _check(probe.transport_us == 0, "new handshake owns a zero elapsed epoch"): return
	probe.ticks_us += 123456
	if not _check(probe._service() and probe.transport_us == 123456, "poll reads elapsed time from the owned epoch"): return
	var peer: Peer = Peer.new()
	var config: Config = Config.new()
	config.local_players = PackedInt32Array([0])
	config.sync_test = false
	config.check_distance = 0
	config.max_snapshot_bytes = 12
	config.storage_budget_bytes = 1048576
	var options: H.Options = H.Options.new()
	options.roundtrips = 1
	var lifecycle: L.Options = L.Options.new()
	lifecycle.enabled = false
	if not _check(peer.configure(config, fixture._local(), Game.new(2), options, I.Options.new(), lifecycle) == I.Code.OK,
		"configure actual peer handshake"): return
	var initial_token: PackedByteArray = probe._next_token()
	if not _check(peer.begin(0, [initial_token]) == I.Code.OK, "begin actual handshake"): return
	peer.drain_outbox() # Lose the initial request at the same public peer boundary as the real browser.
	if not _check(peer.poll(208000) == I.Code.INVALID_ARGUMENT, "missing retry token array reproduces old caller failure"): return
	if not _check(peer.poll(208000, probe._poll_tokens(peer)) == I.Code.OK, "elapsed handshake retry gets caller token array"): return
	var request: RefCounted = fixture._decoded(peer.drain_outbox()[0].bytes)
	if not _check(request.token.size() == 16 and request.token != initial_token, "retry publishes a distinct bounded token"): return
	var reply: RefCounted = fixture._local(2)
	reply.kind = T.Kind.SYNC_REPLY
	reply.token = request.token
	if not _check(peer.receive(fixture._encode(reply), fixture._id(2), 208001, probe._next_token()) == I.Code.OK,
		"receive actual echoed retry token"): return
	if not _check(peer.network_status().state == "running", "lost handshake request recovers and completes"): return
	var callback_token: Variant = probe._next_token.call("remote-uuid")
	if not _check(callback_token is PackedByteArray and callback_token.size() == 16 and callback_token.count(0) < 16
		and callback_token != initial_token and callback_token != request.token, "direct factory UUID callback returns fresh16-byte token"): return
	probe.peers.append(peer)
	probe.player_count = 2
	if not _wait_diagnostics(probe): return
	probe.free()
	print("WEBRTC_CLOCK_TEST passed")
	quit(0)

func _check(condition: bool, message: String) -> bool:
	if condition: return true
	push_error(message)
	quit(1)
	return false


# Value: protects=bounded gameplay stall snapshots; fails_when=only final wait logs or clock/count drift; why_new=retry test omits diagnostic waits; seam=probe clock ticks
func _wait_diagnostics(probe: ClockProbe) -> bool:
	probe.stage = "gameplay"
	var started_us: int = probe.ticks_us
	var schedule: Dictionary = probe._new_wait_diagnostics()
	probe._service_wait_diagnostics(0, schedule)
	probe.ticks_us = started_us + 4999999
	probe._service_wait_diagnostics(1, schedule)
	if not _check(probe.diagnostic_snapshots.is_empty(), "gameplay waits first five elapsed seconds"): return false
	probe.ticks_us += 1
	probe._service_wait_diagnostics(2, schedule)
	if not _check(probe.diagnostic_snapshots.size() == 1, "gameplay diagnostic fires at five second equality"): return false
	var snapshot: Dictionary = probe.diagnostic_snapshots[0]
	if not _check(snapshot.stage == "gameplay" and snapshot.attempt == 2 and snapshot.players == 2, "snapshot identifies actual wait stage"): return false
	if not _check(snapshot.transport_us == probe.ticks_us - probe.transport_epoch_us, "snapshot reports actual elapsed transport clock"): return false
	if not _check(snapshot.endpoints.size() == 1, "snapshot executes actual peer endpoint walk"): return false
	var metadata: Dictionary = snapshot.endpoints.values()[0]
	var fields: Array[String] = ["last_submitted_frame", "last_sent_frame", "last_received_frame", "last_acked_frame", "pending_frames",
		"last_input_progress_us", "peer_statuses", "connect_statuses", "pending_frame_ids"]
	if not _check(metadata.size() == fields.size(), "snapshot contains bounded metadata without input payloads"): return false
	for field: String in fields:
		if not _check(metadata.has(field), "snapshot preserves endpoint field " + field): return false
	probe.ticks_us += 4999999
	probe._service_wait_diagnostics(3, schedule)
	if not _check(probe.diagnostic_snapshots.size() == 1, "repeated diagnostic waits full five seconds"): return false
	for index: int in range(1, 6):
		probe.ticks_us = started_us + 5000000 * (index + 1)
		probe._service_wait_diagnostics(index + 3, schedule)
	if not _check(probe.diagnostic_snapshots.size() == 6, "wait publishes exactly six snapshots"): return false
	probe.ticks_us += 100000000
	probe._service_wait_diagnostics(20, schedule)
	if not _check(probe.diagnostic_snapshots.size() == 6, "long wait cannot exceed six diagnostics"): return false
	probe.diagnostic_snapshots.clear()
	schedule = probe._new_wait_diagnostics()
	probe._service_wait_diagnostics(0, schedule)
	if not _check(probe.diagnostic_snapshots.is_empty(), "new gameplay wait owns a fresh delayed schedule"): return false
	probe.stage = "final_confirmation"
	schedule = probe._new_wait_diagnostics()
	probe._service_wait_diagnostics(0, schedule)
	if not _check(probe.diagnostic_snapshots.size() == 1, "final confirmation preserves immediate diagnostic"): return false
	if not _check(probe.diagnostic_snapshots[0].stage == "final_confirmation", "final snapshot preserves stage"): return false
	probe.stage = "handshake"
	probe.ticks_us += 10000000
	probe._service_wait_diagnostics(1, schedule)
	if not _check(probe.diagnostic_snapshots.size() == 1, "other waits do not emit stall snapshots"): return false
	return true
