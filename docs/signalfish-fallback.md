# SignalFish direct and relay fallback

`FortressSignalFishFallback` keeps one `FortressPeerSession` while individual
links switch between [WebRTC](signalfish-webrtc.md) and [binary relay](signalfish-relay.md).
Player slots, protocol identity, input history and confirmed frames remain owned
by that session. Incoming packets from both paths reach its existing decoder;
protocol duplicate handling applies to overlapping delivery.

## Setup and service

Configure direct and relay adapters with the same membership, plan adapter and
peer session. Configure the relay before direct delivery fails. Raw MessagePack
negotiation and server relay support are required even under a mesh plan.
The SDK's binary relay API supports sending while a mesh plan is active.
Install both WebRTC factories from [the direct guide](signalfish-webrtc.md)
before the first plan. The multiplayer peer factory tolerates automatic engine
removal after physical channel failure during later SDK teardown.

```gdscript
const Fallback = preload("res://addons/fortress_rollback/transport/signalfish_fallback.gd")
var fallback: Fallback = Fallback.new()
var options: Fallback.Options = Fallback.Options.new()
options.fallback_after_us = 1000000
options.restore_after_us = 1000000
var code: int = fallback.configure(direct, relay, membership, adapter, peer, options)
if code != Fallback.Code.OK:
    stop_transport(code)
```

The coordinator exclusively owns both adapters' outgoing queues and `poll`
calls. Continue the SDK's ordinary signaling poll separately. Keep SDK objects,
configuration and protocol information alive. Use one shared handshake token
factory that supplies distinct 16-byte tokens across both receive paths.
Continue peer polling and game advancement through the [peer session API](peer-session.md).
The coordinator routes bytes; it does not advance simulation or run protocol retries.

Drain the peer's outgoing batches only when the previous refused batch is empty:

```gdscript
var retained: Array[FortressPeerSession.Packet] = []

func service_transport(now_us: int) -> void:
    if retained.is_empty():
        retained = peer.drain_outbox()
    if not retained.is_empty():
        var accepted: int = fallback.enqueue_batch(retained)
        if accepted == Fallback.Code.OK:
            retained.clear()
        elif accepted != Fallback.Code.BACKPRESSURE:
            stop_transport(accepted)
            return
    var serviced: Fallback.Result = fallback.poll(now_us, next_handshake_token)
    if serviced.code not in [Fallback.Code.OK, Fallback.Code.BACKPRESSURE]:
        stop_transport(serviced.code)
```

`enqueue_batch` validates the entire batch before copying it. The accepted packet
limit is the smaller of the direct and relay limits. Refusal leaves all caller
bytes owned by the caller. Unsent direct packets return to coordinator ownership
with their original frozen destination and exact payload bytes.

## Idle routes and bounded service batches

`poll()` returns the traffic it moved. `activity` counts the transport items it
took off the wire, refused ones included: a packet the transport consumed and
then refused is still traffic, and valid work can sit behind it. `sent` counts
published packets. `idle()` is true when the composed routes took nothing off
the wire, sent nothing and hold no queued work.

A caller can therefore service in a bounded batch and stop as soon as the route
is idle, instead of spending a whole frame budget on repeated polls:

```gdscript
for _round: int in 8:
    if not _poll_protocol(now_us):
        break
    if not _service_transport(now_us):
        break
    if retained.is_empty() and fallback.idle():
        break
```

A busy route keeps the whole batch, so a slow or refused route still drains its
queue. The caller's own retained batch counts as queued work: a refused batch
keeps the batch alive until the transport accepts it.

## Routing and limits

Routing runs on outgoing work with nonnegative, monotonic injected microseconds.
An unavailable channel, socket pressure or a refused direct send starts that
peer's grace period. At its deadline, relay takes that peer's retained output.
Healthy peers continue through direct channels during the same poll.
Relay socket pressure retains its accepted FIFO and does not drop packets.
Successful direct publication resets that peer's failure timer, including when
the send-work limit retains a healthy tail. A refused send arms only its actual
destination; inbound pressure and untried send-budget tails do not arm timers.

After direct readiness recovers, `restore_after_us` measures a second grace
period. Restoration waits for all accepted relay output to drain before sending
new work directly. This conservative drain gate also prevents older relay work
from being overtaken locally. In-flight network packets may still overlap.
Both timers accept zero through 60 seconds and remain valid near `INT64_MAX`.
A backward clock is refused before servicing queues.

