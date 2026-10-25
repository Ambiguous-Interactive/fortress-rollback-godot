extends RefCounted

const HostRelay = preload("res://addons/fortress_rollback/transport/signalfish_spectator_host.gd")
const Viewer = preload("res://tests/unit/test_signalfish_spectator_relay.gd")
const PublisherFixture = preload("res://tests/unit/test_spectator_publisher.gd")
const Fixture = preload("res://tests/unit/test_spectator_session.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const GameFixture = preload("res://tests/unit/test_driver.gd")
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
	return PackedStringArray(["startup", "canonical_playback", "pressure", "lifetimes", "configuration", "reentry",
		"history_loss", "player_coexistence", "active_requests", "fair_liveness", "finish_retry"])


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
	context.equal(relay.configure(client, config, info, host, VIEWER, helper._identity(), helper._key(), helper._digest(), options), HostRelay.Code.OK, "host publication configured")
	var viewer: Dictionary = Viewer.new()._fixture(context, false, 2, 8)
	var fixture: Dictionary = {"host": host, "client": client, "config": config, "info": info, "options": options, "relay": relay, "viewer": viewer,
		"driver": Driver.new(host, GameFixture.Game.new()), "helper": helper}
	if negotiate:
		context.equal(relay.poll(0).sent, 1, "SDK sends original offer")
		_deliver(fixture)
		var accept: Callable = func(packet: PackedByteArray) -> int:
			return OK if relay.receive_accept(VIEWER, packet).code == HostRelay.Code.OK else FAILED
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
	fixture.client.on_send = func(packet: PackedByteArray) -> void:
		fixture.client.outcome = OK if packet[5] == Stream.KEEPALIVE else ERR_BUSY
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
			"room": fixture.client.room = "replacement"
			"player": fixture.client.player = VIEWER
			"disconnect": fixture.client.connection = 0
			"source": fixture.host.configure(fixture.helper._config())
			"signal": fixture.client.spectator_left.emit("room-one", "ROOM", 0, [])
			"raw": fixture.config.decode_msgpack_payloads = true
		context.equal(fixture.relay.poll(1).code != HostRelay.Code.OK, true, "replacement fences publication: " + change)
		context.equal(fixture.client.sent.is_empty(), true, "no bytes leave invalid lifetime")
		context.equal(fixture.host.status().lifecycle, S.Lifecycle.RUNNING, "publication failure does not terminate player gameplay")
		_stop(fixture)


func _configuration(context: RefCounted) -> void:
	for field: String in ["role", "capability", "size", "identity", "viewer"]:
		var fixture: Dictionary = _fixture(context, false)
		fixture.relay.detach()
		var identity: PackedByteArray = fixture.helper._identity()
		var viewer: String = VIEWER
		match field:
			"role": fixture.client.state = HostRelay.ViewerRelay.SPECTATING
			"capability": fixture.info.capabilities.clear()
			"size": fixture.config.max_outbound_frame_bytes = 1
			"identity": identity.resize(1)
			"viewer": viewer = HOST
		context.equal(fixture.relay.configure(fixture.client, fixture.config, fixture.info, fixture.host, viewer,
			identity, fixture.helper._key(), fixture.helper._digest(), fixture.options) != HostRelay.Code.OK, true, "invalid host configuration refused: " + field)
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
				"detach": fixture.relay.detach()
				"room": fixture.client.room = "replacement"
				"malformed": fixture.client.outcome = true
			packet.fill(0)
		if action == "getter":
			fixture.client.on_buffered = func() -> void: fixture.relay.detach()
		var attempts: int = fixture.client.attempted.size()
		var result: RefCounted = fixture.relay.poll(1)
		if action == "getter":
			context.equal(fixture.client.attempted.size(), attempts, "buffer getter invalidation prevents stale SDK send")
		context.equal(result.code,
			HostRelay.Code.OK if action == "reenter" else (HostRelay.Code.SDK_FAILURE if action == "malformed" else HostRelay.Code.WRONG_STATE),
			"recheck SDK callback result and lifetime")
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
