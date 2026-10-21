# Reference Baseline job time baseline

Measured baseline for [issue 148](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/148).
The numbers come from the public run record, so any engineer can recompute
them without a local run:

```sh
gh run view 39374317270 --json jobs \
  --jq '.jobs[] | "\(.name)\t\(.startedAt)\t\(.completedAt)"'
```

## Per-job wall time on a warm cache key

Run `39374317270` (`main`, 2026-10-20, warm dependency and server-build
cache key). The summed job time is **67.0 minutes**; the target in issue 148
is below 66 minutes.

| Job | Wall time |
| --- | --- |
| SignalFish relay and Chromium WebRTC 4.3 online | 7m52s |
| Native and Chromium snapshot ownership | 7m41s |
| SignalFish relay and Chromium WebRTC 4.7.2 online | 7m11s |
| Godot 4.7.2 and Chromium suites | 6m33s |
| Godot 4.7.2 and Chromium oracles | 6m18s |
| Godot 4.3 and Chromium suites | 5m33s |
| SignalFish relay and Chromium WebRTC 4.3 direct | 4m49s |
| SignalFish relay and Chromium WebRTC 4.7.2 mixed | 4m45s |
| SignalFish relay and Chromium WebRTC 4.3 mixed | 4m55s |
| SignalFish relay and Chromium WebRTC 4.7.2 direct | 3m58s |
| Godot 4.3 and Chromium oracles | 4m37s |
| Pinned Rust reference | 2m23s |
| Reference negative controls | 0m23s |

Every job in the matrix runs; no gate is optional.

The table is the measured run as it stood. The duplicated exported web probe
has since been removed: `godot_smoke.py --web` now runs in the `suites` leg
only, once per pinned engine, so the next run measures a shorter `Godot ...
oracles` job. The `oracles` leg keeps the native engine probes because its
upstream trace comparison needs the pinned editor. These numbers are not
re-measured yet.

## What dominates each job

| Job family | Work that dominates the wall time |
| --- | --- |
| `... online` | Two independent exported Chromium pages play the shipped online example against a local relay: export, import, room setup, then the frames each room submits |
| `... direct` and `... mixed` | One exported Chromium page per peer pair, the WebRTC mesh handshake and the gameplay frames |
| `Native and Chromium snapshot ownership` | The ownership probe exports the project twice per engine and replays every recorded case in the browser |
| `Godot ... suites` and `... oracles` | The native suites in the suites leg and the upstream traces in the oracles leg, plus the exported representation and protocol probes that the suites leg runs once per engine |
| `Pinned Rust reference` | The pinned upstream build and its own test run |

The dominant step of the `... online` row comes from the measured per-step
durations in the `online-example.json` receipt. The online probe records the
elapsed time of every step it ran, including the browser sub-steps, so the
dominant step is read from the published receipt instead of from a local run.
The `Godot ...` row no longer repeats the exported probes, because that probe
now runs once per pinned engine and not once per leg.

No single job is slow enough to remove on its own; the cost is distributed
across the browser work. A reduction has to come from what each browser job
does - the exported page count, the room count, the frames submitted per room,
the export and import steps, or the wait between rendered browser turns.

## What a reduction must preserve

The same rooms, the same canonical prefix comparisons, the same confirmed
frontier, the same rollback and pressure budgets, the same negative controls
and the same source-bound receipts. The matrix keeps both pinned engines and
the direct, mixed and online browser labels.

A later change compares against this table instead of against a single run.
The reduction itself is still open; issue 148 tracks it.
