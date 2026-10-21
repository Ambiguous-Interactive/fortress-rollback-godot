# Godot protocol codec v1

The shipped [codec](../addons/fortress_rollback/protocol/protocol_codec.gd)
serializes bounded messages for fixed rosters of 2–8 players. It is a byte
boundary for the planned P2P endpoint; it does not implement synchronization,
retransmission, acknowledgements, timeouts or remote input acceptance.
The local session remains the implemented gameplay API.

The wire format is Godot-specific. Rust bincode interoperability is outside
scope. Every integer uses fixed-width little-endian encoding. No Variant,
JSON, float, engine object serialization or compressed input encoding occurs.
Unsigned 64/128-bit identities, tokens, digests and checksums remain exact
byte arrays; never convert them to signed integers or JSON numbers.

## Public API

Import `protocol_codec.gd` and `protocol_types.gd`. The types script defines
`Message`, `Config`, `Limits`, `Status`, `Result`, `Kind` and `Code`.

| Operation | Result |
| --- | --- |
| `encode(message, limits)` | `Result.code`, owned `Result.bytes` on success |
| `decode(packet, limits)` | `Result.code`, owned `Result.message` on success |
| `semantic_projection(message, limits)` | `Result.code`, owned `Result.projection` fields for layout-independent oracle comparison |
| `encode_config(config, limits)` | Canonical owned configuration bytes |
| `configuration_matches(first, second, limits)` | True only for valid, byte-equal configurations |

Public boundary arguments deliberately accept `Variant` to reject wrong types
with `INVALID_TYPE` instead of producing an engine conversion error. Records
and their fields are typed; callers construct the appropriate records first.
Errors return empty bytes and a null message. Failures do not mutate input
records, packets or limits. All successful output bytes and decoded fields
own their storage. Encoding observes the record at call time and retains no
references to it after returning.

`Limits` must explicitly match the roster cardinality and fixed input width.
Defaults are 2 players, one-byte inputs, 128 input frames and 65536 packet
bytes. Hard ceilings are 8 players, 65536 input bytes per player, 65535 frames
per input packet and 1048576 packet bytes. Packet capacity must be at least
44 bytes. The actual encoded message must fit the configured packet cap;
not every combination of individually valid maxima can fit one packet.
Applications split redundant input history into complete bounded packets.

Optional `expected_session_id` (16 bytes), `expected_sender_id` (8 bytes) and
`expected_connection_id` (8 bytes) reject mismatches with `IDENTITY_MISMATCH`.
An empty expectation disables that check for setup/offline inspection.
Production receive paths must supply the active session/connection and the
transport-attributed sender. These identities are opaque; the codec accepts
all bit patterns, including zero. Allocation of fresh identities and mapping
roster slots to authenticated transport senders belong to the endpoint.

## Envelope

| Offset | Field | Width |
| --- | --- | --- |
| 0 | ASCII `FRGP` | 4 bytes |
| 4 | Layout version, exactly 2 | u16 |
| 6 | Message kind | u8 |
| 7 | Flags, exactly 0 | u8 |
| 8 | Session identity | 16 bytes |
| 24 | Sender identity | 8 bytes |
| 32 | Connection incarnation identity | 8 bytes |
| 40 | Payload length, excluding header | u32 |
| 44 | Payload | Declared length |

The header length is 44 bytes. The declared payload must consume the complete
packet. Unknown versions, kinds, flags and trailing bytes are rejected.
Layout-version agreement is separate from the synchronization payload's
minimum semantic compatibility version. The codec preserves all u8 semantic
versions so the endpoint can diagnose incompatibility. Layout version 2 adds
`queue_capacity` to the configuration and `max_packet_bytes` to synchronization
messages, so version 1 peers are rejected. No
fallback negotiation is implemented.

## Message payloads

Fields appear left to right, without padding. `i32 frame` accepts
`0..2147483647`; nullable frames additionally accept `-1`. Other negative
values are invalid. A checksum frame and an input start frame are never null.

| Kind | Name | Payload |
| --- | --- | --- |
| 1 | `SYNC_REQUEST` | token[16], min_compat_version:u8, features:u32, configuration, config_digest[8], max_packet_bytes:u32 |
| 2 | `SYNC_REPLY` | Same layout; token echoes the request token |
| 3 | `INPUT` | start_frame:i32, ack_frame:i32, frame_count:u16, player_count:u8, players[player_count], status_count:u8, statuses[status_count], data_length:u32, data[data_length] |
| 4 | `INPUT_ACK` | ack_frame:i32, nullable |
| 5 | `QUALITY_REPORT` | frame_advantage:i16, token[16] |
| 6 | `QUALITY_REPLY` | token[16], echoes report token |
| 7 | `CHECKSUM_REPORT` | frame:i32, checksum[16] |
| 8 | `KEEP_ALIVE` | Empty |
| 9 | `GOODBYE` | reason:u8 |
| 10 | `FLOOR_REQUEST` | round_seq:u32 |
| 11 | `FLOOR_REPLY` | round_seq:u32, count:u8, floors[count]:i32, nullable |
| 12 | `DROP_BARRIER` | phase:u8, stage:u8, reason:u8, reserved:u8, coordinator:u16, coordinator_generation:u16, operation:u32, target_set_digest:u64, cut:i32, nullable, bound:i32, nullable, available_through:i32, nullable, cut_digest:u64, chunk_index:u16, chunk_count:u16, reserved:u16, target_bytes:u32, target_bytes[target_bytes], value_bytes:u32, value_bytes[value_bytes] |

