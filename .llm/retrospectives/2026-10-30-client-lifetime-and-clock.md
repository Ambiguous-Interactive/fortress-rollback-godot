# Retrospective: client lifetime and clock boundaries

## Work under review

This session addresses driver rejected-input retries (#40), replay viewer ownership
(#45), and spectator freeze validation (#47). Trigger: three debugging repairs.
Evidence: deterministic before/after receipts and final delivery records in the
machine-local `progress/session-122-client-progress.md` log.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Same-time input retries conceal premature clock commitment. | `test_driver_input_policy.gd`, `rejected_input_time`: later invalid lists blocked corrected earlier accepted-time calls before repair. | Extend the rollback skill's preflight guidance with the cross-time retry and successful-service controls. |
| Wrapper ownership checks must precede wrapper mutation. | `test_replay_viewer_lifetime.gd`: controls changed playback during callbacks/manual requests; replaced handles remained usable. | Existing callback and composed-control ownership guidance already covers this contract; retain it without duplication. |
| Specialized API audits need validation-only counterparts. | `test_spectator_session.gd`, `mesh_mutators`: inherited freeze validation returned OK while the operation was unsupported. | Extend the existing specialized-mode audit sentence. |

## Prune ledger

Reviewed the existing rollback skill's ownership, preflight and specialized-session
rules. Updated their canonical paragraphs; no competing rule or new skill was added.
No stale guidance was identified for removal. Existing simulation, format and
browser qualification limits remain unchanged.

## Verification

New deterministic cases fail on the prior implementation at their intended
assertions and pass after repair. Ordinary player freeze validation and valid
stalled-input retry provide paired controls. These longstanding omitted boundary
checks have no known pre-regression green revision; that limit is explicit.
Final pinned native, browser CI, feedback and merge results belong in the session
log and linked issues; this artifact does not preclaim their outcomes.

Retro: findings-acted
