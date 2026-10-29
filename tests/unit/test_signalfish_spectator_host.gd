extends RefCounted

const HostRelay = preload("res://addons/fortress_rollback/transport/signalfish_spectator_host.gd")
const Viewer = preload("res://tests/unit/test_signalfish_spectator_relay.gd")
const PublisherFixture = preload("res://tests/unit/test_spectator_publisher.gd")
const Fixture = preload("res://tests/unit/test_spectator_session.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const GameFixture = preload("res://tests/unit/test_driver.gd")
const StatusFixture = preload("res://tests/unit/test_spectator_status.gd")
const Stream = preload("res://addons/fortress_rollback/core/spectator_stream.gd")
const S = preload("res://addons/fortress_rollback/core/session_types.gd")
const HOST: String = Viewer.HOST
const VIEWER: String = Viewer.FOREIGN


class Helper:
	extends PublisherFixture

	func _identity() -> PackedByteArray:
		return Viewer.StreamFixture.new()._identity()


class Client:
	extends Viewer.Client
	signal room_left
	signal room_joined
	signal connection_failed
	signal reconnected
	signal authentication_error
	signal reconnection_failed
	var buffered: int = 0
	var outcome: Variant = OK
	var on_send: Callable
	var on_buffered: Callable
	var sent: Array[PackedByteArray] = []
	var attempted: Array[PackedByteArray] = []

	func _init() -> void:
		state = HostRelay.FINALIZED
		player = HOST

	func get_buffered_amount() -> int:
		if on_buffered.is_valid():
			on_buffered.call()
		return buffered

	func send_game_data_binary(packet: PackedByteArray) -> Variant:
		attempted.append(packet.duplicate())
		if on_send.is_valid():
			on_send.call(packet)
		if outcome is int and outcome == OK:
			sent.append(packet.duplicate())
		return outcome


func cases() -> PackedStringArray:
	return PackedStringArray(
		[
			"startup",
			"canonical_playback",
			"corrected_drop_history",
			"pressure",
			"lifetimes",
			"configuration",
			"sdk_numbers",
			"reentry",
			"history_loss",
			"player_coexistence",
			"active_requests",
			"fair_liveness",
			"finish_retry",
			"callback_lifetimes",
			"setup_callbacks",
			"viewer_departures"
		]
	)


func run_case(name: String, context: RefCounted) -> void:
	call("_" + name, context)
	context.finish()


func _fixture(context: RefCounted, negotiate: bool = true, sends: int = 2, predicting: bool = false) -> Dictionary:
	var helper: RefCounted = Helper.new()
	var host: RefCounted = Session.new()
	var host_config: RefCounted = helper._config()
	if predicting:
		host_config.local_players = PackedInt32Array([0])
		host_config.max_prediction_frames = 2
		host_config.history_slots = 3
	context.equal(host.configure(host_config), S.Code.OK, "configured unchanged player host")
	var client: Client = Client.new()
	var config: RefCounted = Viewer.RelayFixture.SDKConfig.new()
	var info: RefCounted = Viewer.Info.new()
	var options: HostRelay.Options = HostRelay.Options.new()
	options.max_packet_bytes = 128
	options.max_sends_per_poll = sends
	options.max_socket_buffered_bytes = 256
	options.offer_retry_us = 10
	options.keepalive_interval_us = 10
	var relay: HostRelay = HostRelay.new()
	context.equal(
		relay.configure(client, config, info, host, VIEWER, helper._identity(), helper._key(), helper._digest(), options), HostRelay.Code.OK, "host publication configured"
	)
	var viewer: Dictionary = Viewer.new()._fixture(context, false, 2, 8)
	var fixture: Dictionary = {
		"host": host,
		"client": client,
		"config": config,
		"info": info,
		"options": options,
		"relay": relay,
		"viewer": viewer,
		"driver": Driver.new(host, GameFixture.Game.new()),
		"helper": helper
	}
	if negotiate:
		context.equal(relay.poll(0).sent, 1, "SDK sends original offer")
		_deliver(fixture)
		var accept: Callable = func(packet: PackedByteArray) -> int: return OK if relay.receive_accept(VIEWER, packet).code == HostRelay.Code.OK else FAILED
		context.equal(viewer.relay.poll(1, accept).code, HostRelay.Code.OK, "separate authenticated acceptance reaches original publisher")
	return fixture


func _deliver(fixture: Dictionary) -> void:
	for packet: PackedByteArray in fixture.client.sent:
		fixture.viewer.client.game_data_binary_received.emit(HOST, 1, packet)
	fixture.client.sent.clear()


func _stop(fixture: Dictionary) -> void:
	fixture.client.on_send = Callable()
	fixture.client.on_buffered = Callable()
	fixture.relay.detach()
	fixture.viewer.relay.detach()


# Value: protects=real receipt before rows and owned offer retry; fails_when=SDK acceptance substitutes for viewer agreement; why_new=first host SDK bridge; seam=SDK public API
func _startup(context: RefCounted) -> void:
	var fixture: Dictionary = _fixture(context, false)
	fixture.helper._step(context, fixture.driver, 0)
	fixture.client.outcome = ERR_BUSY
	context.equal(fixture.relay.poll(0).code, HostRelay.Code.BACKPRESSURE, "refused first offer stays retryable")
	var offer: PackedByteArray = fixture.client.attempted[0].duplicate()
	fixture.client.outcome = OK
	context.equal(fixture.relay.poll(0).sent, 1, "refusal does not consume retry interval")
	context.equal(fixture.client.sent[0], offer, "exact original offer retry")
	context.equal(fixture.relay.poll(9).sent, 0, "accepted offer waits below retry interval")
	context.equal(fixture.relay.poll(10).sent, 1, "lost offer retries at interval equality")
	context.equal(fixture.relay.status().next_frame, 0, "transport acceptance cannot authorize rows")
	_deliver(fixture)
	fixture.viewer.relay.poll(1)
	var accept: PackedByteArray = fixture.viewer.stream.encode_accept()
	context.equal(fixture.relay.receive_accept(HOST, accept).code, HostRelay.Code.WRONG_SOURCE, "key alone cannot admit another UUID")
	context.equal(fixture.relay.status().agreed_version, 0, "wrong control identity is inert")
	context.equal(fixture.relay.receive_accept(VIEWER, accept).code, HostRelay.Code.OK, "authenticated viewer receipt agrees")
	context.equal(fixture.relay.poll(10).sent, 1, "first row follows receipt")
	context.equal(fixture.relay.poll(9).code, HostRelay.Code.INVALID_ARGUMENT, "clock cannot run backwards")
	_stop(fixture)


# Value: protects=canonical SDK playback; fails_when=cursor skips or player confirmation changes; why_new=receive-only tests bypass sender; seam=SDK API
func _canonical_playback(context: RefCounted) -> void:
	var fixture: Dictionary = _fixture(context)
	var expected: int = 0
	for frame: int in range(12):
		fixture.helper._step(context, fixture.driver, frame)
		var confirmed: int = fixture.host.status().confirmed_frame
		context.equal(fixture.relay.poll(frame + 1).sent, 1, "one original confirmed row sent")
		_deliver(fixture)
		context.equal(fixture.viewer.relay.poll(frame + 2).received, 1, "actual SDK attributed row delivered")
		context.equal(fixture.viewer.driver.step(frame, Viewer.new()._empty()).code, S.Code.OK, "viewer plays original row")
		for player: int in range(2):
			expected = expected * 3 + Fixture.new()._row(frame)[player][0] + frame
		context.equal(fixture.viewer.game.value, expected, "independent canonical state through both bridges")
		context.equal(fixture.host.status().confirmed_frame, confirmed, "spectator never participates in player confirmation")
	context.equal(fixture.relay.finish_host().code, HostRelay.Code.OK, "freeze fully confirmed tail")
	context.equal(fixture.relay.poll(13).sent, 1, "send END after complete prefix")
	_deliver(fixture)
	fixture.viewer.relay.poll(14)
	context.equal(fixture.viewer.driver.step(12, Viewer.new()._empty()).code, S.Code.TERMINATED, "viewer drains exact final tail")
	context.equal(fixture.relay.poll(100).sent, 0, "accepted END stops liveness")
	_stop(fixture)


# Value: protects=corrected disconnected history across both SDK bridges; fails_when=statuses disappear under retained-row pressure;
# why_new=SDK playback ignores statuses and core drop playback bypasses SDK pressure; seam=public SDK API
func _corrected_drop_history(context: RefCounted) -> void:
	var fixture: Dictionary = _fixture(context, true, 1, true)
	var host_game: RefCounted = StatusFixture.Game.new()
	fixture.driver = Driver.new(fixture.host, host_game)
	fixture.viewer.game = StatusFixture.Game.new()
	fixture.viewer.driver = Driver.new(fixture.viewer.stream.playback_session(), fixture.viewer.game)
	var viewer: RefCounted = fixture.viewer.stream.playback_session()
	context.equal(viewer.set_playback(1, 1, 2), S.Code.OK, "hold one confirmed row while viewing")
	context.equal(fixture.host.receive_input(1, 0, PackedByteArray([7])).code, S.Code.OK, "original remote input before departure")
	for frame: int in range(2):
		var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, frame, PackedByteArray([frame + 1]))]
		context.equal(fixture.driver.step(frame, samples).code, S.Code.OK, "host predicts original remote tail")
	context.equal(fixture.relay.poll(2).sent, 1, "only finalized prefix reaches spectator SDK")
	_deliver(fixture)
	context.equal(fixture.viewer.relay.poll(3).received, 1, "viewer buffers original pre-drop prefix")
	context.equal(viewer.recommended_steps(), 0, "delay preserves paused prefix")
	context.equal(fixture.host.freeze_player(1, 0), S.Code.OK, "freeze departed input at original cut")
	context.equal(fixture.driver.recover(2).code, S.Code.OK, "repair predicted status without another sample")
	context.equal(fixture.host.statistics().rollback_count > 0, true, "host actually restores corrected history")
	fixture.client.outcome = ERR_BUSY
	context.equal(fixture.relay.poll(4).code, HostRelay.Code.BACKPRESSURE, "corrected status row meets real SDK refusal")
	var retained: PackedByteArray = fixture.client.attempted[-1].duplicate()
	context.equal(retained[5], Stream.ROW, "refused bytes are gameplay history")
	context.equal(retained.slice(Stream.HEADER_BYTES), PackedByteArray([2, 7, 1, 3]), "signed retained row includes disconnected status")
	for frame: int in range(2, 7):
		var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, frame, PackedByteArray([frame + 1]))]
		context.equal(fixture.driver.step(frame, samples).code, S.Code.OK, "seated host continues while spectator transport refuses")
	context.equal(fixture.host.confirmed_inputs(1), null, "original prepared row is physically evicted")
	context.equal(fixture.relay.status().next_frame, 1, "refusal preserves exact publication cursor")
	context.equal(viewer.status().current_frame, 0, "buffered viewer never advances itself")
	fixture.client.outcome = OK
	var expected: int = 0
	for frame: int in range(1, 7):
		var confirmed: int = fixture.host.status().confirmed_frame
		context.equal(fixture.relay.poll(4 + frame).sent, 1, "one retained original row accepted within send budget")
		if frame == 1:
			context.equal(fixture.client.sent[0], retained, "exact signed row survives source ring reuse")
		_deliver(fixture)
		context.equal(fixture.viewer.relay.poll(5 + frame).received, 1, "viewer bridge receives finalized original row")
		context.equal(viewer.recommended_steps(), 1, "delayed viewer advances one available original frame")
		context.equal(fixture.viewer.driver.step(frame, Viewer.new()._empty()).code, S.Code.OK, "viewer consumes corrected status history")
		expected = _drop_boundary(expected, frame - 1)
		context.equal(fixture.viewer.game.value, expected, "independent status-sensitive canonical boundary")
		var exported: S.FrameInputs = viewer.confirmed_inputs(frame - 1)
		context.equal(exported.read(1).status, 1 if frame == 1 else 3, "viewed exports preserve pre/post-drop status")
		context.equal(fixture.host.status().confirmed_frame, confirmed, "spectator receipt leaves seated confirmation unchanged")
	context.equal(fixture.relay.finish_host().code, HostRelay.Code.OK, "freeze continued fully confirmed host ending")
	context.equal(fixture.relay.poll(11).sent, 1, "END follows every original row")
	_deliver(fixture)
	context.equal(fixture.viewer.relay.poll(12).received, 1, "authenticated END releases remaining delayed row")
	context.equal(fixture.viewer.driver.step(7, Viewer.new()._empty()).code, S.Code.OK, "consume complete corrected final tail")
	expected = _drop_boundary(expected, 6)
	context.equal(fixture.viewer.game.value, expected, "viewer reaches independently calculated original final state")
	context.equal(host_game.value, expected, "repaired player host agrees with original final state")
	context.equal(fixture.viewer.driver.step(8, Viewer.new()._empty()).code, S.Code.TERMINATED, "normal service completes clean corrected match")
	context.equal(viewer.is_complete(), true, "input closure and actual completion remain distinct")
	context.equal(fixture.viewer.relay.status().received_bytes, 0, "all owned ingress bytes release after completion")
	_stop(fixture)


