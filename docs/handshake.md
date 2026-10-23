# Fixed-peer handshake

`FortressHandshake` is a transport-independent endpoint for one fixed peer.
It consumes real [protocol bytes](protocol.md), agrees on configuration, and
publishes a running state after the configured number of successful roundtrips.
It does not exchange gameplay input or create a P2P session. A session layer can
route its outgoing bytes through a socket and observe its events after polling.

## API

Preload `addons/fortress_rollback/protocol/handshake.gd`,
`handshake_types.gd` and `protocol_types.gd`.

| Method | Contract |
| --- | --- |
| `configure(local, remote_sender, options)` | One-shot configuration using a `ProtocolTypes.Message` with kind `SYNC_REQUEST`, a remote eight-byte sender ID, and `HandshakeTypes.Options`. Copies complete canonical configuration and options. |
| `begin(now_us, token)` | Enters synchronizing and emits the first request with the supplied sixteen-byte token. |
| `poll(now_us, next_token = null)` | Checks timeout and retry; a token is required only when a retry is actually due. |
| `receive(packet, attributed_sender, now_us, next_token = null)` | Decodes complete packet bytes and checks transport attribution, header identity and connection era. A fresh token is required only when a valid reply advances an unfinished handshake. |
| `status()` | Returns an owned state dictionary, including remaining roundtrips, live/consumed token sets, connection binding and sticky mismatch. |
| `remote_packet_bytes()` | The smaller of the local `max_packet_bytes` and every limit the remote advertised in an accepted reply. Input batches must fit it. |
| `drain_outbox()` | Returns owned packet bytes and empties the outgoing queue. |
| `drain_events()` | Returns owned event dictionaries after state publication. |
| `drain_transitions()` | Returns owned post-transition records and empties the bounded observation queue. |

Every operation returns `HandshakeTypes.Code`. Invalid arguments, wrong state,
wrong source or connection, unsupported message kinds and queue pressure have
separate codes. Decoding errors return `INVALID_PACKET`. Failures preserve all
state, the accepted clock value, and all existing queues, except the independent
due timeout diagnostic described below. Drain queues and retry
the same operation after `BACKPRESSURE`; a pending-token or consumed-token limit
requires a fresh endpoint and session identity when no progress can free space.

The caller supplies nonnegative, nondecreasing integer microseconds. Equal time
is allowed. The endpoint never calls a clock or RNG. Tokens are opaque sixteen
bytes, including zero; the caller controls their generation and must avoid
reusing consumed tokens. Local configuration supports semantic compatibility
version 1 and the retained-history drop feature bit (`1`). Player sessions advertise
that bit automatically for `disconnect_behavior = CONTINUE`; other policies keep
feature mask zero. Exact feature agreement refuses peers using the older drop tier
before gameplay. Unknown local feature bits are refused; remote masks remain
decodable so mismatches have an explicit diagnosis.

Local session, sender and connection IDs and the remote sender ID must have the
specified widths and contain a nonzero byte. Local and remote identities differ
and both appear in the configured roster. All roster identities are nonzero;
repeated identities are allowed for endpoints owning multiple player slots.
Configuration scalar domains and collection sizes are checked before walking
roster identities or allocating an identity lookup. Oversized rosters fail
without proportional validation work. Configuration is immutable. To restart, create a new endpoint with a new session
identity rather than reusing an old object's outstanding requests.

## Agreement and traffic gates

A sync request is always answered with the local configuration, even after a
terminal incompatibility or after entering running. A request never binds the
remote connection or counts a successful roundtrip. In synchronizing state,
its configuration may set a terminal mismatch. Running requests are answered
without reevaluating configuration.

A reply must echo a live token before its configuration can influence state.
Unknown and duplicate replies cannot poison a handshake. The first compatible
live reply binds the remote connection ID, removes exactly one live token and
decrements remaining roundtrips once. Subsequent packets must carry that bound
connection ID. The source checks always require both the transport's attributed
sender and the packet sender/session to match. A spoofed header alone cannot
satisfy attribution; these checks do not provide cryptographic authentication.

