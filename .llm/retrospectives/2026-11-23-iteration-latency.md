# Measuring and shortening validation

## Work under review

Local source staging, PR test selection and the merge-candidate matrix changed together.
The goals were a verified focused result in 10 seconds and a required hosted verdict in five minutes at p95.

## Findings and actions

- The local edit study on revision `025dfc9` produced p50 3.78 s and p95 6.29 s across
  100 edits, including 50 expected failures. Timing history was empty for half the edits.
  An overlapping qualification can consume the host lease for minutes. The repeatable study checks both fresh
  processes and their edited bytes. Its timings include lease waits. Record host load when repeating it.
- `make test-llm` took a median 35.27 s serial and 12.68 s with four workers in five paired runs.
  The parallel runner retains unittest discovery for package hooks and emits failed-file diagnostics as workers finish.
- Agreement between repeated runs cannot detect a case omitted from both. Full unit shards check expected
  inventory in both processes. The PR verdict derives expected cases from the checkout independently of the worker.
  A fake engine with a missing case and a seeded failure in a real spectator suite exercise these paths.
- Listing many suites in one Godot 4.3 process produced teardown errors. Listing suites separately preserved a clean exit.
  Four partitions matched all 869 historical case records, including their state bytes and assertion outcomes.
- A real PR head reported all five required checks in 231 s using 12.72 runner-minutes.
  [PR Gate](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/45091081449)
- A hosted trial passed 56 jobs in 333 s with 175.7 runner-minutes. Godot 4.3 Chromium ownership took up
  to 322 s in one job. Workload estimates alone understated that path. The jobs retain suite and page timings
  for the next partition adjustment. [Hosted trial](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/45090341692)
- Measuring only Actions runs can miss a required workflow that never starts. The
  [report](../../scripts/github/iteration_report.py) enumerates eligible revisions and then joins their required checks.
- The first protected merge candidate passed all checks in 353 s and used 183.5 runner-minutes.
  Replaying its slow ownership partition on four cores with two isolated Chromium processes
  reduced browser time from 114 s to 59 s. All 152 ordered records matched across both repeats.
  Transport jobs now overlap verified downloads with setup and balance measured page waves.
  [First merge candidate](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/actions/runs/45095685122)
- Alternating 100 matched edit pairs on two filesystems gave p95 8.05 s on the host mount and
  2.05 s on container-local storage. Both filesystems reported the same results for every pair.

## Prune ledger

The job guide and test runner guide now describe the measured partitions and artifact verification.
The [measurement guide](../../docs/reference/iteration.md) owns the clocks, sampling and cost comparison.

## Outcome

findings-acted
