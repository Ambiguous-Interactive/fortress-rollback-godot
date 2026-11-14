extends SceneTree

# gdlint: disable=max-returns

const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Driver = preload("res://addons/fortress_rollback/core/driver.gd")
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const H = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
const Lifecycle = preload("res://tests/oracle/p2p_lifecycle.gd")
const Game = preload("res://tests/oracle/p2p_game.gd")
const REVISION: String = "d124c89080004d96971a629bb0427056ee1805e3"
var peers: Array[RefCounted] = []
var games: Array[RefCounted] = []
var packets: Array[Dictionary] = []
var raw_packets: Array[PackedByteArray] = []
var records: Array[Dictionary] = []
var scenario_settings: Dictionary = {}
var observed_events: Array[Dictionary] = []
var limits: T.Limits
# Runtime input delays per player; a step's own input flight is scheduled at its
# current frame plus the peer's current delay.
var delays: Array[int] = []
# Endpoint layout: local slot lists per machine address and the owning machine per
# slot. The default stays one local slot per endpoint, so slot == machine there.
var slots_of: Array = []
var owner_of: Array[int] = []
# Driver-side staging of every machine's unconsumed step bytes. Production refuses
# an incomplete local row without staging, so the driver retains prior step bytes
# here and re-submits them once the machine's coverage completes — matching the
# pinned engine, which retains partially staged local inputs across the failed
# advance and clears them only on a successful one.
var staged: Array[Dictionary] = []


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() != 2 or args[0] != "--scenario":
		_fail("expected scenario")
		return
	var file: FileAccess = FileAccess.open(args[1], FileAccess.READ)
	if file == null:
		_fail("missing scenario")
		return
	var text: String = file.get_as_text()
	var parser: JSON = JSON.new()
	if not _integer_tokens(text) or parser.parse(text) != OK or not _valid(parser.data):
		_fail("invalid scenario")
		return
	var scenario: Dictionary = _canonical(parser.data)
	scenario_settings = scenario
	_layout(scenario)
	delays.resize(scenario.players)
	delays.fill(scenario.input_delay)
	limits = T.Limits.new()
	limits.player_count = scenario.players
	limits.input_width = 4
	for machine: int in range(machines()):
		var config: RefCounted = Config.new()
		config.player_count = scenario.players
		config.local_players = PackedInt32Array(slots_of[machine])
		config.input_width = 4
		config.neutral_input = PackedByteArray([0, 0, 0, 0])
		config.input_delay = scenario.input_delay
		config.max_prediction_frames = scenario.max_prediction
		config.queue_capacity = scenario.get("queue_capacity", 128)
		config.history_slots = scenario.max_prediction + 1
		config.check_distance = 0
		config.sync_test = false
		config.max_snapshot_bytes = 4 * (scenario.players + 3)
		config.storage_budget_bytes = 1048576
		var local: T.Message = T.Message.new()
		local.kind = T.Kind.SYNC_REQUEST
		local.sender_id = _id(machine)
		local.connection_id = _id(machine)
		local.session_id = _token(0, 0)
		local.config.player_count = scenario.players
		local.config.input_width = 4
		local.config.input_delay = scenario.input_delay
		local.config.max_prediction = scenario.max_prediction
		local.config.queue_capacity = config.queue_capacity
		local.config.neutral_input = config.neutral_input.duplicate()
		local.config.desync_interval = scenario.get("lifecycle", {}).get("checksum_interval", 0)
		config.checksums_enabled = local.config.desync_interval > 0
		local.config.roster.clear()
		for slot: int in range(scenario.players):
			local.config.roster.append(_id(owner_of[slot]))
		var options: H.Options = H.Options.new()
		options.roundtrips = 1
		var game: RefCounted = Game.new(scenario.players)
		if scenario.get("lifecycle", {}).get("divergent_peer", -1) == machine:
			game.game.accumulators[0] = 1
		var peer: RefCounted = Peer.new()
		if peer.configure(config, local, game, options, I.Options.new(), Lifecycle.options(scenario)) != I.Code.OK:
			_fail("configuration")
			return
		peers.append(peer)
		games.append(game)
		staged.append({})
		var tokens: Array[PackedByteArray] = []
		for remote: PackedByteArray in peer.peer_ids():
			tokens.append(_token(machine, remote.decode_u64(0)))
		if peer.begin(0, tokens) != I.Code.OK:
			_fail("begin")
			return
	# Deliver actual production handshake bytes to a bounded fixed point.
	for iteration: int in range(8):
		for player: int in range(peers.size()):
			for packet: RefCounted in peers[player].drain_outbox():
				var destination: int = packet.to.decode_u64(0) - 1
				if peers[destination].receive(packet.bytes, _id(player), 0) != I.Code.OK:
					_fail("handshake delivery")
					return
	for peer: RefCounted in peers:
		if peer.network_status().state != "running":
			_fail("handshake incomplete")
			return
		peer.drain_events()
	for index: int in range(scenario.operations.size()):
		if not _operation(scenario.operations[index], index):
			return
	print("FORTRESS_P2P_RESULT " + JSON.stringify({"format": 1, "complete": true, "upstream_revision": REVISION, "scenario": scenario, "records": records, "packets": packets}))
	quit(0)


