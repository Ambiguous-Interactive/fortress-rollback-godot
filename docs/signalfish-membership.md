# SignalFish membership seam

The optional seam freezes a 2–8 player UUID roster and configures the existing
`FortressPeerSession` handshake. It consumes pinned SDK v3 session plans through
`SignalFishClient.session_plan` and attaches `SFWebRTCMesh` through its public API.
The addon parses and runs when the SDK is absent. Install the SDK separately
only in applications that use SignalFish.

This membership seam does not implement byte delivery or automatic transport fallback.
The separate [binary relay adapter](signalfish-relay.md) supplies recipient envelopes
and bounded send/receive queues. The [WebRTC adapter](signalfish-webrtc.md) owns
direct packet delivery. The membership seam's `status().byte_delivery_implemented` is always
`false`. Applications still supply bytes, attributed senders, clocks and tokens,
and drain the peer's bounded outputs. The [fallback coordinator](signalfish-fallback.md)
owns automatic path selection. Do not treat `route == "mesh"` as a connected gameplay session.

## Freeze membership and configure a peer

Run this after the room baseline has established all participating player UUIDs,
before the first session plan. The roster contains one UUID per player slot.
Every participant must agree the same 16-byte rollback session ID and protocol
configuration through an application-controlled setup step. A room ID, plan
generation or reconnect token is not a rollback session ID.

The application supplies an owned eight-byte transport-incarnation ID for each
local connection lifetime. It must change for a new transport lifetime and stay
stable during the handshake. This is distinct from the server's player `epoch`;
the pinned SDK retains that epoch in `PlayerInfo.raw`, but its binary receive
signal exposes no epoch. This seam cannot prove relay incarnation from that
signal. A reconnect therefore requires explicit termination and a new session.

The following code assumes installed SDK instances `client` and `mesh`, game
callbacks `game`, and already agreed `session_id` and `incarnation_id` byte arrays:

```gdscript
const Membership = preload("res://addons/fortress_rollback/transport/signalfish_membership.gd")
const Adapter = preload("res://addons/fortress_rollback/transport/signalfish_adapter.gd")
const Peer = preload("res://addons/fortress_rollback/core/peer_session.gd")
const Config = preload("res://addons/fortress_rollback/core/config.gd")
const Protocol = preload("res://addons/fortress_rollback/protocol/protocol_types.gd")
const Handshake = preload("res://addons/fortress_rollback/protocol/handshake_types.gd")
const Inputs = preload("res://addons/fortress_rollback/protocol/input_endpoint_types.gd")

var roster: PackedStringArray = PackedStringArray()
for player: RefCounted in client.get_players():
    roster.append(player.get("id"))
var profile: Protocol.Config = Protocol.Config.new()
profile.player_count = roster.size()
profile.input_width = 4
profile.neutral_input = PackedByteArray([0, 0, 0, 0])
var membership: Membership = Membership.new()
var code: Error = membership.configure(
    client.get_player_id(), roster, session_id, incarnation_id, profile
)
if code != OK:
    return code
var config: Config = Config.new()
config.player_count = roster.size()
config.input_width = 4
config.neutral_input = profile.neutral_input.duplicate()
config.sync_test = false
config.check_distance = 0
config.max_snapshot_bytes = 4096
config.storage_budget_bytes = 1048576
var peer: Peer = Peer.new()
var configured: int = membership.configure_peer(
    peer, config, game, Handshake.Options.new(), Inputs.Options.new()
)
if configured != 0:
    return ERR_INVALID_DATA
var adapter: Adapter = Adapter.new()
code = adapter.attach(client, mesh, membership)
```

The profile and the session config must agree on player count, input width, neutral bytes, delay,
prediction window and `queue_capacity`. Otherwise `configure_peer` refuses the peer. Set both when you
change a default.

Retain the adapter and membership alongside the peer. Keep SDK Nodes alive and
call `adapter.detach()` before freeing them. The adapter uses weak SDK references
and does not own the Nodes. Keep one consumer of mesh packet reads.

Call `peer.begin(now_us, tokens)` using a unique 16-byte token per remote peer,
in `peer.peer_ids()` order. Use the existing [peer-session API](peer-session.md)
for polling, stepping, outputs, events and lifecycle diagnostics. Simulation
remains gated by the real peer handshake until every remote agrees.

## Identity and ownership contract

UUIDs must be lowercase canonical hyphenated text. Membership sorts them
lexicographically once. Their positions become player slots; later roster or
plan order cannot renumber them. Multiple local slots per UUID and spectators
are outside this seam's current scope.

