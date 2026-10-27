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

## Ownership job deadline

The ownership matrix has a 45-minute job deadline. This includes tool and operating
system preparation, native execution, browser execution and teardown. Case watchdogs,
partition inventories, repetitions and negative controls retain their own bounds.

Main run [40562144174](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/40562144174)
cancelled its Godot 4.3 Firefox positive part 1 job at the former 30-minute limit.
The job started at 18:40:27 UTC on 2026-10-27; verification could only start at
18:51:28. The same verification step passed in 20m14s in candidate run
[40556289538](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/40556289538),
whose browser/OS preparation took 31 seconds. Combining the observed main startup
with the passing verification duration needs 31m15s before final cleanup.
The wider job budget preserves the full workload and permits that measured cold
preparation without cancelling a valid verification run.

## Ubuntu package mirror selection

The hosted runner uses `mirror+file:/etc/apt/apt-mirrors.txt`; its
[provisioning script](https://github.com/actions/runner-images/blob/main/images/ubuntu/scripts/build/configure-apt-sources.sh)
gives the Azure HTTP mirror priority over the configured Ubuntu HTTPS alternatives.
APT's [mirror transport](https://manpages.ubuntu.com/manpages/noble/man1/apt-transport-mirror.1.html)
uses those priorities and fails over after acquisition errors.

Run [40571093291](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/40571093291)
later cancelled its Godot 4.7.2 Firefox negative part 2 job at 45 minutes while
APT still retried Azure repository indexes. Verification never started.
The earlier run fetched only 17.7 MB in 9m35s at 30.8 kB/s from that mirror.

Every reference job that installs Ubuntu packages now prepares the existing
mirror list before its first APT operation. Preparation removes only the Azure
entry, retains the configured HTTPS archive/security alternatives, and leaves
source suites, components and `Signed-By` settings unchanged. It refuses missing
references or alternatives before editing and preserves the mirror file mode.
Package signature and checksum authentication remain enabled.

## Measured baseline scope

This table records the measured baseline and names the dominant browser work.
It does not shorten a browser job. The reduction of the room and page work
without weakening a gate is tracked in the follow-up issue linked from
[#148](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/148).
