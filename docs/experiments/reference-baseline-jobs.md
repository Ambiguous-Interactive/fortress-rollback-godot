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

## Warm runs of the recent main line

The spread between warm runs of the recent main line is wider than the
remaining gap to the target, so one run is not a baseline. The table lists the
last eight `main` runs with the commit each one ran. They are eight different
commits, so the spread mixes machine noise with the tree changes between them.

| Run | Commit | Cache | Summed job time |
| --- | --- | --- | --- |
| 39527781430 | 7ca07ec | warm | 68.2 min |
| 39514898835 | cc1ae3a | warm | 68.2 min |
| 39492851106 | 33bfa1c | warm | 70.4 min |
| 39477990792 | 508ac91 | warm | 71.7 min |
| 39383559398 | 86a5b99 | warm | 64.5 min |
| 39374317270 | 0502dd5 | warm | 67.0 min |
| 39372426632 | 22af4ee | warm | 73.2 min |
| 39355664025 | 39d20ea | cold | 76.1 min |

The warm runs measure 64.5 to 73.2 minutes. A later change compares against
this spread, not against the fastest or the slowest run.

The table is recomputed from the public run records:

```sh
for run in 39527781430 39514898835 39492851106 39477990792 \
           39383559398 39374317270 39372426632 39355664025; do
  gh run view "$run" --json jobs --jq '[.jobs[] |
    ((.completedAt | fromdate) - (.startedAt | fromdate))] | add / 60'
done
```

## What dominates each job

| Job family | Work that dominates the wall time |
| --- | --- |
| `... online` | The five-room browser flow of the online probe: 90.8 s of the 141.9 s of measured probe steps, from the `online-example.json` receipt |
| `... direct` and `... mixed` | One exported Chromium page per peer pair, the WebRTC mesh handshake and the gameplay frames |
| `Native and Chromium snapshot ownership` | The ownership probe exports the project twice per engine and replays every recorded case in the browser |
| `Godot ... suites` and `... oracles` | The native suites in the suites leg and the upstream traces in the oracles leg, plus the exported representation and protocol probes that the suites leg runs once per engine |
| `Pinned Rust reference` | The pinned upstream build and its own test run |

The browser jobs carry 55.3 of the 68.2 minutes of run `39527781430`, or 81
percent. The step records of that run name the dominant work:

| Step family | Measured time | Source |
| --- | --- | --- |
| `Verify real browser WebRTC on the pinned engine` | 18.1 min over four jobs | the job records of run `39527781430` |
| `Verify integer encoding, snapshot ownership and byte sessions` | 4.8 min | the ownership job record and the `ownership.json` receipt |
| `Play the shipped online example in two independent browsers` | 2.3 min | the online job record |
| `Verify native relay and late-event controls` | 3.2 to 3.9 min | the online job record |
| `Verify runner failure controls and fresh-process suites` | 4.7 to 5.9 min | the suites job record |

Inside the browser work, the measured label times are 82 to 114 s for each of
the three mixed-path labels, 74 to 85 s for each direct-path label, 285 s for
the four ownership rounds and 91 s for the online browser flow. Each mixed or
direct label runs three rooms, one for two, four and eight peers, and each
room submits 40 frames per peer. The ownership rounds take 65 to 78 s each and
export the project once per round. The receipts that carry these numbers are
`signalfish-live-reference-results-4.7.2-mixed/signalfish-webrtc/signalfish-webrtc.json`,
`signalfish-live-reference-results-4.7.2-direct/signalfish-webrtc/signalfish-webrtc.json`,
`ownership-reference-results/ownership.json` and
`signalfish-live-reference-results-4.7.2-online/online-example/online-example.json`
of run `39527781430`.

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
