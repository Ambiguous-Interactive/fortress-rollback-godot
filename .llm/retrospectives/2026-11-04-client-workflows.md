# Retrospective: client workflows

## Work under review

Session 151 advances driver-only input submission, local-example focus handling
and replay keyboard inspection under #40, #41 and #45. New user interactions and
cross-area verification trigger this retrospective.

## Evidence and findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Configuration order is not byte-row order | `test_driver_local_bytes.gd`, `local_players`: noncontiguous/reversed membership drives actual callbacks | Expose owned ascending local slots; document `step_local` retries |
| Local inspection needs application lifecycle coverage | Both scene `focus_pause` cases compare canonical state and injected clock before/after focus loss, including completion callbacks | Pause local demos until explicit resume; add deferred pointer-resume coverage |
| Handler calls do not prove GUI routing | `replay_navigation_probe.gd`, `_inspection_shortcuts`: real dispatched keys cross editing focus, filters and seeking | Extend the existing deferred witness and its CI inventory |
| Concurrent author edits invalidate qualification | Focused launcher receipts reject source changes while direct selected cases pass | Freeze sources before final full qualification; retain rejected receipts as rejected |

## Curation and pruning

The existing testing skill already requires a coordinated source freeze, actual
GUI routing and matched CI inventories. No additional rule or duplicate knowledge
entry is needed. The existing rollback skill already covers ownership and stalled
samples. Verified those instructions against the new cases rather than expanding
them. Removed the offline guide's stale claim that online networking is planned;
its replacement links the existing online setup guide.

## Verification and limits

Capability-removal controls fail at their intended assertions. Focused driver
cases pass twice on both engine pins; local scene cases pass direct repeated
execution. Source-drift launcher attempts are disqualified and do not establish
full verification. Final frozen-source native, GUI, CI, review and delivery
results are recorded in the machine-local session log and linked issue evidence.
The original broad driver, examples and replay acceptance remains open.

## Outcome

Retro: findings-acted.
