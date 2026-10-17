class_name FortressPeerExampleMatch
extends RefCounted

const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const H = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const Reader = preload("res://addons/fortress_rollback/core/snapshot_reader.gd")
const Simulation = preload("res://examples/offline/simulation.gd")
const Presentation = preload("res://examples/offline/presentation.gd")
const MAX_PACKETS: int = 256
const TICK_US: int = 16667


class Game:
	extends Simulation
	var restores: int = 0
	var is_divergent: bool = false

	func simulate_frame(input_frame: int, inputs: Types.FrameInputs) -> bool:
		if not super.simulate_frame(input_frame, inputs):
			return false
		if is_divergent:
			x[0] = 20 + (x[0] - 20 + 1) % 441
		return true

	func load_state(saved_frame: int, reader: Reader) -> bool:
		var accepted: bool = super.load_state(saved_frame, reader)
		if accepted:
			restores += 1
		return accepted


var sessions: Array[Peer] = []
var games: Array[Game] = []
var presentations: Array[Presentation] = []
var stalls: PackedInt32Array = PackedInt32Array([0, 0])
var last_codes: PackedInt32Array = PackedInt32Array([0, 0])
var latency_ticks: int = 3
var drop_every: int = 7
var reorder: bool = true
var is_partitioned: bool = false
## Confirmed frames each peer records; 0 disables recording.
var replay_frames: int = 0
## Unacknowledged local frames each peer retains before steps report NETWORK_BACKPRESSURE.
var max_pending_frames: int = 128
var now_us: int = 0
var sent: int = 0
var dropped: int = 0
var delivered: int = 0
var failure: int = I.Code.OK
var event_counts: Array[Dictionary] = [{}, {}]
var latest_events: Array[Dictionary] = [{}, {}]
var _tokens: int = 0
var _packets: Array[Dictionary] = []
var _held: PackedInt32Array = PackedInt32Array([-1, -1])
var _ids: Array[PackedByteArray] = [PackedByteArray([1, 0, 0, 0, 0, 0, 0, 0]), PackedByteArray([2, 0, 0, 0, 0, 0, 0, 0])]


func reset() -> int:
	sessions.clear()
	games.clear()
	presentations.clear()
	_packets.clear()
	stalls = PackedInt32Array([0, 0])
	last_codes = PackedInt32Array([0, 0])
	_held = PackedInt32Array([-1, -1])
	now_us = 0
	sent = 0
	dropped = 0
	delivered = 0
	_tokens = 0
	failure = I.Code.OK
	event_counts = [{}, {}]
	latest_events = [{}, {}]
	is_partitioned = false
	for player: int in range(2):
		var config: Config = Config.new()
		config.sync_test = false
		config.check_distance = 0
		config.local_players = PackedInt32Array([player])
		config.input_delay = 2
		config.replay_max_frames = replay_frames
		config.max_snapshot_bytes = Simulation.SNAPSHOT_BYTES
		config.storage_budget_bytes = config.required_storage_bytes()
		var profile: T.Message = T.Message.new()
		profile.kind = T.Kind.SYNC_REQUEST
		profile.sender_id = _ids[player].duplicate()
		profile.connection_id = _ids[player].duplicate()
		profile.session_id[0] = 17
		profile.config.input_delay = 2
		profile.config.desync_interval = 30
		profile.config.roster = [_ids[0].duplicate(), _ids[1].duplicate()]
		var handshake: H.Options = H.Options.new()
		handshake.roundtrips = 2
		var game: Game = Game.new()
		var session: Peer = Peer.new()
		var inputs: I.Options = I.Options.new()
		inputs.max_pending_frames = max_pending_frames
		failure = session.configure(config, profile, game, handshake, inputs)
		if failure != I.Code.OK:
			return failure
		sessions.append(session)
		games.append(game)
		presentations.append(Presentation.new())
	for session: Peer in sessions:
		failure = session.begin(now_us, [_token()])
		if failure != I.Code.OK:
			return failure
	_collect()
	return failure