Core sender IDs are the first eight SHA-256 bytes of each full UUID. Godot mesh
IDs follow the pinned `SFWebRTCMesh.uuid_to_peer_id` FNV-1a mapping. Both mapping
spaces are checked independently for collisions before accepting membership.
A collision refuses setup rather than assigning an alternate ID.

The protocol configuration digest is the first eight SHA-256 bytes of:
`fortress-signalfish-membership-v1`, sorted fixed-width UUID text, and the existing
canonical `ProtocolCodec.encode_config` bytes. Full UUIDs are included, not just
compressed sender IDs. The peer's existing handshake compares the digest,
configuration and roster. The session ID is independently checked by its codec.
This is agreement and attribution validation, not cryptographic authentication.

Configuration, rosters, IDs and returned handshake messages own their bytes.
`configure_peer` derives local slots on a copied config and leaves the supplied
config unchanged. An accepted membership cannot be reconfigured.

`membership.receive(peer, bytes, attributed_uuid, now_us, next_token)` rejects
unknown or local UUIDs before passing the frozen core sender ID to the existing
peer decoder. `adapter.receive_mesh` resolves the SDK-attributed Godot numeric
ID; `adapter.receive_relay` accepts the SDK-attributed full UUID. The peer decoder
then validates sender, session and connection identity. The binary relay adapter supplies a validated recipient envelope body.

## Plans and restart fences

Generations are opaque UUIDs. The latest SDK event replaces the prior plan;
there is no numeric or lexicographic generation ordering. Server `initiate`
flags are preserved and consumed by the SDK mesh, never recalculated locally.
`status()` returns an owned snapshot with these routes:

| Route | Meaning |
| --- | --- |
| `awaiting_plan` | Attached; no accepted v3 plan |
| `mesh` | Complete frozen roster under mesh + WebRTC |
| `relay` | Server-selected relay topology and transport |
| `relay_required` | Unsupported topology/transport with explicit relay fallback |
| `blocked` | Invalid plan, unknown member, duplicate member or unsupported fallback |
| `restart_required` | Transport/membership lifetime ended, or mesh restoration needs a new session |
| `unconfigured` | Detached |

The adapter detaches the mesh before an unsupported plan can open connections.
A host/direct plan with relay fallback selects `relay_required`; it never
approximates host topology as rollback mesh. Supported mesh plans require every
remote frozen member exactly once. Relay plans may have no peers.
The additive `NewPeer` signal is fenced before the mesh listener runs. Only a
remote UUID and offerer role already authorized by the accepted mesh plan may
reach the SDK. Unknown UUIDs, local UUIDs, conflicting roles, and directives
without an active mesh plan latch `restart_required`, including UUIDs that
collide with a frozen member's Godot peer ID.

After a relay plan detached the mesh, a later mesh plan requires restart.
The pinned mesh has no public plan-application API, so this seam never invents
SDK notifications to restore it. The [fallback coordinator](signalfish-fallback.md)
restores still-valid direct channels and accepts relay overlap without replacing
the SDK mesh. SDK relay-to-mesh replans remain S4 work.
Room baseline replacement, joins, departures, room exit, disconnect, connection
failure and reconnect latch `restart_required`. A late plan cannot clear this
fence. Stop the old peer and create a new session; reconnect alone is no proof
that rollback history or membership remains recoverable.

Synchronous SDK callbacks cannot replace an ended lifetime while attach, plan
conversion or mesh teardown returns. Teardown marks the mesh released before calling
the SDK, and refuses nested plan acceptance or replacement attach until it returns.
An initial plan emitted during attach remains accepted. This guards lifecycle
ownership; it does not add transparent replan or ICE-restart support.

## Evidence and pinned sources

Unit tests cover independent digest bytes, roster order and ownership,
real `FortressPeerSession` startup, configuration/roster mismatch, known SDK
numeric-ID collision, unknown senders, old session bytes and plan/lifecycle
fences. Digest, collision and lifecycle mutants fail their intended assertions.
Both pinned engine versions run the suite with deterministic repeats.

The installed-SDK witness uses its actual decoder, public transport injection,
mesh attach and binary APIs. It is separate from complete browser or server
integration; it does not establish real WebRTC availability or relay latency.

- [Pinned client public APIs](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/blob/db7d30f228d8d564adcb2eb38d5983bf6b9877ac/addons/signal_fish/signal_fish_client.gd)
- [Pinned mesh identity and plan handling](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/blob/db7d30f228d8d564adcb2eb38d5983bf6b9877ac/addons/signal_fish/webrtc/sf_webrtc_mesh.gd)
- [Pinned v3 plan and offerer fields](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/blob/db7d30f228d8d564adcb2eb38d5983bf6b9877ac/addons/signal_fish/protocol/sf_session_types.gd)
