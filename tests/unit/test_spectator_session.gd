extends RefCounted

# Value: protects=confirmed-only spectator playback; fails_when=host input predicts or rewrites history; why_new=no spectator path; seam=none
const Spectator = preload("res://addons/fortress_rollback/core/spectator_session.gd")
const Session = preload("res://addons/fortress_rollback/core/session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Fixture = preload("res://tests/unit/test_driver.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const H = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")


class WideGame:
	extends Fixture.Game
	var players: int
	var width: int

	func simulate_frame(frame: int, inputs: Types.FrameInputs) -> bool:
		if inputs.size().value != players:
			return false
		for player: int in range(players):
			var expected: PackedByteArray = PackedByteArray()
			expected.resize(width)
			expected.fill((frame + player) % 256)
			if inputs.read(player).bytes != expected:
				return false
		return super.simulate_frame(frame, inputs)


func cases() -> PackedStringArray:
	return PackedStringArray(
		["configuration", "confirmed_playback", "buffering", "delay_and_loss", "expert_parity", "host_export",
			"storage_budget", "host_export_repair", "exhaustion", "shapes", "retained_row", "delay_bounds", "mesh_mutators"]
	)


func run_case(name: String, context: RefCounted) -> void:
	call("_" + name, context)
	context.finish()


func _config() -> RefCounted:
	var config: RefCounted = Config.new()
	config.spectator = true
	config.local_players = PackedInt32Array()
	config.sync_test = false
	config.check_distance = 0
	config.max_prediction_frames = 0
	config.queue_capacity = 5
	config.history_slots = 1
	config.max_snapshot_bytes = 8
	config.storage_budget_bytes = 65536
	return config


func _spectator(context: RefCounted) -> RefCounted:
	var session: RefCounted = Spectator.new()
	context.equal(session.configure(_config()), Types.Code.OK, "configure spectator")
	return session


## A bounded player host configuration for the publisher side of the envelope exchange.
func host_config() -> RefCounted:
	var config: RefCounted = Config.new()
	config.spectator = false
	config.local_players = PackedInt32Array([0, 1])
	config.sync_test = false
	config.check_distance = 0
	config.max_prediction_frames = 0
	config.queue_capacity = 5
	config.history_slots = 1
	config.max_snapshot_bytes = 8
	config.storage_budget_bytes = 65536
	return config


## One startup exchange between a host publisher and a viewer stream.
func negotiate(publisher: RefCounted, stream: RefCounted, now_us: int = 0) -> int:
	var offer: PackedByteArray = publisher.encode_offer()
	if offer.is_empty():
		return Types.Code.INVALID_CONFIGURATION
	var code: int = stream.receive_packet(offer, now_us)
	if code != Types.Code.OK:
		return code
	var accept: PackedByteArray = stream.encode_accept()
	if accept.is_empty():
		return Types.Code.INVALID_CONFIGURATION
	return publisher.receive_accept(accept)


func _row(frame: int) -> Array[PackedByteArray]:
	return [PackedByteArray([frame % 7]), PackedByteArray([(frame + 1) % 7])]


func _configuration(context: RefCounted) -> void:
	var config: RefCounted = _config()
	context.equal(config.validate(), Types.Code.OK, "explicit all-remote configuration")
	context.equal(config.owned_copy().spectator, true, "mode copied")
	for field: String in ["sync_test", "input_delay", "max_prediction_frames", "local_players"]:
		var invalid: RefCounted = _config()
		invalid.set(field, PackedInt32Array([0]) if field == "local_players" else (true if field == "sync_test" else 1))
		context.equal(invalid.validate(), Types.Code.INVALID_CONFIGURATION, "incompatible " + field)
	config.spectator = false
	context.equal(config.validate(), Types.Code.INVALID_CONFIGURATION, "ordinary session still needs locals")
	var session: RefCounted = _spectator(context)
	context.equal(session.configure(Config.new()), Types.Code.INVALID_CONFIGURATION, "cannot reconfigure as a player")
	context.equal(session.submit_local_input(0, 0, PackedByteArray([1])).code, Types.Code.UNSUPPORTED, "no spectator input")
	context.equal(session.receive_input(0, 0, PackedByteArray([1])).code, Types.Code.UNSUPPORTED, "host rows are atomic")
	context.equal(session.set_input_delay(0, 1).code, Types.Code.UNSUPPORTED, "no spectator input delay")
	context.equal(session.set_playback(5, 1, 1), Types.Code.INVALID_CONFIGURATION, "delay fits buffer")
	context.equal(session.set_playback(0, 1, 0), Types.Code.INVALID_CONFIGURATION, "positive catchup")


func _confirmed_playback(context: RefCounted) -> void:
	var session: RefCounted = _spectator(context)
	var game: RefCounted = Fixture.Game.new()
	var driver: RefCounted = Driver.new(session, game)
	var expected: int = 0
	for frame: int in range(45):
		context.equal(driver.step(frame, _empty()).code, Types.Code.PREDICTION_STALL, "never predicts")
		var row: Array[PackedByteArray] = _row(frame)
		context.equal(session.receive_host_frame(frame, row).code, Types.Code.OK, "host row")
		row[0][0] = 99
		context.equal(driver.step(frame, _empty()).code, Types.Code.OK, "one confirmed advance")
		for player: int in range(2):
			expected = expected * 3 + _row(frame)[player][0] + frame
		context.equal(game.value, expected, "original submitted input state")
		context.equal(session.status().current_frame, frame + 1, "next frame convention")
		context.equal(game.retained_inputs.read(0).code, Types.Code.EXPIRED_VIEW, "callback view expires")
	context.equal(session.statistics().rollback_count, 0, "spectators never roll back")


func _buffering(context: RefCounted) -> void:
	var session: RefCounted = _spectator(context)
	context.equal(session.receive_host_frame(4, _row(4)).code, Types.Code.OK, "future within nonpower ring")
	context.equal(session.receive_host_frame(5, _row(5)).code, Types.Code.NETWORK_BACKPRESSURE, "bounded future")
	context.equal(session.recommended_steps(), 0, "gap does not advance live edge")
	context.equal(session.receive_host_frame(4, _row(4)).code, Types.Code.OK, "identical duplicate")
	context.equal(session.receive_host_frame(4, _row(3)).code, Types.Code.INPUT_ALREADY_SUBMITTED, "conflicting duplicate")
	context.equal(session.receive_host_frame(0, _bad_row(false)).code, Types.Code.INVALID_CONFIGURATION, "wrong cardinality")
	context.equal(session.receive_host_frame(0, _bad_row(true)).code, Types.Code.INPUT_WIDTH, "atomic malformed row")
	context.equal(session.recommended_steps(), 0, "malformed row does not advance frontier")
	for frame: int in range(4):
		context.equal(session.receive_host_frame(frame, _row(frame)).code, Types.Code.OK, "fill gap")
	var driver: RefCounted = Driver.new(session, Fixture.Game.new())
	for frame: int in range(5):
		context.equal(driver.step(frame, _empty()).code, Types.Code.OK, "drain reordered history")
	context.equal(session.receive_host_frame(5, _row(5)).code, Types.Code.OK, "wrap permits next row")
	context.equal(session.receive_host_frame(0, _row(0)).code, Types.Code.INVALID_FRAME, "overwritten old duplicate")
	context.equal(session.receive_host_frame(-1, _row(0)).code, Types.Code.INVALID_FRAME, "negative frame")


func _delay_and_loss(context: RefCounted) -> void:
	_clean_end_advice(context)
	var session: RefCounted = _spectator(context)
	context.equal(session.set_playback(2, 1, 3), Types.Code.OK, "bounded delayed catchup")
	var driver: RefCounted = Driver.new(session, Fixture.Game.new())
	for frame: int in range(5):
		session.receive_host_frame(frame, _row(frame))
	context.equal(session.recommended_steps(), 3, "catchup relative to delayed edge")
	for frame: int in range(3):
		context.equal(driver.step(frame, _empty()).code, Types.Code.OK, "catchup frame")
	context.equal(session.recommended_steps(), 0, "hold stream delay")
	context.equal(driver.step(3, _empty()).code, Types.Code.PREDICTION_STALL, "cannot bypass delay with expert driver")
	context.equal(session.finish_host(), Types.Code.OK, "clean host end releases delayed tail")
	context.equal(session.receive_host_frame(5, _row(5)).code, Types.Code.TERMINATED, "closed host cannot add data")
	for frame: int in range(3, 5):
		context.equal(driver.step(frame, _empty()).code, Types.Code.OK, "play valid tail")
	context.equal(driver.step(5, _empty()).code, Types.Code.TERMINATED, "clean end terminal")
	var failed: RefCounted = _spectator(context)
	failed.receive_host_frame(0, _row(0))
	failed.terminate(Types.Code.PROTOCOL_FAILED)
	context.equal(Driver.new(failed, Fixture.Game.new()).step(0, _empty()).code, Types.Code.TERMINATED, "host failure stops buffered work")


func _expert_parity(context: RefCounted) -> void:
	var manual: RefCounted = _spectator(context)
	var driven: RefCounted = _spectator(context)
	var manual_game: RefCounted = Fixture.Game.new()
	var driver_game: RefCounted = Fixture.Game.new()
	var driver: RefCounted = Driver.new(driven, driver_game)
	for frame: int in range(15):
		manual.receive_host_frame(frame, _row(frame))
		driven.receive_host_frame(frame, _row(frame))
		manual.poll(frame)
		var advance: Types.Result = manual.begin_advance()
		context.equal(advance.code, Types.Code.READY, "expert ready")
		var request: Types.Request = advance.batch.next_request()
		context.equal(request.kind, Types.Kind.ADVANCE, "shared advance request")
		var ok: bool = manual_game.simulate_frame(request.frame, request.inputs)
		context.equal(manual.complete_request(request.batch_id, request.request_id, ok).code, Types.Code.OK, "expert completion")
		context.equal(driver.step(frame, _empty()).code, Types.Code.OK, "driver completion")
		context.equal(driver_game.value, manual_game.value, "expert and driver canonical state")
		context.equal(driver_game.trace, manual_game.trace, "identical ordered requests")


func _host_export(context: RefCounted) -> void:
	var config: RefCounted = _config()
	config.spectator = false
	config.local_players = PackedInt32Array([0, 1])
	var host: RefCounted = Session.new()
	context.equal(host.configure(config), Types.Code.OK, "zero prediction host")
	var driver: RefCounted = Driver.new(host, Fixture.Game.new())
	var spectator: RefCounted = _spectator(context)
	var viewing: RefCounted = Driver.new(spectator, Fixture.Game.new())
	context.equal(host.confirmed_inputs(0), null, "unsimulated input unavailable")
	for frame: int in range(15):
		var samples: Array[Driver.LocalInput] = []
		for player: int in range(2):
			samples.append(Driver.LocalInput.new(player, frame, _row(frame)[player]))
		context.equal(driver.step(frame, samples).code, Types.Code.OK, "host advance")
		var inputs: Types.FrameInputs = host.confirmed_inputs(frame)
		context.equal(inputs != null, true, "export after zero-window discard")
		var row: Array[PackedByteArray] = [inputs.read(0).bytes, inputs.read(1).bytes]
		context.equal(spectator.receive_host_frame(frame, row).code, Types.Code.OK, "copy host confirmed bytes")
		context.equal(viewing.step(frame, _empty()).code, Types.Code.OK, "spectator advance")
	context.equal(host.confirmed_inputs(0), null, "overwritten physical tag unavailable")
	context.equal(host.status().current_frame, 15, "spectator never affects host progress")


func _empty() -> Array[Driver.LocalInput]:
	return []


func _bad_row(wide: bool) -> Array[PackedByteArray]:
	var row: Array[PackedByteArray] = [PackedByteArray([1])]
	if wide:
		row.append(PackedByteArray([1, 2]))
	return row


# Value: protects=payload budget includes spectator staging; fails_when=host rows allocate outside reservation; why_new=core budget omits host ring; seam=none
func _storage_budget(context: RefCounted) -> void:
	var config: RefCounted = _config()
	config.spectator = false
	var core_bytes: int = config.required_storage_bytes()
	config.spectator = true
	var required: int = core_bytes + config.queue_capacity * (config.player_count * (config.input_width + 1) + 8)
	context.equal(config.required_storage_bytes(), required, "owned host rows, statuses and int64 tags are reserved")
	config.storage_budget_bytes = required - 1
	context.equal(config.validate(), Types.Code.INVALID_CONFIGURATION, "one byte below reservation rejected")
	context.equal(Spectator.new().configure(config), Types.Code.INVALID_CONFIGURATION, "rejected before ring allocation")
	config.storage_budget_bytes = required
	context.equal(Spectator.new().configure(config), Types.Code.OK, "exact reservation accepted")
	var profile: T.Message = T.Message.new()
	profile.kind = T.Kind.SYNC_REQUEST
	profile.sender_id = _identity(3, 8)
	profile.connection_id = _identity(4, 8)
	profile.session_id = _identity(5, 16)
	profile.config.player_count = config.player_count
	profile.config.input_width = config.input_width
	profile.config.input_delay = 0
	profile.config.max_prediction = 0
	profile.config.queue_capacity = config.queue_capacity
	profile.config.neutral_input = config.neutral_input.duplicate()
	profile.config.roster = [_identity(1, 8), _identity(2, 8)]
	var peer: RefCounted = Peer.new()
	context.equal(peer.configure(config, profile, Fixture.Game.new(), H.Options.new(), I.Options.new()), I.Code.INVALID_ARGUMENT, "spectator cannot join player protocol")
	context.equal(peer.network_status().state, "unconfigured", "peer refusal preserves unconfigured state")


# Value: protects=host exports corrected confirmed inputs only; fails_when=receipt confirmation exposes pending rollback; why_new=lockstep export has no predictions; seam=none
func _host_export_repair(context: RefCounted) -> void:
	var config: RefCounted = _config()
	config.spectator = false
	config.local_players = PackedInt32Array([0])
	config.max_prediction_frames = 2
	config.history_slots = 3
	var host: RefCounted = Session.new()
	context.equal(host.configure(config), Types.Code.OK, "predicting host")
	var driver: RefCounted = Driver.new(host, Fixture.Game.new())
	context.equal(host.receive_input(1, 0, PackedByteArray([1])).code, Types.Code.OK, "actual initial input")
	for frame: int in range(2):
		var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, frame, PackedByteArray([2]))]
		context.equal(driver.step(frame, samples).code, Types.Code.OK, "host advances with prediction")
	context.equal(host.confirmed_inputs(1), null, "predicted row is private")
	context.equal(host.receive_input(1, 1, PackedByteArray([3])).code, Types.Code.OK, "late differing actual input")
	context.equal(host.status().confirmed_frame, 1, "input receipt confirms row")
	context.equal(host.status().pending_rollback_frame, 1, "state still needs correction")
	context.equal(host.confirmed_inputs(0) != null, true, "earlier unaffected history remains exportable")
	context.equal(host.confirmed_inputs(1), null, "pending correction hides affected history")
	var retry: Array[Driver.LocalInput] = [Driver.LocalInput.new(0, 2, PackedByteArray([2]))]
	context.equal(driver.step(2, retry).code, Types.Code.OK, "shared driver repairs host")
	var repaired: Types.FrameInputs = host.confirmed_inputs(1)
	context.equal(repaired != null, true, "completed correction releases row")
	if repaired != null:
		context.equal(repaired.read(1).bytes, PackedByteArray([3]), "exports actual corrected input")


