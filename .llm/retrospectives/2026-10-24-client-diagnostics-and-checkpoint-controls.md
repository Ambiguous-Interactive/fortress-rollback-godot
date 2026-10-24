# Retrospective: client diagnostics and checkpoint controls

## Work under review

Session work advances driver diagnostics (#40), retained checkpoint navigation (#45),
and the playable spectator host-loss flow (#47). Runtime format and simulation algorithms are unchanged.

## Findings

| Finding | Evidence | Disposition |
| --- | --- | --- |
| Driver-only clients need callback identity in returned results, including later rejected calls. | `core/driver.gd` result projection and `test_driver_callback_results.gd` SAVE/LOAD/ADVANCE matrix | Added the existing status field to results; no second failure store. |
| Retained checkpoint targets should come from the cache's validated inventory. | `replay_player.gd` checkpoint listing; callback/expert inventory and eviction tests | Added an owned list and viewer controls sharing existing restoration. |
| Controller tests cannot prove help text fits above a board. | Rendered spectator image exposed overlap after adding a help line. | Spacing uses rendered label dimensions; documentation screenshots refreshed. |

All paths above are relative to `addons/fortress_rollback/` or `tests/unit/`, except the example layout.
Fresh reviewers independently examined each scoped diff and ran focused repeated suites.
Full native and exported checks are required before delivery; local progress logs record exact receipts.

## Curation and pruning

Existing testing guidance already requires actual UI controls, rendered evidence and failure-boundary checks.
Existing rollback guidance covers first-cause preservation and callback guards. No new rule duplicates these contracts.
No stale claim or contradictory guidance was found; no canonical guidance was retired.
The original broad source, differential and live-network acceptance stays in the open issues.

## Outcome

Retro: no-findings