func machines() -> int:
	return slots_of.size()


## Local slot lists per machine; an omitted layout stays one slot per endpoint.
func _layout(scenario: Dictionary) -> void:
	if not scenario.has("layout"):
		for slot: int in range(scenario.players):
			slots_of.append([slot])
			owner_of.append(slot)
		return
	var start: int = 0
	for machine: int in range(scenario.layout.size()):
		var slots: Array[int] = []
		for offset: int in range(int(scenario.layout[machine])):
			slots.append(start + offset)
			owner_of.append(machine)
		slots_of.append(slots)
		start += int(scenario.layout[machine])


func _operation(op: Dictionary, index: int) -> bool:
	var slot: int = int(op.get("peer", 0))
	var player: int = owner_of[slot]
	if op.kind == "deliver":
		if op.packet >= packets.size():
			_fail("unobserved packet")
			return false
		player = packets[op.packet].to
	var peer: RefCounted = peers[player]
	var before: int = peer.status().current_frame
	var pre_state: String = games[player].game.bytes().hex_encode()
	var pre_confirmed: int = peer.status().confirmed_frame
	var code: int = 0
	var error: Variant = null
	match op.kind:
		"step":
			staged[player][slot] = String(op.bytes).hex_decode()
			var inputs: Array[Driver.LocalInput] = []
			if _covered(player):
				for owned: int in slots_of[player]:
					inputs.append(Driver.LocalInput.new(owned, before, staged[player][owned]))
			else:
				inputs.append(Driver.LocalInput.new(slot, before, staged[player][slot]))
			var result: Driver.StepResult = peer.step(op.now_us, inputs)
			if not result.events.is_empty():
				_fail("unmodeled core event")
				return false
			code = result.code
			if code == Types.Code.OK:
				# A successful advance consumed the whole machine's staged row.
				staged[player].clear()
			if code == Types.Code.MISSING_LOCAL_INPUT:
				# The pinned engine polls remote clients before its missing-input gate, so the
				# refused advance still services timers; production refuses before its own poll.
				peer.poll(op.now_us)
			if code != Types.Code.OK:
				error = Types.Code.find_key(code)
		"poll":
			code = peer.poll(op.now_us)
		"deliver":
			code = peer.receive_and_poll(raw_packets[op.packet], _id(packets[op.packet].from), op.now_us)
		"delay":
			# Production API; it takes no clock, so the source reuses the previous operation's time.
			code = peer.set_input_delay(player, op.delay)
			if code != Types.Code.OK:
				error = Types.Code.find_key(code)
			else:
				delays[player] = int(op.delay)
	if op.kind not in ["step", "delay"] and code != I.Code.OK and not (scenario_settings.has("lifecycle") and code == I.Code.TERMINATED):
		_fail("network operation rejected")
		return false
	var scheduled: int = before + delays[slot] if op.kind == "step" else -1
	var published: Variant = _publish(peer, player, scheduled)
	if published == null:
		return false
	var outgoing: Array[int] = published
	var game: RefCounted = games[player]
	observed_events.clear()
	var extensions: Array[Dictionary] = _events(peer)
	records.append(
		{
			"index": index,
			"peer": player,
			"frame_before": before,
			"frame_after": peer.status().current_frame,
			"confirmed_frame": peer.status().confirmed_frame,
			"error": error,
			"requests": game.requests.duplicate(true),
			"events": observed_events.duplicate(true),
			"extension_events": extensions,
			"outgoing": outgoing,
			"state": game.game.bytes().hex_encode()
		}
	)
	if scenario_settings.has("lifecycle"):
		records[-1].pre_state = pre_state
		records[-1].pre_confirmed = pre_confirmed
		records[-1].metrics = Lifecycle.metrics(peer, player, peers.size(), op.now_us)
	game.requests.clear()
	return true


