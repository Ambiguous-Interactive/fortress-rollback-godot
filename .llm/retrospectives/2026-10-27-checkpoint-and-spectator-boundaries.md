# Retrospective: checkpoint and spectator boundaries

## Work Under Review

- Scope: finalized peer input reads, terminal replay checkpoint navigation, chronological cache retention and delayed spectator source comparisons.
- Trigger: new client capabilities, a reproduced cache defect and fresh review findings.
- Evidence: baseline capability failures, checkpoint eviction reproduction, executed Rust/Godot traces and independent adversarial reviews.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Evicting before inserting an older checkpoint can discard newer history during backward inspection. | `replay_player.gd` removed index one before sorting the incoming frame; the bounded-cache regression fails for capacities two and three. | Sort combined candidates before evicting; extend rollback guidance at its checkpoint contract. |
| Per-record validation cannot establish a complete observed history. | The initial delayed validator accepted fourteen copies of startup while its smaller source projection stayed unchanged. | Validate the detailed delivery/microstep inventory and retain an omitted-history negative control. |
| A final accumulator cannot prove input order. | The executed spectator control swaps the first two delivered samples and preserves their sum. | Compare the original ordered callback transcript; reuse existing temporal-mutation guidance. |

## Actions Taken

- Updated [rollback fundamentals](../skills/rollback-fundamentals/SKILL.md) at the existing checkpoint boundary.
- Updated [oracle validation](../skills/testing/references/oracle-validation.md) for detailed observation coverage.
- Kept delayed source comparison separate from the unchanged no-delay formal projection.
- Kept broader client, replay and spectator acceptance in #40, #45 and #47; live relay acceptance remains in #131.

## Prune Ledger

- Fixed at source: PLAN now names the scoped delayed source comparison and terminal checkpoint behavior.
- Considered merging/retirement: existing ownership and temporal-mutation rules remain correct; no duplicate knowledge entry added.
- Machine-local dry run: 5,951 reclaimable entries, 1.03 GB; no deletion performed.
- Verify-on-touch: generated guidance, harness/source lint, regression suites and final source-bound gates are session delivery requirements.

## Outcome

- State: `findings-acted`.
- Follow-ups: event/status, arbitrary-delivery, clean-end delayed source acceptance and live spectator relay remain in their existing issues.
