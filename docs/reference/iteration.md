# Measuring development feedback

| Loop | Target | Timed interval |
| --- | --- | --- |
| Local focused edit | p95 under 10 seconds | Invoke the focused command after editing through its verified result |
| PR | p95 under 300 seconds | Head ref update through the last required check on that head |
| Merge queue | p95 under 300 seconds | Candidate ref creation through the last required check on that candidate |

Run `make test-focus SUITE=res://tests/unit/test_online_startup.gd` for a named suite. Add
`FILTER=<case substring>` for a single regression or `make test-changed` for the affected unit suites.
The broader local pre-push check is `make gate`.

## Hosted baseline and comparison

The November 18–22, 2026 baseline uses repository activity and all five required check contexts.
143 completed PR heads took 627 seconds at p95. Another 46 heads were cancelled.
45 completed merge candidates took 825 seconds at p95. These distributions include failed verdicts.
Successful merge candidates used a mean of 169.0 runner-minutes across the required workflows.
The [baseline](iteration-baseline.json) includes the sample counts and cost by change mix.

With authenticated `gh`, collect one rollout window after the new Gate went live. Supply UTC timestamps
within the past month. Use a separate window for a change in workflow design or required checks.

```sh
python3 scripts/github/iteration_report.py --since "$ROLLOUT_UTC" \
  --baseline docs/reference/iteration-baseline.json --output .cache/tests/iteration.json
```

The report joins Actions jobs across attempts and workflows to the exact branch, SHA, and ref activity.
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
