# Retrospective — 2026-11-28 drop and browser boundaries

## Findings and actions

The P2P schedule bundle held 67 recipes with a stale generator fingerprint.
The new inventory test failed on that bundle and passed after regeneration.
The selected Rust observer regenerated all 67 recipes without changing a
scenario. Building them took 3,724 observer processes with an empty cache and
67 with the restored bundle. The clean Godot 4.3 mesh receipts match across
54 cases, 572 record controls and 59 process controls.
[Iteration evidence](../../docs/reference/iteration.md#november-28-p2p-schedule-cache)

The first exhausted prediction step left the donor one input short of the
reachable bound. Continuing to service receipt gossip let the target stage
frame 23 and physically replace ring tag 5. A no-refresh control stopped at 22
and left tag 5 in place. Review also found that checking one absent row and
the final cut could miss a partial write or a byte permutation with the same
game sum. The final witness records the tags and full intervals on each
survivor. Both pinned editors rejected 28 focused controls.
[Donor retention comparison](../../docs/oracle-p2p.md#donor-retention-at-the-live-recipient-bound)

The reference check found two new donor cases missing from the Chromium
ownership inventory. Adding the case names to the owned inventory restored
the declaration check and requires both cases in exported results.

Page enumeration placed four archived expiry receipts out of controller
sequence. A fixture with equal controller timestamps failed with page order
`[0, 2]` and passed with receipt order `[2, 0]`. All 48 browser cleanup
tests and 10 live clock controls passed. The archived natural Firefox
failures lack a calibrated Gecko interval. The current mixed attempt found
a distinct warmup gap after 18 exact Chromium TLS receipts.
[Warmup follow-up](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/561)

One recording endpoint reached frame 152 while its partner waited for the
exact original receipt at boundary 151. The controller now waits for both
pages at the recovered prefix before accepting the next sample. The receipt
also checks a unique server carrier through the browser message and SDK
admission. It records the pending TCP chunk and the final WebSocket frame
header and offsets. The split-stream test compares the preceding bytes
directly and proves that holding one final byte prevents complete delivery.
Both Chromium labels passed twice on each pin. The asymmetric receipts
rejected 13 controls and the completed recording bytes repeated exactly.
[Recording acceptance](../../docs/oracle-replay.md#exported-mixed-path-recordings)

Hosted review found missing links between the held write and recovery.
The validator now checks browser admission order, requires the released
chunk to start the recovered prefix, and checks resource closure in
withheld rooms through the same teardown validation.

## Outcome

State is `findings-acted`. The
[oracle guidance](../skills/testing/references/oracle-validation.md) now
requires the complete tracked hint inventory and a physical reuse witness
after receipt gossip. It also requires a shared browser recovery boundary
and unique relay delivery attribution. The [plan](../../PLAN.md) carries
the remaining pinned operation and release cases and links the warmup investigation.
