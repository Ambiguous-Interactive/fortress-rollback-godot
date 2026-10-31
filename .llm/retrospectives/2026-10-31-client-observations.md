# Retrospective: client observations and batch ownership

## Work under review

Session 125 advances driver, recording and spectator client contracts under issues #40, #45 and #47.
The incident trigger is a reproduced callback replacement defect; the other changes add bounded public observations.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Callback guards alone do not protect manual work between SAVE and ADVANCE. | `tests/unit/test_driver_termination.gd`, `manual_configuration`: unchanged production left original state at 1 instead of the control's 18. | Driver configuration checks shared mutation ownership on current and target sessions. |
| Replacement guidance named expert batches but did not identify both session owners. | `rollback-fundamentals/SKILL.md`, replacement guidance. | Add the precise attachment rule and partial-batch counterexample to that existing skill. |
| Nested status must respect the facade's captured viewer lifetime. | Fresh review reproduced a relay reporting WRONG_STATE while nested host status reported a replacement as OK. | Fence nested observation against attached session/configuration; add regressions and update the existing networking skill's lifetime rule. |
| Stronger attachment validation invalidated a recovery test's setup. | Browser ownership artifacts showed `expert_parity` constructed a driver after opening the expert batch, yielding NOT_CONFIGURED instead of BUSY. | Attach before opening the batch; preserve the original BUSY assertion and separately check refused construction. |
| Call-entry ownership can change during an SDK status getter. | Automatic review's getter-reentry regression mixed a rejected old status call with replacement host liveness. | Capture revision and owners before the callback boundary, then validate before publishing nested observations. |
| Finalized recording count can lag simulated capacity. | Actual scene/core controls show pending frames filling the cap before finalized frames reach it. | Warn using finalized plus pending usage before capacity; retain explicit omitted-gameplay feedback. |
| Retained recording data does not make Finish available after Leave or failure. | Fresh warning review traced detached matches retaining progress while the control is disabled. | Share action readiness with the control, test failed/offline states and capture the rule in the existing user-copy skill. |

## Verification

The new ownership regression failed unchanged production without engine errors.
Twenty-seven focused cases pass twice on Godot 4.3 and 4.7.2.
A fresh adversarial reviewer found no defects and independently passed the termination suite.
Complete candidate and merge evidence belongs in the session PR and machine-local session log.

## Prune ledger

Existing replacement, reentry and view-expiry guidance was inspected before adding the two-line clarification.
No obsolete claim or duplicate knowledge entry required removal. Existing source behavior remains authoritative.
Generated skill discovery files are regenerated and the complete harness checks are required before delivery.

## Outcome

State: findings-acted. Broader source parity and browser qualification remain with their original roadmap issues.
