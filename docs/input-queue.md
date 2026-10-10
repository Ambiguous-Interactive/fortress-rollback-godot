# Input queue and prediction contract

This source audit scopes [C1](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/25)
and [C2](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/26)
against Fortress `f13cd5c0f2815926785a395947e18da0dbea0dd8`.
It contributes to [B2](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/13);
it does not complete that inventory or certify source-family coverage.
The [session ADR](contracts.md) remains authoritative for the Godot API boundary.

## Source anchors

These links bind contracts to the pinned source, rather than moving upstream branches.
Method names are the stable anchors; line numbers help locate this revision.

| Source | Audited anchors |
| --- | --- |
| [Queue](https://github.com/wallstop/fortress-rollback/blob/f13cd5c0f2815926785a395947e18da0dbea0dd8/src/input_queue/mod.rs) | `try_with_queue_length` (275), `set_frame_delay_with_reclaim_floor` (396), `reset_prediction` (539), `confirmed_input` (547), `discard_confirmed_frames` (828), `input` (937), `add_input_with_reclaim_floor` (1506), `add_input_by_frame` (1541), `advance_queue_head` (1789) |
| [Strategies](https://github.com/wallstop/fortress-rollback/blob/f13cd5c0f2815926785a395947e18da0dbea0dd8/src/input_queue/prediction.rs) | `PredictionStrategy`, `RepeatLastConfirmed::predict`, `BlankPrediction::predict` |
| [Sync layer](https://github.com/wallstop/fortress-rollback/blob/f13cd5c0f2815926785a395947e18da0dbea0dd8/src/sync_layer/mod.rs) | `rollback_window_floor`, `add_local_input`, `add_remote_input`, `reset_prediction`, `set_last_confirmed_frame` |
| [P2P session](https://github.com/wallstop/fortress-rollback/blob/f13cd5c0f2815926785a395947e18da0dbea0dd8/src/sessions/p2p_session.rs) | `advance_frame` prediction and lockstep gates, around lines 3194–3208 |

## Retained actual inputs and delay

Each queue belongs to one player. Its retained ring has exact frame tags and a
bounded contiguous interval; a modulo index alone does not prove ownership.
Rust's default capacity is 128. Construction rejects capacity below two and
allocation failure. The maximum delay is capacity minus one.

Ordinary submissions schedule sample frame `f` at `f + delay`. After the first
accepted submission, that scheduled frame must equal the last accepted frame
plus one. Duplicate, old and skipped submissions return `Frame::NULL`.
A first Rust submission above frame zero fills the prefix from zero with default
input. If that prefix exceeds capacity, `add_input` returns `Frame::NULL` after
retaining the successfully inserted prefix. It does not restore the whole add.
The Godot queue rejects such insertion atomically; this is an intentional
divergence. Godot session submission additionally requires the current sample frame.
With ordinary frame-zero startup, delay `D` creates neutral inputs at `0..D-1`
and stores the first actual sample at `D`.

Setting the same delay changes nothing. Before accepting inputs, delay can
increase or decrease. After accepting inputs, decreasing it returns
`InputDelayDecreaseUnsupported`. Increasing it inserts copies of the latest
input into the newly created gap, then changes the delay. Failed gap insertion
restores queue state, including prediction fields and delay. A configured neutral
Godot payload replaces Rust's generic `Input::default()`; neutral need not be zero.

The ordinary Rust `add_input` path refuses insertion into a full ring rather
than overwriting retained history. The session's reclaiming path may evict only
frames at or below a supplied global rollback floor. It preserves the floor
itself in one bounded side slot. This protects cross-player rollback history;
a player's local arrival progress cannot authorize another player's eviction.
The sync layer computes the floor as `max(0, current_frame - prediction_limit)`.

`discard_confirmed_frames(f)` removes frames strictly before `f`, retaining `f`
when present. It clamps `f` to the last requested frame when that marker exists.
It keeps the newest actual input even for a target beyond the newest frame.
An empty queue stays empty. Resetting prediction clears the last-request marker,
so it also removes that discard clamp. This is retention behavior, not permission
to mutate already accepted actual bytes.

`confirmed_input(f)` checks an exact frame tag and never creates a prediction.
Both low-level implementations may still find a tagged ring slot outside the
logical retained interval before reuse. Session callers must validate retained
history before using this result for recovery. Tests must distinguish physical
stale bytes from recoverable history; `input` enforces the retained lower bound.

## Prediction episodes

The queue directly calls `RepeatLastConfirmed`. Its base is the latest accepted
actual input for this player, including delayed gap fillers. It is independent
of the session-wide confirmed frame. Before any accepted actual input, it uses
default input. Godot uses the configured neutral payload at this boundary.
The strategy types' descriptive phrase “last confirmed” means this per-player
queue value; it does not mean the last frame confirmed for every player.

Without an active episode, retained actual reads return `Confirmed`. A missing
read starts an episode, freezing the current per-player value. Bookkeeping starts
at the first missing frame (`last_added_frame + 1`, or zero for a virgin queue),
even if the requested frame is later. Repeated reads return the frozen value with
`Predicted` status. While the episode remains active, the Rust `input` path also
returns that prediction for otherwise retained frames; `confirmed_input` is the
separate exact-actual lookup. Session callers normally request increasing frames.

Every sequential accepted arrival updates the actual-input base and compares
its bytes against the frozen value. The first differing arrival records the
first incorrect frame. Later mismatches do not replace it. Matching arrivals
through the last requested frame end the episode if no mismatch occurred.
After a mismatch, every `input` read is refused, including an actual frame,
until rollback calls `reset_prediction`. Reset clears the episode, incorrect
frame and last-request marker; it preserves actual inputs and their latest base.
A later missing read freezes that latest base into a new episode.

Required asymmetric witness: A has actual inputs through 6, B through 4 with
value 7, and C through 1. Global confirmation remains 1. B reads at 5 and 6
predict 7. B's arriving frame 5 value 9 updates its actual base but marks mismatch
5 against frozen 7. Reads fail until reset. After reset, frame 5 is actual 9 and
missing frame 6 predicts 9. A test must observe statuses, mismatch, refusal and
post-reset value separately. Equal arrival prefixes cannot exercise this case.

## Prediction window and Godot boundary

The queue has no session prediction-window gate. P2P owns that gate.
For a positive limit `P`, advancement requires `ahead < P`. When confirmation
is `-1`, `ahead = current_frame`; otherwise it is `current_frame - confirmed_frame`.
With `P=8`, no confirmation permits input frames 0–7 and stalls at 8.
Confirmation of input frame 0 still stalls at current frame 8. Both witnesses
must survive differential normalization. Zero prediction uses lockstep and
requires actual input from every player for the current frame.

| Boundary | Required Godot behavior |
| --- | --- |
| Frames | Reject negative frames and arithmetic past `2147483647`; `-1` is metadata only |
| Ownership | Copy fixed-width submitted and returned bytes; callers cannot modify retained actual input |
| Local retry | Identical repeated current sample is idempotent during stalls; changed bytes return `INPUT_ALREADY_SUBMITTED` |
| Queue failures | Typed invalid-frame, nonsequential, capacity and retained-history failures; failed insertion preserves state |
| Capacity | Validate before allocation; account for any retained-floor side slot in total storage bounds |
| Fatal recovery | Missing required history terminates explicitly before game load; queue success alone cannot prove recoverability |

Rust's internal `Frame::NULL`, `Option` and telemetry violations are oracle
observations, not the Godot public result vocabulary. Invalid low-level frame
handling and atomic rejection of an over-capacity startup prefix are intentional
stricter Godot boundaries. Exact tagged-slot lookup remains raw queue parity.
The ADR's idempotent submission wrapper is also distinct from Rust queue-level
duplicate rejection. Compare supported legal queue traces directly; test the
additional Godot validation and ownership contracts independently.

## Deferred modes and acceptance evidence

The exported Rust `BlankPrediction` and custom `PredictionStrategy` implementations
are standalone strategy APIs. The audited queue has no strategy-selection field;
its reads hardcode repeat-last prediction. The first Godot tier supports that
behavior only. Do not infer selectable queue strategies from those exports.

Frozen queues, agreed freeze frames, thaw/reset-to-frame, coordinated-drop
backfill, retained-floor recovery and hot-join lifecycle require separate semantic
entries and session evidence. First-tier active-peer loss terminates the session.
A standalone queue reclaim operation is not evidence that coordinated drop or
hot join is implemented. Rust-specific Kani/ProofVec and allocator mechanisms
need applicability decisions while preserving bounded storage obligations.

C1/C2 acceptance needs current-head native minimum/current Godot tests and an
independent pinned Rust differential runner. Compare operation results, bytes,
input statuses, first mismatch, delay and retained-history failures. Exercise
wraparound, non-power-of-two capacity, full-ring refusal, reclaim-floor boundaries,
discard clamps, neutral startup, delay changes and failed-change preservation.
Record the Rust partial-prefix startup failure beside Godot atomic rejection;
this witness must assert retained bytes after failure, not only the error code.
Prediction traces need matching completion, frozen-value mismatch, skipped read
entry, virgin entry, earliest mismatch across players and reset after correction.
Add width/frame/capacity rejection and alias-mutation checks at the Godot boundary.

A real game/session test must also prove prediction stalls and corrected
resimulation equal an uninterrupted actual-input run. Queue fixtures alone do
not close C3 rollback/history, C4 sync-test, event parity, or session lifecycle.
Upstream unit tests, property tests, fuzz regressions, allocation checks and
formal models remain source obligations until mapped to executable evidence.
The schema-1 [ledger](reference/parity-ledger.json) cannot split these mixed
source families into semantic entries. Their family status remains pending;
this document supplies scoped audit evidence without a coverage certification.

## Reproduce the current implementation

The runtime component is `addons/fortress_rollback/core/input_queue.gd`.
Construct `FortressInputQueue`, then call `configure(capacity, neutral_bytes)`.
Its typed `Code`, `Status` and owned `Result` fields report queue operations.
Configuration caps capacity and input width at 65536 and ring payload at 16 MiB;
frame tags, object metadata and temporary owned copies add bounded overhead.
The addon has no Rust, SignalFish or SceneTree dependency.

```sh
make test-godot GODOT=/path/to/godot
make test-oracle
make queue-probes GODOT=/path/to/godot
```

The queue runner verifies source archives and the existing Rust toolchain/lock
before building a development-only `__internal::InputQueue` adapter. It executes
705 cases and 7961 operations in each fresh process, twice per implementation.
Its exhaustive component covers every depth-three operation sequence from a
seven-operation alphabet after valid frame-zero insertion, for capacities two
and three. This is a finite scoped exploration, not an exhaustive queue proof.
Other cases cover player indices 0–7, widths 1/4/8/32, ring wrap, duplicate/old
rejection, delay changes, matching and differing prediction episodes and reset.
The independent Godot unit suite verifies custom neutral bytes, invalid bounds,
owned input/read copies and atomic failures.

`receipt.json` records engines, source/binary/lock/scenario/trace hashes,
completion counts, run-twice equality and limits. Missing/extra records and the
first exact normalized difference fail comparison. Four malformed artifact
controls run against each binary; a separate witness records the reviewed
startup partial-prefix divergence and checks retained bytes after rejection.
Raw traces and logs remain under `.cache/reference/results/queue/` by default.
CI runs the queue corpus on the minimum and pinned current native engines.
Exported-browser queue coverage remains a separate gate.