func _drop_boundary(previous: int, frame: int) -> int:
	var value: int = (previous * 17 + frame + 1 + 31 + frame) % 1000000007
	return (value * 17 + 7 + (1 if frame == 0 else 3) * 31 + frame) % 1000000007


# Value: protects=refused rows and liveness; fails_when=pressure loses history or suppresses pulse; why_new=core tests omit SDK policy; seam=SDK API
func _pressure(context: RefCounted) -> void:
	var fixture: Dictionary = _fixture(context)
	fixture.helper._step(context, fixture.driver, 0)
	fixture.client.outcome = ERR_BUSY
	context.equal(fixture.relay.poll(1).code, HostRelay.Code.BACKPRESSURE, "SDK row refusal retains cursor")
	var original: PackedByteArray = fixture.client.attempted[-1].duplicate()
	for frame: int in range(1, 6):
		fixture.helper._step(context, fixture.driver, frame)
	fixture.client.outcome = OK
	context.equal(fixture.host.confirmed_inputs(0) == null, true, "source ring evicts prepared row")
	context.equal(fixture.relay.poll(2).sent, 2, "bounded turn accepts retained row and next row")
	context.equal(fixture.client.sent[0], original, "original refused bytes survive host wrap")
	fixture.client.buffered = 256
	var attempts: int = fixture.client.attempted.size()
	context.equal(fixture.relay.poll(3).code, HostRelay.Code.BACKPRESSURE, "socket pressure checked before SDK call")
	context.equal(fixture.client.attempted.size(), attempts, "full socket does not invoke send")
	fixture.client.buffered = 0
	fixture.client.outcome = ERR_OUT_OF_MEMORY
	context.equal(fixture.relay.poll(12).code, HostRelay.Code.BACKPRESSURE, "recoverable allocation pressure retains exact row")
	context.equal(fixture.client.attempted[-1][5], Stream.KEEPALIVE, "blocked rows leave independent liveness opportunity")
	fixture.client.on_send = func(packet: PackedByteArray) -> void: fixture.client.outcome = OK if packet[5] == Stream.KEEPALIVE else ERR_BUSY
	var live: RefCounted = fixture.relay.poll(12)
	context.equal(live.code, HostRelay.Code.BACKPRESSURE, "row refusal remains visible alongside heartbeat success")
	context.equal(live.sent, 1, "independent heartbeat reaches SDK despite row refusal")
	context.equal(fixture.client.sent[-1][5], Stream.KEEPALIVE, "actual accepted packet carries only liveness")
	context.equal(fixture.relay.status().next_frame, 2, "refused row and pulse never skip source cursor")
	_stop(fixture)


