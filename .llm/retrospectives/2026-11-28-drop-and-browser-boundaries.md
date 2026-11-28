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

Page enumeration placed four archived expiry receipts out of controller
sequence. A fixture with equal controller timestamps failed with page order
`[0, 2]` and passed with receipt order `[2, 0]`. All 48 browser cleanup
tests and 10 live clock controls passed. The archived natural Firefox
failures lack a calibrated Gecko interval. The current mixed attempt found
a distinct warmup gap after 18 exact Chromium TLS receipts.
[Warmup follow-up](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/561)

## Outcome

State is `findings-acted`. The
[oracle guidance](../skills/testing/references/oracle-validation.md) now
requires the complete tracked hint inventory and a physical reuse witness
after receipt gossip. The [plan](../../PLAN.md) carries the remaining
pinned operation cases and links the new warmup investigation.