func _identity(value: int, width: int) -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(width)
	bytes[0] = value
	return bytes


# Value: protects=terminal frame/token exhaustion while input-idle; fails_when=spectator delay masks shared-core fatal limits; why_new=core tests bypass override; seam=none
func _exhaustion(context: RefCounted) -> void:
	for frame_limit: bool in [true, false]:
		var spectator: RefCounted = _spectator(context)
		var game: RefCounted = Fixture.Game.new()
		var driver: RefCounted = Driver.new(spectator, game)
		# Reaching these counters by playback would require billions of ticks.
		if frame_limit:
			spectator._current = 2147483647
		else:
			spectator._batch_id = 9223372036854775807
		context.equal(driver.step(0, _empty()).code, Types.Code.FRAME_EXHAUSTED, "exhaustion precedes unavailable host data")
		context.equal(spectator.status().lifecycle, Types.Lifecycle.TERMINATED, "exhaustion is terminal")
		context.equal(spectator.status().reason, Types.Code.FRAME_EXHAUSTED, "terminal cause retained")
		context.equal(game.trace.is_empty(), true, "exhaustion runs no game callback")


# Value: protects=every supported roster and maximum input width; fails_when=staging uses a two-player or byte-sized stride; why_new=other cases use two bytes; seam=none
func _shapes(context: RefCounted) -> void:
	for players: int in range(2, 9):
		for width: int in [1, 4, 65536] if players == 8 else [1, 4]:
			var config: RefCounted = _config()
			config.player_count = players
			config.input_width = width
			config.neutral_input.resize(width)
			config.storage_budget_bytes = config.required_storage_bytes()
			var session: RefCounted = Spectator.new()
			context.equal(session.configure(config), Types.Code.OK, "shape %d players x %d bytes" % [players, width])
			var game: WideGame = WideGame.new()
			game.players = players
			game.width = width
			var driver: RefCounted = Driver.new(session, game)
			var expected: int = 0
			for frame: int in range(7):
				var row: Array[PackedByteArray] = []
				for player: int in range(players):
					var bytes: PackedByteArray = PackedByteArray()
					bytes.resize(width)
					bytes.fill((frame + player) % 256)
					row.append(bytes)
					expected = expected * 3 + bytes[0] + frame
				context.equal(session.receive_host_frame(frame, row).code, Types.Code.OK, "bounded shape row")
				context.equal(driver.step(frame, _empty()).code, Types.Code.OK, "shape advance")
				context.equal(game.value, expected, "stable per-player stride")