func _lifetimes(context: RefCounted) -> void:
	for change: String in ["room", "player", "disconnect", "source", "signal", "raw"]:
		var fixture: Dictionary = _fixture(context)
		fixture.helper._step(context, fixture.driver, 0)
		match change:
			"room":
				fixture.client.room = "replacement"
			"player":
				fixture.client.player = VIEWER
			"disconnect":
				fixture.client.connection = 0
			"source":
				fixture.host.configure(fixture.helper._config())
			"signal":
				fixture.client.spectator_left.emit("room-one", "ROOM", 0, [])
			"raw":
				fixture.config.decode_msgpack_payloads = true
		context.equal(fixture.relay.poll(1).code != HostRelay.Code.OK, true, "replacement fences publication: " + change)
		context.equal(fixture.client.sent.is_empty(), true, "no bytes leave invalid lifetime")
		context.equal(fixture.host.status().lifecycle, S.Lifecycle.RUNNING, "publication failure does not terminate player gameplay")
		_stop(fixture)


# Value: protects=real SDK protocol metadata configures publication; fails_when=raw JSON floats replace authoritative typed properties; seam=public SDK shape
func _sdk_numbers(context: RefCounted) -> void:
	for field: String in ["protocol_version", "max_outbound_message_size"]:
		var values: Array = [3, 2, 3.5, false, "3", NAN, INF] if field == "protocol_version" else [4096, 256, 255, 4096.5, false, "4096", NAN, INF]
		for value: Variant in values:
			var fixture: Dictionary = _fixture(context, false)
			fixture.relay.detach()
			var info: Viewer.JSONInfo = Viewer.JSONInfo.new()
			info.set(field, value)
			var allowed: bool = value is int and value >= (3 if field == "protocol_version" else 256)
			var code: int = fixture.relay.configure(
				fixture.client, fixture.config, info, fixture.host, VIEWER, fixture.helper._identity(), fixture.helper._key(), fixture.helper._digest(), fixture.options
			)
			var rejected: int = HostRelay.Code.INCOMPATIBLE_MODE if field == "protocol_version" else HostRelay.Code.TOO_LARGE
			context.equal(code, HostRelay.Code.OK if allowed else rejected, "typed SDK property controls publication: " + field)
			_stop(fixture)


