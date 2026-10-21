# Reference Baseline job time baseline

Measured baseline for [issue 148](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/148).
The numbers come from the public run record, so any engineer can recompute
them without a local run:

```sh
gh run view 39527781430 --json jobs \
  --jq '.jobs[] | "\(.name)\t\(.startedAt)\t\(.completedAt)"'
```

## Per-job wall time on a warm cache key

Run `39527781430` (`main`, 2026-10-21, warm dependency and server-build
cache key). The summed job time is **68.2 minutes**; the target in issue 148
is below 66 minutes. The preceding pull request run `39526908602` of the same
tree sums to **71.8 minutes**, so the run-to-run spread is wider than the
remaining gap.

| Job | Wall time |
| --- | --- |
| SignalFish relay and Chromium WebRTC 4.7.2 online | 7m33s |
| Godot 4.7.2 and Chromium suites | 7m06s |
| SignalFish relay and Chromium WebRTC 4.7.2 mixed | 6m53s |
| SignalFish relay and Chromium WebRTC 4.3 mixed | 6m23s |
| SignalFish relay and Chromium WebRTC 4.3 online | 6m04s |
| Godot 4.3 and Chromium suites | 5m47s |
| Native and Chromium snapshot ownership | 5m33s |
| SignalFish relay and Chromium WebRTC 4.7.2 direct | 5m10s |
| Godot 4.3 and Chromium oracles | 5m08s |
| Godot 4.7.2 and Chromium oracles | 5m01s |
| SignalFish relay and Chromium WebRTC 4.3 direct | 4m49s |
| Pinned Rust reference | 2m29s |
| Reference negative controls | 0m18s |

Every job in the matrix runs; no gate is optional.

The duplicated exported web probe is gone: `godot_smoke.py --web` runs in the
`suites` leg only, once per pinned engine. The `oracles` leg keeps the native
engine probes because its upstream trace comparison needs the pinned editor.
The four `Godot ...` jobs sum to 23.0 minutes of the 68.2 minutes.

## What dominates each job

| Job family | Work that dominates the wall time |
| --- | --- |
| `... online` | The five-room browser flow of the online probe: 90.8 s of the 141.9 s of measured probe steps, from the `online-example.json` receipt |
| `... direct` and `... mixed` | One exported Chromium page per peer pair, the WebRTC mesh handshake and the gameplay frames |
| `Native and Chromium snapshot ownership` | The ownership probe exports the project twice per engine and replays every recorded case in the browser |
| `Godot ... suites` and `... oracles` | The native suites in the suites leg and the upstream traces in the oracles leg, plus the exported representation and protocol probes that the suites leg runs once per engine |
| `Pinned Rust reference` | The pinned upstream build and its own test run |

The dominant step of the `... online` row comes from the measured per-step
durations in the `online-example.json` receipt of run `39527781430`: the
browser flow is 90.8 s, the corrupt control 16.2 s, the diagnostic viewer
7.6 s, the replay playback 7.6 s, the editor imports 4.7 s and 3.1 s, the
exports 3.6 s and 3.4 s, and the remaining steps are below one second each.
The online probe records the elapsed time of every step it ran, including the
browser sub-steps, so the dominant step is read from the published receipt
instead of from a local run. The `Godot ...` row no longer repeats the exported
probes, because that probe now runs once per pinned engine and not once per
leg.

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
