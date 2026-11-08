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

## Negative-control job deadline

The negative-control job has a 15-minute outer deadline for setup, both complete
Python suites and cleanup. Each subprocess keeps its existing watchdog.

Run [40586724579](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/40586724579)
exceeded the former 10-minute deadline on 2026-10-27. The reference suite passed
all 222 tests with nine skips in 559.091 seconds. The oracle suite then passed
all 95 tests in 45.952 seconds before the runner reported cancellation.
Their combined execution took 605.043 seconds before setup and cleanup.

The same job passed in 9m51s in run
[40581746832](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/40581746832),
leaving only nine seconds of the former budget. The 15-minute deadline adds
about five minutes for runtime variation and preparation. Both suite commands,
case inventories, assertions and inner watchdogs remain unchanged.

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

## Native-only oracle setup

The `oracles` legs run native Godot smoke, Rust/Godot comparisons and Java model
checks. Node and Playwright setup now run only on the `suites` legs, which own
the exported Chromium probes. All native, differential and model commands remain.

In main run [41496019984](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/41496019984),
the unused Node/browser setup took 5+16 seconds for 4.3 and 5+14 seconds for
4.7.2: 40 seconds of summed setup work. This measures removed work, not an
observed reduction in overall workflow time. The broader browser-room savings
and consecutive warm-run target remain open in #164.


## Current ownership wall-time partition

Run [41394927982](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/41394927982)
qualified main `1e4f96f161430e7c400ea4764c325f4e23e589b0` on 2026-11-02.
Its 22 jobs summed to 211m58s and the workflow took 24m55s. This expanded
inventory is not comparable with the older 69m20s total above.

| Chromium ownership pin | Job time | Verification step |
| --- | --- | --- |
| 4.7.2 | 24m52s | 23m55s |
| 4.3 | 18m23s | 17m37s |

The Chromium ownership matrix now uses the existing suite parts 1 and 2 on
each engine pin. Each part still runs native and exported Web execution,
negative and positive controls, and the unchanged repetitions. Their exact
union contains every declared suite/case; only the alias control is repeated.
Distinct job and artifact names preserve each part's evidence. The spectator
origin check stays once on Chromium 4.3 part 1.

This targets wall time by running smaller inventories concurrently. It repeats
setup and export work, so summed runner time can increase.

Main run [41530525492](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/41530525492)
qualified the partitioned inventory at `ab95f187a1e355da523c5e9a71172a02b627c655`.
Chromium 4.3 parts 1/2 took 16m16s/9m46s; 4.7.2 parts 1/2 took 14m32s/7m32s.
The longest ownership job was 16m16s, compared with 24m52s in the earlier run.
These are observed job times across changing inventories, not a controlled speedup measurement.
All 24 jobs summed to 233m58s. The expanded inventory is not comparable with the original 66-minute target.
Reducing total work without removing coverage remains tracked in #148 and #164.

## Measured negative control: stat-keyed digest reuse is unsound