# Value: protects=advice-driven clean end; fails_when=final empty advice hides lifecycle completion; why_new=direct step end bypasses advice; seam=none
func _clean_end_advice(context: RefCounted) -> void:
	for scenario: Dictionary in [
		{"rows": [], "delay": 0, "frames": 0}, {"rows": [0], "delay": 0, "frames": 1}, {"rows": [0, 1, 2], "delay": 2, "frames": 3}, {"rows": [0, 2], "delay": 1, "frames": 1}
	]:
		var session: RefCounted = _spectator(context)
		var game: RefCounted = Fixture.Game.new()
		var driver: RefCounted = Driver.new(session, game)
		context.equal(session.set_playback(scenario.delay, 1, 3), Types.Code.OK, "configure clean end playback")
		for frame: int in scenario.rows:
			context.equal(session.receive_host_frame(frame, _row(frame)).code, Types.Code.OK, "stage ending host rows")
		context.equal(session.finish_host(), Types.Code.OK, "finish host before advice loop")
		var attempts: int = 0
		var last_code: int = Types.Code.OK
		while session.recommended_steps() > 0 and attempts < 8:
			last_code = driver.step(attempts, _empty()).code
			attempts += 1
		context.equal(last_code, Types.Code.TERMINATED, "advice loop observes terminal completion")
		context.equal(session.status().lifecycle, Types.Lifecycle.TERMINATED, "advice loop finishes lifecycle")
		context.equal(session.status().current_frame, scenario.frames, "only contiguous prefix is played")
		context.equal(game.trace.size(), scenario.frames, "terminal control step simulates no input")
		context.equal(session.recommended_steps(), 0, "terminated viewer needs no further service")


