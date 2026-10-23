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
const Mixed = preload("res://webrtc_mixed.gd")

class RetainedMixed:
	extends Mixed
	var calls: int = 0
	var traffic_per_call: bool = false
	func service(host: Node) -> bool:
		calls += 1
		if traffic_per_call: host.sent_packets += 1
		return true

class RouteFallback:
	extends "res://addons/fortress_rollback/transport/signalfish_fallback.gd"
	var routed: bool = false
	func status() -> Dictionary:
		return {"pending_packets": 0, "direct": {}, "relay": {}, "relay_peers": ["remote"] if routed else []}

class RouteMixed:
	extends RetainedMixed
	func _init() -> void:
		fallback = RouteFallback.new()
	func service(_host: Node) -> bool:
		calls += 1
		var selected: RouteFallback = fallback as RouteFallback
		selected.routed = not selected.routed
		return true

class BufferedCompletionMixed:
	extends RetainedMixed
	var reply: PackedByteArray
	var sender: PackedByteArray
	func service(host: Node) -> bool:
		calls += 1
		return host.peers[0].receive(reply, sender, host.transport_us, host._next_token()) == I.Code.OK

class RetainedProbe:
	extends ClockProbe
	func _healthy(_final: bool = false) -> bool:
		return errors.is_empty()

class ClockProbe:
	extends "res://host.gd"
	var ticks_us: int = 10000000
	var service_calls: int = 0
	var failed_service_call: int = -1
	var force_service_work: bool = false
	var diagnostic_snapshots: Array[Dictionary] = []

	func _service() -> bool:
		service_calls += 1
		if service_calls == failed_service_call: return false
		var serviced: bool = super._service()
		if force_service_work: _service_had_work = true
		return serviced

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
	if not _check(probe.service_calls == 1, "an idle wait stops after one service"): return
	probe.service_calls = 0
	probe.force_service_work = true
	if not _check(await probe._wait(func() -> bool: return true, true), "a busy wait remains serviceable"): return
	if not _check(probe.service_calls == 8, "a busy wait retains the bounded eight-poll schedule"): return
	probe.service_calls = 0
	probe.force_service_work = true
	probe.failed_service_call = 3
	if not _check(not await probe._wait(func() -> bool: return true, true), "wait preserves a failed transport service"): return
	if not _check(probe.service_calls == 3, "failed service stops the remaining bounded polls"): return
	probe.failed_service_call = -1
	probe.force_service_work = false
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
	var retained: RetainedProbe = RetainedProbe.new()
	retained.clients.append(retained.SDK.new())
	retained.meshes.append(retained.SDKMesh.new())
	retained.peers.append(peer)
	retained.mixed_enabled = true
	var mixed: RetainedMixed = RetainedMixed.new()
	mixed.pending.append(Peer.Packet.new(fixture._id(2), PackedByteArray([1])))
	retained.mixed = mixed
	retained.transport_epoch_us = retained.ticks_us - 400000
	if not _check(retained._service(), "retained mixed transport remains serviceable"): return
	if not _check(peer.network_status().last_now_us == 400000, "retained mixed output cannot suppress actual peer elapsed time"): return
	if not _check(mixed.calls == 1 and mixed.has_pending(), "poll preserves caller-owned mixed batch until service"): return
	if not _mixed_batches(fixture, peer): return
	if not _expired_handshake(fixture, config, lifecycle): return
	retained.meshes[0].free()
	retained.clients[0].free()
	retained.free()
	probe.peers.append(peer)
	probe.player_count = 2
	if not _wait_diagnostics(probe): return
	if not _terminal_diagnostics(peer): return
	probe.free()
	print("WEBRTC_CLOCK_TEST passed")
	quit(0)

func _check(condition: bool, message: String) -> bool:
	if condition: return true
	push_error(message)
	quit(1)
	return false


# Value: protects=terminal witness causes; fails_when=poll rejection discards lifecycle events; why_new=wait snapshots omit terminal polls; seam=actual peer close
func _terminal_diagnostics(peer: Peer) -> bool:
	var probe: RetainedProbe = RetainedProbe.new()
	probe.clients.append(probe.SDK.new())
	probe.meshes.append(probe.SDKMesh.new())
	probe.peers.append(peer)
	probe.mixed_enabled = true
	probe.stage = "peer_drop_agreement"
	probe.mixed = RetainedMixed.new()
	probe.transport_epoch_us = probe.ticks_us - 400002
	peer.close(400001)
	for frame: int in 20:
		peer._publish_event({"kind": "peer_drop_pending", "frame": frame, "peer": PackedByteArray([2])})
	peer._publish_event({"kind": "peer_drop_unconfirmed", "reason": "no_common_window", "peer": PackedByteArray([2])})
	if not _check(peer.status().lifecycle == probe.S.Lifecycle.TERMINATED, "close actual peer before failed service"): return false
	if not _check(not probe._service(), "terminal peer still rejects browser service"): return false
	if not _check(probe.peer_failures.size() == 1, "failed poll retains one terminal snapshot before teardown"): return false
	var snapshot: Dictionary = probe.peer_failures[0]
	if not _check(snapshot.reason == probe.S.Code.TERMINATED and snapshot.poll_code == I.Code.TERMINATED,
		"failure distinguishes the committed terminal cause from poll result"): return false
	if not _check(snapshot.stage == "peer_drop_agreement" and snapshot.events.size() == 16
		and snapshot.events[-1].reason == "no_common_window", "terminal snapshot retains the bounded event tail and exact last cause"): return false
	for event: Dictionary in snapshot.events:
		if not _check(not event.has("peer") and not event.has("bytes"), "terminal diagnostics omit packet and peer byte payloads"): return false
	probe.meshes[0].free()
	probe.clients[0].free()
	probe.free()
	return true


