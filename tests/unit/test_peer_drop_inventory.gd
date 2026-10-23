extends "res://tests/unit/test_peer_drop_barrier.gd"

const Inventory = preload("res://addons/fortress_rollback/core/peer_drop_inventory.gd")
const INVALID: Dictionary = {
	"unknown_version": 1,
	"empty_inventory": 1,
	"wrong_cardinality": 1,
	"wrong_target": 1,
	"unbounded_interval": 1,
	"changed_certificate": 2,
}

var _legacy_startup: bool = false
var _legacy_features: int = 0
var _startup_features: Array[int] = []
var _undercut_candidate: bool = false
var _candidate_count: int = 0
var _ready_cuts: Array[int] = []


func cases() -> PackedStringArray:
	return PackedStringArray(
		[
			"independent_inventory_golden",
			"startup_feature",
			"legacy_startup_refused",
			"retained_only_startup_refused",
			"control_packet_budget",
			"unknown_version",
			"empty_inventory",
			"wrong_cardinality",
			"wrong_target",
			"unbounded_interval",
			"changed_certificate",
			"candidate_below_receipts"
		]
	)


func run_case(name: String, context: RefCounted) -> void:
	_legacy_startup = name in ["legacy_startup_refused", "retained_only_startup_refused"]
	_legacy_features = T.FEATURE_RETAINED_DROP if name == "retained_only_startup_refused" else 0
	_startup_features.clear()
	_undercut_candidate = name == "candidate_below_receipts"
	_candidate_count = 0
	_ready_cuts.clear()
	if name == "candidate_below_receipts":
		_undercut(context)
	elif name == "control_packet_budget":
		_packet_budget(context)
	elif name in ["startup_feature", "legacy_startup_refused", "retained_only_startup_refused"]:
		var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE)
		context.equal(_startup_features.is_empty(), false, "the actual startup emitted feature-bearing packets")
		for features: int in _startup_features:
			context.equal(features, T.FEATURE_HISTORY_DROP, "graceful peers negotiate retained-history semantics before play")
		for peer: Peer in mesh.peers:
			context.equal(
				peer.status().lifecycle, Types.Lifecycle.TERMINATED if _legacy_startup else Types.Lifecycle.RUNNING, "legacy graceful semantics are refused before gameplay"
			)
	elif name == "independent_inventory_golden":
		_golden(context)
	else:
		_invalid(context, name)
	context.finish()


# Value: protects=per-target retained coverage is preserved exactly; fails_when=width/order/version silently changes; why_new=barrier carried only scalar receipt; seam=none
func _golden(context: RefCounted) -> void:
	var slots: PackedInt32Array = PackedInt32Array([1, 4])
	var receipts: Dictionary = {1: Vector2i(3, 9), 4: Vector2i(2, 8)}
	var bytes: PackedByteArray = PackedByteArray([1, 2, 1, 3, 0, 0, 0, 9, 0, 0, 0, 4, 2, 0, 0, 0, 8, 0, 0, 0])
	context.equal(Inventory.encode(receipts, slots), bytes, "independent little-endian interval golden")
	context.equal(Inventory.decode(bytes, slots, 128), receipts, "independent golden retains every target interval")
	context.equal(Inventory.covers(receipts, slots, 3, 8), true, "both complete ranges cover the requested cut")
	context.equal(Inventory.covers(receipts, slots, 3, 9), false, "one complete target cannot conceal another target's missing actual row")


# Value: protects=only a complete original per-target inventory certifies; fails_when=malformed or replaced READY interval commits;
# why_new=value digest does not establish earlier actual coverage; seam=none
func _invalid(context: RefCounted, name: String) -> void:
	var bytes: PackedByteArray = PackedByteArray([1, 1, 2, 0, 0, 0, 0, 8, 0, 0, 0])
	match name:
		"unknown_version":
			bytes[0] = 99
		"empty_inventory":
			bytes.clear()
		"wrong_cardinality":
			bytes[1] = 2
		"wrong_target":
			bytes[2] = 1
		"unbounded_interval":
			bytes.encode_s32(7, 2147483647)
		"changed_certificate":
			bytes.encode_s32(3, 1)
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE)
	_play(context, mesh, 6, true)
	_leave(context, mesh, 2)
	_detect(context, mesh, [0, 1], 800000, true, [{"phase": 2, "stage": INVALID[name], "fields": {"bytes": bytes}, "replace": true}], [], true)
	context.equal(mesh.cuts.is_empty(), true, "invalid inventory cannot authorize a cut")
	for survivor: int in [0, 1]:
		context.equal(mesh.peers[survivor].status().lifecycle, Types.Lifecycle.TERMINATED, "invalid coverage fails closed")
		context.equal(mesh.peers[survivor]._core.frozen_frame(2), -1, "partial rejection leaves every slot unfrozen")