| Option | Default | Bound |
| --- | --- | --- |
| `fallback_after_us` | 1,000,000 | 0–60,000,000 |
| `restore_after_us` | 1,000,000 | 0–60,000,000 |
| `max_pending_packets` | 128 | 1–4096 |
| `max_pending_bytes` | 1,048,576 | At least the accepted packet limit; at most 16 MiB |
| `max_routes_per_poll` | 8 | 1–`max_pending_packets` |

Coordinator queue limits supplement the adapters' independent queue, receive,
send-work and socket limits. `status()` exposes each queue separately and lists
`relay_peers`. Size the peer outbox and coordinator queue so a drained batch fits;
retaining an oversized batch cannot create capacity. Per-peer FIFO order is
preserved; ready peers can pass another peer's blocked output.

An accepted relay plan immediately moves new output to relay. A replacement
mesh generation, changed offerer roles, room or membership changes, SDK reconnect,
and incarnation changes remain fenced. These require a new supported transport
or rollback lifetime; the coordinator never fabricates SDK plans or resets history.
A receive overflow, peer failure or terminal direct SDK error is terminal.
Configuration rejects an already failed direct adapter, even if its unsent queue was reclaimed.
A refused direct send (`ERR_BUSY`) remains retryable; other direct socket errors preserve their original failure and fence relay publication. An invalid direct transport
lifetime under an unchanged mesh plan is also terminal; it cannot authorize
relay fallback. An accepted relay plan explicitly permits direct teardown. During callbacks, detach fails
closed and releases retained queues and observers when the active poll returns.
Call `fallback.detach()`, then detach direct and relay, then the plan adapter.

## Evidence and remaining work

Deterministic injected tests use actual three-player peer sessions and production
adapters. They exercise a failed link alongside healthy direct links, two-path
overlap, prediction repair, restoration and canonical game-state equality.
Unit cases cover exact grace deadlines, send refusal, owned FIFO retry, bounded
queues, clock exhaustion, accepted relay plans, callback teardown and lifetime fences.

The exported Chromium witness also runs the coordinator over actual WebRTC and
raw MessagePack relay sockets on both pinned engines with 2, 4 and 8 peers.
It injects send pressure on one outgoing data channel during frames 4–15.
Other links keep direct service; the pressured link uses relay, then returns
to the same direct channel. This models channel pressure without closing ICE.

The witness compares 38 corrected canonical prefixes per peer against original
inputs, requires actual rollback loads and monotonic frame/confirmation histories,
and checks physical direct sends after restoration. One captured input packet
must appear in its original direct send/receipt and subsequent addressed relay
receipt. All channels and peer connections close at teardown.

Both default 8-send/8-receive and selected 32-send/32-receive work budgets use
eight routes per coordinator poll. Refused batches remain caller-owned.
Owned queues and observed socket buffers are bounded separately. Disabling
fallback must stall within the pressure interval and fail the gameplay watchdog.
The existing snapshot-corruption and incompatible-channel controls still run.

Run the full witness with the pinned server built as described in
[the WebRTC guide](signalfish-webrtc.md):

```sh
python3 scripts/reference/signalfish_webrtc_probe.py \
  --server .cache/reference/results/signalfish-server-build/target/debug/signal-fish-server \
  --server-source .cache/reference/signal-fish-server-9c2fb8fa635a69241b8ccf38be651d561fef7434 \
  --build-receipt .cache/reference/results/signalfish-server-build/build-receipt.json \
  --output .cache/reference/results/signalfish-webrtc
```

A separate physical-outage room closes the exact destination's actual unreliable
channel at source frame four. Godot removes that link and closes its companion
channels. Both ends keep relay service through final confirmation; healthy links
continue direct service. The same original-input, rollback, overlap, queue and
teardown gates apply. No replacement channel is created during this workload.

This scoped witness does not establish ICE restoration, relay congestion,
SDK-driven channel replacement, relay-to-mesh server replans, browser
suspension or server restart. These remain
[S4 follow-up work](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/38)
and [live recovery acceptance](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/75).
Firefox, WebKit, mixed browsers and sustained release workloads remain in S5.