# Value: protects=bounded mixed service batches; fails_when=an idle or a busy route stops the wrong schedule; why_new=the batch rule needs route work; seam=actual mixed service
func _mixed_batches(fixture: Fixture, peer: Peer) -> bool:
	var probe: RetainedProbe = RetainedProbe.new()
	probe.clients.append(probe.SDK.new())
	probe.meshes.append(probe.SDKMesh.new())
	probe.peers.append(peer)
	probe.mixed_enabled = true
	# The completed handshake leaves no pending event, so the route is the only work in the batch.
	peer.drain_events()
	peer.drain_transitions()
	# The shared peer's clock already advanced, so this probe owns the same elapsed epoch.
	probe.transport_epoch_us = probe.ticks_us - 400000
	var mixed: RetainedMixed = RetainedMixed.new()
	mixed.pending.append(Peer.Packet.new(fixture._id(2), PackedByteArray([1])))
	probe.mixed = mixed
	if not _check(probe._service_batch() and mixed.calls == 8, "retained mixed output keeps the bounded service batch"): return false
	mixed.pending.clear()
	mixed.calls = 0
	if not _check(probe._service_batch() and mixed.calls == 1, "empty mixed queues stop after one service"): return false
	mixed.calls = 0
	mixed.traffic_per_call = true
	if not _check(probe._service_batch() and mixed.calls == 8, "physical mixed traffic keeps the bounded service batch"): return false
	mixed.traffic_per_call = false
	var routes: RouteMixed = RouteMixed.new()
	probe.mixed = routes
	if not _check(probe._service_batch() and routes.calls == 8, "mixed route changes keep the bounded service batch"): return false
	probe.meshes[0].free()
	probe.clients[0].free()
	probe.free()
	return true


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


# Value: protects=probe expiry before buffered completion; fails_when=timeout diagnostics are discarded; seam=actual peer poll and retained transport
func _expired_handshake(fixture: Fixture, config: Config, lifecycle: L.Options) -> bool:
	for full_diagnostics: bool in [false, true]:
		for now_us: int in [1000, 1001]:
			if not _handshake_deadline_case(fixture, config, lifecycle, full_diagnostics, now_us): return false
	return true

func _handshake_deadline_case(fixture: Fixture, config: Config, lifecycle: L.Options, full_diagnostics: bool, now_us: int) -> bool:
	var probe: RetainedProbe = RetainedProbe.new()
	var peer: Peer = Peer.new()
	var options: H.Options = H.Options.new()
	options.roundtrips = 1
	options.timeout_us = 1000
	options.retry_interval_us = 1000
	options.max_pending_tokens = 1
	if full_diagnostics: options.max_transitions = 2
	if not _check(peer.configure(config, fixture._local(), Game.new(2), options, I.Options.new(), lifecycle) == I.Code.OK,
		"configure bounded expiring handshake"): return false
	if not _check(peer.begin(0, [probe._next_token()]) == I.Code.OK, "begin expiring handshake"): return false
	var request: RefCounted = fixture._decoded(peer.drain_outbox()[0].bytes)
	var reply: RefCounted = fixture._local(2)
	reply.kind = T.Kind.SYNC_REPLY
	reply.token = request.token
	peer.drain_events()
	if not full_diagnostics: peer.drain_transitions()
	probe.clients.append(probe.SDK.new())
	probe.meshes.append(probe.SDKMesh.new())
	probe.peers.append(peer)
	probe.mixed_enabled = true
	var mixed: BufferedCompletionMixed = BufferedCompletionMixed.new()
	mixed.reply = fixture._encode(reply)
	mixed.sender = fixture._id(2)
	mixed.pending.append(Peer.Packet.new(fixture._id(2), PackedByteArray([1])))
	probe.mixed = mixed
	probe.transport_epoch_us = probe.ticks_us - now_us
	var serviced: bool = probe._service()
	var stopped: bool = not serviced and mixed.calls == 0 and probe.errors.has("peer_sync_timeout")
	var valid: bool = stopped if now_us > options.timeout_us else serviced and mixed.calls == 1 and peer.network_status().state == "running"
	probe.meshes[0].free()
	probe.clients[0].free()
	probe.free()
	return _check(valid, "probe handshake deadline=%d full_diagnostics=%s service=%s calls=%d" % [now_us, full_diagnostics, serviced, mixed.calls])
