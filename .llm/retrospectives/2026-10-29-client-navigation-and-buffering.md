# Retrospective: client navigation and buffering

## Work Under Review

Session 117 advances driver acceptance, replay inspection and spectator feedback.
The trigger is a client-facing feature change and a reproduced UI defect.
Evidence: `test_driver_external_parity.gd`, `test_replay_input_navigation.gd`,
`test_spectator_status.gd` and `test_spectator_demo.gd`; session receipts remain
in ignored root `progress/`.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Startup buffering checks missed a gap after playback had begun. | The added `playback_feedback` assertions failed because the example only checked frame zero. | Extend browser-integration testing guidance to mid-match gaps and deliberate delay. |
| Similar clients can share the same incorrect delay expectation. | `independent_delay_control` leaves paired execution equal but rejects an omitted bridge at canonical boundary five. | Retain the independent original-history control; existing oracle guidance already owns this method. |
| An input-change index must not replace integrity validation. | `input_change_integrity` corrupts row/digest evidence and requires navigation to fail at frame 120. | Keep ordinary verified seek; existing replay guidance already covers prefix/destination checks. |

## Prune Ledger

No skill or knowledge file retired. Existing independent-history and verified-navigation
rules remain accurate; only the missing mid-match feedback instruction was added.
No duplicated skill or new procedure was needed. Source/tool pins are unchanged.

## Outcome

State: findings-acted. Broader driver, replay and spectator release gates remain
in issues #40, #45 and #47; this session does not close those parents.
