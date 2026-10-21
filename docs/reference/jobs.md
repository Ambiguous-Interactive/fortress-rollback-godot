# Reference Baseline job baseline

Every Reference Baseline job spends wall time on the same warm cache key. This
file records that per-job time so a later change is compared against a table
instead of against a single run.

## Measured baseline

Source: run `39539697986` of the `Reference Baseline` workflow on `main`, the
squash commit `20098dbc16cc31084a667c8aaacbfbe6c2974b68`, 2026-10-21. The run
used the warm `reference-signalfish-server-v1` cache key, so the pinned Rust
crates, the pinned engine archives, the export templates and the shared relay
server build tree were already restored.

| Job | Wall time |
| --- | --- |
| Reference negative controls | 1m20s |
| Pinned Rust reference | 2m45s |
| SignalFish relay and Chromium WebRTC 4.3 direct | 3m36s |
| SignalFish relay and Chromium WebRTC 4.7.2 direct | 5m07s |
| SignalFish relay and Chromium WebRTC 4.3 mixed | 5m13s |
| Godot 4.7.2 and Chromium suites | 5m35s |
| Godot 4.3 and Chromium suites | 5m56s |
| Godot 4.3 and Chromium oracles | 6m01s |
| Godot 4.7.2 and Chromium oracles | 6m08s |
| SignalFish relay and Chromium WebRTC 4.3 online | 6m22s |
| SignalFish relay and Chromium WebRTC 4.7.2 online | 6m22s |
| SignalFish relay and Chromium WebRTC 4.7.2 mixed | 6m51s |
| Native and Chromium snapshot ownership | 8m04s |
| **Summed job time** | **69m20s** |

The ten browser jobs and the ownership job carry 65m15s of the 69m20s. The
three jobs without a browser carry 4m05s.

Reproduce the table from the public run records:

```sh
gh run view 39539697986 --json jobs \
  --jq '.jobs[] | "\(.name)\t\(.startedAt)\t\(.completedAt)"'
```

The same command on any other warm run gives the same table, and the spread
between identical warm runs is larger than the gap to the 66-minute target.

## Where the browser time goes

| Job | Browser work |
| --- | --- |
| SignalFish relay and Chromium WebRTC `direct` | One web export, then the `clean`, `faults`, `corrupt`, `default` and `mixed-disabled` labels: eleven rooms in total |
| SignalFish relay and Chromium WebRTC `mixed` | One web export, then the `mixed`, `mixed-default` and `mixed-close` labels: nine rooms in total |
| SignalFish relay and Chromium WebRTC `online` | The shipped online example in two browsers, then the native relay and late-event controls |
| Godot `suites` | The native suites, then the exported representation and protocol probes |
| Godot `oracles` | No browser work; the five actual upstream oracle launchers |
| Native and Chromium snapshot ownership | The native and exported ownership probes for both engines |

One room launches one exported page per peer, completes a real handshake, submits
40 frames per peer and compares 38 canonical prefixes per peer. The room count
and the page count therefore set the browser time; the export and the engine
bootstrap are already restored from the cache and are not the dominant part.

## Scope

This table records the measured baseline and names the dominant browser work.
It does not shorten a browser job. The reduction of the room and page work
without weakening a gate is tracked in the follow-up issue linked from
[#148](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/148).