Mismatch precedence is minimum compatibility version, player count, input width,
FPS, prediction window, checksum interval and feature mask. These seven checks
match pinned upstream `HandshakeConfig::first_mismatch`. Godot then checks input
delay, input format, snapshot format, checksum algorithm, queue capacity, neutral input and roster
before checking the opaque configuration digest. The extra fields belong to the
Godot session agreement. A mismatch event retains the field and locally oriented
`ours`/`theirs` values; bytes and rosters use canonical hexadecimal strings.
The digest remains an independently compared negotiated value; the endpoint does
not replace the caller's digest with a checksum of the wire layout.

An incompatibility is sticky and emits exactly one `incompatible` event. It
leaves the state synchronizing, stops retries and timeout notifications, and
continues answering requests so the peer can diagnose its own orientation.
Timeout is different: it emits one `sync_timeout` event and synchronization
continues. Retry and timeout checks use strictly `elapsed > interval`, including
one-microsecond boundaries. Event `elapsed_ms` values use integer floor division.
Every queued request or reply refreshes the retry timer. Merely receiving an
unknown or duplicate reply does not postpone a retry.

Intermediate accepted replies emit `synchronizing` with total/count,
`total_requests_sent` and elapsed milliseconds, then immediately emit the next
request. The final reply changes state to running and emits `synchronized`.

## Bounds and deliberate differences

Defaults are five roundtrips, a 200000-microsecond retry interval, no timeout,
65536 packet bytes, 128 live tokens, 4096 consumed tokens, 128 queued packets,
128 events and 1024 transitions. Roundtrips are bounded to 1–128; queue/token
bounds to 1–4096, except transitions require at least two slots. Consumed-token
history must hold at least the configured roundtrip count; these minima permit
begin and completion after queue drains. Packet bytes are bounded to
44–1048576. Request counts saturate at u32 max.
A packet is bounded before decoding. Packet processing plans its complete state
and queue changes and publishes them together only if all bounds permit it.
Polling can publish its independent timeout diagnostic after refusing a retry.

Pinned upstream permits a random-token collision to emit another request while
retaining one live set entry. This endpoint preserves that behavior and records
`collision`. A later reply still advances once. Consumed token reuse is rejected
with `TOKEN_REUSED`, providing an explicit stale-echo fence that upstream's
unbounded random request set does not provide. Live and consumed sets have hard
limits rather than silently evicting tokens; this is an intentional bounded
Godot policy. Trace queue pressure also rejects the whole operation instead of
silently dropping a transition.

A due `sync_timeout` diagnostic is independent of a retry refused by token or
outgoing-packet capacity. The endpoint commits that one diagnostic without
committing the unsent token, request count or packet. The retry still returns
`BACKPRESSURE`. Applications must drain events and transitions; their own full
diagnostic queues still apply backpressure. Invalid callback tokens leave state
unchanged. Timeout remains diagnostic-only at this expert boundary; the online
example uses it to stop and require a fresh room.

Transition records use `action`, `token`, `disposition`, `state`, `remaining`,
`outstanding_request_count`, `remote_connection`, `timeout_sent`, `mismatch` and
`elapsed_ms`. Empty connection strings mean unbound. Actions are
`begin_synchronization`, `send_request`, `handle_request`, `handle_reply` and
`report_timeout`. Replies distinguish accepted, incompatible, duplicate, unknown,
not synchronizing and already incompatible. Observations reflect the state after
the named transition; intermediate accepted-reply observations precede the next
send observation. They are diagnostic records, not a released replay format.

## Verification and source audit

Run the focused deterministic suite with:

```sh
make test-focus SUITE=res://tests/unit/test_handshake.gd
```

It covers successful roundtrips, live-token collisions, duplicates, unknown
mismatch replies, every configuration field, explicit time boundaries, timeout
recovery, wrong transport/header/session/era identities, all queue/token limits,
and mutation of configuration, options, tokens and returned status.

The source audit uses fortress-rollback commit
`f13cd5c0f2815926785a395947e18da0dbea0dd8`,
`src/network/protocol/mod.rs`: `HandshakeConfig::first_mismatch`, `synchronize`,
`poll`, `send_sync_request`, `on_sync_request`, `on_sync_reply` and
`observe_handshake`. `handshake_trace.rs` defines upstream dispositions and
post-transition observations. Godot uses its own explicit byte layout and wide
identity/token representation; this is semantic agreement, not Rust wire
compatibility. Gameplay exchange, disconnect handling, rejoin and WebRTC adapter
integration remain separate roadmap work.
