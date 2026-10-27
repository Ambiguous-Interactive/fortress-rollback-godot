# Retrospective: playback completion and digest evidence

## Work Under Review

- Scope: replay prefix evidence, spectator completion/cause reporting and actual-source multi-row donor recovery.
- Trigger: production debugging, new public completion query and expanded differential acceptance.
- Evidence: deterministic baseline failures, both-pin playback suites, cold reviews and source-bound oracle receipts.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| A prefix copy can invent validation storage even when the source intentionally retains incomplete evidence. | `replay.gd` used unconditional digest `resize`; the new partial-row test fails baseline preservation/export assertions. | Bound resizing by the original size; teach the existing transport skill to test partial digests. |
| A shared terminal reason cannot establish clean playback completion. | External failure became generic `TERMINATED`; plain cancellation at the final input boundary looked complete. | Preserve committed first cause and latch `is_complete()` only in ordinary clean terminal service. |
| A final-state-only control can miss incorrect interior history. | Four-row donor permutation preserves endpoints and payload sum while the original-prefix comparison rejects altered interior history. | Extend the actual-source witness with multiple missing rows and an encoded temporal corruption control. |

## Actions Taken

- Updated [networking transport](../skills/networking-transport/SKILL.md) at its existing replay evidence contract.
- Reused [rollback fundamentals](../skills/rollback-fundamentals/SKILL.md) guidance on committed causes and final lifecycle service.
- Reused [oracle validation](../skills/testing/references/oracle-validation.md) temporal mutation guidance rather than adding another procedure.
- Kept full barrier parity, physical no-donor eviction and live browser donor acceptance in the existing owning issues.

## Prune Ledger

- Fixed at source: PLAN's single missing-row scope now names both one-row and four-row suffix cases.
- Considered retirement/merging: existing first-cause and temporal mutation rules remain correct; no duplicate knowledge entry added.
- Verified on touch: source widths, generated guidance, harness lint/tests and relevant deterministic/differential controls.

## Outcome

- State: `findings-acted`.
- Follow-ups: broader replay/spectator acceptance and coordinated-drop source/live matrix remain in #45, #47, #188, #48 and #166.
