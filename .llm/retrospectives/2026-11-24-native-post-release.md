# Native browser progress after release

## Work under review

[Issue #471](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/471)
tracks Firefox rooms that drained their held inputs, then timed out during
correction or history capture. The failure logs also showed that final page reads
could all time out. The witness now keeps scalar checkpoints in the controller
as each relay room progresses.

## Findings

| Finding | Evidence |
| --- | --- |
| The stall is intermittent. | The unchanged main 4.3 Firefox run printed `relay:8 passed` with 40 matching input and state rows. The earlier three-CPU failure reached the correction wait and ended with all eight final reads rejected. |
| The first correction can precede a peer's own release. | The checkpoint control increments the restore count after readiness and before local release. It requires an earlier correction timestamp and the original restore count. |
| Malformed records can hide progress. | Cold review found that a kind-only record could occupy the first-correction slot. The control inserts a kind-only correction before a valid one and a kind-only heartbeat after two valid samples. |
| A pending promise can let a Node subprocess exit successfully without running assertions. | The delta review identified the gap in the fake timer. The checkpoint control uses a real watchdog alongside its fake heartbeat. |

## Actions and pruning

The [browser testing reference](../skills/testing/references/browser-integration.md)
now requires controller retention at the relevant boundaries. It supersedes
the release-return advice, which covered only drains whose evaluation returned.
The [Web room guide](../../docs/experiments/upstream-binding.md#playable-web-rooms)
describes the separate clock domains and limits on interpreting a missing sample.

`python3 -m unittest discover -s scripts/reference -p test_browser_cleanup.py`
reported `Ran 15 tests` and `OK`.

## Outcome

State `findings-acted`.