func _configuration(context: RefCounted) -> void:
	for field: String in ["role", "capability", "size", "identity", "viewer"]:
		var fixture: Dictionary = _fixture(context, false)
		fixture.relay.detach()
		var identity: PackedByteArray = fixture.helper._identity()
		var viewer: String = VIEWER
		match field:
			"role":
				fixture.client.state = HostRelay.ViewerRelay.SPECTATING
			"capability":
				fixture.info.capabilities.clear()
			"size":
				fixture.config.max_outbound_frame_bytes = 1
			"identity":
				identity.resize(1)
			"viewer":
				viewer = HOST
		context.equal(
			(
				fixture.relay.configure(
					fixture.client, fixture.config, fixture.info, fixture.host, viewer, identity, fixture.helper._key(), fixture.helper._digest(), fixture.options
				)
				!= HostRelay.Code.OK
			),
			true,
			"invalid host configuration refused: " + field
		)
		context.equal(fixture.relay.poll(0).sent, 0, "rejected configuration sends nothing")
		_stop(fixture)


func _reentry(context: RefCounted) -> void:
	for action: String in ["reenter", "detach", "room", "malformed", "getter"]:
		var fixture: Dictionary = _fixture(context)
		fixture.helper._step(context, fixture.driver, 0)
		fixture.client.on_send = func(packet: PackedByteArray) -> void:
			match action:
				"reenter":
					context.equal(fixture.relay.poll(1).code, HostRelay.Code.INVALID_ARGUMENT, "SDK callback cannot reenter publication")
					context.equal(fixture.relay.finish_host().code, HostRelay.Code.WRONG_STATE, "callback cannot freeze publication")
				"detach":
					fixture.relay.detach()
				"room":
					fixture.client.room = "replacement"
				"malformed":
					fixture.client.outcome = true
			packet.fill(0)
		if action == "getter":
			fixture.client.on_buffered = func() -> void: fixture.relay.detach()
		var attempts: int = fixture.client.attempted.size()
		var result: RefCounted = fixture.relay.poll(1)
		if action == "getter":
			context.equal(fixture.client.attempted.size(), attempts, "buffer getter invalidation prevents stale SDK send")
		context.equal(
			result.code,
			HostRelay.Code.OK if action == "reenter" else (HostRelay.Code.SDK_FAILURE if action == "malformed" else HostRelay.Code.WRONG_STATE),
			"recheck SDK callback result and lifetime"
		)
		context.equal(fixture.host.status().lifecycle, S.Lifecycle.RUNNING, "callback invalidation leaves player host running")
		if action == "reenter":
			context.equal(fixture.relay.status().next_frame, 1, "callback mutation cannot change retained acknowledgement")
		_stop(fixture)


