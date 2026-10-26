# Session hot path measurement

This is one measured production improvement toward [issue 43](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/43).
It publishes the steady-frame, snapshot, rollback and codec costs of the
production session, and it records the one change those measurements selected.
It does not close that issue's allocation-count, sustained-memory and
release-matrix gates.

`FortressSnapshotWriter.write_bytes()` copied the caller's bytes into the
writer's buffer one interpreted step per byte, and the writer reserved its whole
capacity before the first write. The new path appends the caller's bytes with
one native buffer append and keeps the capacity as a bound instead of a
reservation. The written bytes, the sticky overflow behavior and the
caller-owned copy are unchanged.

## Reproduce

Run from the repository root with each desired engine executable:

```sh
make hot-path-probes GODOT=godot
make hot-path-probes GODOT=.cache/reference/editors/4.3/Godot_v4.3-stable_linux.arm64
```

The [benchmark](../../scripts/benchmark_session_hot_path.gd) prints one JSON
object with the engine, the workload shape and, for every workload, the p50,
p95, p99, minimum, maximum and a canonical checksum. The snapshot workload
also measures an embedded control that keeps the previous per-byte copy, in the
same process, so the two candidates see the same machine state.

The benchmark compares its checksums with the published baseline and fails
when they differ. A changed checksum means the simulated result changed, which
is a reviewed change and not a benchmark repair.

## Workloads

| Workload | What it measures | Shape |
| --- | --- | --- |
| `steady` | A whole session frame: local sample, confirmed remote samples, the ordered save and advance requests, the game's own save and the input view | 4 KiB game state, one local player, 400 frames, 15 samples |
| `rollback` | The same session with the remote inputs one window late, so every correction loads a snapshot and resimulates the prediction window | 8-frame window, 400 frames, 15 samples |
| `snapshot` | One snapshot write: the production writer against the previous per-byte control | 4 KiB payload, 400 writes, 15 samples |
| `codec` | One protocol input packet: encode plus decode, with every player's input and status | 1-byte inputs, 400 packets, 15 samples |

The session is configured exactly as a peer session: eight prediction frames,
no check distance, a nine-slot history, checksums enabled and one local player.
The game saves a 4 KiB state, restores it byte for byte and reads the frame
inputs, which is the shape of a real client's per-frame work.

The session predicts eight frames ahead of the last confirmed frame, so the
deepest correction it can reach rewinds seven frames. The benchmark fails
unless the run corrects the window that often.

Every workload accumulates a canonical checksum. The steady and rollback
checksums cover the applied input bytes and statuses of every simulated frame,
the snapshot checksum covers every written byte, and the codec checksum covers
every decoded input byte. The checksums are identical before and after the
change, on both pinned engines, so the faster path simulates exactly the same
match.

## Results

All times are microseconds per iteration. The `steady`, `rollback` and `codec`
rows are per frame or per packet; the `snapshot` row is per 4 KiB write.

| Engine | Players | Steady p50 | Steady p95 | Rollback p50 | Codec p50 |
| --- | --- | --- | --- | --- | --- |
| 4.7.2 | 2 | 88.7 → 31.7 | 94.8 → 36.3 | 146.7 → 51.7 | 25.9 → 26.4 |
| 4.7.2 | 4 | 102.6 → 44.6 | 104.9 → 45.6 | 165.0 → 67.2 | 29.3 → 29.5 |
| 4.7.2 | 8 | 124.6 → 68.5 | 129.4 → 72.8 | 212.4 → 99.8 | 38.5 → 37.0 |
| 4.3 | 2 | 157.8 → 69.3 | 160.9 → 146.3 | 286.6 → 118.1 | 33.7 → 30.6 |
| 4.3 | 4 | 178.4 → 62.7 | 184.8 → 66.2 | 292.9 → 98.5 | 36.7 → 35.2 |
| 4.3 | 8 | 233.5 → 88.2 | 299.3 → 93.4 | 328.8 → 133.4 | 45.1 → 44.0 |

The snapshot write does not depend on the player count, so it is measured once:

| Engine | Snapshot p50 | Snapshot p95 | Control p50 (previous copy) |
| --- | --- | --- | --- |
| 4.7.2 | 58.3 → 2.9 | 60.4 → 3.3 | 57.9 |
| 4.3 | 122.8 → 10.0 | 183.9 → 13.2 | 118.9 |

The snapshot write is the dominant cost of the steady frame with a 4 KiB state:
it was about two thirds of the frame before the change. After the change the
steady frame costs about a third of its previous value for 2 and 4 players and
about half for 8 players, because the per-frame input view, the request
bookkeeping and the game's own read of the frame inputs are now the larger
share. The codec is unchanged, as expected: it never used a per-byte loop.

