# Measuring development feedback

| Loop | Target | Timed interval |
| --- | --- | --- |
| Linux-volume local edit | p95 under 1 second for each command | Invoke a focused regression or small changed suite after editing through its verified result |
| PR | p95 under 300 seconds ideal, under 420 seconds acceptable | Head ref update through the last required check on that head |
| Merge queue | p95 under 300 seconds ideal, under 420 seconds acceptable | Candidate ref creation through the last required check on that candidate |

Run `make test-focus SUITE=res://tests/unit/test_online_startup.gd` for a named suite. Add
`FILTER=<case substring>` for a single regression or `make test-changed` for the affected unit suites.
The broader local pre-push check is `make gate`. Shared changes can reach the whole inventory.
Use a Linux-volume checkout for the subsecond targets. The local report gives each command its own p95 and counts lease waits.

For a paired study, run this command in the checkout you want to measure with Godot 4.7.2 on PATH.
It creates temporary worktrees on the same filesystem, alternates which revision runs first and records timing, source digests and result digests for both runs in each JSONL row.

```sh
python3 scripts/measure_local_iteration.py --compare-revision ce384c3 --revision HEAD --count 100 --output .cache/scratch/paired.jsonl
```

The study alternates expected failures and passes in a shared addon, the online example and unit tests.
It verifies edited bytes, case identity, both fresh processes, both in-process repeats and the expected
assertion outcome. Cold samples clear runner timing history. Warm samples seed it. Both use the host's ordinary filesystem cache.

## Measured local edits

On a container-local Linux checkout, 100 alternating pairs compared `ce384c3` with `4370614`.
Each pair used the same edit, Godot 4.7.2 executable, case identities, result digest and timing-history condition.
Both revisions reproduced all 50 expected failures. Neither waited for a lease.

| Verified command | Edits | Control p95 | Candidate p95 |
| --- | ---: | ---: | ---: |
| Single case by suite and filter | 80 | 0.852 s | 0.740 s |
| Changed suite with eight cases | 20 | 1.892 s | 0.925 s |
| Both commands | 100 | 1.785 s | 0.840 s |

The first candidate edit took 0.535 s. With empty timing history the candidate p95 was 0.925 s,
and with seeded timing history it was 0.839 s. The slowest of the 100 edits took 0.938 s.
The selector checks the current files on every invocation. Source verification and engine hashing overlap.
On the host mount, a separate ten-edit candidate sample took 2.385 seconds at the median and 2.676 seconds at maximum.
The preceding ten-edit control took 4.923 seconds at the median and 8.171 seconds at maximum.

Two 100-edit runs used Godot 4.7.2 on the development host. Each included 50 intentional failures,
50 passing edits, 80 single-case commands and 20 eight-case changed-suite commands.

| Revision | Median | p95 | Maximum |
| --- | ---: | ---: | ---: |
| `025dfc9` | 3.78 s | 6.29 s | 10.01 s |
| `0144540` | 3.43 s | 5.97 s | 8.22 s |

On the second run, single-case p95 was 5.41 s and changed-suite p95 was 7.26 s. Neither run
waited for another host lease. A separate trial that overlapped full qualification waited over five
minutes for the lease and was interrupted. These distributions describe an available development host.
The first five paired edits on each revision matched the control's edited bytes, engine and result
digests. Their median time difference changed sign between runs, so these small pairs establish
workload equivalence and do not establish a consistent speedup.

