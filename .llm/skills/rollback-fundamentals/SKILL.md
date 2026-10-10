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
   known. Confirmed states are checksummed and exchanged to detect desync.

## Frame Lifecycle (per fixed tick)

```
submit current sample (the queue schedules input delay)
  -> advance_frame() returns ordered save/load/advance requests
  -> fulfill every request in return order
  -> consume events after completion
  -> reconcile presentation from the final simulation state
```

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
session. Prediction uses a frozen per-player episode, not global confirmation.
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

Protocol, P2P event lifecycle and browser support remain separately gated.
Do not infer those from local request parity or deterministic delivery tests.

## Code Samples

- [fixed_step_loop.gd](../../code-samples/fixed_step_loop.gd) — driving ticks
  deterministically from the engine loop.
- [input_serialization.gd](../../code-samples/input_serialization.gd) —
  fixed-width input frames.
