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
Connect `driver.step_completed(code, frame_before, frame_after)` to update
presentation after an outer step finishes. The signal runs synchronously after
all game callbacks and event collection, including repair-only stalls and
explicit callback failures. Request views have expired. `BUSY` and unconfigured
calls emit no completion signal; they did not own a step. Recursive `step` and
`configure` calls on this driver return `BUSY` until all signal handlers return.
Use the scalar notification for presentation and the returned `StepResult` for
the owned event list. Peer callers use `peer.step_completed` or reconcile after
`peer.step` returns; both observe finished peer control processing. Peer signals
report every configured attempt, including not-ready/error outcomes. Unconfigured
and recursive BUSY attempts emit nothing. Mutating peer calls remain BUSY inside
handlers, and publication drains return empty until the outer call returns.

A failed callback terminates the session. GDScript exceptions or malformed
callback return types are application programming errors; use the typed result
contracts and return explicit failure for runtime errors.

The game owns snapshot format/version, stable checksums, PRNG state and pending
simulation events. Enabled checksums are exactly 16 bytes in little-endian
unsigned128 order. Readers reject underflow or trailing bytes; writers reject
overflow with sticky errors. Views expire on completion or termination.
Returned bytes are copies. Snapshot slots validate frame and generation.
`confirmed_checksums(include_boundary = false)` returns owned saved-frame,
generation and checksum metadata. Active requests and callback reentry return
an empty inventory. Pending correction excludes affected snapshot boundaries.
External cores can enable `capture_confirmed_snapshots` to save advancing
lockstep boundaries; the default is false. Peer checksum exchange enables it.
Call `reader.is_complete()` after reading a fixed-size snapshot and before
applying restored fields. It returns false for unread trailing bytes, errors
or expired views; request completion still belongs to the driver or expert API.

## Expert request consumption

Submit every local sample using `submit_local_input(player, current_frame, bytes)`.
Identical retries during a stall are idempotent; a conflicting retry returns
`INPUT_ALREADY_SUBMITTED`. Successful submissions and identical retries return
the actual delayed scheduled frame in `Result.value`. Before successful advance,
`scheduled_local_input(player)` returns an owned `InputResult` with that frame,
bytes and confirmed status; absent samples return `MISSING_LOCAL_INPUT`.
`set_input_delay(player, delay)` raises a local delay by appending copies of the
latest actual input. Raised during a stall, the retained sample's retries and
`scheduled_local_input` then report the last appended frame, which holds the same bytes.

In external mode, `receive_input(player, scheduled_frame, bytes)` accepts already
scheduled remote inputs. The first record may start at zero or at the negotiated
`input_delay`; the latter uses the queue's bounded atomic startup insertion of
neutral frames. Subsequent records are strictly sequential and immutable.
Explicit neutral prefixes remain supported. A rejected gap preserves history.
`received_frames()` returns an owned per-slot actual scheduled receipt vector.

A fixed-membership transport can enable `set_confirmation_limit(-1)` before
actual receipts expose a higher confirmation and before simulation, then publish
its monotonically increasing mesh confirmation fold. Initial activation must
preserve the already published confirmation even when the simulation frame is
still zero. An equal initial bound is valid; a lower bound is rejected.
Each bound must remain in `[-1, FRAME_MAX]` and no greater than the local receipt
minimum. This mutation observes the same batch and callback guards as input.
Sync-test rejects it; standalone external sessions retain receipt-only behavior.
The transport folds each remote slot's local receipt with every running
endpoint's gossiped receipt, while local slots contribute their own receipt.
The pinned source witness is `P2PSession::remote_slot_confirmed_bound` and
`confirmed_frame` at commit `f13cd5c0f2815926785a395947e18da0dbea0dd8`.
Disconnect membership changes require a separate protocol; this bound cannot
lower confirmation or implement disconnect convergence.

`begin_advance()` returns a typed result. `READY` includes a batch whose
`next_request()` returns the next `SAVE`, `LOAD` or `ADVANCE`. Complete it through
`complete_request(batch_id, request_id, callback_ok, checksum)` before requesting
the next. No completion may be duplicated, skipped, reordered or borrowed from
another batch. Poll, submit, configure and advance return `BUSY` during a batch.
Read-only status remains available. An abandoned batch stays busy until termination.
`status().pending_rollback_frame` names the earliest incorrect predicted input,
or `-1` when no correction is pending.
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
confirmation is the minimum actual scheduled input frame across all players,
capped by the explicit mesh limit when enabled;
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

## Completed work statistics

`session.statistics()` returns a new `FortressSessionTypes.Statistics` value.
The peer facade exposes the same counters with `peer.statistics()`. Both the
manual request API and `FortressDriver` update this single engine inventory:

| Field | Meaning |
| --- | --- |
| `rollback_count` | Successfully completed LOAD callbacks, including sync-test rewinds. |
| `resimulated_frames` | Successfully completed ADVANCE callbacks below the current frontier. |
| `advanced_frames` | Successfully completed ADVANCE callbacks at the current frontier. |
| `prediction_stalls` | Attempts that finish with PREDICTION_STALL, including repair-only batches. |
| `last_rollback_depth` | Frontier minus restored frame for the last successful LOAD. |
| `max_rollback_depth` | Largest successful LOAD depth in this configured session. |

Rejected calls and failed callbacks do not count as successful work. A successful
restore followed by a later callback failure still counts that completed restore.
Repeated reads do not drain or reset counters. Returned values cannot change the
session. A successful fresh `configure` resets every counter; rejected configuration
does not. Counts saturate at signed 64-bit maximum and stay outside game snapshots.