# Value: protects=playback simulates the row the host sent; fails_when=a recycled ring slot is played as confirmed
# host input; why_new=other cases keep the ring consistent; seam=none
func _retained_row(context: RefCounted) -> void:
	var session: RefCounted = _spectator(context)
	context.equal(session.receive_host_frame(0, _row(0)).code, Types.Code.OK, "host row")
	# The retained row for the current frame disappears before playback.
	session._host_tags[0] = -1
	var game: RefCounted = Fixture.Game.new()
	var driver: RefCounted = Driver.new(session, game)
	context.equal(driver.step(0, _empty()).code, Types.Code.HISTORY_UNAVAILABLE, "a missing host row is not played as confirmed input")
	context.equal(game.trace.is_empty(), true, "no game callback runs without the host row")
	context.equal(session.status().current_frame, 0, "refused playback keeps the boundary")
	context.equal(session.status().lifecycle, Types.Lifecycle.RUNNING, "a missing row is a refusal, not a terminal cause")


# Value: protects=playback policy fits the retained ring; fails_when=a delay, threshold or speed beyond the ring is accepted; why_new=model cases use fixed policies; seam=none
func _delay_bounds(context: RefCounted) -> void:
	var session: RefCounted = _spectator(context)
	context.equal(session.set_playback(4, 1, 1), Types.Code.OK, "largest legal stream delay")
	context.equal(session.set_playback(5, 1, 1), Types.Code.INVALID_CONFIGURATION, "delay beyond the ring is refused")
	context.equal(session.set_playback(0, 5, 1), Types.Code.OK, "largest legal behind threshold")
	context.equal(session.set_playback(0, 6, 1), Types.Code.INVALID_CONFIGURATION, "behind threshold beyond the ring is refused")
	context.equal(session.set_playback(0, 1, 5), Types.Code.OK, "largest legal catchup speed")
	context.equal(session.set_playback(0, 1, 6), Types.Code.INVALID_CONFIGURATION, "catchup speed beyond the ring is refused")
	context.equal(session.playback_policy(), PackedInt64Array([0, 1, 5]), "the accepted policy is reported back")


