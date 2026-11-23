# Measuring development feedback

| Loop | Target | Timed interval |
| --- | --- | --- |
| Local focused edit | p95 under 10 seconds | Invoke the focused command after editing through its verified result |
| PR | p95 under 300 seconds | Head ref update through the last required check on that head |
| Merge queue | p95 under 300 seconds | Candidate ref creation through the last required check on that candidate |

Run `make test-focus SUITE=res://tests/unit/test_online_startup.gd` for a named suite. Add
`FILTER=<case substring>` for a single regression or `make test-changed` for the affected unit suites.
The broader local pre-push check is `make gate`.

For a repeatable edit study, the following commands create private, temporary Git worktrees.
They require a Godot 4.7.2 executable on PATH and each writes a new JSONL file.

```sh
python3 scripts/measure_local_iteration.py --revision e2bdaca --count 5 --output .cache/scratch/control.jsonl
python3 scripts/measure_local_iteration.py --revision HEAD --control .cache/scratch/control.jsonl --output .cache/scratch/candidate.jsonl
```

The study alternates expected failures and passes in a shared addon, the online example and unit tests.
It verifies edited bytes, case identity, both fresh processes, both in-process repeats and the expected
assertion outcome. Cold samples clear runner timing history. Warm samples seed it. Both use the host's ordinary filesystem cache.

## Measured local edits

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

## Hosted baseline and comparison

The November 18–22, 2026 baseline uses repository activity and all five required check contexts.
143 completed PR heads took 627 seconds at p95. Another 46 heads were cancelled.
44 completed merge candidates took 823 seconds at p95. One more candidate lacked successful evidence for its skipped controls.
Both distributions include failed verdicts.
Successful merge candidates used a mean of 169.0 runner-minutes across the required workflows.
The [baseline](iteration-baseline.json) includes the sample counts and cost by change mix.

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
A missing baseline stratum leaves cost unverified. The accepted tolerance is 5%.

## Reproducing an experiment

Measure the same revision, engine, host capacity and test inventory on both sides. Keep cold and warm
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
controls and expensive suites to parts by estimated cost. Firefox retains its nightly plan.
