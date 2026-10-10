# Local sessions and rollback core

The shipped addon implements `FortressConfig`, `FortressSession`, bounded
snapshot reader/writer views and `FortressDriver`. All extend `RefCounted` and
run without SignalFish, Rust, nodes or engine physics.

Local sync-test is supported for 2–8 players. Setting `sync_test=false` exposes
an external-input core for deterministic delivery experiments. It provides
prediction and correction, without a transport, handshake or network lifecycle.
Networked P2P and browser release gates remain in the [plan](../PLAN.md).

## Setup and callbacks

Preload `addons/fortress_rollback/core/config.gd`, `session.gd` and `driver.gd`.
Configure input width and same-width neutral bytes, ascending dense player slots,
local slot membership, delay and prediction limits. Every sync-test slot is local.
Supply `max_snapshot_bytes` and `storage_budget_bytes` explicitly. `validate()`
rejects incompatible capacities before allocation; `configure()` owns a copy.
Mutation of the original configuration cannot change the session.

`required_storage_bytes()` includes queue payload/tag storage, the retained-floor
side slot, snapshot payloads, staging/views and first-save comparison history.
Godot object/array metadata adds bounded overhead; this is a payload reservation,
not a measured whole-heap limit or a zero-allocation guarantee. Prediction and
check distance are capped at 128, with at least `max(window,distance)+1` snapshots.

A game supplies these synchronous methods:

| Callback | Result and contract |
| --- | --- |
| `save_state(frame, writer)` | `Driver.SaveResult(ok, checksum)`; write full canonical `S(frame)` through `write_bytes` |
| `load_state(frame, reader)` | `bool`; consume the complete published snapshot through `read_bytes` |
| `simulate_frame(frame, inputs)` | `bool`; read each ascending slot through `inputs.read(player)` and advance exactly once |

`Driver.LocalInput(player, sample_frame, bytes)` copies one local sample.
Construct `Driver.new(session, game)` and call `step(now_us, samples)` per tick.
`StepResult` reports code, before/after frame and drained events. The driver
consumes the expert engine's requests in order; it has no rollback algorithm.
A failed callback terminates the session. GDScript exceptions or malformed
callback return types are application programming errors; use the typed result
contracts and return explicit failure for runtime errors.

The game owns snapshot format/version, stable checksums, PRNG state and pending
simulation events. Enabled checksums are exactly 16 bytes in little-endian
unsigned128 order. Readers reject underflow or trailing bytes; writers reject
overflow with sticky errors. Views expire on completion or termination.
Returned bytes are copies. Snapshot slots validate frame and generation.

## Expert request consumption

Submit every local sample using `submit_local_input(player, current_frame, bytes)`.
Identical retries during a stall are idempotent; a conflicting retry returns
`INPUT_ALREADY_SUBMITTED`. Input delay schedules each local sample. In external
mode, `receive_input(player, scheduled_frame, bytes)` accepts already scheduled
remote inputs; frames must arrive sequentially starting at zero and remain
immutable. A gap is rejected without changing confirmation or input history.
Delayed neutral prefixes must arrive explicitly as remote input records.

`begin_advance()` returns a typed result. `READY` includes a batch whose
`next_request()` returns the next `SAVE`, `LOAD` or `ADVANCE`. Complete it through
`complete_request(batch_id, request_id, callback_ok, checksum)` before requesting
the next. No completion may be duplicated, skipped, reordered or borrowed from
another batch. Poll, submit, configure and advance return `BUSY` during a batch.
Read-only status remains available. An abandoned batch stays busy until termination.
Driver callbacks keep an independent mutation guard through their return, even
when a callback explicitly terminates the session; reconfiguration is available
only after the callback ends.

`current_frame` is the next input frame. `SAVE(f)` and `LOAD(f)` refer to `S(f)`;
`ADVANCE(f)` produces `S(f+1)`. The exposed frame changes only after all callbacks
succeed. Recovery loads its earliest mismatched frame, advances that frame, then
saves before each subsequent resimulated advance. Missing recovery history is
fatal before a load callback. Presentation reads only the final corrected state.

For positive prediction limit `P`, advancement requires `ahead < P`. Before
confirmation, `ahead=current_frame`; otherwise it is `current_frame-confirmed`.
Zero prediction waits for actual current inputs from every slot. Global
confirmation is the minimum actual scheduled input frame across all players;
it can include the current unsimulated frame. Speculative agreement never confirms.
A recovery-only batch can finish with `PREDICTION_STALL`; it corrects the game,
preserves the current sample and leaves the exposed frame unchanged.

## Sync-test behavior and verification

Sync-test distance `D>0` loads `current-D` only when `current>D`. It checks
resimulated snapshots on the next advance against the first saved canonical
bytes and, when enabled, checksums. Byte comparison catches checksum collisions.
Distance zero emits only advances, matching pinned upstream behavior; it performs
no save/load nondeterminism detection. Sync-test and the driver share the same
snapshot and request engine as external-input correction.

Run `make test-godot` and `make oracle-probes GODOT=/absolute/path/to/godot`.
[Oracle documentation](oracle.md) specifies exact Rust/Godot trace comparisons.
Unit experiments also cover 2–8 players, tiny rings, 40-frame repeated recovery,
integer PRNG and pending-event state, deliberate omissions, constant checksum
collisions, asymmetric delayed input, lockstep, callbacks, reentry and stale views.

The current sync-test event drain is empty, matching upstream. External-input
mode has no network events. Status reports terminal reason plus failure frame
and request kind where applicable. The [ADR](contracts.md) remains the target
contract for future transport/events and release interfaces. This implementation
uses `complete_request(..., callback_ok, checksum)` and driver-local callback
records as the current typed completion boundary.
