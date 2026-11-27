# Relay publication and final recording

| Finding | Evidence | Action |
| --- | --- | --- |
| The server's combined encode and flush interval hid the amount of time spent writing. | The original eight-player receipt had 13,063,527 bytes. Replaying it through the same Rust publisher produced byte-identical output in 799–1,003 ms, including 46–54 ms in file writes. The original room recorded 4,895 ms for the combined phase. | Enable optimization for the instrumented server crate. Keep the existing snapshot format, buffered file writes, and request recheck. |
| A hard link can invalidate a source-bound receipt. | The archive kept its bytes when the recording worktree linked it. The stock room failed with `native browser witness inputs changed during execution` for the template path. A private copy let the next stock run retain its receipt. | Isolate assets that another run can replace or hard-link. Run the browser and Gate from an immutable checkout. |
| A matched frame needs complete timing evidence around the proxy inlet. | Fresh review evicted an identical observation before comparing the remaining frame. A second control put the earlier candidate at the exact inlet timestamp. The original join returned a strict order in both cases. | Leave the timing unresolved when a matching callback ties the inlet or an evicted candidate could match. |
| Controller and browser timers can invalidate a loopback schedule. | A controller pause could move a planned early write into the expiry interval. The revised Firefox loopback drove its sends from the corresponding page receipts. It held a real debugger event for 393 ms. It printed a negative source interval, an overlap, and a positive interval. | Use observed page milestones to place the carriers. Keep the debugger delivery delay separate. |
| A final recorded correction needs an actual original delivery. | The recording fixture reached boundary 257 on both pages, held input 256, and matched the original socket send to SDK receipt. Each peer performed one extra LOAD and verified 258 playback boundaries. The pinned Rust witness exported 256 and 255 finalized rows after both peers confirmed frame 256. | Keep the decoded browser proof and route no-sample recovery to [upstream #607](https://github.com/Ambiguous-Interactive/fortress-rollback/issues/607). |

The controlled generation replay varied only code generation for the trace
publisher. Each result was compared with the original bytes. Optimization
level 1 reduced the median elapsed publication time from 603 to 456 ms.
The optimized 4.3 Firefox pilot printed `relay:4 passed` and
`relay:8 passed`. The eight-player final generation encoded and flushed in
1,436 ms. Independent verification found 40 original canonical rows, eight
clean Leaves and exact Gecko carriers on all 56 directed links.

The [browser integration guidance](../skills/testing/references/browser-integration.md)
now calls for separate encode and write measurements, strict coverage at the
inlet, and private copies for concurrently staged assets. It replaces the
older generic source-clock and shared-installation wording.

State `findings-acted`.
