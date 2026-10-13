# SignalFish binary relay

`FortressSignalFishRelay` sends and receives bounded rollback protocol packets
through the optional pinned SDK's binary APIs. It broadcasts a recipient envelope
and filters other participants' traffic before the peer receives it.
It reuses the [membership and plan seam](signalfish-membership.md) and the existing
`FortressPeerSession`; it does not create another rollback engine.

## Configure the SDK and relay

Use the same `SignalFishConfig` instance supplied to the SDK client:

```gdscript
sdk_config.game_data_format = "message_pack"
sdk_config.decode_msgpack_payloads = false
sdk_config.max_inbound_packets_per_poll = 64
sdk_config.max_buffered_bytes = 262144
sdk_config.max_outbound_frame_bytes = 65536
sdk_config.max_inbound_frame_bytes = 262144
```

Retain the actual public `protocol_info` event object. After authentication,
room membership and an accepted mesh or relay plan are established, configure
the relay. A mesh plan allows standby delivery for the
[fallback coordinator](signalfish-fallback.md).

```gdscript
const Relay = preload("res://addons/fortress_rollback/transport/signalfish_relay.gd")
var options: Relay.Options = Relay.Options.new()
options.max_packet_bytes = 8192
options.max_sends_per_poll = 8
options.max_receives_per_poll = 8
var relay: Relay = Relay.new()
var result: int = relay.configure(
    client, sdk_config, protocol_info, membership, plan_adapter, peer, options
)
if result != Relay.Code.OK:
    return ERR_INVALID_DATA
```

The server must advertise protocol v3 and `message_pack`. Raw payload decoding
must remain disabled. Unsupported formats refuse configuration; send failures
are surfaced without converting bytes to JSON. The default maximum protocol
packet is 65,479 bytes, leaving the 57-byte application envelope inside the
pinned SDK's default 65,536-byte outbound cap. Configure a smaller packet limit
when the SDK or server advertises a smaller cap.

The adapter checks SDK outbound/inbound caps and the server's advertised maximum
outbound message size. It reserves 128 bytes for the pinned SDK's server envelope.
The socket budget must fit at least one maximum application envelope. A valid
SDK receive budget is 1–4,096 packets per SDK poll. Production WebSocket polling
uses that SDK limit; injected transports must enforce their own equivalent bound.

## Preserve output ownership during pressure

Keep an application-held batch between draining the peer and acceptance:

```gdscript
var retry_batch: Array[Peer.Packet] = []

func service_network(now_us: int) -> void:
    if retry_batch.is_empty():
        retry_batch = peer.drain_outbox()
    var accepted: int = relay.enqueue_batch(retry_batch)
    if accepted == Relay.Code.OK:
        retry_batch.clear()
    elif accepted != Relay.Code.BACKPRESSURE:
        handle_transport_failure(accepted)
        return
    var serviced: Relay.Result = relay.poll(now_us, next_handshake_token)
    if serviced.code not in [Relay.Code.OK, Relay.Code.BACKPRESSURE]:
        handle_transport_failure(serviced.code)
```

`Peer` is the `FortressPeerSession` preload from the membership guide.
`next_handshake_token(from_uuid)` supplies each next unique 16-byte token for
multi-round handshakes. A single-round handshake may omit that callback.
Applications continue to poll/step the peer through its documented API.
Run relay service between SDK polls so receive queues can drain.

`enqueue_batch` accepts every packet or none. It validates packet count before
scanning identities, checks bytes and destinations before queueing, and copies
accepted bytes. A refused batch remains entirely caller-owned. Never discard a
batch after backpressure, or drain another peer batch over it.

The adapter retains the exact FIFO head when the SDK returns `ERR_BUSY` or when
socket backlog plus the next envelope exceeds the configured budget. Later
polls retry it before newer packets. No retry copies accumulate. Other SDK errors
latch `SDK_FAILURE` and preserve pending output for diagnostics until detach.
Protocol input history and retransmission remain owned by the peer session.

## Receive, diagnostics and lifecycle

The SDK's `game_data_binary_received` signal queues owned validated bytes.
Each relay poll processes at most `max_receives_per_poll` packets and publishes
at most `max_sends_per_poll` packets. SDK polling and relay service have separate
budgets; an application must schedule both.

The envelope layout is fixed little-endian:

| Field | Width |
| --- | --- |
| `FSR1` magic | 4 bytes |
| Version `1` | 1 byte |
| Rollback session ID | 16 bytes |
| Full sender UUID | 16 bytes |
| Full recipient UUID | 16 bytes |
| Protocol payload length | 4 bytes |
| Protocol payload | Declared bounded bytes |

