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
const Game = preload("res://tests/oracle/p2p_game.gd")
const REVISION: String = "f13cd5c0f2815926785a395947e18da0dbea0dd8"
var peers: Array[RefCounted] = []
var games: Array[RefCounted] = []
var packets: Array[Dictionary] = []
var raw_packets: Array[PackedByteArray] = []
var records: Array[Dictionary] = []
var limits: T.Limits


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
	limits = T.Limits.new()
	limits.player_count = scenario.players
	limits.input_width = 4
	for player: int in range(scenario.players):
		var config: RefCounted = Config.new()
		config.player_count = scenario.players
		config.local_players = PackedInt32Array([player])
		config.input_width = 4
		config.neutral_input = PackedByteArray([0, 0, 0, 0])
		config.input_delay = scenario.input_delay
		config.max_prediction_frames = scenario.max_prediction
		config.history_slots = scenario.max_prediction + 1
		config.check_distance = 0
		config.sync_test = false
		config.max_snapshot_bytes = 4 * (scenario.players + 3)
		config.storage_budget_bytes = 1048576
		var local: T.Message = T.Message.new()
		local.kind = T.Kind.SYNC_REQUEST
		local.sender_id = _id(player)
		local.connection_id = _id(player)
		local.session_id = _token(0, 0)
		local.config.player_count = scenario.players
		local.config.input_width = 4
		local.config.input_delay = scenario.input_delay
		local.config.max_prediction = scenario.max_prediction
		local.config.neutral_input = config.neutral_input.duplicate()
		local.config.roster.clear()
		for slot: int in range(scenario.players):
			local.config.roster.append(_id(slot))
		var options: H.Options = H.Options.new()
		options.roundtrips = 1
		var game: RefCounted = Game.new(scenario.players)
		var peer: RefCounted = Peer.new()
		if peer.configure(config, local, game, options, I.Options.new()) != I.Code.OK:
			_fail("configuration")
			return
		peers.append(peer)
		games.append(game)
		var tokens: Array[PackedByteArray] = []
		for remote: PackedByteArray in peer.peer_ids():
			tokens.append(_token(player, remote.decode_u64(0)))
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


func _operation(op: Dictionary, index: int) -> bool:
	var player: int = int(op.get("peer", 0))
	if op.kind == "deliver":
		if op.packet >= packets.size():
			_fail("unobserved packet")
			return false
		player = packets[op.packet].to
	var peer: RefCounted = peers[player]
	var before: int = peer.status().current_frame
	var code: int = 0
	var error: Variant = null
	match op.kind:
		"step":
			var inputs: Array[Driver.LocalInput] = [Driver.LocalInput.new(player, before, String(op.bytes).hex_decode())]
			var result: Driver.StepResult = peer.step(op.now_us, inputs)
			if not result.events.is_empty():
				_fail("unmodeled core event")
				return false
			code = result.code
			if code != Types.Code.OK:
				error = Types.Code.find_key(code)
		"poll":
			code = peer.poll(op.now_us)
		"deliver":
			code = peer.receive_and_poll(raw_packets[op.packet], _id(packets[op.packet].from), op.now_us)
	if op.kind != "step" and code != I.Code.OK:
		_fail("network operation rejected")
		return false
	var outgoing: Array[int] = []
	for packet: RefCounted in peer.drain_outbox():
		limits.expected_session_id = _token(0, 0)
		limits.expected_sender_id = _id(player)
		limits.expected_connection_id = _id(player)
		var result: T.Result = Codec.decode(packet.bytes, limits)
		if result.code != T.Code.OK:
			_fail("outgoing codec")
			return false
		var message: T.Message = result.message
		var semantic: Dictionary = {"kind": "input_ack", "ack_frame": message.ack_frame}
		if message.kind == T.Kind.INPUT:
			var frames: Array[String] = []
			for frame: int in range(message.frame_count):
				frames.append(message.data.slice(frame * 4, (frame + 1) * 4).hex_encode())
			var statuses: Array[Dictionary] = []
			for status: T.Status in message.statuses:
				statuses.append({"disconnected": status.disconnected, "epoch": status.epoch, "last_frame": status.last_frame})
			semantic = {
				"kind": "input", "ack_frame": message.ack_frame, "start_frame": message.start_frame, "players": Array(message.players), "frames": frames, "statuses": statuses
			}
		elif message.kind != T.Kind.INPUT_ACK:
			_fail("unsupported outgoing kind")
			return false
		var id: int = packets.size()
		outgoing.append(id)
		packets.append({"id": id, "from": player, "to": packet.to.decode_u64(0) - 1, "semantic": semantic})
		raw_packets.append(packet.bytes.duplicate())
	var game: RefCounted = games[player]
	records.append(
		{
			"index": index,
			"peer": player,
			"frame_before": before,
			"frame_after": peer.status().current_frame,
			"confirmed_frame": peer.status().confirmed_frame,
			"error": error,
			"requests": game.requests.duplicate(true),
			"events": [],
			"extension_events": _events(peer),
			"outgoing": outgoing,
			"state": game.game.bytes().hex_encode()
		}
	)
	game.requests.clear()
	return true


func _events(peer: RefCounted) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event: Dictionary in peer.drain_events():
		var copy: Dictionary = event.duplicate(true)
		if copy.get("peer") is PackedByteArray:
			copy.peer = copy.peer.decode_u64(0) - 1
		result.append(copy)
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
	if not _fields(value, ["format", "players", "input_delay", "max_prediction", "operations"]):
		return false
	for field: String in ["format", "players", "input_delay", "max_prediction"]:
		var bounds: Array = {"format": [1, 1], "players": [2, 8], "input_delay": [0, 2], "max_prediction": [2, 8]}[field]
		if not _integer(value[field], bounds[0], bounds[1]):
			return false
	if not value.operations is Array or value.operations.is_empty() or value.operations.size() > 10000:
		return false
	var previous: int = 0
	for op: Variant in value.operations:
		if not op is Dictionary or not op.get("kind") is String or op.kind not in ["step", "poll", "deliver"]:
			return false
		var names: Array = {"step": ["kind", "peer", "now_us", "bytes"], "poll": ["kind", "peer", "now_us"], "deliver": ["kind", "packet", "now_us"]}[op.kind]
		if not _fields(op, names) or not _integer(op.now_us, previous, 10000000):
			return false
		previous = int(op.now_us)
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
	var operations: Array[Dictionary] = []
	for op: Dictionary in source.operations:
		var converted: Dictionary = {"kind": op.kind, "now_us": int(op.now_us)}
		if op.kind == "deliver":
			converted.packet = int(op.packet)
		else:
			converted.peer = int(op.peer)
			if op.kind == "step":
				converted.bytes = op.bytes
		operations.append(converted)
	result.operations = operations
	return result


func _fail(message: String) -> void:
	print("FORTRESS_P2P_ERROR " + message)
	quit(2)
