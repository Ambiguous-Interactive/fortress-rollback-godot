# Retrospective: 2026-10-16 playable effects

## Work under review

Scope: input-driven playable rollback effects, bounded delivery controller,
actual-input-history tests and clean-install commands. Trigger: new capability
and a resampling mutation that initially survived. Evidence:
[session log](../../progress/session-023-playable-effects.md).

## Findings

| Finding | Type | Evidence |
| --- | --- | --- |
| Equal gameplay state does not prove once-per-frame scheduling when remote delivery accepts identical duplicates. | Technique | Resampling mutation initially survived; exact pending occupancy now fails with 9 versus 8 |
| A copy command can reference an absent asset even when the project runs without it. | Verification | First clean-install run failed copying absent `icon.svg`; corrected commands pass on both engines |

## Actions taken

| Action | Canonical home | Verification |
| --- | --- | --- |
| Require scheduling and queue assertions for idempotent input-delivery mutations. | [Testing](../skills/testing/SKILL.md) | Remote resampling mutant fails at queue occupancy; unmodified suite passes on both pins |
| Execute clean-install commands rather than infer them from the repository launch. | Existing task execution contract and integration guide | Import, scene, input and reset pass from isolated copies on both pins |

## Prune ledger

Updated the existing testing mutation guidance without adding another skill or
growing its 299-line body. Replaced redundant wording about unrelated failures
with equally strict, compact wording. No existing supported-feature claim was
retired; the new example explicitly uses in-process delivery.

## Outcome

State: `findings-acted`.
Remaining feature and release scope stays under #41 and #38/#39/#75.