func _history_loss(context: RefCounted) -> void:
	var fixture: Dictionary = _fixture(context)
	for frame: int in range(8):
		fixture.helper._step(context, fixture.driver, frame)
	var result: RefCounted = fixture.relay.poll(1)
	context.equal(result.code, HostRelay.Code.PEER_FAILURE, "overwritten next source row fails publication explicitly")
	context.equal(result.peer_code, S.Code.HISTORY_UNAVAILABLE, "specific missing-history cause retained")
	context.equal(fixture.client.sent.is_empty(), true, "missing history cannot be replaced with plausible later rows")
	context.equal(fixture.host.status().lifecycle, S.Lifecycle.RUNNING, "spectator failure leaves gameplay live")
	_stop(fixture)


# Value: protects=player-session isolation from spectator broadcasts; fails_when=FRGS enters player clocks or confirmation; why_new=first shared send path; seam=SDK signals
func _player_coexistence(context: RefCounted) -> void:
	var fixture: Dictionary = _fixture(context)
	var helper: RefCounted = Viewer.RelayFixture.new()
	var players: Dictionary = helper._build(context)
	var before: Dictionary = players.peer.network_status().duplicate(true)
	var confirmed: int = players.peer.status().confirmed_frame
	fixture.helper._step(context, fixture.driver, 0)
	fixture.relay.poll(1)
	for packet: PackedByteArray in fixture.client.sent:
		players.client.game_data_binary_received.emit(HOST, 1, packet)
	context.equal(players.relay.status().received_packets, 0, "FRGS broadcast never occupies player receive capacity")
	context.equal(players.relay.poll(50).code, HostRelay.Code.OK, "player bridge remains live after foreign envelope")
	context.equal(players.peer.network_status(), before, "spectator bytes do not touch player protocol clocks or state")
	context.equal(players.peer.status().confirmed_frame, confirmed, "spectator broadcast cannot advance player confirmation")
	helper._destroy(players)
	_stop(fixture)


# Value: protects=host request guard; fails_when=outstanding requests permit SDK sends; why_new=core tests omit SDK order; seam=SDK API
func _active_requests(context: RefCounted) -> void:
	_getter_requests(context)
	var fixture: Dictionary = _fixture(context)
	fixture.helper._step(context, fixture.driver, 0)
	for player: int in range(2):
		fixture.host.submit_local_input(player, 1, Fixture.new()._row(1)[player])
	var batch: S.Result = fixture.host.begin_advance()
	context.equal(batch.code, S.Code.READY, "host has an outstanding expert request")
	var attempts: int = fixture.client.attempted.size()
	context.equal(fixture.relay.poll(1).code, HostRelay.Code.BACKPRESSURE, "outstanding host requests defer SDK sends")
	context.equal(fixture.client.attempted.size(), attempts, "active host cannot enter SDK callback")
	context.equal(fixture.relay.finish_host().code, HostRelay.Code.BACKPRESSURE, "active host cannot freeze publication")
	var request: S.Request = batch.batch.next_request()
	context.equal(fixture.host.complete_request(request.batch_id, request.request_id, true).code, S.Code.OK, "release host request")
	context.equal(fixture.relay.poll(1).sent, 2, "original rows publish after request completes")
	_stop(fixture)


