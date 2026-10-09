---
name: determinism
description: "Bit-identical simulation across platforms: seeded RNG only, no wall-clock, no transcendentals, fixed timestep, integer/fixed-point math, full state snapshot/restore. Use when writing or reviewing ANY simulation, state, input, checksum, or replay code."
metadata:
  category: core
---

# Determinism

Determinism is not a feature of this library; it **is** the product. A rollback
netcode that diverges on a different CPU, OS, or compiler build is broken. The
upstream Rust crate achieves this with `#![forbid(unsafe_code)]`,
`BTreeMap`-ordered collections, and no hidden entropy. In GDScript we must
re-derive those guarantees ourselves.

## The Rule

Simulation code is any code that advances game state frame to frame. It must
produce identical state for identical input sequences — bit for bit, on every
platform — forever, including after load/save and across replays.

## Forbidden in Simulation Code

| Forbidden | Why | Use instead |
| --- | --- | --- |
| `randf()`, `randi()`, `randomize()` | Global RNG, unseeded, unsnapshottable | Seeded `RandomNumberGenerator` or a custom PRNG whose state lives **inside** sim state (see [sample](../../code-samples/deterministic_rng.gd)) |
| `Time.get_ticks_*`, `Time.get_unix_time*` | Wall clock varies per machine/frame | Fixed frame counters |
| `sin/cos/tan/atan2/exp/log/pow` (float) | libm results differ per platform | Integer tables, fixed-point, or precomputed data |
| `move_and_slide()` / physics engine | Solver is not cross-platform deterministic | Custom kinematic integration at fixed tick |
| `Vector2.normalized()` chains in sim | `sqrt` is IEEE-exact (safe), but downstream float accumulation drifts | Prefer integer math; if floats, keep ops in fixed order |
| Threads / `Mutex` / `WorkerThreadPool` in sim | Ordering is scheduler-dependent | Single-threaded sim; parallelize presentation only |
| `hash()` builtin for state checksums | Algorithm may differ across Godot versions/platforms | Explicit FNV-1a (see [sample](../../code-samples/state_checksum.gd)) |
| Iterating sets where order matters | GDScript `Dictionary` preserves insertion order, but sorted iteration is the contract for state walks | Sort keys explicitly before iterating in checksums/serialization |

## Required

1. **Fixed timestep**: the sim advances only in whole ticks (60 Hz, set in
   `project.godot`). Never advance by delta time. See
   [fixed_step_loop.gd](../../code-samples/fixed_step_loop.gd).
2. **Seeded, snapshotted randomness**: every PRNG is constructed from state
   that is itself part of the saved state.
3. **Integer-first math**: damage, positions (tile-based), timers in ticks.
   If floats are unavoidable, document why and keep expressions in one
   platform-stable form (`+ - * /` on floats are IEEE-deterministic; avoid
   fused reordering by not relying on compiler optimizations — GDScript
   evaluates in source order).
4. **Full state capture**: save/load must round-trip *everything*, including
   PRNG states, pending events, and frame counters. Missing one field = desync
   that only appears mid-match.
5. **Checksum discipline**: checksum state every N frames; include the frame
   number and input prefix in the comparison so divergence is localizable.

## Godot-Specific Traps

- `Array.sort()` is not documented as stable; provide full tie-breaking in
  comparators when order feeds the sim.
- `String.to_float()` parsing may differ across platforms; parse replay/data
  numbers as integers where possible.
- `@export` variables changed in the editor must not bypass constructors —
  they silently differ between editor and exported builds. Gate dev-only
  values with `OS.is_debug_build()` outside the sim, never inside it.
- `PI`, `TAU` constants are fine; computed trig on them is not (in sim).

## Metamorphic Relations (oracle-free checks)

These relations must hold for ANY correct sim state and inputs; each is a
test that needs no expected-output fixture (write them as property tests
over seeded random scenarios):

| Relation | Check |
| --- | --- |
| Run-twice identity | Same seed + inputs twice -> identical checksum sequence (the core oracle) |
| Save/load round trip | Snapshot at K, continue to K+M; restore at K and continue to K+M -> identical checksums to the uninterrupted run |
| Resimulate-after-rollback | Roll back to frame f and resimulate the same inputs -> checksums match the pre-rollback frames (GGRS sync-test) |
| Input-order invariance | Two independent (non-interacting) inputs applied in either order -> identical final state |
| Tick-scaling consistency | Simulating 2M ticks must extend, never diverge from, the 1M-tick trajectory (prefix property) |
| Serialization round trip | Serialize -> deserialize -> serialize -> byte-identical to the first serialization |

A violated relation localizes the bug class: round-trip misses a field,
prefix violation means hidden state, serialization asymmetry means the
writer and reader disagree. On any mismatch, report seed, tick, and both
checksums so the divergent tick is bisectable (see
[debugging](../debugging/SKILL.md)).

## Verification

- Run the same seed twice in-process and compare checksums (fast, catches
  most regressions).
- Replay a recorded input log and compare the final checksum (catches
  save/restore gaps).
- Cross-platform runs (macOS dev box vs Linux CI) for release candidates.

Related: [rollback-fundamentals](../rollback-fundamentals/SKILL.md),
[testing](../testing/SKILL.md).
