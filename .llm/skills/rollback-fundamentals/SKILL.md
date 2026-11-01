---
name: rollback-fundamentals
description: "Rollback netcode concepts and their GDScript mapping: input delay, prediction, rollback and re-simulation, state save/load, checksums, session lifecycle. Use when designing or modifying session, input, prediction, or sync code."
metadata:
  category: core
---

# Rollback Fundamentals

This repo ports [fortress-rollback](https://github.com/wallstop/fortress-rollback)
(a fortified `ggrs` fork, GGPO lineage) to GDScript. Read this before touching
anything session-shaped.

## The Model

Each peer simulates every frame locally:

1. **Input delay**: local input for frame `N` is scheduled to be applied at
   frame `N + delay` (a few frames) so remote players' inputs usually arrive
   in time.
2. **Prediction**: if a remote input has not arrived by its deadline, predict
   it (usually: repeat the last known input) and keep simulating.
3. **Rollback**: when actual input differs from a frozen prediction, reset
   prediction and restore the required saved simulation frame. Consume the
   engine's ordered requests to resimulate; never select a snapshot from the
   global confirmation value alone. Presentation reconciles after completion.
4. **Confirm**: frames become confirmed once all players' inputs for them are
   known. Confirmed states are checksummed and exchanged to detect desync. Activating
   an additional confirmation policy cannot revoke already published history,
   including before the first simulation advance.

## Frame Lifecycle (per fixed tick)

```
submit current sample (the queue schedules input delay)
  -> advance_frame() returns ordered save/load/advance requests
  -> fulfill every request in return order
  -> consume events after completion
  -> reconcile presentation from the final simulation state
```

Predicted frames can show input-driven events that rollback later removes.
Draw reversible visuals from corrected state. Start irreversible effects only
for simulated frames at or below `confirmed_frame` and before any
`pending_rollback_frame` (delivery confirms before correction), deduplicated by stable IDs
([integration guide](../../../docs/integration.md#presentation-and-effects)).

## GDScript Mapping (from the Rust crate)

| Rust (fortress-rollback) | GDScript equivalent |
| --- | --- |
| `BTreeMap` / `BTreeSet` | `Dictionary`/`Array` iterated in explicitly sorted key order |
| `Result<T, E>` (panic-free) | Return codes + `push_error`, or a `Result`-style typed wrapper; never `assert` in sim paths |
| Traits for state serialization | Bounded writer/reader callbacks and canonical bytes; checksum is an owned 16-byte domain |
| `#![forbid(unsafe_code)]` | Pure GDScript; no engine calls inside `tick()` — sim reads only its own state + inputs |
| Event/callback channels | Typed event drain after request processing; signals never control mid-tick simulation |

## Session Lifecycle

Pinned Rust `SessionState` has `Synchronizing` and `Running`, plus feature-gated
`HotJoining`. The Godot ADR additionally specifies terminal lifecycle behavior;
do not describe that decision as an existing Rust enum variant.

Actual pinned `FortressEvent` variants include `Synchronizing`, `Synchronized`,
`Disconnected`, `NetworkInterrupted`, `NetworkResumed`, `WaitRecommendation`,
`DesyncDetected`, `SyncTimeout`, `ReplayDesync`, `SpectatorDivergence`,
`InputDelayRecommendation` and `PeerDropped`, with additional hot-join variants.
There is no built-in emitter for `InputDelayRecommendation`. Prediction and
rollback requests are not events named `prediction_used` or `frame_rolled_back`.
Public sync-test currently drains no events and exposes no confirmation getter.

Evidence: pinned `src/lib.rs` enum definitions and
`src/sessions/sync_test_session.rs`, verified by the
[runtime oracle](../../../docs/oracle.md). The
[session ADR](../../../docs/contracts.md) owns frame domains, Godot lifecycle,
request acknowledgement and view lifetime. Bootstrap samples are not APIs.

## Hard Rules

1. `sim.tick(frame, inputs)` is pure: no I/O, no engine singletons, no
   RNG beyond state-held PRNGs (see
   [determinism](../determinism/SKILL.md)).
2. Save/load round-trips exactly; a state that cannot be serialized is a bug.
3. Prediction window is bounded (`max_prediction_frames`); exceeding it means
   stall and wait, not unbounded guessing.
4. Never mutate confirmed frames' inputs. Ever.
5. Checksums flow through the transport (see
   [networking-transport](../networking-transport/SKILL.md)); a mismatch is a
   first-class error event, not a log line.

## Raw queue and session boundaries

The [audited queue contract](../../../docs/input-queue.md) separates raw queue
observations from session guarantees. `confirmed_input` checks a physical frame
tag even after logical discard; session recovery must check retained history.
Raw duplicate submission is rejected; stalled-sample idempotence belongs to the
session. Validate every local sample's metadata and list conflicts before retaining
any valid prefix; rejection must leave corrected same-frame retries usable. Use
bounded player-slot lookup for duplicate checks, rather than pairwise list scans.
For driver lists, validate completeness before retaining a prefix too; an omitted local
slot may already have an expert-staged sample. Rejected incomplete lists must allow changed
buttons on retry. Queue-capacity failure remains a separate atomicity boundary.
Prediction uses a frozen per-player episode, not global confirmation.
Applied input statuses describe execution time: a matching late actual input can
confirm history without replaying it, so retained trace rows may still say predicted.
Validate their bytes against original inputs below the corrected confirmation boundary.
Capacity failures must preserve Godot state even when the pinned upstream
startup gap path partially inserts default inputs. Keep that divergence explicit
and verify retained bytes after failure; a rejected result alone is insufficient.

## Implemented local engine

The [session guide](../../../docs/session.md) documents shipped sync-test and
external-input correction. Recovery emits `LOAD(R)`, `ADVANCE(R)`, then
`SAVE(f), ADVANCE(f)` for later resimulated frames. Commit the exposed frame only
after complete consumption. The thin driver uses the same engine. Sync-test
distance zero emits no saves/loads; positive distance rewinds only when current
is strictly greater than distance. Check canonical bytes as well as checksums
to catch missing PRNG/pending-event state even with checksum collisions.

Keep a separate driver callback guard until each callback returns. Termination
may clear the active batch, but must not reopen configuration, input submission,
polling, advancement or request completion inside that callback. Status and
termination remain available; the driver acknowledges only after releasing the
guard. Test valid request identities as well as terminate-then-reconfigure.
Completion notifications need a guard on the shared session too. A facade-local flag
cannot stop a second driver or the expert API from changing state between handlers.
Test both access paths and cancellation; keep completed read-only exports available.
Application presentation hooks can run after driver guards release. Hold shared ownership through a composed effect batch;
exercise immediate and delayed final-tail effects, including cancellation followed by reentry, and return the terminal cause.
Observe reentrant control state inside the callback; an outer reset can erase a transient mutation before the final assertion.
Destructive event drains share that guard so one completion handler cannot consume cancellation before later handlers observe it.
Apply callback termination checks to paused validation and checkpoint restoration too.
Cancellation retains the exposed playback frame as its first-cause diagnostic; a failed checkpoint restore identifies the attempted cached frame.
Track their active bounded readers/writers so termination expires them. Recheck the
latched terminal reason before accepting callback returns, invoking another callback,
committing a restored frame or publishing validation coverage.
Replacing an owned example match must retire its prior sessions and replay player, including retained public handles.
Stage replacement first and refuse it during callbacks, notifications or active expert batches.
Cross both endpoint positions in composed examples; invalid replacement settings must preserve the current match, queues and clocks.
Driver attachment and callback replacement must check the shared mutation gate on both current and target sessions.
A callback-only guard misses expert batches paused between a completed SAVE and the remaining ADVANCE.
Apply the same ownership check before composed service controls change clocks, stage inputs or pause/end playback.
An inner BUSY result cannot undo those outer side effects; cross each control with host/viewer callbacks and retained expert batches.
Hold the same composed-operation guard across SDK setup getters and transport configuration.
A callback can cancel setup before a core exists; fence the setup lifetime before creating or publishing later owners.
Cancellation may clear the public handle before the callback returns; retain that executing owner privately until it unwinds, including across repeated cancellation.
Completion getters must also exclude open navigation/revalidation batches and active callbacks, even when
the exposed frame still equals the final boundary. Test after LOAD and before its verification SAVE.

Audit low prediction windows through actual upstream callbacks before claiming
checksum parity. No SAVE callbacks means no callback-supplied checksum evidence;
extra product snapshot capture must be tested and labeled as an extension.
Use the last completed advance's confirmation boundary for exchange, and hide
snapshots invalidated by pending corrections until actual repair completes.
The [peer lifecycle guide](../../../docs/peer-lifecycle.md) owns product policy;
the [P2P oracle](../../../docs/oracle-p2p.md) owns the source comparison scope.
Protocol and P2P evidence require their own boundary tests and observations.
Browser support remains separately gated; local request parity and deterministic
delivery tests cannot establish it.

Session wrappers must preserve shared-engine terminal checks before returning
recoverable input or delay stalls. Exercise exhausted frame and request counters
through each wrapper while its input is unavailable. Run terminal preflight before
wrapper-owned sample staging, endpoint polling or publication; a later driver guard
cannot undo those effects. Nonterminal BUSY must preserve transport state.
Validate candidate samples against the shared session's retained input before wrapper-owned caching,
delivery or clock changes. Cross expert-staged input with a conflicting wrapper call and a corrected retry;
checking only active batches and callbacks misses idle input ownership.
Driver input-list and unsupported-operation preflights must precede clock commitment.
Reject a call at a later time, retry corrected input at the last accepted time, then
verify successful service still rejects a backward clock. Same-time retries conceal premature clock mutation.
When callers service only a recommended number of steps, include pending lifecycle
completion after payload drains. Test clean end through that public service loop
with empty input, a delayed tail and a gap; direct advancement can conceal starvation.
Clean closure must preserve every accepted row. Refuse a known gap before a buffered suffix without closing input, then verify recovery and complete tail playback.
Include wrapper-owned staging payloads and frame tags in configuration storage
reservations before allocation. Verify exact-budget acceptance and rejection one
byte below it; a bounded extra ring still consumes the declared budget.

Recovery can succeed without a forward frame. Consume staged local samples only when the
exposed frame advances, and refresh any retained current boundary after correction before
publishing its checksum. Finalize late matching inputs without fabricating another sample.

A peer drop changes simulation status even when frozen bytes equal prior predictions; repair
every simulated frame after the cut. Keep receipt-only replay rows private until mesh confirmation,
and rewrite their bytes, statuses and checksum coverage when the agreed drop replaces them.
The final survivor still applies the receipt-raised cut and complete per-slot retained-history checks before freezing any target.
Removing network agreement does not remove original-history protection.
Carry finalized statuses through spectator publication, authentication, retention and every playback API;
equal bytes do not imply equal simulation behavior. Use a status-sensitive game and independently
calculated states to catch a byte-only bridge, and keep historical wire versions frozen.

Specialized session modes must audit inherited public mutators and their validation-only counterparts. A confirmed-only spectator
cannot accept player freezing or player-mesh confirmation limits: playback may succeed while exports lose
their confirmed rows. Test public confirmation and row export alongside game state, using changing host inputs.
N pre-input state checksums cannot verify the state after input N-1. Keep input integrity,
pre-input coverage and final-state evidence distinct. Capture terminal checksums through a bounded
application SAVE of exactly the finalized exported prefix. Pending corrections and a capped prefix
behind the live state must not inherit a predicted or newer checksum. Preserve historical absence;
exercise a game that differs only on the last input and a matching control.

Paused replay validation must check the selected input digest before publishing snapshot or
checksum coverage, including input-only playback and boundaries without state checksums.
Revisited retained checkpoints compare canonical bytes and callback checksums before consuming input,
even when the recording has no state checksums. Apply comparison to both paused validation and
advancement through callback and expert APIs; test changed bytes with an unchanged callback checksum.
Cached comparisons do not increase recorded-checksum coverage, and evicted boundaries provide no cached evidence.
Exercise checkpoint eviction after backward navigation, when newly visited frames can be older than retained ones.
Apply chronological retention to the combined candidates before eviction; insertion order must not discard a newer verified ending.
Track displayed-state validation separately from lifetime checksum totals. Advancing input clears the selected-state claim;
only a successful recorded-checksum comparison during that visit can restore it. Cache-only validation does not qualify.

## Code Samples

- [fixed_step_loop.gd](../../code-samples/fixed_step_loop.gd) — driving ticks
  deterministically from the engine loop.
- [input_serialization.gd](../../code-samples/input_serialization.gd) —
  fixed-width input frames.
