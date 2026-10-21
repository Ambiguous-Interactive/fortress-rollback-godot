class_name FortressSpectatorNegotiation
extends RefCounted

# gdlint: disable=constant-name,max-returns

enum AgreementState { PENDING, AGREED, REFUSED }

const Types = preload("res://addons/fortress_rollback/core/session_types.gd")
const Code = Types.Code

## Startup exchange kinds. ROW, END and keepalive keep their version 2 values.
const OFFER: int = 4
const ACCEPT: int = 5

## Capability bits of the optional packet kinds.
const CAP_ROW: int = 1
const CAP_END: int = 2
const CAP_KEEPALIVE: int = 4
const CAP_ALL: int = CAP_ROW | CAP_END | CAP_KEEPALIVE

## Capability body: u32 version mask, then u32 kind mask.
const CAPABILITY_BYTES: int = 8
const MAX_VERSION: int = 31

## One side's negotiated envelope agreement.
## The state is PENDING before the exchange, AGREED after it and REFUSED after it fails.
var _state: int = AgreementState.PENDING
var _version: int = 0
var _kinds: int = 0
var _reason: int = Code.OK


## A fresh lifetime starts without an agreement.
func reset() -> void:
	_state = AgreementState.PENDING
	_version = 0
	_kinds = 0
	_reason = Code.OK


func state() -> int:
	return _state


## The agreed envelope version, or zero before the agreement.
func version() -> int:
	return _version


## The agreed optional kinds, or zero before the agreement.
func kinds() -> int:
	return _kinds


## The one recorded refusal reason, or OK while the agreement holds.
func reason() -> int:
	return _reason


func agreed() -> bool:
	return _state == AgreementState.AGREED


func refused() -> bool:
	return _state == AgreementState.REFUSED


## Record the agreed envelope version and the agreed optional kinds.
func agree(version: int, kinds: int) -> void:
	_state = AgreementState.AGREED
	_version = version
	_kinds = kinds
	_reason = Code.OK


## Record one refusal reason. A refused agreement never starts a partial playback.
func refuse(reason: int) -> void:
	_state = AgreementState.REFUSED
	_version = 0
	_kinds = 0
	_reason = reason


## The envelope versions of one implementation, as a bitmask over the version number.
static func supported_versions(version: int) -> int:
	if version < 1 or version > MAX_VERSION:
		return 0
	return 1 << version


## The highest version in a mask, or zero when the mask is empty.
static func highest_version(mask: int) -> int:
	var version: int = 0
	for candidate: int in range(1, MAX_VERSION + 1):
		if (mask & (1 << candidate)) != 0:
			version = candidate
	return version


## The version both sides speak, or zero when they share none.
static func common_version(offered: int, supported: int) -> int:
	return highest_version(offered & supported)


## True when the offered kinds are known and carry the mandatory row and end kinds.
## A host that cannot deliver a row or close its stream is refused.
static func kinds_acceptable(offered: int) -> bool:
	return (offered & ~CAP_ALL) == 0 and (offered & CAP_ROW) != 0 and (offered & CAP_END) != 0


## True when the accepted kinds stay inside the offered kinds and keep the row and end kinds.
## The optional keepalive kind may be dropped, so a viewer that does not want
## liveness packets never receives one.
static func kinds_within(accepted: int, offered: int) -> bool:
	return (accepted & ~offered) == 0 and (accepted & CAP_ROW) != 0 and (accepted & CAP_END) != 0


## The capability body: the version mask, then the kind mask.
static func encode_capabilities(version_mask: int, kind_mask: int) -> PackedByteArray:
	var buffer: StreamPeerBuffer = StreamPeerBuffer.new()
	buffer.big_endian = false
	buffer.put_u32(version_mask)
	buffer.put_u32(kind_mask)
	return buffer.data_array


## The capability body of one packet, or an empty array when the body is malformed.
static func decode_capabilities(packet: PackedByteArray, offset: int) -> PackedInt64Array:
	if packet.size() < offset + CAPABILITY_BYTES:
		return PackedInt64Array()
	return PackedInt64Array([packet.decode_u32(offset), packet.decode_u32(offset + 4)])
