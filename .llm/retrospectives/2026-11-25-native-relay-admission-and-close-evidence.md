# Relay admission and close evidence

The session investigated native relay receive overflow, WebKit close proof
collection, and the slowest grouped oracle lane.

| Finding | Evidence | Action |
| --- | --- | --- |
| The SDK can hand over more addressed frames than the relay can queue. | The 256-frame Godot control stopped with code 10 on a 128-packet relay FIFO. The first refusal test distinguished a full packet queue from a full byte queue. | Read capacity at admission, retain the socket FIFO, and record exact occupancy before detach. |
| Clamping each SDK call to the number of free relay slots also slows unrelated broadcast traffic. | The mixed control with 128 unrelated frames followed by 128 addressed frames left all 128 addressed frames in the SDK. In a real eight-player room the batch cap held even though addressed arrivals peaked at 32. The room stopped at a native expiry in corrected history. | Keep the existing SDK budget and recheck capacity before each frame read. Service bounded relay batches around the native step. |
| A timed-out page read can hide earlier timely evidence or start another read. | The close controls lost the prior round's snapshot and showed a third calibration read after the second had timed out. A real WebKit eight-player room matched 40 rows and snapshots and then lacked proof for one tagged send. | Retain the last timely snapshot per page and preserve individual clock brackets. Bound each read within the shared deadline. Use only the complete qualifying round for proof. |
| Fixture size did not capture the cost of the lifecycle workload sharing the oracle lane. | Group 45537876607 verified 64 jobs. The slowest oracle comparison was 200 seconds. The eight verified archives identify two movable wrap cases at 12–16 and 8–10 seconds. The focused comparison repeated both cases twice per engine and matched the grouped traces on both pins. | Keep lifecycle in its lane and move the two measured wrap cases. Retain receipt inventories and compare total runner allocation in the next grouped Gate. |

The [browser integration guidance](../skills/testing/references/browser-integration.md)
now ties overflow evidence to admission and defines the lifetime of partial
close evidence. The [plan](../../PLAN.md) drops the completed departure witness
and points to the expiry that followed eight-player history publication. The original
departure failure lacked an expiry timestamp. The new receipts establish the
healthy SDK departure path and preserve future expiry observations separately.

The exported mixed rooms on CPUs 0–2 printed `relay:4 passed` and
`relay:8 passed` on both Godot pins. Each eight-player receipt contained 40
matching rows and snapshots, zero overflows and eight clean leaves.

State `findings-acted`.
