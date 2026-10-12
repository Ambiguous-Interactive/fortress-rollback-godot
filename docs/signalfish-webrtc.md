# SignalFish WebRTC byte delivery

`FortressSignalFishWebRTC` delivers the existing rollback protocol through the
optional SDK's `SFWebRTCMesh.get_multiplayer_peer()` byte interface. It uses the
same frozen [membership](signalfish-membership.md), peer handshake and simulation
engine as [binary relay](signalfish-relay.md).

## Configure and service direct delivery

Install the pinned SignalFish SDK separately. Configure membership and attach
the plan adapter after joining the room, before its first plan. Wait for a validated mesh plan and
the SDK multiplayer peer before configuring byte delivery:

```gdscript
const Direct = preload("res://addons/fortress_rollback/transport/signalfish_webrtc.gd")
var direct: Direct = Direct.new()
var options: Direct.Options = Direct.Options.new()
options.max_packet_bytes = 1024
var code: int = direct.configure(mesh, membership, plan_adapter, peer, options)
if code != Direct.Code.OK:
    return ERR_UNAVAILABLE
```

Keep SDK Nodes alive. The application owns SDK and mesh polling; direct delivery
services the multiplayer peer. Reserve packet consumption for this adapter.
Assigning the peer to a `MultiplayerAPI`, or calling `get_packet()` elsewhere,
can steal protocol packets and invalidate the ownership contract.

Retain a drained peer batch until `enqueue_batch()` accepts it in full. This is
the same ownership rule as the relay adapter:

```gdscript
var retry_batch: Array[Peer.Packet] = []

func service_direct(now_us: int) -> void:
    client.poll()
    mesh.poll()
    if retry_batch.is_empty():
        retry_batch = peer.drain_outbox()
    var accepted: int = direct.enqueue_batch(retry_batch)
    if accepted == Direct.Code.OK:
        retry_batch.clear()
    elif accepted != Direct.Code.BACKPRESSURE:
        handle_transport_failure(accepted)
        return
    var result: Direct.Result = direct.poll(now_us, next_handshake_token)
    if result.code not in [Direct.Code.OK, Direct.Code.BACKPRESSURE]:
        handle_transport_failure(result.code)
```

`Peer` is the `FortressPeerSession` preload from the membership guide.
`next_handshake_token(from_uuid)` supplies unique owned 16-byte tokens for
multi-round handshakes; a single-round handshake can omit the callback.
The callback may return `null` or exactly 16 bytes. Other values latch
`INVALID_ARGUMENT` before copying or retaining token data.
Continue polling/stepping the peer, and drain its events and transitions.
Protocol clocks remain injected and monotonic. WebRTC does not advance gameplay.

## Channels and readiness

The pinned SDK calls `create_mesh()` with default channel configuration and
`add_peer()` without overriding its unreliable lifetime. Godot creates three
default channels. Direct rollback bytes select transfer channel zero with
`TRANSFER_MODE_UNRELIABLE`, which chooses the built-in unordered channel.
Protocol control packets use that same path; handshake retries, cumulative ACKs
and retained input redundancy provide recovery.