A further 100-edit run on `ef16395` finished at p95 4.24 s on the same development host. During
a later period of high host I/O pressure, 14 of the first 23 edits on the host-mounted checkout took
at least 10 s without waiting for a host lease. Even 77 subsequent passes could not meet the
100-sample p95, so that trial stopped. Record the workspace filesystem along with host load.
On Docker Desktop a container volume avoids the host bind mount. Use **Dev Containers: Clone
Repository in Container Volume** and repeat the same study to compare both locations.
A paired study on `5aba6b7` alternated execution order over 100 edits with the same engine, commit,
changed bytes and result digests. The host mount produced median 3.39 s, p95 8.05 s and a maximum
of 11.74 s. The container-local Linux filesystem produced median 0.88 s, p95 2.05 s and a maximum
of 3.04 s. It finished first on all 100 pairs.
[VS Code disk performance guide](https://code.visualstudio.com/remote/advancedcontainers/improve-performance)

## Hosted baseline and comparison

The November 18–22, 2026 baseline uses repository activity and all five required check contexts.
143 completed PR heads took 627 seconds at p95. Another 46 heads were cancelled.
44 completed merge candidates took 823 seconds at p95. One more candidate lacked successful evidence for its skipped controls.
Both distributions include failed verdicts.
Successful merge candidates used a mean of 169.0 runner-minutes across the required workflows.
The [baseline](iteration-baseline.json) includes the sample counts and cost by change mix.

The first four PR revisions in the rollout trial completed in 231, 224, 229 and 236 seconds.
Together they used 54.07 runner-minutes against a matched baseline of 54.91. The first real merge
candidate passed all required checks in 353 s using 183.50 runner-minutes. Its Godot 4.3 positive
ownership part took 336 s, including 179 s in browser batches. The PR left the queue for further
tuning. [First merge-candidate qualification](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/45095685122)

With authenticated `gh`, collect one rollout window after the new Gate went live. Supply UTC timestamps
within the past month. Use a separate window for a change in workflow design or required checks.

```sh
python3 scripts/github/iteration_report.py --since "$ROLLOUT_UTC" \
  --baseline docs/reference/iteration-baseline.json --output .cache/tests/iteration.json
```

The report starts with queue ref creations and PR head revisions observed while each PR targeting main was open.
Opening, reopening or retargeting an open PR onto main starts a sample at its current revision. The report joins Actions jobs by event, head repository, ref and SHA.
Base repository activity cannot establish fork head history. An overlapping fork PR leaves an incomplete sample.
A candidate with zero workflow runs also remains incomplete.
It includes pickup, steps, upload, peak simultaneous runners, summed allocation, first failed step, and
elapsed time through a successful retry. Missing ref timestamps or required contexts leave an incomplete row.
Superseded heads are counted separately. A job step that emits the test failure before finishing provides
an upper bound on time to the first diagnostic. The nearest-rank p95 needs at least 40 completed heads
of each event. Runner cost is compared at the observed mix of event, tooling controls and outcome.
A missing baseline stratum leaves cost unverified. The accepted tolerance is 5%. The summary counts individual verdicts at or above 420 seconds, even before the window has 40 completed heads.

### November 23 partition trials

The five PR heads of #453 each selected all 142 unit suites. The first unknown input was
`experiments/gdextension/benchmark.py`. The required verdicts took 213–233 seconds. Together they
used 79.38 runner-minutes against 68.64 matched. The two merge candidates in the same window took
287 and 805 seconds. The latter spent 785 seconds in Godot 4.3 positive ownership part 2.

Five replays of that part on `ce384c3` took 136–210 seconds each. Native execution took 35–63 seconds
and browser execution took 46–86 seconds. The original took 153 and 282 seconds respectively.
Dependency installation took 107 seconds on the original and 16–29 seconds on replay.
From the last native log to the export log, artifact timestamps span about 78 seconds on the original
and 6–10 seconds on replay, including template preparation. Uploads took four seconds and one second respectively.
All five reproduced the original 217 records on both runtimes. Continue measuring runner variance.

On PR head `7392465`, three unit partitions used 574 runner-seconds, with the longest job taking
217 seconds. Four used 614 runner-seconds, with a longest job of 187 seconds. Both produced identical
results for all 869 cases. Applying the measured three-job cost to the five observed PRs gives
72.02 projected runner-minutes (4.9% above matched). A natural rollout window measures actual cost
and the complete verdict. The tracker requires 40 completed heads of each event under the same layout.
[Hosted trial and receipts](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/45115694355) ·
[Rollout tracker](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/451)

## Reproducing an experiment

Compare CI layouts at the same revision. Across local revisions, match the edits, engine, host capacity, cases and results. Keep cold and warm
observations separate. Compare at least five pairs and retain case identities, repeats, checksums and
failure-control results. Count scheduling hints only as estimates. Measure the verdict through job pickup
and artifact uploads before adopting a partition count. GitHub runner limits and timing-based scheduling
inform the experiments. [GitHub Actions limits](https://docs.github.com/en/actions/reference/limits) ·
[CircleCI timing-based splitting](https://circleci.com/docs/guides/optimize/parallelism-faster-jobs/)

The affected-test selector follows script and resource dependencies and widens to all suites when an
edge cannot be resolved. An independent checkout derives the selected case inventory and checks the
completed partition receipts. This uses the dependency-based selection studied at Google and preserves
a complete qualification run on the GitHub merge candidate. [Regression Test Selection at Scale](https://research.google/pubs/regression-test-selection-at-scale-4/) ·
[GitHub merge queues](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue)

On the 30 first-parent revisions ending at `e2bdaca`, replaying the old and new selectors against
each revision's own source reduced suite selections from 3,335 to 1,961. Full-inventory selections
fell from 23 to 11. The new selector retained the old selector's traceable resource dependencies
on every revision. Four full PR partitions also reproduced all 869 historical case records.

## What runs on a candidate

A PR runs the harness, affected unit partitions and, when tooling changes, the reference and oracle controls.
The merge-group Gate runs both controls once. It calls the full qualification workflow on the same SHA.
The required unit verdict uses the full minimum-engine result on the candidate. The Qualification summary
requires the controls and the complete matrix. A standalone qualification dispatch runs its own controls.

Per engine, the matrix balances whole-unit suites by recorded time, runs integration and determinism
separately, and distributes the upstream oracle launchers across four jobs. A common server build
supplies the verified executable to the transport jobs. Chromium ownership assigns the download
controls and expensive suites to five parts on Godot 4.3 and four on 4.7.2. Firefox retains four
parts per phase on each pin. Browser jobs share a verified Web-only subset of the upstream export
templates. An unknown upstream digest uses the full pinned archive. Nightly refreshes the per-engine
template and editor caches on main so future merge refs can restore them.
[GitHub cache scope](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching#restrictions-for-accessing-a-cache)