## Every local slot of the machine holds a driver-staged sample, so the step can
## submit the complete row exactly when this op's slot is the last one missing.
func _covered(machine: int) -> bool:
	for owned: int in slots_of[machine]:
		if not staged[machine].has(owned):
			return false
	return true


## Publish one operation's outgoing packets in the pinned source's shared-socket
## order. The per-endpoint drain concatenates queues, but the pinned session
## flushes every endpoint's queued controls first and then publishes each
## endpoint's checksum reports with that step's own input flight, so this split
## moves the advance flight after the controls. The flight is recognized by
## shape: poll-phase retries stop one frame below the scheduled frame and no
## current schedule combines delay raises or nudges with lifecycle controls, so
## a queued input ending exactly at the scheduled frame is always the step's
## own publication. Deliver and poll operations have no advance pass, so their
## drained order already matches the pinned socket order.
## Returns null after a decode failure has failed the run.
func _publish(peer: RefCounted, player: int, scheduled: int) -> Variant:
	var observed: Array[Dictionary] = []
	for packet: RefCounted in peer.drain_outbox():
		var decoded: Dictionary = _decode_outgoing(packet, player)
		if decoded.is_empty():
			return null
		decoded.destination = packet.to.decode_u64(0) - 1
		decoded.sender = player
		observed.append(decoded)
	var controls: Array[Dictionary] = []
	var flights: Array[Dictionary] = []
	for item: Dictionary in observed:
		var semantic: Dictionary = item.semantic
		if semantic.kind == "checksum_report" or (semantic.kind == "input"
				and int(semantic.start_frame) + semantic.frames.size() - 1 == scheduled):
			flights.append(item)
		else:
			controls.append(item)
	var outgoing: Array[int] = []
	for item: Dictionary in controls:
		_register(item, outgoing)
	for item: Dictionary in flights:
		_register(item, outgoing)
	return outgoing


func _decode_outgoing(packet: RefCounted, player: int) -> Dictionary:
	limits.expected_session_id = _token(0, 0)
	limits.expected_sender_id = _id(player)
	limits.expected_connection_id = _id(player)
	var result: T.Result = Codec.decode(packet.bytes, limits)
	if result.code != T.Code.OK:
		_fail("outgoing codec")
		return {}
	var message: T.Message = result.message
	var semantic: Dictionary = {"kind": "input_ack", "ack_frame": message.ack_frame}
	if message.kind == T.Kind.INPUT:
		# One flight row carries one four-byte input per slot the sender owns locally.
		var row: int = 4 * message.players.size()
		var frames: Array[String] = []
		for frame: int in range(message.frame_count):
			frames.append(message.data.slice(frame * row, (frame + 1) * row).hex_encode())
		var statuses: Array[Dictionary] = []
		for status: T.Status in message.statuses:
			statuses.append({"disconnected": status.disconnected, "epoch": status.epoch, "last_frame": status.last_frame})
		semantic = {
			"kind": "input", "ack_frame": message.ack_frame, "start_frame": message.start_frame, "players": Array(message.players), "frames": frames, "statuses": statuses
		}
	elif message.kind != T.Kind.INPUT_ACK:
		semantic = Lifecycle.semantic(message)
		if semantic.is_empty() or not scenario_settings.has("lifecycle"):
			_fail("unsupported outgoing kind")
			return {}
	return {"packet": packet, "semantic": semantic}