# Value: protects=host rows remain authoritative after player-mesh calls; fails_when=inherited freezes replace host input;
# why_new=configuration tests reject local input but not inherited remote-slot mutators; seam=none
func _mesh_mutators(context: RefCounted) -> void:
	for method: String in ["control", "freeze_player", "freeze_player_with_value"]:
		var session: RefCounted = _spectator(context)
		var game: RefCounted = Fixture.Game.new()
		var driver: RefCounted = Driver.new(session, game)
		var expected: int = 0
		for frame: int in range(3):
			if frame == 1 and method != "control":
				var rejected: int = session.freeze_player(0, 0) if method == "freeze_player" else session.freeze_player_with_value(0, 0, PackedByteArray([9]))
				context.equal(rejected, Types.Code.UNSUPPORTED, "spectators reject mesh slot freezing")
				context.equal(session.frozen_frame(0), -1, "refusal does not freeze a host slot")
			var row: Array[PackedByteArray] = _row(frame)
			context.equal(session.receive_host_frame(frame, row).code, Types.Code.OK, "host remains authoritative")
			context.equal(driver.step(frame, _empty()).code, Types.Code.OK, "play every complete host row")
			for bytes: PackedByteArray in row:
				expected = expected * 3 + bytes[0] + frame
			context.equal(game.value, expected, "canonical state uses changing host bytes")
			context.equal(session.status().confirmed_frame, frame, "confirmation follows complete host rows")
			context.equal(session.received_frames(), PackedInt64Array([frame, frame]), "every slot receives the host row")
			var exported: Types.FrameInputs = session.confirmed_inputs(frame)
			context.equal(exported != null, true, "completed host row remains exportable")
			if exported != null:
				for player: int in range(row.size()):
					context.equal(exported.read(player).bytes, row[player], "exports retain original host bytes")
