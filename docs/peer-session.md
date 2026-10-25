# Fixed-membership byte sessions

`FortressPeerSession` connects the shared rollback engine and game driver to one
input endpoint per remote identity. It supports 2–8 player slots, including
multiple local handles. Applications supply delivery, source attribution,
integer protocol time and request tokens. The [playable example](peer-example.md)
runs two sessions through an in-process transport with packet faults.

Preload `addons/fortress_rollback/core/peer_session.gd`. Configure the existing
core configuration, a protocol `SYNC_REQUEST` profile, game callbacks, handshake
options and input endpoint options. Core/profile player count, local roster
ownership, input width, neutral bytes, delay, prediction window and queue capacity must agree.
Use external-input mode (`sync_test = false`, `check_distance = 0`).
With three or more distinct identities, lockstep (prediction zero) and prediction
one without input delay are rejected. Those pinned-upstream profiles cannot
propagate enough third-party gossip to resume after their first acknowledged
flight. Two-identity sessions retain low-window support; delayed prediction one
remains permitted. This restriction counts endpoint identities, not player slots.

| Operation | Result and contract |
| --- | --- |
| `configure(config, local, game, handshake_options, input_options, lifecycle_options = null)` | One-shot configuration; lifecycle controls enabled by default. |
| `peer_ids()` | Owned remote identities in ascending hexadecimal order. |
| `begin(now_us, tokens)` | One nonzero 16-byte token per remote, in `peer_ids()` order. |
| `poll(now_us, tokens = [])` | Service every endpoint with current receipt gossip; supply fresh retry tokens during synchronization. |
| `receive(packet, attributed_sender, now_us, next_token = null)` | Route actual bytes using independently attributed sender identity. |
| `receive_and_poll(packet, attributed_sender, now_us, next_token = null, tokens = [])` | Receive and service timers using the receipt gossip from the start of the operation. |
| `step(now_us, local_inputs)` | Existing driver `StepResult`; submit every local slot at the current sample frame. |
| `close(now_us, reason = 0)` | Queue redundant goodbye packets and halt the fixed-membership game. |
| `status()` | Existing core status, including frame, confirmation and termination reason. |
| `network_status()` | Owned endpoint observations keyed by remote hexadecimal identity. |
| `drain_outbox()` | Owned `Packet` records with `to` and `bytes`; caller delivers or drops them. |
| `drain_events/transitions()` | Owned endpoint records tagged with a `peer` byte identity. |

Use `receive_and_poll` for a single incoming packet and timer service in the same
iteration. Retry packets carry the receipt bank from before delivery, matching
the upstream service boundary; accepted input is still retained before its ACK.
Separate `receive` and `poll` calls publish the receipt bank from after delivery.

Call `poll` during stalls and drain **all three** publication queues each service
iteration. They are bounded independently. A sender can enter running state
before its receiver. During compatible synchronization, the receiver validates
early gameplay/control bytes and discards them with `OK`; it does not retain
inputs, acknowledge receipt or change gameplay. The sender retains its inputs
and retries after synchronization. Malformed bytes, wrong session/sender, known
connection mismatch and inputs claiming another player's slot remain errors.
This permits independent handshake completion over unordered delivery.

`step` requires the complete local sample set and validates it before submission.
It transmits the actual delayed frame returned by the core, retaining the packed
sample in every endpoint before advancing the game. `NOT_SYNCHRONIZED` means the
handshake gate remains closed. `NETWORK_BACKPRESSURE` preserves the current game
frame and accepted sample; drain queues or recover ACKs, then retry identical
inputs. `PREDICTION_STALL` preserves the current frame but can still repair old
predictions and save that boundary. Save/load callbacks must therefore tolerate
repeated frames. Changing an already submitted sample is rejected.

Once the shared engine's frame or request counter is exhausted, `step` and
`recover` return `FRAME_EXHAUSTED` and terminate before accepting or publishing
another local sample. Missing input cannot conceal this terminal outcome.
When lifecycle controls are enabled, drain and deliver the final goodbye packets.

`step_completed(code, frame_before, frame_after)` emits synchronously after all
game callbacks and peer controls finish. It reports configured stalls, not-ready
attempts and errors too. Unconfigured and BUSY calls emit nothing. Read the final
state for presentation inside the handler; mutating peer calls stay BUSY and drains
return empty until handlers finish. Drain packets, events and transitions after `step` returns.

Clock values are nonnegative, nondecreasing integers. A valid operation consumes
its supplied clock before component mutations, including a partially published
multi-link operation. Link publication is independently atomic; the façade does
not promise an atomic transaction across all peers. Callback reentry returns
`BUSY`; drains inside callbacks return empty. Protocol mismatch or inability to
retain accepted remote input terminates the core explicitly.

Recoverable pressure on one link does not suppress polling later links. Their
elapsed clocks and disconnect deadlines still apply. `poll` retains its
`BACKPRESSURE` result when another link progresses or expires; inspect committed
lifecycle and drain events before delivering buffered traffic.

For local slots, confirmation uses the local scheduled receipt. For remote slots,
it requires both local receipt and every remote endpoint's incoming receipt
gossip. Outgoing local status never counts as a remote observation. Confirmation
names immutable input history; predicted game state can require another `step`
to repair after delivery. Compare game bytes at completed confirmed boundaries.

Gossip travels with input packets. When the prediction window is exhausted and
confirmation falls below every actual receipt, `poll` and identical stalled-sample
`step` retries automatically refresh remote evidence. Each input-idle endpoint
repeats one owned acknowledged input strictly after its keepalive interval
(default 200000 microseconds), carrying current receipts. Lost carriers retry;
ACKs and lifecycle controls cannot postpone them. Pending input retransmission
still owns recovery when actual input is missing. Confirmation remains bounded
by actual receipts and incoming remote gossip.

This matches the pinned upstream exhausted-window nudge arm. The source's
separate disconnect-agreement arm remains outside fixed-membership support.
Voluntary idle periods with prediction room can retain a final confirmation lag;
submitting another input propagates fresh gossip. Final-tail convergence and real
WebRTC/SignalFish delivery have separate roadmap gates.
[Lifecycle controls](peer-lifecycle.md) provide timing observations, confirmed
game checksums and explicit terminal outcomes. This façade is a usable byte
session, not a supported browser release.

See [input exchange](input-exchange.md) for bounded retention and ACK rules,
[session callbacks](session.md) for game state obligations, and
[source comparisons](oracle-p2p.md) for exact scope and evidence.
