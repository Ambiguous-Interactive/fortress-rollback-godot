# Retrospective: client workflows

## Work under review

Session 151 advances driver-only input submission, local-example focus handling
and replay/spectator keyboard inspection under #40, #41, #45 and #47. New user interactions and
cross-area verification trigger this retrospective.

## Evidence and findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Configuration order is not byte-row order | `test_driver_local_bytes.gd`, `local_players`: noncontiguous/reversed membership drives actual callbacks | Expose owned ascending local slots; document `step_local` retries |
| Local inspection needs application lifecycle coverage | Both scene `focus_pause` cases compare canonical state and injected clock before/after focus loss, including completion callbacks | Pause local demos until explicit resume; add deferred pointer-resume coverage |
| Handler calls do not prove GUI routing | `replay_navigation_probe.gd`, `_inspection_shortcuts`: real dispatched keys cross editing focus, filters and seeking | Extend the existing deferred witness and its CI inventory |
| Concurrent author edits invalidate qualification | Focused launcher receipts reject source changes while direct selected cases pass | Freeze sources before final full qualification; retain rejected receipts as rejected |
| US punctuation alone can hide an unreachable shortcut | PR #318 review and spectator sweep: Shift-required punctuation conflicts with the modifier guard | Add unshifted alternatives and expand existing browser-testing guidance |
| Guide setup must define aliases used by snippets | PR #318 review and guide sweep: `Types` expressions lack a declared alias | Declare preloads across affected guides and clarify the existing copy skill |
| Inverse controls can hide intermediate mutation | PR #318 follow-up: one check after Y/U/I/O lets paired changes cancel | Assert policy immediately after each protected keypress; extend existing browser-testing guidance |

## Curation and pruning

The existing testing skill already requires a coordinated source freeze, actual
GUI routing and matched CI inventories. Expanded its keyboard-layout guidance to
cover Shift-required punctuation alongside numeric glyphs. The existing rollback
skill already covers ownership and stalled samples; no duplicate entry is needed.
Added alias setup to the existing copy skill instead of creating another skill.
Removed the offline guide's stale claim that online networking is planned;
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