func _deliver(context: RefCounted, mesh: Dictionary, packets: Array[Dictionary], terminated: bool = false) -> void:
	var delivered: Array[Dictionary] = []
	for packet: Dictionary in packets:
		var decoded: T.Result = Codec.decode(packet.bytes, _limits(mesh.count))
		if _undercut_candidate and decoded.code == T.Code.OK and decoded.message.kind == T.Kind.DROP_BARRIER:
			if decoded.message.phase == 1 and decoded.message.cut_digest != 0:
				_candidate_count += 1
				context.equal(decoded.message.cut, 8, "the real coordinator first selected every target receipt")
				decoded.message.cut = 5
				var value: PackedByteArray = _sample(2, 5)
				decoded.message.cut_digest = mesh.peers[0]._drops._digest(value)
				var altered: T.Result = Codec.encode(decoded.message, _limits(mesh.count))
				context.equal(altered.code, T.Code.OK, "the undercut remains a valid coordinator packet with matching retained value")
				delivered.append({"from": packet.from, "to": packet.to, "bytes": altered.bytes})
				continue
			if decoded.message.phase == 2 and decoded.message.stage == 2:
				_ready_cuts.append(decoded.message.cut)
		if decoded.code == T.Code.OK and decoded.message.kind in [T.Kind.SYNC_REQUEST, T.Kind.SYNC_REPLY]:
			_startup_features.append(decoded.message.features)
			if _legacy_startup:
				decoded.message.features = _legacy_features
				var encoded: T.Result = Codec.encode(decoded.message, _limits(mesh.count))
				context.equal(encoded.code, T.Code.OK, "encode a well-formed legacy feature offer")
				delivered.append({"from": packet.from, "to": packet.to, "bytes": encoded.bytes})
				continue
		delivered.append(packet)
	super._deliver(context, mesh, delivered, terminated or _legacy_startup)


# Value: protects=accepted graceful sessions can publish complete bounded inventories; fails_when=control cannot fit after valid handshake;
# why_new=INPUT and startup dimensions do not reserve retained-interval control bytes; seam=none
func _packet_budget(context: RefCounted) -> void:
	var config: Config = Config.new()
	config.player_count = 8
	config.local_players = PackedInt32Array([0])
	config.input_width = 4
	config.neutral_input = PackedByteArray([0, 0, 0, 0])
	config.sync_test = false
	config.check_distance = 0
	config.max_snapshot_bytes = 64
	config.storage_budget_bytes = 1048576
	var local: T.Message = T.Message.new()
	local.kind = T.Kind.SYNC_REQUEST
	local.sender_id = _id(0)
	local.connection_id = _id(20)
	local.session_id = _id(90, 16)
	local.config.player_count = 8
	local.config.input_width = 4
	local.config.neutral_input = config.neutral_input.duplicate()
	local.config.roster.clear()
	for slot: int in range(8):
		local.config.roster.append(_id(slot))
	var options: H.Options = H.Options.new()
	var controls: L.Options = L.Options.new()
	controls.enabled = true
	controls.disconnect_behavior = L.Disconnect.CONTINUE
	for limit: int in [195, 196]:
		options.max_packet_bytes = limit
		var peer: Peer = Peer.new()
		context.equal(
			peer.configure(config, local, Game.new(8), options, I.Options.new(), controls),
			I.Code.OK if limit == 196 else I.Code.INVALID_ARGUMENT,
			"full-roster inventory budget accepts exact bound and refuses one byte less"
		)
	context.equal(local.features, 0, "automatic negotiation never mutates the caller's profile")


# Value: protects=each survivor certifies its own highest actual receipt; fails_when=valid coordinator undercuts declared receipt with matching value;
# why_new=honest coordinator always selects the maximum so ordinary agreement hides missing follower validation; seam=none
func _undercut(context: RefCounted) -> void:
	var mesh: Dictionary = _build(context, L.Disconnect.CONTINUE)
	_play(context, mesh, 6, true)
	_leave(context, mesh, 2)
	_detect(context, mesh, [0, 1], 800000, true, [], [], true)
	context.equal(_candidate_count > 0, true, "the test altered an actual final candidate from the role-valid coordinator")
	context.equal(_ready_cuts.has(5), false, "a lower cut cannot produce an actual READY certificate")
	var follower: RefCounted = mesh.peers[1]._drops.barrier(_id(2).hex_encode())
	context.equal(5 >= follower.upper, true, "the hostile cut still covers the protected exposed frontier")
	context.equal(Inventory.highest(follower.receipts), 8, "the follower's own actual target receipts require a higher cut")
	context.equal(follower.certified, false, "matching value bytes cannot authorize a cut below declared receipts")
	context.equal(mesh.peers[1].status().lifecycle, Types.Lifecycle.TERMINATED, "the invalid candidate fails closed")