The rollback workload improves less, because a correction resimulates seven
frames and each resimulated frame saves a snapshot of the same size.

Measurements were collected on Linux 6.12.76, ARM64, 16 CPU cores; the exact
CPU model is unavailable. There is no warmup, and the first timed sample is
kept with the others. Fifteen samples support a p50 and an approximate p95;
the p99 is reported for completeness and is not a reliable estimate. The
minimum and maximum columns of the raw output show the observed spread, which
reaches about 30 percent of the median on a shared machine. These figures
describe this host and are not a performance guarantee.

## Storage and allocation statements

The writer no longer reserves its capacity before the first write, so its own
storage is the bytes actually written rather than the configured maximum. The
capacity still bounds the writer, and an overflowing write is still rejected
before anything is copied. The new path allocates one buffer per append, where
the previous path allocated one buffer per save; this is a native allocation
per write, not a claim of zero allocation. The history slot, its checksum and
its tags are unchanged, and the configured storage budget still covers the
session's reserved payload. No allocation count, peak-memory or whole-game
latency claim is made here.

## Regression budget

On the reference host, a steady frame with a 4 KiB state costs about 32 to 45
microseconds for 2 and 4 players and about 68 to 88 microseconds for 8 players,
with an observed spread of up to about 30 percent of the median. A change that
raises the steady p50 above twice the measured median on the same hardware is
worth investigating. The budget is deliberately not a CI gate: portable CI must
not fail on an unstable timing threshold, and the browser matrix measures a
different workload.

## Correctness and source identity

The snapshot ownership, overflow, sticky-error, expiry and copy cases in
`tests/unit/test_snapshot_history.gd` cover the changed write path, and the
driver, rollback, replay and spectator suites cover the sessions that use it.
The complete unit category passes twice in fresh processes on Godot 4.7.2, and
the immutable native and Chromium ownership matrix covers the same suites on
both pinned engines.

| Source | SHA-256 |
| --- | --- |
| `addons/fortress_rollback/core/snapshot_writer.gd` | `eead54ea8f14c8e3c6cf3d99965731d629ea0a2bff7dd69e0a6796e9ed6152a3` |
| `scripts/benchmark_session_hot_path.gd` | `f526edb8d652049428ff9f2f034e8cbacdf258c30d9517df41f3dc1d16c49a25` |
| `tests/unit/test_snapshot_history.gd` | `964f680eb51be6899f5d970008c26132d4b6aa2dfd1996de3a405549547a20e6` |
| `tests/unit/test_scenario_runner.gd` | `d738f21a70c2a691af1f45ce7828844a98ad85904f66d947a59368be5ec1d219` |

Matching benchmark checksums before and after the change:

| Workload | Players | Checksum |
| --- | --- | --- |
| snapshot | - | 4150103641047209673 |
| steady | 2 | 1276642125363926553 |
| steady | 4 | 193693954048565353 |
| steady | 8 | 167760427949277961 |
| rollback | 2 | 804470947006420549 |
| rollback | 4 | 8216305103245225058 |
| rollback | 8 | 7771464832153107854 |
| codec | 2 | 1009799064992073792 |
| codec | 4 | 5039977378390133760 |
| codec | 8 | 8583044641210005760 |


## Confirmation receipt reads in eight-player sessions

Issue [223](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/223)
compares the unchanged eight-player driver/expert parity case at seed 1701.
Both repetitions retain all 21,685 assertions, encoded traffic comparisons,
callback/status checks and independently reconstructed canonical boundaries.
The baseline is `7363ecd18a52f4eeffe5e3b3b477ef4d5e72e42b`.

Firefox 142.0.1 with Godot 4.3 on Linux arm64 measured:

| Receipt observation | Complete case time |
| --- | --- |
| Full endpoint status per slot and endpoint | 377.893 seconds |
| One receipt-bank snapshot per endpoint per fold | 173.597 seconds |
| Internal scalar receipt-frame read | 141.557 seconds |

Delivery accounted for about 89 percent of the original case. Each eight-player
confirmation fold made 49 complete owned endpoint snapshots to read 49 integers.
The scalar read preserves each observation's timing and avoids copying retained
packet/input history. Public diagnostic snapshots keep their existing ownership.
The scalar-only source-bound batch still lacked sufficient margin under the
180-second page deadline. The final implementation also reads running and failure
state, local submission position and timing scalars without copying endpoint
histories. Acceptance keeps the original 180-second
page and 240-second process limits; no assertion, case or repeat is removed.

These are workload measurements, not live-game frame-rate or transport claims.
Run the complete source-bound acceptance with
`xvfb-run -a python3 scripts/reference/ownership_probes.py --web --browser firefox`.
The deterministic parity suite and both browser controls remain required on both
engine pins; the extended diagnostic budget used to measure the old slow case
never changes acceptance deadlines.