# Value: protects=SDK getters cannot send through newly active host requests; fails_when=BUSY is ignored after callbacks;
# why_new=preexisting active requests do not cross a getter; seam=public SDK callback
func _getter_requests(context: RefCounted) -> void:
	for kind: int in [Stream.OFFER, Stream.ROW, Stream.END]:
		for open_request: bool in [false, true]:
			var fixture: Dictionary = _fixture(context, kind != Stream.OFFER, 1)
			if kind == Stream.ROW:
				fixture.helper._step(context, fixture.driver, 0)
			elif kind == Stream.END:
				context.equal(fixture.relay.finish_host().code, HostRelay.Code.OK, "close empty original host")
			var next_frame: int = fixture.host.status().current_frame
			var expected: PackedByteArray = (
				Stream.encode_offer(fixture.helper._identity(), fixture.helper._digest(), 2, 1, fixture.helper._key())
				if kind == Stream.OFFER
				else fixture.viewer.stream.encode_row(0, Fixture.new()._row(0))
			)
			for player: int in range(2):
				context.equal(fixture.host.submit_local_input(player, next_frame, Fixture.new()._row(next_frame)[player]).code, S.Code.OK, "stage real next host input")
			var batches: Array[RefCounted] = []
			fixture.client.on_buffered = func() -> void:
				if open_request and batches.is_empty():
					var batch: S.Result = fixture.host.begin_advance()
					context.equal(batch.code, S.Code.READY, "SDK getter opens real host expert request")
					batches.append(batch.batch)
			var before: int = fixture.client.attempted.size()
			var result: RefCounted = fixture.relay.poll(1)
			context.equal(result.code, HostRelay.Code.BACKPRESSURE if open_request else HostRelay.Code.OK, "getter pressure stays retryable")
			context.equal(fixture.client.attempted.size() - before, 0 if open_request else 1, "SDK send waits for newly opened host request")
			context.equal(result.sent, 0 if open_request else 1, "publication reports actual accepted sends")
			if open_request:
				context.equal(fixture.relay.status().next_frame, 0, "busy getter cannot consume original packet")
				fixture.client.on_buffered = Callable()
				var request: S.Request = batches[0].next_request()
				context.equal(fixture.host.complete_request(request.batch_id, request.request_id, true).code, S.Code.OK, "release original host batch")
				if kind != Stream.END:
					context.equal(fixture.relay.poll(1).sent, 1, "original pending packet retries at the same time")
					context.equal(fixture.client.sent[-1], expected, "retry retains exact original packet bytes")
			_stop(fixture)


# Value: protects=final-tail liveness with one send slot; fails_when=refused rows or END starve pulses; why_new=pressure covers two-slot row only; seam=SDK API
func _fair_liveness(context: RefCounted) -> void:
	for kind: int in [Stream.ROW, Stream.END]:
		for sends: int in [1, 2]:
			for pulse_accepted: bool in [false, true]:
				var fixture: Dictionary = _fixture(context, true, sends)
				if kind == Stream.ROW:
					fixture.helper._step(context, fixture.driver, 0)
				else:
					context.equal(fixture.relay.finish_host().code, HostRelay.Code.OK, "empty host freezes END")
				var accept_payload: Array[bool] = [false]
				fixture.client.on_send = func(packet: PackedByteArray) -> void:
					var accepted: bool = pulse_accepted if packet[5] == Stream.KEEPALIVE else accept_payload[0]
					fixture.client.outcome = OK if accepted else ERR_BUSY
				var original: PackedByteArray
				var pulses: int = 0
				var payloads: int = 0
				for turn: int in range(8):
					var before: int = fixture.client.attempted.size()
					fixture.relay.poll(10 + turn * 10)
					context.equal(fixture.client.attempted.size() - before <= sends, true, "both kinds share exact attempt budget")
					for packet: PackedByteArray in fixture.client.attempted.slice(before):
						if packet[5] == Stream.KEEPALIVE:
							pulses += 1
						else:
							payloads += 1
							if original.is_empty():
								original = packet.duplicate()
							context.equal(packet, original, "every refused payload retries exact original bytes")
				context.equal(pulses >= 3, true, "refused ROW and END cannot starve liveness at minimum budget")
				context.equal(payloads >= 3, true, "refused heartbeat cannot permanently starve original payload")
				var accepted_pulses: int = 0
				for packet: PackedByteArray in fixture.client.sent:
					if packet[5] == Stream.KEEPALIVE:
						accepted_pulses += 1
				context.equal(accepted_pulses, pulses if pulse_accepted else 0, "timely pulse attempts reach exact SDK acceptance")
				context.equal(fixture.relay.status().next_frame, 0, "liveness never consumes the refused original packet")
				accept_payload[0] = true
				for turn: int in range(4):
					fixture.relay.poll(90 + turn)
				var delivered: bool = false
				for packet: PackedByteArray in fixture.client.sent:
					if packet[5] == kind:
						delivered = true
						context.equal(packet, original, "eventual acceptance receives original retained packet")
				context.equal(delivered, true, "original payload eventually sends despite pulse refusals")
				if kind == Stream.END:
					context.equal(fixture.relay.poll(100).sent, 0, "accepted END stops further liveness")
				_stop(fixture)