[Godot 4.3 documents](https://docs.godotengine.org/en/4.3/classes/class_webrtcmultiplayerpeer.html)
the default unreliable lifetime as one millisecond, passed as `maxPacketLifetime`.
This is not `maxRetransmits = 0`. The SDK's introductory single-channel comment
does not describe the actual engine configuration.

The real browser audit found an engine option spelling mismatch: its default
`maxPacketLifetime` is ignored by the browser, which expects `maxPacketLifeTime`.
Install the shipped connection factory before any mesh plan creates connections:

```gdscript
const Connection = preload("res://addons/fortress_rollback/transport/signalfish_webrtc_connection.gd")
const Multiplayer = preload("res://addons/fortress_rollback/transport/signalfish_webrtc_multiplayer_peer.gd")
mesh.peer_connection_factory = Connection.create
mesh.multiplayer_peer_factory = Multiplayer.create
```

The GDScript wrapper delegates to the actual browser peer connection and
corrects the channel option at creation. The direct adapter verifies channel
properties before sending. The multiplayer peer factory also makes SDK removal
idempotent when Godot already removed a failed channel's peer. Present peers still
use the engine's normal removal path. Install both factories before the first plan.
Browser constructor observations, rather than the
configured dictionary alone, establish the resulting reliability policy.

An endpoint must have all default channels open before publication. Queue and
socket pressure preserve the exact outgoing FIFO head for retry. Packet and byte
limits bound application ownership; send and receive budgets bound each service
call. Recoverable peer publication pressure retains the incoming packet and its
handshake token. It must not starve bounded outgoing ACK service.

The default packet limit is 1,200 bytes. Larger protocol configurations must
fit that direct-path limit; relay has a different size budget. The adapter retains
one refused incoming packet. Remaining packets stay in the engine's channel
buffers; the receive budget limits application reads per call, not engine polling.

Size send and receive work together for the roster and actual polling interval.
Slow full-mesh service can receive both retry inputs and their ACKs from every
remote peer. Raising only the send budget can grow a FIFO of stale packets even
without network loss. The browser witness exercises both default 8-send/8-receive
and selected 32-send/32-receive budgets, with eight bounded transport polls per
yielded host turn. The deterministic delayed-delivery integration test exercises
default budgets at 300 ms host turns. A single poll at that cadence accumulates
stale retries and ACKs; these measurements do not guarantee arbitrary caller throughput.

## Identity, lifetime and failures

Packets are attributed by the multiplayer peer's numeric sender ID and resolved
through frozen UUID membership before entering the peer decoder. Unknown/local
IDs, oversized packets and unexpected channels are refused. The core decoder
still validates session, connection and protocol sender identity.

Direct delivery belongs to one validated plan generation and multiplayer-peer
instance. A monotonic local revision also fences replacements that return to the
same generation or change offerer roles. A replacement plan or mesh teardown fences queued bytes. Disconnect,
room replacement and membership changes require an explicit new rollback session.
Call `direct.detach()` before releasing SDK objects, then detach the plan adapter.

The [fallback coordinator](signalfish-fallback.md) switches individual failed links
to relay and restores ready direct links within the same peer session. Exported
Chromium validates mixed delivery under single-link send pressure and preserves
game state through relay after physical channel loss. ICE restoration and SDK
mesh replacement remain tracked in
[S4](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/38).
Do not treat direct readiness as permission to reset confirmed history or
restart an old peer. A new SDK connection does not restore simulation state.

## Platform and evidence limits

Browser exports use the browser's WebRTC implementation. Native Godot requires
an independently installed WebRTC implementation; the GDScript addon supplies
none. Native injected tests establish adapter behavior, not native ICE support.
Use a single-threaded Compatibility-renderer export and serve its `.wasm` with
the correct MIME type. HTTPS production pages require compatible secure
SignalFish WebSocket hosting. Loopback development evidence does not prove
internet traversal, TURN availability or the full release browser matrix.

The real-browser witness and scoped acceptance evidence are recorded in
[session 013](../progress/session-013-webrtc.md).

Run the development witness after building the pinned server with the
[relay guide](signalfish-relay.md)'s source-bound build command:

```sh
python3 scripts/reference/signalfish_webrtc_probe.py \
  --server .cache/reference/results/signalfish-server-build/target/debug/signal-fish-server \
  --server-source .cache/reference/signal-fish-server-9c2fb8fa635a69241b8ccf38be651d561fef7434 \
  --build-receipt .cache/reference/results/signalfish-server-build/build-receipt.json \
  --output .cache/reference/results/signalfish-webrtc
```

The launcher verifies pinned engines, templates and Chromium archives. It runs
both engine pins by default; `--godot` requires one matching `--version`.
Independent Chromium processes run 2/4/8-player matches and observe actual
channel traffic and closure. Synthetic send drops/delays exercise recovery;
snapshot corruption must fail at an original-input canonical comparison.
Mixed runs use both default and selected work budgets. They inject one-link send
pressure and correlate the same input bytes across physical direct and addressed
relay delivery. A fallback-disabled control must fail the gameplay watchdog.
Automatic CI retains source, tool, export and log inventories with its receipts.
