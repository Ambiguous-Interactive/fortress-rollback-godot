# Retrospective: drop recovery and driver input policy

## Work under review

Session 070 advances #188, #166 and #40: physical history retention, live lost-answer
recovery and driver input policy. New capability and experimental controls trigger this review.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| A proposed physical no-donor scenario instead preserves the missing suffix through the global floor. Fabricating an inventory would test a different fault. | `test_peer_drop_eviction.gd`, `unequal_retained_history`: donor receives through 22, floor stays 7, original row 8 survives and transfers. | Extend oracle-validation guidance to distinguish physical eviction from fabricated inventories. |
| A captured journal remains usable after actual ring reuse; rebuilding it from the donor would lose valid retry ownership. | `journal_after_ring_wrap` advances the source to 46, verifies frame 2 is physically overwritten, then installs the original multi-target bytes. Removing the cached-journal return fails the intended assertion. | Keep the physical regression and its bounded source/session control. |
| The small driver lacked access to scheduling information already available on its expert session. | `test_driver_input_policy.gd` rejects missing methods before implementation, then exercises a stalled retry with owned input and between-step delay changes. | Delegate to the existing session and retain the completion-handler guard. |

## Prune ledger

Corrected the obsolete peer-lifecycle claim that any survivor lacking a row ends the match;
existing donor recovery can supply it. Removed lost inventory answers from the unqualified live
list after both exported engine pins passed the actual RTC loss/retry case.
No new skill or duplicate knowledge file is needed. Remaining pinned-source comparison,
live missing-history transfer and other physical departure cases stay in their existing issues.

## Verification

Focused native cases pass on both engine pins. The journal mutation fails without engine errors.
The exported lost-answer witness passes on both pins and rejects eight tampered real receipts.
Fresh-context reviews cover driver, browser witness and history qualification; final delivery
checks and CI evidence are recorded in the machine-local session log and linked issues.

Outcome: findings-acted.
