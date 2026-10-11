# Development handshake differential

This gate compares the production Godot byte endpoint with the **actual pinned
upstream `P2PSession`**, not a second implementation of the handshake algorithm.
The shipped addon still has no Rust dependency. This is a development tool for
P2 (#31) and the handshake slice of the P2P oracle (#59); it does not establish gameplay
input exchange, WebRTC delivery, browser multiplayer, or full P2P parity.

Run after the normal pinned reference tool setup, with Java 11 or newer installed:

```sh
python3 scripts/oracle/handshake_launch.py --godot /path/to/godot
```

The launcher downloads the upstream-pinned TLC 1.8.0 jar once and verifies its
recorded SHA-256. Subsequent `--offline` runs require the verified cached source,
Cargo dependencies, toolchain, and jar. `--output` selects an owned result directory;
the launcher removes an old receipt before attempting any setup or work.
The minimum/current engine matrix runs this command with each pinned Godot binary.

## Actual upstream boundary

The Rust binary uses only public upstream APIs: `SessionBuilder`, a fake
`NonBlockingSocket`, an injected `ProtocolConfig.clock`, seeded protocol randomness,
`with_handshake_trace_capacity`, `P2PSession.handshake_trace`, and `events()`.
It enables the optional `handshake-oracle` Cargo feature, which enables the existing
upstream `trace-validation` recorder. Ordinary session and queue oracle builds
retain their previous feature set. No upstream source patch or observation hook
is added.

The fake socket preserves actual outgoing `Message` objects. The scheduler delivers
a cloned observed request as an explicit request or reply, using public serde
serialization/deserialization to change the echo, peer connection, or configuration.
The upstream session itself decides whether to accept, bind, advance, retry,
fail, or report timeout. Incoming source attribution is passed through the real
socket boundary. Raw upstream packet headers, wide values, messages, trace
snapshots, and application events are stored before projection.

Godot receives the equivalent scheduled messages through the production
`FortressProtocolCodec` and `FortressHandshake.receive`. The caller supplies
upstream-observed send tokens to the Godot endpoint. Tokens are converted from
upstream u32 to 16 little-endian bytes with zero padding; identities are never
renumbered independently for a send or a reply. Connection IDs similarly retain
their u32 value in eight little-endian bytes. Digests remain exact eight-byte hex,
never JSON numeric values on the Godot side.

The two protocols intentionally have different semantic profiles. This fixture
maps upstream local compatibility **2 to Godot 1**, and the tested incompatible
upstream **3 to Godot 2**. These are the only accepted version mappings; the tool
does not subtract one from arbitrary versions or claim wire compatibility.
Raw upstream versions remain available in every artifact. Other shared fields
and oriented mismatch values are compared directly. Godot-only roster, neutral
input, delay, formats, and checksum-algorithm policy are outside this differential.

## Executed cases and evidence

The bounded corpus covers matching completion; duplicate and reordered replies;
an unknown echo carrying a poisoned config; wrong transport source; wrong bound
connection; all eight upstream mismatch fields in both request and reply paths;
locked mismatch precedence; and continued answering after sticky incompatibility.

Retry and timeout thresholds are tested at equality and **one microsecond after**.
Timeout is emitted once, followed by retry and eventual successful synchronization;
it is a notification rather than a terminal disconnect. A request at 190ms
refreshes the reply send timer, suppressing a retry at 201ms and 390ms, then
allowing it at 390ms plus one microsecond.

Each upstream and Godot process runs twice. Comparison includes every operation,
ordered emitted handshake packet, application event (including progress counts,
request counts and elapsed milliseconds), and relevant post-transition snapshot.
Mismatch reasons preserve field and ours/theirs orientation. A partial result,
unknown field, boolean or float in an integer field, altered token, changed packet,
missing event, changed remaining count, or altered timeout duration is rejected.
These negative controls run against the actual result, with rejection localized
to the affected operation. Receipts record source, binary, submitted scenario,
raw upstream trace, and model artifacts by SHA-256. A failed attempt produces no
success receipt.

The existing scoped runtime tests cover Godot-specific wrong-session fences,
caller token reuse, owned buffers, bounded queues, and atomic rejection. Those
policies cannot be inferred from a Rust protocol that lacks those exact fields.

## Bounded model projection

`handshake_formal.py` sends the observed Godot matching trace to the **pinned
upstream full TLC trace checker** for `SyncHandshakeV1`. The scheduler prefix is
an audited copy of the pinned matching scenario: the remote environment answers
requests, duplicates a reply, and delays B until after C. Every p1 send/reply action
must align with an emitted Godot record. p1 phase, remaining rounds, and accepted
token sets come from those records. A single raw-token-to-bounded-token map retains
A/B/C relationships. The positive trace must be accepted. A derivative changes
the observed ignored duplicate into an additional decrement and must be rejected
by TLC at that action. A parser crash or unrelated tool error cannot count as a
successful negative control.

This projection proves only that the observed single-endpoint path is admitted
by the bounded model. The second peer's scheduler/handler rows are modeled
environment actions; they are not a second Godot runtime. The model has two
configuration fields (player count and input width), two successful roundtrips,
three request identities, and a three-message network. It omits byte layout,
source/session fencing, most compatibility fields, finite buffer pressure,
connection reuse, RNG collisions, and exact microsecond time. The independently
executed source differential covers the broader fields and exact timing. Neither
check replaces the planned broader transport, gameplay, and P2P oracle gates.
