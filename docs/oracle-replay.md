# Replay session applicability

Run `make replay-probes GODOT=/path/to/pinned/godot` to compare the actual pinned
Rust `ReplaySession` and the shipped `FortressReplayPlayer`. CI runs both engine
pins. The receipt and raw logs go to `.cache/reference/results/replay/`.

The probe invokes public APIs from unchanged fortress-rollback revision
`f13cd5c0f2815926785a395947e18da0dbea0dd8`. Relevant upstream source:
[`src/sessions/replay_session.rs`](https://github.com/wallstop/fortress-rollback/blob/f13cd5c0f2815926785a395947e18da0dbea0dd8/src/sessions/replay_session.rs)
and [`src/replay.rs`](https://github.com/wallstop/fortress-rollback/blob/f13cd5c0f2815926785a395947e18da0dbea0dd8/src/replay.rs).
This is gameplay replay applicability, separate from network fault-trace replay.

## Observed contract

| Boundary | Pinned Rust | Godot |
| --- | --- | --- |
| Initial frame | Last advanced frame, initially -1 | Next frame to simulate, initially 0 |
| Input playback | Recorded order, all statuses `Confirmed` | Same order, all statuses `CONFIRMED` |
| Unvalidated playback | One advance request per frame | One simulation callback per frame |
| Validated playback | Save request before every advance, even without a recorded checksum | Save callback only when a recorded checksum exists |
| Checksum domain | `u128` | 16 owned bytes; probe maps Rust `u128` to little-endian bytes |
| Mismatch | `ReplayDesync` event; continues advancing | `DESYNC`; stops before the mismatching advance |
| Final mismatch | Event drain after completion resolves pending validation | Checked before the final advance |
| Completion | True after the final advance; another advance errors | True after the final callback; another step returns `FRAME_EXHAUSTED` |
| Empty replay | Complete immediately; advance errors | Complete immediately; step returns `FRAME_EXHAUSTED` |

Godot callback playback dispatches the same ordered requests exposed by
`FortressReplayPlayer.configure_expert`, `begin_advance` and `complete_request`.
The expert interface uses the live session
[batch and request types](session.md); validation keeps the Godot policy above.
These differences are explicit expectations; the comparator excludes no
requests, events or frame observations.

## Evidence boundaries

The 22 scenarios cover two and eight players, zero, one and seven frames,
unvalidated playback, full and sparse checksums, and first/final mismatches.
Seed `4294967295` exercises unsigned input/state boundaries. Ordered integer
updates include a PRNG state and pending value in canonical 16-byte snapshots.

Python generates original inputs and independently computes every canonical
state boundary. Rust consumes the original rows; Godot decodes independently
packed version-4 FRRP files. Actual save/advance callbacks, player statuses,
events, completion and failure frames must match their full expected traces.
Comparisons validate exact fields and numeric types before comparing values.
Both engines run in two fresh processes with identical results.

Every frame of the version-4 file carries the digest of its own input row. Those
digests are a Godot-side integrity extension: the pinned upstream session owns the
input history and stores no such digest, so the corpus compares only the
upstream-owned behaviour and never claims parity for the digests.

Negative controls mutate intermediate state while preserving the final result,
input status, frame convention, numeric type, missing/invented events and a
checksum-absent upstream save. Each
must fail at its independently named boundary. The mismatch scenarios corrupt
actual encoded checksum bytes and require Godot to stop before simulation.
Separate process controls reject oversized Rust/Godot bundle files and empty
or excessive Rust case inventories.

Receipts bind authored sources, verified engine archive bytes, oracle binary,
scenario files and the pinned source/lockfile identities. Source and tool hashes
must remain unchanged throughout execution. A failed attempt removes its prior
success receipt and retains raw logs.

This does not establish upstream recording parity, file interchangeability,
independent expert-request differential coverage, snapshot seek acceleration or network-fault replay.
Native/browser gameplay replay evidence remains in the
[ownership experiment](experiments/buffer-ownership.md) and
[online example](online-example.md#record-and-download-a-replay).
