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
A receive overflow or peer failure is terminal. An invalid direct transport
lifetime under an unchanged mesh plan is also terminal; it cannot authorize
relay fallback. An accepted relay plan explicitly permits direct teardown. During callbacks, detach fails
closed. Call `fallback.detach()`, then detach direct and relay, then the plan adapter.

## Evidence and remaining work

Deterministic injected tests use actual three-player peer sessions and production
adapters. They exercise a failed link alongside healthy direct links, two-path
overlap, prediction repair, restoration and canonical game-state equality.
Unit cases cover exact grace deadlines, send refusal, owned FIFO retry, bounded
queues, clock exhaustion, accepted relay plans, callback teardown and lifetime fences.

This proves coordinator behavior through injected SDK seams. Live browser mixed
path recovery, SDK-driven channel replacement, relay-to-mesh server replans and
browser suspension remain [S4 follow-up work](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/38).
[Live mixed-path validation](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/75)
owns the real packet and confirmed-state witness for the coordinator.