# Value: protects=retryable clean host finish; fails_when=unconfirmed or uncorrected tails report peer failure; why_new=clean-end test starts fully confirmed; seam=none
func _finish_retry(context: RefCounted) -> void:
	for pending_repair: bool in [false, true]:
		var fixture: Dictionary = _fixture(context, true, 2, pending_repair)
		var frames: int = 2 if pending_repair else 1
		if pending_repair:
			context.equal(fixture.host.receive_input(1, 0, Fixture.new()._row(0)[1]).code, S.Code.OK, "real initial remote input")
			for frame: int in range(frames):
				var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, frame, Fixture.new()._row(frame)[0])]
				context.equal(fixture.driver.step(frame, samples).code, S.Code.OK, "host advances actual then predicted remote input")
			context.equal(fixture.host.receive_input(1, 1, Fixture.new()._row(1)[1]).code, S.Code.OK, "differing late input confirms history")
			context.equal(fixture.host.status().pending_rollback_frame, 1, "actual late input requires real correction")
		else:
			context.equal(fixture.host.set_confirmation_limit(-1).code, S.Code.OK, "hold genuine mesh confirmation")
			fixture.helper._step(context, fixture.driver, 0)
		var refused: RefCounted = fixture.relay.finish_host()
		context.equal(refused.code, HostRelay.Code.BACKPRESSURE, "unfinished confirmation or repair keeps clean finish retryable")
		context.equal(refused.peer_code, S.Code.PREDICTION_STALL, "specific unfinished-tail cause preserved")
		context.equal(fixture.relay.status().code, HostRelay.Code.OK, "recoverable finish leaves publication live")
		if pending_repair:
			context.equal(fixture.driver.recover(2).code, S.Code.OK, "repair confirms original exposed prefix without advancing")
		else:
			context.equal(fixture.host.set_confirmation_limit(0).code, S.Code.OK, "release genuine mesh confirmation")
		context.equal(fixture.relay.finish_host().code, HostRelay.Code.OK, "same host clean finish succeeds after recovery")
		for now_us: int in [3, 4]:
			fixture.relay.poll(now_us)
			_deliver(fixture)
			context.equal(fixture.viewer.relay.poll(now_us + 1).code, HostRelay.Code.OK, "original corrected rows precede exact END")
		var expected: int = 0
		for frame: int in range(frames):
			context.equal(fixture.viewer.driver.step(frame, Viewer.new()._empty()).code, S.Code.OK, "viewer plays complete original prefix")
			for player: int in range(2):
				expected = expected * 3 + Fixture.new()._row(frame)[player][0] + frame
		context.equal(fixture.viewer.game.value, expected, "independent final state includes corrected original input")
		context.equal(fixture.viewer.driver.step(frames, Viewer.new()._empty()).code, S.Code.TERMINATED, "clean END follows exact recovered prefix")
		_stop(fixture)


# Value: protects=host publication lifetime across synchronous SDK callbacks; fails_when=setup misses signals or gates clear them;
# why_new=ordinary lifetimes emit outside SDK getters; seam=public SDK signals/getters
func _callback_lifetimes(context: RefCounted) -> void:
	for boundary: String in ["protocol", "setup_room", "runtime_room"]:
		for signal_name: String in HostRelay.ViewerRelay.LIFETIME_SIGNALS:
			for invalidated: bool in [false, true]:
				var fixture: Dictionary = _fixture(context, false)
				if boundary != "runtime_room":
					fixture.relay.detach()
				var callback: Callable = func() -> void:
					if invalidated:
						match signal_name:
							"spectator_left":
								fixture.client.spectator_left.emit("room-one", "ROOM", 0, [])
							"spectator_joined":
								fixture.client.spectator_joined.emit(RefCounted.new())
							"disconnected":
								fixture.client.disconnected.emit(0, "ended")
							_:
								fixture.client.emit_signal(signal_name)
				if boundary == "protocol":
					fixture.info.on_info = callback
				else:
					fixture.client.on_room = callback
				var expected: int = HostRelay.Code.WRONG_STATE if invalidated else HostRelay.Code.OK
				if boundary != "runtime_room":
					context.equal(_configure_again(fixture), expected, "setup observes lifetime signal: " + boundary + "/" + signal_name)
					for lifetime_signal: String in HostRelay.ViewerRelay.LIFETIME_SIGNALS:
						context.equal(fixture.client.get_signal_connection_list(lifetime_signal).size(), 0 if invalidated else 1, "temporary setup listeners released")
				var result: RefCounted = fixture.relay.poll(0)
				context.equal(result.code, expected, "poll preserves lifetime failure: " + boundary + "/" + signal_name)
				context.equal(result.sent, 0 if invalidated else 1, "invalid lifetime sends no OFFER")
				context.equal(fixture.client.sent.size(), 0 if invalidated else 1, "SDK sends agree with diagnostics")
				context.equal(fixture.relay.status().code, expected, "status cannot clear failure")
				context.equal(fixture.relay.finish_host().code, expected, "finalization cannot revive invalid lifetime")
				if invalidated:
					context.equal(fixture.relay.receive_accept(VIEWER, PackedByteArray()).code, expected, "acceptance cannot revive invalid lifetime")
				context.equal(fixture.host.status().lifecycle, S.Lifecycle.RUNNING, "publication failure leaves player host running")
				fixture.relay.detach()
				context.equal(_configure_again(fixture), HostRelay.Code.OK, "explicit fresh publication recovers")
				context.equal(fixture.relay.poll(0).sent, 1, "new publication sends fresh OFFER")
				fixture.helper._step(context, fixture.driver, 0)
				_stop(fixture)