The Reference negative-control suite was profiled per module on a warm
arm64 devcontainer (session 158, PR #332 investigation). One module,
`test_ownership_probes`, took 473s of the 520s serial suite. cProfile on its
slowest case attributed most of that to 501,959 `hashlib.file_digest` calls
from `tool_inventory` (2,517 calls) and `signalfish_probe.inventory`
(1,650 calls): every native/browser boundary re-walks and re-hashes the
staged project and the Playwright `node_modules` trees.

A digest memo keyed by each file's stat identity was implemented and
measured at 2.2x (`make test-reference` 8m39s to 3m53s; the slowest cases
79.8s to 14.4s), then removed because it is not sound for this evidence
contract. Measured on the devcontainer filesystem:

- `st_mtime_ns` and `st_ctime_ns` are jiffy-quantized (about 1ms), so a
  same-size rewrite within the same jiffy keeps the previous key.
- Deleting and recreating a file immediately reuses the inode, so `st_ino`
  does not distinguish re-creation either.

Two existing controls do exactly that and failed with the memo
(`test_signalfish_webrtc_probe`'s same-size editor-metadata rewrite failed
6 of 8 isolated runs; `test_fetch`'s same-size `prepare_zip` repair control
failed under load). Serving a stale digest would let a receipt publish
boundary evidence that no re-read supports. Boundary verification must
therefore read every byte at every boundary; the per-boundary hashing cost
of the negative-control suite and the real ownership jobs is contractual.

The `os.scandir` enumeration change from the same investigation is kept:
it lists the identical entry set as `sorted(root.rglob('*'))` without
following symlinks, and it fails closed with `OSError` where `rglob`
silently skipped an unreadable directory, so repeated inventories cannot
report a vacuously incomplete membership as evidence.

Remaining reduction levers are gate changes or runner changes: removing a
redundant boundary check, or running browser rooms concurrently. The
process-parallel negative-control runner landed separately: each
`test_*.py` file now executes in its own fresh interpreter under a bounded
worker pool with fail-closed aggregation (`scripts/parallel_unittests.py`,
wired into `make test-reference`), so per-file cases, seeds, receipts and
skips are unchanged while no file waits behind another. The ownership
rejection suite was split along its existing concern boundaries into
`test_ownership_phase_selection`, `test_ownership_full_inventories`,
`test_ownership_mutation_identity` and `test_ownership_rejection_diagnosis`
(51 methods preserved by name; the shared rejected-run fixture moved to
`ownership_rejection_fixture.py`). Measured on this devcontainer, warm and
otherwise idle: sequential `unittest discover` 8m49.0s (299 cases, 10
skips); parallel runner 3m21.0s, 36 files, 0 failed, 0 missing. The
critical path is now the slowest single file (about 202s), so further
wall reduction requires gate changes, not scheduling.

## Native-wave overlap in the ownership jobs

The ownership witness ran its native suites one engine process at a time: 49
suites per phase per part, twice per Chromium job and once per Firefox job.
The per-suite shape is unchanged — one fresh engine process per suite, both
in-process repetitions and the 180-second watchdog — but the wave now runs
those processes concurrently (bounded by host capacity: four workers on an
idle host, serial when another owner holds it) and joins every suite before
the run continues. Browser pages stay serial because they need a responsive
host. The staged project and the editor are verified once before the wave and
after every suite, so a mutation during any suite is still caught; the
rejection names the first failing suite in suite order, and every suite's log
survives.

Measured on this devcontainer, warm and otherwise idle, the native-only 4.3
part-1 witness (both phases, no browser) fell from 9m41.0s serial to 2m38.4s
under the wave with identical receipts (passed, same inventory, same sources).
The per-suite repeated-inventory cost also dropped: the boundary inventory now
scans each directory once with cached entry types instead of re-statting every
member through pathlib, with identical membership, symlink rejection and
fail-closed unreadable-directory behavior (`test_signalfish_probe` covers all
three).

Runner evidence for the wave, from public run records. Before: main run
[42457452576](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/42457452576)
(`25edd524d77b0099c114cf932d52b9cc1dc490f0f`) took 18m04s of wall time and its
jobs summed to 235m56s; its longest job was the Chromium 4.3 part-1 ownership
job at 18m00s. After: the branch run
[42510871354](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/42510871354)
of the same inventory took 13m54s of wall time, 215m21s summed, all 24 jobs
green; the four Chromium ownership jobs took 10m59s/11m06s (4.3 parts 1/2) and
12m04s/11m14s (4.7.2 parts 1/2), against 18m00s/13m48s and 14m41s/11m29s
before. The Firefox ownership jobs moved within their observed run-to-run
variance (for example 4.7.2 positive part 1 fell 12m35s → 9m10s while 4.3
positive part 1 rose 11m31s → 13m53s), and the new wall critical path is the
Firefox 4.3 positive part-1 job at 13m53s. These are single-run comparisons of
changing trees, not a noise-controlled per-job benchmark; the controlled
causal measurement is the same-tree local witness above.

## Parallel oracle launchers and per-phase Chromium ownership jobs

The oracles leg ran its six upstream comparison launchers strictly serially:
the "Compare actual upstream and Godot traces" step took 592s of the 677s
Godot 4.3 oracles job in run 42521796675. `scripts/oracle/parallel_launchers.py`
now runs them in bounded parallel subprocesses (longest first, default
`min(4, cpus)` workers, fail-closed aggregation, join-all, per-launcher logs).
The launcher receipts are unchanged: each launcher keeps its own interpreter,
output directory and receipt, and the shared pinned cargo target stays correct
under cargo's own build lock. The runner provisions the pinned Rust toolchain
once before the pool, because six concurrent rustup installations on a cold
cache raced on the same partial downloads (first branch run 42529928519).

The Chromium ownership jobs each ran `--phase both` (two full phases serially
in one job), which made them the wall critical path. The matrix now declares
negative and positive jobs per version and suite part, matching the Firefox
shape: 12 ownership jobs become 16 and the workflow 24 becomes 28. This
repeats per-job setup (~32s per job) while cutting the per-job verification.

Branch run [42530683579](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/42530683579)
(head `b16e5a8`, all 28 checks green) against the 24-job main run 42521796675
(`081c7ad`, all 24 jobs green):

| Job group | Before | After |
| --- | --- | --- |
| Godot 4.3 oracles | 11m17s | 5m36s |
| Godot 4.7.2 oracles | 10m47s | 5m25s |
| Chromium ownership 4.3 part 1 | 14m03s | 7m31s / 6m06s (positive/negative) |
| Chromium ownership 4.3 part 2 | 11m39s | 5m29s / 4m12s (positive/negative) |
| Chromium ownership 4.7.2 part 1 | 11m59s | 4m49s / 6m13s (positive/negative) |
| Chromium ownership 4.7.2 part 2 | 9m29s | 5m52s / 5m43s (positive/negative) |
| Workflow wall | 14m03s | 13m01s |
| Summed job time | 207m48s | ~198m |

The oracles step fell to about 250s because the four shorter launchers now
overlap the p2p launcher instead of running before it; the local controlled
measurement (same tree, warm target, idle) is 445.7s serial → 278.0s parallel.
The wall gain is smaller than the ownership job gain because the Firefox
ownership jobs moved within their documented run-to-run variance (4.3 positive
part 2 took 12m39s here against 10m20s in the earlier main run, and became the
critical path). These are single-run comparisons of changing trees, not a
noise-controlled benchmark; the per-job table remains the comparison point.

## Current 24-job baseline and the parallel oracle suite

Run [42443776980](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/42443776980)
qualified main `5118de2405a2c440ff1db661319ac90f84025f17` on 2026-11-08: all 24
jobs passed, the workflow took 18m04s of wall time and the jobs summed to
235m56s. Reproduce with:

```sh
gh api repos/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/42443776980/jobs --paginate \
  --jq '.jobs[] | [.name, .started_at, .completed_at] | @tsv'
```

Job times, longest first:

| Job | Wall time |
| --- | --- |
| Native and Chromium snapshot ownership 4.3 part 1 | 18m00s |
| Native and Chromium snapshot ownership 4.7.2 part 1 | 14m41s |
| Native and Chromium snapshot ownership 4.3 part 2 | 13m48s |
| Native and Firefox snapshot ownership 4.7.2 positive part 1 | 12m35s |
| Native and Firefox snapshot ownership 4.7.2 negative part 2 | 12m08s |
| Native and Firefox snapshot ownership 4.3 negative part 1 | 12m02s |
| Native and Firefox snapshot ownership 4.3 positive part 1 | 11m31s |
| Native and Chromium snapshot ownership 4.7.2 part 2 | 11m29s |
| Godot 4.3 and Chromium oracles | 11m11s |
| Native and Firefox snapshot ownership 4.3 positive part 2 | 11m07s |
| Native and Firefox snapshot ownership 4.3 negative part 2 | 10m40s |
| Native and Firefox snapshot ownership 4.7.2 positive part 2 | 10m24s |
| Native and Firefox snapshot ownership 4.7.2 negative part 1 | 10m01s |
| Godot 4.7.2 and Chromium suites | 9m44s |
| SignalFish relay and Chromium WebRTC 4.3 online | 9m43s |
| SignalFish relay and Chromium WebRTC 4.7.2 online | 9m15s |
| Godot 4.3 and Chromium suites | 7m56s |
| Godot 4.7.2 and Chromium oracles | 7m38s |
| SignalFish relay and Chromium WebRTC 4.3 direct | 6m39s |
| Reference negative controls | 6m39s |
| SignalFish relay and Chromium WebRTC 4.7.2 mixed | 6m00s |
| SignalFish relay and Chromium WebRTC 4.7.2 direct | 5m33s |
| SignalFish relay and Chromium WebRTC 4.3 mixed | 5m15s |
| Pinned Rust reference | 1m57s |

The wall-time critical path is no longer a browser room job: it is the
ownership 4.3 part 1 verification step ("Verify integer encoding, snapshot
ownership and byte sessions", 17m12s of its 18m00s). The twelve ownership
jobs hold twelve of the thirteen longest positions; only the Godot 4.3
oracles job (11m11s, ninth) interrupts the run. The longest SignalFish
browser job (4.3 online, 9m43s) sits in the middle of the pack. The original
66-minute summed target predates this expanded 24-job inventory and is no
longer comparable with it.

The negative-controls job shows the landed scheduling levers. #333's
process-parallel runner took the `make test-reference` step from 10m34s (run
42432613366, 01:04:19Z–01:14:53Z) to 5m12s (this run, 03:41:42Z–03:46:54Z) on
the identical 299-case inventory; the whole job fell from 11m49s to 6m39s.
Within the same
job, `make test-oracle` was still one serial `unittest discover` process (its
step took 1m21s in this run). It
now uses the same parallel runner. Local measurement on this devcontainer,
warm and otherwise idle: 16 files, 120 cases, serial wall 63.0s, parallel
wall 41.6s (summed process time 74.2s; the critical path is `test_replay.py`
at 41.6s). Flipping it exposed a real fragility first: `make test-oracle`
passed single-process only because `test_engine.py` alphabetically imports
before the other files and mutates `sys.path` as a side effect, which let
their transitive `scripts/reference` imports resolve. `handshake_formal.py`
now inserts that path itself, so every oracle test file is import-order
independent and per-file subprocess isolation is sound.
