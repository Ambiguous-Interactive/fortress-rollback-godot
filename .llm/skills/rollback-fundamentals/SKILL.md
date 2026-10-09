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
3. **Rollback**: when the real input finally arrives and differs from the
   prediction, rewind to the last confirmed frame, store the current
   visual/presentation state, re-simulate frames `confirmed..N` with correct
   inputs, then restore presentation.
4. **Confirm**: frames become confirmed once all players' inputs for them are
   known. Confirmed states are checksummed and exchanged to detect desync.

## Frame Lifecycle (per fixed tick)

```
gather_local_input(frame + input_delay)
  -> session.advance(inputs)              # may trigger ROLLBACK first
       -> load_state(last_confirmed)
       -> for f in confirmed..current: apply_inputs(f); sim.tick(f)
       -> save_state(); checksum(state)
  -> events emitted (predicted_input_used, rolled_back, desync_detected)
  -> presentation syncs from sim (interpolation optional, never in sim)
```

## GDScript Mapping (from the Rust crate)

| Rust (fortress-rollback) | GDScript equivalent |
| --- | --- |
| `BTreeMap` / `BTreeSet` | `Dictionary`/`Array` iterated in explicitly sorted key order |
| `Result<T, E>` (panic-free) | Return codes + `push_error`, or a `Result`-style typed wrapper; never `assert` in sim paths |
| Traits for state serialization | A `FortressState` interface: `serialize(StreamPeerBuffer)`, `deserialize(StreamPeerBuffer)`, `checksum() -> int` |
| `#![forbid(unsafe_code)]` | Pure GDScript; no engine calls inside `tick()` — sim reads only its own state + inputs |
| Event/callback channels | Typed signal-emitting session events (delivery deferred to end of tick, never mid-tick) |

## Session Lifecycle

`connect (start/response handshake) -> syncing (input delay negotiation) ->
running (advance/rollback loop) -> disconnected`. Mirror the upstream event
names so documentation and tests stay portable: `session_start`,
`input_processed`, `prediction_used`, `frame_rolled_back`, `desync_detected`,
`session_terminated`.

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

## Code Samples

- [fixed_step_loop.gd](../../code-samples/fixed_step_loop.gd) — driving ticks
  deterministically from the engine loop.
- [input_serialization.gd](../../code-samples/input_serialization.gd) —
  fixed-width input frames.