func _configure_again(fixture: Dictionary) -> int:
	return fixture.relay.configure(
		fixture.client, fixture.config, fixture.info, fixture.host, VIEWER, fixture.helper._identity(), fixture.helper._key(), fixture.helper._digest(), fixture.options
	)


# Value: protects=setup recursion, detach and frozen options; fails_when=callbacks install stale publication or retain listeners;
# why_new=signal controls omit recursive setup and caller mutation; seam=public SDK callbacks
func _setup_callbacks(context: RefCounted) -> void:
	for boundary: String in ["protocol", "room"]:
		for action: String in ["reentry", "detach", "replace", "options", "malformed_signal"]:
			var fixture: Dictionary = _fixture(context, false)
			fixture.relay.detach()
			var callback: Callable = func() -> void:
				if action in ["detach", "replace"]:
					fixture.relay.detach()
				if action in ["reentry", "replace"]:
					context.equal(_configure_again(fixture), HostRelay.Code.WRONG_STATE, "recursive setup cannot install publication")
				if action == "options":
					fixture.options.max_sends_per_poll = 0
				if action == "malformed_signal":
					fixture.client.spectator_left.emit("room-one", "ROOM", 0, [])
					fixture.info.capabilities.clear()
			if boundary == "protocol":
				fixture.info.on_info = callback
			else:
				fixture.client.on_room = callback
			var accepted: bool = action in ["reentry", "options"]
			context.equal(_configure_again(fixture), HostRelay.Code.OK if accepted else HostRelay.Code.WRONG_STATE, "only uninterrupted setup installs publication")
			for signal_name: String in HostRelay.ViewerRelay.LIFETIME_SIGNALS:
				context.equal(fixture.client.get_signal_connection_list(signal_name).size(), 1 if accepted else 0, "temporary listeners released on every exit")
			context.equal(fixture.relay.poll(0).sent, 1 if accepted else 0, "rejected setup cannot publish")
			context.equal(fixture.host.status().lifecycle, S.Lifecycle.RUNNING, "partial setup never terminates caller host")
			fixture.relay.detach()
			fixture.options.max_sends_per_poll = 2
			fixture.info.capabilities.clear()
			fixture.info.capabilities.append("spectator_relay")
			context.equal(_configure_again(fixture), HostRelay.Code.OK, "setup rejection releases guard")
			_stop(fixture)


# Value: protects=publication stops when admitted viewer leaves; fails_when=host listens only to its own spectator role;
# why_new=room lifetime tests omit remote spectator departure; seam=public SDK signals
func _viewer_departures(context: RefCounted) -> void:
	for boundary: String in ["idle", "getter", "send", "protocol_setup", "getter_setup"]:
		for selected: bool in [false, true]:
			var fixture: Dictionary = _fixture(context, false)
			var departing: String = VIEWER if selected else HOST
			var callback: Callable = func() -> void: fixture.client.spectator_disconnected.emit(departing, 0, [])
			var setup: bool = boundary.ends_with("setup")
			if setup:
				fixture.relay.detach()
				if boundary == "protocol_setup":
					fixture.info.on_info = callback
				else:
					fixture.client.on_room = callback
				context.equal(_configure_again(fixture), HostRelay.Code.WRONG_STATE if selected else HostRelay.Code.OK, "setup fences selected viewer departure")
			elif boundary == "idle":
				callback.call()
			elif boundary == "send":
				fixture.client.on_send = func(_packet: PackedByteArray) -> void: callback.call()
			else:
				fixture.client.on_room = callback
			var expected: int = HostRelay.Code.WRONG_STATE if selected else HostRelay.Code.OK
			context.equal(fixture.relay.poll(0).code, expected, "only selected viewer departure stops publication")
			context.equal(fixture.client.attempted.size(), 1 if boundary == "send" or not selected else 0, "no new sends after viewer departure")
			context.equal(fixture.relay.finish_host().code, expected, "finish cannot revive abandoned publication")
			context.equal(fixture.host.status().lifecycle, S.Lifecycle.RUNNING, "viewer departure never stops player host")
			fixture.helper._step(context, fixture.driver, 0)
			_stop(fixture)

	var fixture: Dictionary = _fixture(context, false)
	var old_callback: Callable = fixture.client.get_signal_connection_list("spectator_disconnected")[0].callable
	fixture.client.outcome = FAILED
	context.equal(fixture.relay.poll(0).code, HostRelay.Code.SDK_FAILURE, "establish first publication failure")
	fixture.client.spectator_disconnected.emit(VIEWER, 0, [])
	context.equal(fixture.relay.status().code, HostRelay.Code.SDK_FAILURE, "viewer departure preserves first publication failure")
	fixture.relay.detach()
	fixture.client.outcome = OK
	context.equal(_configure_again(fixture), HostRelay.Code.OK, "explicit replacement publication")
	old_callback.call(VIEWER, 0, [])
	context.equal(fixture.relay.poll(0).sent, 1, "old viewer observer cannot end replacement")
	_stop(fixture)
	context.equal(fixture.client.get_signal_connection_list("spectator_disconnected").size(), 0, "detach releases selected viewer observer")