## Clock and packet faults are explicit; simulation receives only input bytes.
func tick(buttons: PackedInt32Array, can_advance: bool = true) -> void:
	if failure != I.Code.OK:
		return
	if latency_ticks < 0 or latency_ticks > 120 or drop_every < 0 or drop_every > 1000:
		failure = I.Code.INVALID_ARGUMENT
		return
	if buttons.size() != 2 or buttons[0] < 0 or buttons[0] > 15 or buttons[1] < 0 or buttons[1] > 15:
		failure = I.Code.INVALID_ARGUMENT
		return
	now_us += TICK_US
	for session: Peer in sessions:
		if session.status().lifecycle == Types.Lifecycle.TERMINATED:
			continue
		var code: int = session.poll(now_us, [_token()])
		if code != I.Code.OK and session.status().lifecycle != Types.Lifecycle.TERMINATED:
			failure = code
	_deliver()
	for player: int in range(sessions.size()):
		var session: Peer = sessions[player]
		if can_advance and session.network_status().state == "running":
			if _held[player] == -1:
				_held[player] = buttons[player]
			var samples: Array[Driver.LocalInput] = [Driver.LocalInput.new(player, session.status().current_frame, PackedByteArray([_held[player]]))]
			var result: Driver.StepResult = session.step(now_us, samples)
			last_codes[player] = result.code
			if result.code == Types.Code.OK:
				_held[player] = -1
				presentations[player].reconcile(games[player])
			elif result.code in [Types.Code.PREDICTION_STALL, Types.Code.NETWORK_BACKPRESSURE]:
				stalls[player] += 1
			elif session.status().lifecycle == Types.Lifecycle.TERMINATED:
				pass
			else:
				failure = I.Code.INPUT_FAILED
		# Bounded diagnostics must be drained even when simulation stalls.
		for event: Dictionary in session.drain_events():
			var kind: String = event.kind
			event_counts[player][kind] = event_counts[player].get(kind, 0) + 1
			if kind != "inputs_received":
				latest_events[player] = event.duplicate(true)
		session.drain_transitions()
	_collect()


func queued_packets() -> int:
	return _packets.size()


## Delay one more frame of this player's input; peers receive the added frames as ordinary input.
func raise_input_delay(player: int) -> int:
	if player < 0 or player >= sessions.size():
		return Types.Code.INVALID_PLAYER
	return sessions[player].set_input_delay(player, sessions[player].input_delay(player) + 1)


## Deliberately use different game rules on peer one to demonstrate checksum failure.
func inject_desync() -> void:
	if games.size() == 2:
		games[0].is_divergent = true


func _token() -> PackedByteArray:
	_tokens += 1
	var token: PackedByteArray = PackedByteArray()
	token.resize(16)
	token.encode_s64(0, _tokens)
	return token


func _collect() -> void:
	for sender: int in range(sessions.size()):
		for packet: Peer.Packet in sessions[sender].drain_outbox():
			sent += 1
			if is_partitioned or (drop_every > 0 and sent % drop_every == 0) or _packets.size() >= MAX_PACKETS:
				dropped += 1
				continue
			var extra: int = 2 if reorder and sent % 2 == 0 else 0
			_packets.append({"sender": sender, "due": now_us + (latency_ticks + extra) * TICK_US, "bytes": packet.bytes.duplicate()})


func _deliver() -> void:
	var retained: Array[Dictionary] = []
	for packet: Dictionary in _packets:
		if packet.due > now_us:
			retained.append(packet)
			continue
		var source: int = packet.sender
		if sessions[1 - source].status().lifecycle == Types.Lifecycle.TERMINATED:
			dropped += 1
			continue
		var code: int = sessions[1 - source].receive(packet.bytes, _ids[source], now_us, _token())
		if code != I.Code.OK and sessions[1 - source].status().lifecycle == Types.Lifecycle.TERMINATED:
			delivered += 1
		elif code != I.Code.OK:
			failure = code
		else:
			delivered += 1
	_packets = retained