The codec preserves all u32 feature masks for endpoint agreement checks.
Parsing a feature bit does not enable its behavior. `GOODBYE.reason` preserves
all u8 values; policy maps known reasons and handles unknown reasons explicitly.

`DROP_BARRIER` carries the coordinated drop of a departed peer. Its phase is
`1` for the prepare, `2` for a survivor's report, `3` for the backfill of the
frozen value, `4` for the commit and `5` for the abort. Its stage is `1` for
an inventory report, `2` for a certificate and `3` for the committed
acknowledgement. The operation identity names the coordinator slot, the
coordinator's connected era, the operation sequence and the digest of the
target set; an older identity never joins the agreement. The cut is the frame
the sender proposes or accepts, the bound is the oldest frame the sender can
still freeze and `available_through` is the frame through which the sender
still retains the departed slot's inputs. The target list names the departed
peer's slots in increasing order, each with its connected era, and the value
bytes carry one bounded chunk of the frozen value. The barrier is a Godot-scoped
tier: the pinned source keeps its coordinated drop in a different byte layout,
so the eleven pinned kinds keep the golden fixtures and this kind has its own
round-trip and rejection coverage.

An input packet carries at least one complete frame and one slot. `players`
contains strictly increasing, unique slot indices in the fixed roster.
Data is frame-major, then listed-player-major, with `Limits.input_width` bytes
per player sample. Its length must equal
`frame_count * players.size() * input_width`; no partial sample is accepted.
The last included frame may reach 2147483647 but cannot overflow it.
`ack_frame` is the peer's cumulative receipt acknowledgement, independent of
the packet's input start; `-1` means no acknowledged frame.

Every input carries exactly one status for every roster slot, in slot order.
A status is `disconnected:u8` (exactly 0 or 1), `last_frame:i32` (nullable),
`epoch:u16`, totaling 7 bytes. The epoch survives encoding unchanged.
A floor reply likewise requires exactly one nullable frame for every slot.
Codec success does not authorize a status transition, a floor advance or a
slot's input: freshness, ownership, duplicate/reordered data, ACK bounds,
round sequence and lifecycle checks remain endpoint responsibilities.

## Canonical configuration

| Field | Encoding | Accepted values |
| --- | --- | --- |
| player_count | u8 | 2–8, independently of the local player's configuration |
| input_width | u32 | 1–65536, independently of the local input width |
| fps | u32 | 1–4294967295 |
| max_prediction | u16 | 0–128 |
| input_delay | u16 | 0–65535 |
| desync_interval | u32 | 0 disables detection; otherwise positive |
| input_format | u32 | Positive application input format version |
| snapshot_format | u32 | Positive application snapshot format version |
| checksum_algorithm | u32 | Positive application checksum algorithm identifier |
| queue_capacity | u32 | 2–65536; must equal the session `queue_capacity` |
| neutral_input | input_width bytes | Exact width, owned bytes |
| roster | player_count × 8 bytes | Slot-ordered peer identities |

The projection contains kind, identities and exactly the fields relevant to that
kind. Wide byte fields use lowercase hex strings; bounded numeric fields stay
integers. Slots/statuses/floors retain array order. Returned nested arrays and
dictionaries are newly constructed; no record storage is exposed.

The fixed configuration part is 33 bytes. Roster entries can repeat because one endpoint
may own several player slots. Transport identities are never renumbered during
a live session. The input width uses u32 so the local engine's supported
65536-byte input domain remains representable.

Handshake dimensions are bounded before reading variable bytes, then compared
by the endpoint. This allows player-count and input-width mismatch events.
Gameplay input/status/floor geometry still uses the agreed `Limits` values.

`config_digest` is an opaque application-supplied 8-byte compatibility digest
for additional game agreement beyond these explicit fields. It is preserved
without hashing, integer conversion or inferred authentication. The endpoint
must compare both canonical configuration bytes and this digest, alongside
version/features and a matching echoed token, before declaring synchronization.
Equal digests do not replace exact comparison of the explicit configuration.

