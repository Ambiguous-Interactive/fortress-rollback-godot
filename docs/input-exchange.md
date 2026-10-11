# Input and ACK exchange

`FortressInputEndpoint` composes the real byte codec and peer handshake. Each
endpoint represents one remote roster identity, including every slot owned by
that identity. A session with more peers creates one endpoint per remote identity.
This layer retains inputs and exchanges cumulative ACKs; the P2P façade owns
simulation correction and global confirmation.

## API

Preload `protocol/input_endpoint.gd`, `input_endpoint_types.gd`,
`handshake_types.gd` and `protocol_types.gd` from the addon directory.

| Operation | Contract |
| --- | --- |
| `configure(local, remote_sender, handshake_options, options, accept_input, lifecycle_options = null)` | One-shot configuration; optional lifecycle controls. |
| `begin(now_us, token)` | Start the composed handshake. |
| `poll(now_us, next_token = null, statuses = [], status_nudge = false)` | Drive synchronization or strict running retry; optional full roster statuses and boolean idle-carrier policy. |
| `receive(packet, attributed_sender, now_us, next_token = null)` | Decode and validate the actual packet before retaining new inputs. |
| `submit(frame, data, statuses, now_us)` | Retain one complete local frame and send the oldest pending prefix. |
| `status()` | Owned observations, including handshake, history, slot ownership and ACK floors. |
| `drain_outbox/events/transitions()` | Drain owned packets, events or transition observations. |

`now_us` is an injected nonnegative, nondecreasing integer. There is no internal
clock, RNG or transport. The handshake guide defines token supply and source
binding. Gameplay packets require a running handshake and the negotiated session,
sender and connection identity, plus the independently attributed transport source.

`data` packs one input-width record per locally owned slot, in ascending roster
order. Incoming packets must name exactly every slot owned by the remote identity,
in the same order. Multiple local handles and multiple remote handles are supported.
Other identities may exist in the roster; they belong to separate endpoints.

The first submitted or retained frame must be zero or the agreed input delay.
Later frames must be contiguous. The delayed start lets the session engine supply
its bounded startup neutral inputs. Other gaps are dropped and answered with the
current retained ACK; they never skip a missing frame or consume a piggyback ACK.

## Retention and recovery

The sink callable receives `(frame, packed_remote_slot_data)` and returns integer
zero only after the session engine has retained that complete frame. The caller
must keep its callback owner alive. Every frame in the packet is validated before
any callback: ownership, shape, retained-history conflicts and publication capacity
cannot partially mutate the session. The callback receives owned bytes.

A refusal, invalid return or freed callback terminates the endpoint with
`INPUT_FAILED` and an `input_failed` event carrying the failing frame. An earlier
accepted prefix remains visible, but the endpoint publishes no ACK for that packet
and never consumes its piggyback ACK. It cannot resume afterward. Callback reentry
returns `BUSY`; drains inside a callback return empty without clearing queues.
Status remains available.

Cumulative ACKs remove retained local frames **through and including** the ACK
frame. Stale ACKs, ACKs beyond the highest transmitted frame and ACKs with no
retained frame to release have no effect. Local submission preserves every older
unacknowledged input; an equal retained duplicate is idempotent and a differing
one returns `CONFLICT`. An acknowledged old sample cannot be resubmitted.

Each send takes the oldest consecutive pending prefix that fits both the frame
batch cap and packet byte cap. It piggybacks the actual retained remote ACK floor.
Only receiving new input refreshes the running input-progress clock. Duplicate
inputs, standalone ACKs and fresh local sends cannot postpone retransmission.
`poll` retries strictly after the configured interval, then resets that retry
clock even if there is no pending output.

`status_nudge = true` enables an input-idle status carrier after every pending
input has been acknowledged. It repeats exactly one owned last-acknowledged frame,
with current full-roster statuses and the actual received ACK floor. Both the
last real input send and last nudge must be strictly older than the keepalive
interval (default 200000 microseconds; explicit lifecycle options select it even
when controls are disabled). ACKs, duplicate input and lifecycle packets cannot
reset those clocks. A capacity refusal preserves the carrier, gossip and clocks;
the caller can drain outputs and retry at the same time. The session enables this
policy automatically only for an exhausted window held below actual receipts by
stale remote gossip. Standalone endpoints default to no idle carrier.
When a carrier replaces an otherwise empty retry, one `status_nudge` transition
records the service. A retained-input packet has priority at the outbox minimum;
overdue quality traffic waits for space without consuming its timer or token.
Interruption and timeout decisions still run during that deferral.

Recent received actual bytes are bounded and immutable. A conflicting retained
frame rejects the whole packet. Older pruned frames are ignored and cumulatively
re-ACKed, repairing a lost ACK without overwriting confirmed session data.
Full-roster status `last_frame` values merge monotonically. `peer_statuses`
contains only received peer observations; the separate `connect_statuses` cache
contains local status supplied to `submit`/`poll` and feeds outgoing packets.
Local status must never stand in for evidence of a remote peer retaining input.
Disconnect flags and nonzero epochs return `UNSUPPORTED_KIND`: disconnect
convergence and epoch changes remain separate roadmap work. An explicit lifecycle options
argument enables [quality, liveness, checksum and goodbye controls](peer-lifecycle.md).
Omitting it preserves the standalone input-only API; the peer façade enables it
by default.

## Bounds and evidence

Input options bound pending and received history (1–4096 frames each), packet
batches (1–128 frames) and each publication queue (1–4096 entries). Configuration
checks cardinalities before allocating lookup state and rejects history geometry
above the configured retained-byte budget, capped at 16 MiB. Geometry includes
one extra locally packed frame for the last acknowledged input:
`(max_pending_frames + 1) * local_width + max_received_frames * remote_width`.
Existing callers with an exact history-only budget must include this extra frame. The handshake options
own packet size and independent handshake queue capacities. Input publication
queues have their own caps; callers drain all outputs between service iterations.
At least one complete input frame in either direction must fit the packet cap.
Capacity rejection preserves state, timestamps, ACKs and retained bytes and occurs
before calling the sink. Received history is pruned only after actual retention.

`tests/unit/test_input_endpoint.gd` drives production bytes through loss, gap
recovery, inclusive/future/stale ACKs, strict retry boundaries, stale gossip,
multiple slot ownership, malformed/source/connection rejection, conflicts,
publication/history capacity, callback refusal/reentry and owned views on both
engine pins. The transport source contract is the pinned upstream
`src/network/protocol/mod.rs`: `classify_ack_frame`/`apply_ack_frame`,
`send_pending_output`, running `poll`, and `on_input`. The Rust reference uses
delta/RLE compression while the Godot wire uses raw bounded records; comparison
must project complete semantic frames and ACK/status observations.
