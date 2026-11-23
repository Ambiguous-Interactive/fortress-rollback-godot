# Verified subsecond edits

## Work under review

Development feedback covers the selected regression or small affected suite from command invocation through its verified result.
The hosted study measures required PR and merge-queue verdicts separately.

## Findings and actions

- Running the same eight cases by name took 0.757–0.894 seconds on Linux storage.
  Selecting their suite took over one additional second. Numeric fixtures accounted for most literal scans.
  The optimized parser matched all 324 source inputs and 20,000 generated quote and escape cases.
  On 100 alternating real edit pairs, the changed-suite p95 fell from 1.892 to 0.925 seconds.
  Both processes reproduced the expected result in every pair.
- Five hosted replays of the 785-second ownership partition took 136–210 seconds on the same source SHA.
  Compare identical native and browser records before changing partitions. The
  [measurement guide](../../docs/reference/iteration.md) records the runner cost, export interval and case comparisons.
- Fresh review found that concurrent verification could change the reported error when two inputs changed,
  and cancellation could wait on a digest. The launcher retains error priority, checks for cancellation
  between digest blocks and exercises simultaneous source and engine changes in the receipt tests.

## Prune ledger

The measurement guide replaces the ten-second local target. The existing
[infrastructure guide](../skills/testing/references/infrastructure.md) now describes how to isolate discovery cost and compare partition layouts.

## Outcome

Findings acted on. The hosted rollout needs 40 natural heads per event to measure p95.