func _register(item: Dictionary, outgoing: Array[int]) -> void:
	var packet: RefCounted = item.packet
	var id: int = packets.size()
	outgoing.append(id)
	packets.append({"id": id, "from": item.sender, "to": item.destination, "semantic": item.semantic})
	raw_packets.append(packet.bytes.duplicate())


func _events(peer: RefCounted) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event: Dictionary in peer.drain_events():
		var copy: Dictionary = event.duplicate(true)
		if copy.get("peer") is PackedByteArray:
			copy.peer = copy.peer.decode_u64(0) - 1
		if copy.kind == "inputs_received" or (copy.kind == "disconnected" and typeof(copy.get("reason")) == TYPE_INT and copy.reason == 255):
			result.append(copy)
		else:
			if copy.has("disconnect_timeout_ms"):
				copy.disconnect_timeout = copy.disconnect_timeout_ms
				copy.erase("disconnect_timeout_ms")
			for key: String in ["local_checksum", "remote_checksum"]:
				if copy.get(key) is PackedByteArray:
					copy[key] = copy[key].hex_encode()
			observed_events.append(copy)
	return result


func _id(player: int) -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(8)
	bytes.encode_u64(0, player + 1)
	return bytes


func _token(player: int, remote: int) -> PackedByteArray:
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(16)
	bytes.encode_u64(0, player + 1)
	bytes.encode_u64(8, remote + 1)
	return bytes


func _fields(value: Variant, names: Array) -> bool:
	if not value is Dictionary or value.size() != names.size():
		return false
	for name: String in names:
		if not value.has(name):
			return false
	return true


## Godot JSON converts all numeric tokens to floats; preserve the original integer grammar.
func _integer_tokens(text: String) -> bool:
	var quoted: bool = false
	var escaped: bool = false
	var index: int = 0
	while index < text.length():
		var character: String = text[index]
		if quoted:
			if escaped:
				escaped = false
			elif character == "\\":
				escaped = true
			elif character == '"':
				quoted = false
		elif character == '"':
			quoted = true
		elif character == "-" or "0123456789".contains(character):
			while index < text.length() and "0123456789.eE+-".contains(text[index]):
				if text[index] in [".", "e", "E"]:
					return false
				index += 1
			continue
		index += 1
	return true


func _integer(value: Variant, low: int, high: int) -> bool:
	return (value is int or value is float) and is_finite(value) and value == floor(value) and value >= low and value <= high


