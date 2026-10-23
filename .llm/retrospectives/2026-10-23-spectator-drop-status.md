# Retrospective: 2026-10-23 spectator drop status

## Work Under Review

- Scope: finalized spectator statuses, authenticated v3 delivery and protected drop frontiers.
- Trigger: new wire format, production divergence and dependency qualification.
- Evidence: `test_spectator_status.gd` canonical history regression and status-erasing mutant;
  `test_peer_drop_history.gd` unequal-frontier freeze rejection; native SDK relay qualification.

## Findings

| Finding | Type | Evidence |
| --- | --- | --- |
| Equal input bytes can hide different disconnected-player simulation behavior across a spectator bridge. | technique | `tests/unit/test_spectator_status.gd`: `host_drop` fails against the byte-only path and the status-erasing mutant. |
| An unaudited dependency upgrade is unnecessary to prove the current SDK can decode spectator delivery. | fact | [Qualification](../../docs/reference/spectator-relay-qualification.md): identical public drill passes with reviewed and current SDK on both pins. |
| Full unequal-frontier recovery requires missing historical rows, beyond agreement on one frozen value. | rule | [Drop contract](../../docs/peer-lifecycle.md#unequal-confirmation-frontiers); #188 retains receipt-raised cut and range backfill acceptance. |

## Actions Taken

| Action | Canonical home | Verification |
| --- | --- | --- |
| Extend existing status/rollback guidance to cover the complete spectator bridge and a status-sensitive canonical gate. | [Rollback fundamentals](../skills/rollback-fundamentals/SKILL.md) | `make llm-index`, `make lint-llm`, `make test-llm` |
| Replace stale byte-only spectator and local-frontier fallback claims. | `PLAN.md`, `docs/spectators.md`, `docs/peer-lifecycle.md` | Production tests and cold diff review |
| Keep dependency drill results separate from exported Fortress acceptance and pin review. | [Qualification](../../docs/reference/spectator-relay-qualification.md) | Actual public SDK drill on both engine pins |

## Prune Ledger

- Fixed at source: byte-only spectator limitation replaced with explicit v3 compatibility and finalized-status contract.
- Fixed at source: unsafe fallback description replaced with fail-closed behavior and the remaining recovery gap.
- Considered consolidation: existing rollback skill owns status propagation; no overlapping skill or knowledge file added.
- Verify-on-touch: existing spectator model command passes and rejects its unsafe mutant.

## Outcome

- State: `findings-acted`.
- Follow-ups: #188 full receipt-raised history transfer; #131 dependency review and exported authenticated spectator witness; #47 upstream differential acceptance.