Sender UUID must match the SDK's attributed sender and frozen membership.
Session ID must match the current rollback lifetime. A different recipient is
ignored as expected broadcast traffic. Version, size and trailing bytes are
validated before the payload enters a queue. The existing peer decoder then
checks protocol sender, session, connection and handshake agreement.

`status()` exposes pending/received packet and byte counts, `last_receive_code`,
rejected packets and ignored broadcasts. `poll()` returns `code`, `sent`,
`received` and the underlying `peer_code` for a peer refusal.

Invalid envelopes and unrelated broadcasts do not enter receive queues.
Receive overflow latches `RECEIVE_OVERFLOW`; subsequent service refuses work.
The application must stop and close the old session on that failure. This
explicit failure avoids continuing after silently dropping required history.
Recoverable peer queue pressure retains the exact incoming FIFO head and its
handshake token for retry after the application drains peer publications.
Bounded outgoing service continues during receive pressure so queued ACKs can flow.
Terminal peer refusal latches `PEER_FAILURE`. Pending queues remain
bounded and observable until `detach()` releases them.

The S1 adapter's restart fences also block relay sends and receive service.
Room replacement, membership changes, disconnect and reconnect cannot resume
an old rollback lifetime. Missed control events are not a game-input replay.
The adapter checks current public SDK connection, authentication, player UUID and
frozen room identity before servicing queued bytes. Closing a socket blocks work
before its disconnect callback; a spectator baseline and a known-player reconnect
also require a new rollback session.
Keep the SDK Nodes alive, detach the relay before freeing them, and explicitly
start a new session after an unrecoverable lifetime change.

Binary relay uses a reliable WebSocket. A slow socket can delay every later
packet behind its head. Bounded queues limit accumulated work; they cannot
remove head-of-line latency. The [fallback coordinator](signalfish-fallback.md)
accepts authenticated relay overlap under mesh plans and switches individual links.
Live browser path recovery remains a separate gate.

## Evidence limits

Unit tests cover independent envelope bytes, queue ownership, atomic batch
refusal, socket/SDK pressure, bounded receive work, overflow and lifetime fences.
Negative controls must reject dropping a refused FIFO head, bypassing sender
attribution, or bypassing broadcast-recipient filtering.

The pinned SDK integration witness runs 2/4/8 real peer sessions through the
actual SDK binary send/receive decoder with deterministic injected transport.
It compares canonical corrected game state during pressure and delayed delivery.
This proves the production relay adapter and SDK byte boundary together.
It does not alone establish a live server, browser compatibility, real network
latency or transparent reconnect recovery; report those gates separately.

## Reproduce native server delivery

The development witness connects real SDK WebSockets to the pinned local server,
joins actual rooms, starts relay plans and runs 2/4/8-player sessions. Each submits
40 varied-input frames and checks 38 corrected confirmed state prefixes per
player. It also rejects SDK errors arriving during the last gameplay drain.
This native loopback evidence covers the production relay and actual server;
live queue pressure, browser behavior and direct WebRTC remain separate gates.

First complete the [reference setup](reference/README.md). Use the direct Cargo
executable from the installed Rust 1.94.0 toolchain and the verified server source:

```sh
python3 scripts/reference/signalfish_build_server.py \
  --cargo <pinned-toolchain>/bin/cargo \
  --source .cache/reference/signal-fish-server-9c2fb8fa635a69241b8ccf38be651d561fef7434 \
  --output .cache/reference/results/signalfish-server-build
python3 scripts/reference/signalfish_live_probe.py \
  --godot <editor> \
  --server .cache/reference/results/signalfish-server-build/target/debug/signal-fish-server \
  --server-source .cache/reference/signal-fish-server-9c2fb8fa635a69241b8ccf38be651d561fef7434 \
  --build-receipt .cache/reference/results/signalfish-server-build/build-receipt.json \
  --output .cache/reference/results/signalfish-live-<version>
```

The builder verifies the supplied source against the pinned archive and runs
locked commands with a fresh Cargo source directory. It retains crate archives
for later `--offline` builds. Source, compiler and executable hashes bind its
build receipt; the witness validates that receipt before launching a temporary
server. All servers stop after the witness. Source/tool inventories and native
and server logs bind the final gameplay result. Both programs invalidate prior
success before each attempt. Rust remains development-only.

## Foreign protocol identities

After envelope attribution, a valid inner packet can still belong to a different
session, sender or connection incarnation. The adapter discards and counts these
packets in `status().rejected`, releases their bytes and callback token, and
continues bounded service. They cannot refresh liveness or end the current game.
Malformed inner packets retain the existing `PEER_FAILURE` policy.