func _valid(value: Variant) -> bool:
	var required: Array = ["format", "players", "input_delay", "max_prediction", "operations"]
	if value is Dictionary and value.has("lifecycle"):
		required.append("lifecycle")
	if value is Dictionary and value.has("queue_capacity"):
		required.append("queue_capacity")
	if value is Dictionary and value.has("layout"):
		required.append("layout")
	if not _fields(value, required):
		return false
	for field: String in ["format", "players", "input_delay", "max_prediction"]:
		var bounds: Array = {"format": [1, 1], "players": [2, 8], "input_delay": [0, 2], "max_prediction": [2, 8]}[field]
		if not _integer(value[field], bounds[0], bounds[1]):
			return false
	if value.has("queue_capacity"):
		if not _integer(value.queue_capacity, 2, 128):
			return false
		if int(value.queue_capacity) < int(value.input_delay) + int(value.max_prediction) + 2:
			return false
	# Explicit endpoint layout: machine counts, per-machine slot coverage and the shared
	# slot total. An omitted field stays one local slot per endpoint. Lifecycle timers
	# stay a single-local slice, exactly like the shared Python grammar.
	if value.has("layout"):
		if not value.layout is Array or value.layout.size() < 2 or value.layout.size() > int(value.players):
			return false
		var covered: int = 0
		for size: Variant in value.layout:
			if not _integer(size, 1, 8):
				return false
			covered += int(size)
		if covered != int(value.players):
			return false
		if value.has("lifecycle"):
			return false
	# The peer session refuses any agreed initial delay above its own unclamped bound.
	var capacity_bound: int = int(value.queue_capacity) if value.has("queue_capacity") else 128
	if int(value.input_delay) > (capacity_bound - 2 * int(value.max_prediction) - 2) / 2:
		return false
	if value.has("lifecycle"):
		var settings: Variant = value.lifecycle
		if not _fields(settings, ["quality_us", "keepalive_us", "notify_us", "timeout_us", "checksum_interval", "divergent_peer"]):
			return false
		for key: String in ["quality_us", "keepalive_us"]:
			if not _integer(settings[key], 1000, 100000000):
				return false
		if not _integer(settings.notify_us, 1, 9999999) or not _integer(settings.timeout_us, int(settings.notify_us) + 1, 10000000):
			return false
		if not _integer(settings.checksum_interval, 0, 60) or not _integer(settings.divergent_peer, -1, int(value.players) - 1):
			return false
	if not value.operations is Array or value.operations.is_empty() or value.operations.size() > 10000:
		return false
	var previous: int = 0
	var stepped: Dictionary = {}
	var addressed: int = -1
	for op: Variant in value.operations:
		if not op is Dictionary or not op.get("kind") is String or op.kind not in ["step", "poll", "deliver", "delay"]:
			return false
		var names: Array = {
			"step": ["kind", "peer", "now_us", "bytes"], "poll": ["kind", "peer", "now_us"], "deliver": ["kind", "packet", "now_us"], "delay": ["kind", "peer", "delay"]
		}[op.kind]
		if not _fields(op, names):
			return false
		if op.kind == "delay":
			# Only changes after the peer's first step, outside the band where the two bounds
			# differ; multi-local endpoints refuse runtime delay raises in production.
			if value.has("layout"):
				return false
			if not _integer(op.peer, 0, int(value.players) - 1) or not stepped.has(int(op.peer)) or addressed != int(op.peer) or not _integer(op.delay, 0, 1000):
				return false
			var window: int = int(value.max_prediction)
			var capacity: int = int(value.queue_capacity) if value.has("queue_capacity") else 128
			if int(op.delay) > (capacity - 2 * window - 2) / 2 and int(op.delay) <= capacity - 1 - window:
				return false
			continue
		if not _integer(op.now_us, previous, 10000000):
			return false
		previous = int(op.now_us)
		if op.kind == "step" and _integer(op.peer, 0, int(value.players) - 1):
			stepped[int(op.peer)] = true
		addressed = int(op.peer) if op.kind != "deliver" and _integer(op.peer, 0, int(value.players) - 1) else -1
		if op.kind == "deliver":
			if not _integer(op.packet, 0, 100000):
				return false
		elif not _integer(op.peer, 0, int(value.players) - 1) or (op.kind == "step" and not Game.Reference.valid_hex(op.bytes, 8)):
			return false
	return true


func _canonical(source: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for field: String in ["format", "players", "input_delay", "max_prediction"]:
		result[field] = int(source[field])
	if source.has("queue_capacity"):
		result.queue_capacity = int(source.queue_capacity)
	if source.has("layout"):
		var layout: Array = []
		for size: Variant in source.layout:
			layout.append(int(size))
		result.layout = layout
	var operations: Array[Dictionary] = []
	for op: Dictionary in source.operations:
		if op.kind == "delay":
			operations.append({"kind": op.kind, "peer": int(op.peer), "delay": int(op.delay)})
			continue
		var converted: Dictionary = {"kind": op.kind, "now_us": int(op.now_us)}
		if op.kind == "deliver":
			converted.packet = int(op.packet)
		else:
			converted.peer = int(op.peer)
			if op.kind == "step":
				converted.bytes = op.bytes
		operations.append(converted)
	if source.has("lifecycle"):
		result.lifecycle = {}
		for key: String in source.lifecycle:
			result.lifecycle[key] = int(source.lifecycle[key])
	result.operations = operations
	return result


func _fail(message: String) -> void:
	print("FORTRESS_P2P_ERROR " + message)
	quit(2)
