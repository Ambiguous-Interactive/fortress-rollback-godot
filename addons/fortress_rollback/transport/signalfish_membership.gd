class_name FortressSignalFishMembership
extends RefCounted

# gdlint: disable=max-returns
const T = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const Codec = preload("res://addons/fortress_rollback/protocol/protocol_codec.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const I = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")

var _local: String = ""
var _roster: PackedStringArray = PackedStringArray()
var _session: PackedByteArray = PackedByteArray()
var _incarnation: PackedByteArray = PackedByteArray()
var _profile: T.Config = null
var _digest: PackedByteArray = PackedByteArray()
var _ids: Dictionary = {}
var _godot_ids: Dictionary = {}


## Freeze one UUID per player slot. A new rollback session requires a new instance.
## incarnation_id is application-supplied transport identity, not an SDK reconnect token.
func configure(local_uuid: String, roster: PackedStringArray, session_id: PackedByteArray, incarnation_id: PackedByteArray, profile: T.Config) -> Error:
	if _profile != null:
		return ERR_ALREADY_IN_USE
	if roster.size() < 2 or roster.size() > 8 or not valid_uuid(local_uuid) or session_id.size() != 16 or incarnation_id.size() != 8 or profile == null:
		return ERR_INVALID_PARAMETER
	if profile.player_count != roster.size():
		return ERR_INVALID_PARAMETER
	var sorted: PackedStringArray = roster.duplicate()
	sorted.sort()
	var identities: Dictionary = {}
	var numeric: Dictionary = {}
	var core: Dictionary = {}
	for uuid: String in sorted:
		if not valid_uuid(uuid) or identities.has(uuid):
			return ERR_INVALID_DATA
		var identity: PackedByteArray = uuid.sha256_buffer().slice(0, 8)
		var godot_id: int = uuid_to_peer_id(uuid)
		if numeric.has(godot_id) or core.has(identity.hex_encode()):
			return ERR_ALREADY_EXISTS
		identities[uuid] = identity
		numeric[godot_id] = uuid
		core[identity.hex_encode()] = uuid
	if not identities.has(local_uuid):
		return ERR_INVALID_DATA
	var owned: T.Config = _copy_profile(profile)
	owned.roster.clear()
	for uuid: String in sorted:
		owned.roster.append(identities[uuid].duplicate())
	var bounds: T.Limits = T.Limits.new()
	bounds.player_count = owned.player_count
	bounds.input_width = owned.input_width
	var encoded: T.Result = Codec.encode_config(owned, bounds)
	if encoded.code != T.Code.OK:
		return ERR_INVALID_DATA
	var canonical: PackedByteArray = "fortress-signalfish-membership-v1".to_utf8_buffer()
	for uuid: String in sorted:
		canonical.append_array(uuid.to_utf8_buffer())
	canonical.append_array(encoded.bytes)
	_local = local_uuid
	_roster = sorted
	_session = session_id.duplicate()
	_incarnation = incarnation_id.duplicate()
	_profile = owned
	_digest = _sha256(canonical).slice(0, 8)
	_ids = identities
	_godot_ids = numeric
	return OK


## Build the existing protocol handshake, including full UUID roster agreement.
func handshake_message() -> T.Message:
	if _profile == null:
		return null
	var message: T.Message = T.Message.new()
	message.kind = T.Kind.SYNC_REQUEST
	message.sender_id = identity(_local)
	message.session_id = _session.duplicate()
	message.connection_id = _incarnation.duplicate()
	message.config = _copy_profile(_profile)
	message.config_digest = _digest.duplicate()
	return message


## The peer's existing handshake gates simulation until every remote agrees.
## Local slots are derived on an owned config; the supplied config is unchanged.
func configure_peer(peer: Peer, config: Config, game: RefCounted, handshake_options: RefCounted, input_options: RefCounted, lifecycle_options: RefCounted = null) -> int:
	if _profile == null or peer == null or config == null:
		return I.Code.INVALID_ARGUMENT
	var owned: Config = config.owned_copy()
	owned.local_players = PackedInt32Array([slot(_local)])
	return peer.configure(owned, handshake_message(), game, handshake_options, input_options, lifecycle_options)


func roster() -> PackedStringArray:
	return _roster.duplicate()


func local_uuid() -> String:
	return _local


func slot(uuid: String) -> int:
	return _roster.find(uuid)


func identity(uuid: String) -> PackedByteArray:
	return _ids[uuid].duplicate() if _ids.has(uuid) else PackedByteArray()


func uuid_for_peer_id(peer_id: int) -> String:
	return _godot_ids.get(peer_id, "")


## Attribute protocol bytes through the frozen full UUID mapping, never payload claims.
func receive(peer: Peer, packet: PackedByteArray, attributed_uuid: String, now_us: int, next_token: Variant = null) -> int:
	# next_token is the existing protocol's nullable owned token input.
	if peer == null or not _ids.has(attributed_uuid) or attributed_uuid == _local:
		return I.Code.WRONG_SOURCE
	return peer.receive(packet, identity(attributed_uuid), now_us, next_token)


## Pinned SFWebRTCMesh.uuid_to_peer_id: FNV-1a and the same 31-bit squeeze.
static func uuid_to_peer_id(uuid: String) -> int:
	var digest: int = -3750763034362895579
	for index: int in uuid.length():
		digest = ((digest ^ uuid.unicode_at(index)) * 1099511628211) & 0x7fffffffffffffff
	var value: int = digest & 0x7fffffff
	return value + 2 if value < 2 else value


static func valid_uuid(uuid: String) -> bool:
	if uuid.length() != 36:
		return false
	for index: int in 36:
		var character: String = uuid.substr(index, 1)
		if index in [8, 13, 18, 23]:
			if character != "-":
				return false
		elif character not in "0123456789abcdef":
			return false
	return true


static func _copy_profile(profile: T.Config) -> T.Config:
	var owned: T.Config = T.Config.new()
	var fields: Array[String] = [
		"player_count", "input_width", "fps", "max_prediction", "input_delay", "desync_interval", "input_format", "snapshot_format", "checksum_algorithm", "queue_capacity"
	]
	for field: String in fields:
		owned.set(field, profile.get(field))
	owned.neutral_input = profile.neutral_input.duplicate()
	owned.roster.clear()
	for owner: PackedByteArray in profile.roster:
		owned.roster.append(owner.duplicate())
	return owned


static func _sha256(bytes: PackedByteArray) -> PackedByteArray:
	var context: HashingContext = HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish()