`max_packet_bytes` (44–1048576) is the largest packet the sender accepts. Peers
may differ: each endpoint sizes input batches to fit the smaller of its own
limit and the smallest limit in the remote's accepted replies.

The codec validates representation and bounds; it does not declare a peer's
configuration agreed or a cryptographic checksum valid.

## Bounded parsing

Packet size is rejected before a packet copy or reader is allocated. Writers
validate records and compute exact payload size before allocating output.
Readers check every primitive and byte slice against remaining bytes. Variable
counts are compared with configured bounds before constructing collections:
config width/cardinality before neutral/roster bytes; player/frame counts before
input bytes; status/floor counts before records. A declared input byte count
must match complete sample geometry before copying. All arithmetic operands
are capped so products remain within signed-64 range. Malformed prefixes,
invalid flags, reserved sentinels and excess bytes return typed errors without
assertions or partially decoded records.

## Pinned source audit and scope

The semantic reference is Fortress
`f13cd5c0f2815926785a395947e18da0dbea0dd8`, particularly
`src/network/messages.rs` and the bounded decoder in `src/network/codec.rs`.

| Pinned family | Godot v1 decision |
| --- | --- |
| Header sentinel/version/flags/conn_id | Explicit Godot header, plus session and sender; connection identity widened to opaque 8 bytes |
| SyncRequest/SyncReply | Preserve challenge/echo, minimum compatibility, features, configuration and wide digest; injected challenge widened to 16 bytes |
| SessionConfigBlock | Preserve player count/input width/fps/prediction/desync interval; add delay, game formats, queue capacity, neutral bytes and ordered roster |
| Input/InputAck/ConnectionStatus | Preserve input start, cumulative ACK and every roster status including epoch; complete uncompressed samples replace Rust compressed bytes |
| QualityReport/QualityReply | Preserve signed i16 advantage and full 128-bit ping/pong token |
| ChecksumReport | Preserve full frame domain and u128 checksum bytes |
| KeepAlive/Goodbye | Preserve empty keepalive and u8 terminal reason |
| FloorRequest/FloorReply | Preserve u32 round sequence and all nullable roster floors |
| DropPrepare/DropReport/DropBackfill/DropCommit/DropAbort | Deferred coordinated graceful-drop tier; the Godot scoped `DROP_BARRIER` kind carries its own layout |
| JoinRequest/StateSnapshot/StateSnapshotAck/ReactivateSlot/ReactivateSlotAck/JoinCommitted/JoinAborted | Deferred snapshot transfer, hot join and reactivation; unknown kinds rejected |

Floor/status representation does not advertise recovery or coordinated drop
support. The first session tier terminates on unrecoverable history loss and
keeps a fixed roster. Compression, fragmentation/snapshot transport, spectators,
hot join and transparent recovery remain outside this codec release.

[Independent golden fixtures](../tests/fixtures/protocol/golden.json) encode
all eleven kinds with a separate Python fixed-width layout. The
[codec suite](../tests/unit/test_protocol_codec.gd) checks those bytes, ownership,
malformed prefixes/counts, negotiated bounds and semantic field preservation.
Runtime endpoint integration and supported native/browser release validation
remain separate roadmap gates.

## Translated rejection controls

The pinned `src/network/codec.rs` controls below define semantic rejection
classes; Godot tests translate them into this layout instead of passing Rust
bincode packets to a different decoder.

| Pinned control | Godot boundary |
| --- | --- |
| `decode_message_rejects_every_truncated_handshake_field` | Every shorter prefix of each supported packet fails |
| `decode_message_rejects_every_invalid_v2_header_before_body_decode` | Bad magic, version, flags and unknown kind fail |
| `decode_message_rejects_vec_length_that_exceeds_packet_bytes` | Status/slot/floor counts must match configured roster bounds |
| `decode_message_rejects_input_bytes_length_that_exceeds_packet_bytes` | Data count must match complete sample geometry and remaining packet bytes |
| `decode_message_rejects_negative_connection_status_frame` | Status frame less than -1 fails |
| `decode_message_rejects_negative_floor_reply_frame` | Floor frame less than -1 fails |
| `decode_message_rejects_negative_checksum_frame` | Any negative checksum frame fails |
| `decode_message_allows_null_connection_status_and_floor_frames` | Nullable fields preserve -1 |
| `decode_message_accepts_maximum_frame_for_all_d12_fields` | Signed-i32 maximum frame is preserved |
| `decode_message_rejects_trailing_bytes` | Envelope/body must consume exactly the packet |

Rust's default `Input.start_frame = -1` with empty bytes is representable there,
but the supported pending-input/nudge send paths supply actual complete frames.
Godot v1 deliberately requires positive frame count and nonnull start. ACK-only
and keepalive traffic have dedicated kinds. This restriction is not a claim of
whole-library parity or drop/hot-join support. Independent semantic fixtures
and the projection distinguish field preservation from mere byte roundtrip.
