# Relay checkpoints and unit process counts

| Finding | Evidence | Durable action |
| --- | --- | --- |
| Wall time includes startup, loading and host contention. It can misclassify small suites. | The self-suite execute control took 0.681 seconds median wall and 0.135 seconds median CPU when quiet. With 15 contenders pinned to the same CPU, one execute took 4.332 seconds wall. Median CPU stayed at 0.162 seconds. The legacy runner stores the slower repetition. | [Infrastructure evidence](../skills/testing/references/infrastructure.md#faster-local-iteration) now describes separate sources for shard boundaries and launch priority. It replaces the instruction that the local timing cache sets both. |
| The witness can lose every final RPC while pages are still emitting errors. | The three-CPU Godot 4.7.2 Firefox relay room received eight warmup receipts through frame 12. Every page emitted the hold-cap error. The eight final reads timed out. The checkpoint control failed with missing arm and cap records before the repair. | [Browser integration](../skills/testing/references/browser-integration.md) now records the arm, readiness and first cap hit. The page still uses the original stall predicate, FIFO, deadline and cap. |
| A native inbox acceptance precedes protocol dispatch. | The pinned Fortress protocol refreshes its receive clock when dispatch accepts traffic. A native quality reply echoes that report's timestamp. The correlation control failed with `6 !== undefined` when an incomplete same-token report could explain the echo. The repaired control also rejects a resurfaced token after eviction. | The [browser guide](../../docs/experiments/upstream-binding.md#playable-web-rooms) names all three times and preserves the distinction between one proved reply and the last deadline refresh. A single per-link watermark keeps the ambiguity check bounded. |
| A history publication can arrive while its controller RPC stalls. | The three-CPU Firefox relay rooms on both Godot pins each published eight 40-frame captures. The polling path returned none. The regression reported `matching history publication did not settle the request` when dispatch never returned. | The [browser integration rules](../skills/testing/references/browser-integration.md) now require a complete, request-correlated event when publication can outlive the RPC. The original capture deadline and gameplay comparisons still apply. |

The retained watermark deliberately declines an old echo when an earlier
discarded record can no longer rule out another explanation. The receipt
covers attributable quality traffic through the cutoff. Issue
[#473](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/473)
still needs the exact native failure endpoint. The three-CPU hold failure
remains under [#467](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/467).

The rollout sample used the first #455 head to separate the change in unit
partition weights. The new window contained 23 completed PR heads and 18
merge candidates. It remains below the 40-revision threshold per event.
The slowest observed grouped job spent 459 seconds comparing native request
traces on Godot 4.7.2. [Issue #479](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/479)
tracks balancing that work with equivalent traces and runner cost.

## Acceptance

The [three-CPU Firefox commands and receipts](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/471#issuecomment-7141872916)
printed `relay:4 passed` and `relay:8 passed` on both Godot pins at `08f5b011`.
All eight captures reached the controller. Each room matched 40 confirmed rows
and snapshots and passed teardown. Same-CPU Chromium printed `relay:8 passed`
on both pins and `mesh-recovery:4 passed` on 4.7.2 with 111 compared frames.

The [contended-cache comparison](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/478#issuecomment-7141160014)
launched 570 shards per repetition on the old runner. Both candidate passes
launched 409 and passed all 869 cases in both repetitions. Their complete
records match the main control seeded with tracked timings. On `08f5b011`,
`make gate` reported `{"passed": true}` and `make test-reference` reported
`43 files, 0 failed`.

State `findings-acted`.
