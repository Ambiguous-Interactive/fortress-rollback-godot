# Session hot path measurement

This is one measured production improvement toward [issue 43](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/43).
It publishes the steady-frame, snapshot, rollback and codec costs of the
production session, and it records the one change those measurements selected.
It does not close that issue's allocation, sustained-memory and release-matrix
gates.

`FortressSnapshotWriter.write_bytes()` copied the caller's bytes into the
writer's buffer one interpreted step per byte, and the writer reserved its whole
capacity before the first write. The new path appends the caller's bytes with
one native buffer append and keeps the capacity as a bound instead of a
reservation. The written bytes, the sticky overflow behavior and the
caller-owned copy are unchanged.

## Reproduce

Run from the repository root with each desired engine executable:

```sh
godot --headless --path . --script scripts/benchmark_session_hot_path.gd
.cache/reference/editors/4.3/Godot_v4.3-stable_linux.arm64 --headless --path . --script scripts/benchmark_session_hot_path.gd
```

The [benchmark](../../scripts/benchmark_session_hot_path.gd) prints one JSON
object with the engine, the workload shape and, for every workload, the p50,
p95, p99, minimum, maximum and a canonical checksum. The snapshot workload
also measures an embedded control that keeps the previous per-byte copy, in the
same process, so the two candidates see the same machine state.

## Workloads

| Workload | What it measures | Shape |
| --- | --- | --- |
| `steady` | A whole session frame: local sample, confirmed remote samples, the ordered save and advance requests, the game's own save and the input view | 4 KiB game state, one local player, 400 frames, 15 samples |
| `rollback` | The same session with the remote inputs one window late, so every correction loads a snapshot and resimulates the whole prediction window | 8-frame window, 400 frames, 15 samples |
| `snapshot` | One snapshot write: the production writer against the previous per-byte control | 4 KiB payload, 400 writes, 15 samples |
| `codec` | One protocol input packet: encode plus decode, with every player's input and status | 1-byte inputs, 400 packets, 15 samples |

The session is configured exactly as a peer session: eight prediction frames,
no check distance, a nine-slot history, checksums enabled and one local player.
The game saves a 4 KiB state, restores it byte for byte and reads the frame
inputs, which is the shape of a real client's per-frame work.

Every workload accumulates a canonical checksum. The steady and rollback
checksums cover the applied input bytes and statuses of every simulated frame,
the snapshot checksum covers the written bytes and the codec checksum covers
the decoded payload and the packet size. The checksums are identical before and
after the change, so the faster path simulates exactly the same match.

## Results

All times are microseconds per iteration. The `steady`, `rollback` and `codec`
rows are per frame or per packet; the `snapshot` row is per 4 KiB write.

| Engine | Players | Steady p50 | Steady p95 | Rollback p50 | Snapshot p50 (control p50) | Codec p50 |
| --- | --- | --- | --- | --- | --- | --- |
| 4.7.2 | 2 | 92.6 → 32.2 | 103.2 → 44.4 | 33.2 → 29.8 | 59.0 → 2.8 (59.0) | 25.7 → 25.6 |
| 4.7.2 | 4 | 101.6 → 44.5 | 129.3 → 46.5 | 42.9 → 33.4 | 60.1 → 2.8 (60.7) | 36.3 → 29.7 |
| 4.7.2 | 8 | 132.3 → 68.2 | 147.4 → 78.6 | 44.6 → 40.6 | 58.8 → 2.8 (60.5) | 38.8 → 37.9 |
| 4.3 | 2 | 161.8 → 45.2 | 182.8 → 52.8 | 40.2 → 34.9 | 114.8 → 9.7 (116.3) | 29.4 → 30.4 |
| 4.3 | 4 | 170.7 → 61.8 | 178.4 → 78.7 | 44.4 → 37.9 | 114.1 → 10.2 (117.0) | 34.2 → 34.6 |
| 4.3 | 8 | 197.3 → 84.2 | 202.9 → 88.9 | 51.0 → 47.1 | 116.3 → 9.8 (115.0) | 44.9 → 45.9 |

The snapshot write is the dominant cost of the steady frame with a 4 KiB state:
it was about two thirds of the frame before the change. After the change the
steady frame costs about a third of its previous value for 2 and 4 players and
about half for 8 players, because the per-frame input view, the request
bookkeeping and the game's own read of the frame inputs are now the larger
share. The codec is unchanged, as expected: it never used a per-byte loop.

The rollback workload improves less, because a correction resimulates eight
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
microseconds for 2 and 4 players and about 68 to 84 microseconds for 8 players,
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
| `scripts/benchmark_session_hot_path.gd` | `51fdb77e62744dbace25e2f13e91dad6fdd477b87b4ec4dbef4c3e5898feab88` |
| `tests/unit/test_snapshot_history.gd` | `dd7295fd2abbeca968fec8915fd2bd6604f1e9c45216065401ded79491abe4a8` |

Matching benchmark checksums before and after the change:

| Players | Steady | Rollback | Snapshot | Codec |
| --- | --- | --- | --- | --- |
| 2 | 46680 | 314 | 7200 | 468000 |
| 4 | 134072 | 619 | 7200 | 576000 |
| 8 | 310584 | 1409 | 7200 | 792000 |
