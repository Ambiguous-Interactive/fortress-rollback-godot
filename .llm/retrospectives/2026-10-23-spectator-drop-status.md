# Retrospective: 2026-10-23 spectator drop status

## Work Under Review

- Scope: finalized spectator statuses, authenticated v3 delivery, protected drop frontiers and certified retained-history cuts.
- Trigger: new wire format, production divergence and dependency qualification.
- Evidence: `test_spectator_status.gd` canonical history regression and status-erasing mutant;
  `test_peer_drop_history.gd` unequal-frontier freeze rejection; native SDK relay qualification.

## Findings

| Finding | Type | Evidence |
| --- | --- | --- |
| Equal input bytes can hide different disconnected-player simulation behavior across a spectator bridge. | technique | `tests/unit/test_spectator_status.gd`: `host_drop` fails against the byte-only path and the status-erasing mutant. |
| An unaudited dependency upgrade is unnecessary to prove the current SDK can decode spectator delivery. | fact | [Qualification](../../docs/reference/spectator-relay-qualification.md): identical public drill passes with reviewed and current SDK on both pins. |
| Receipt-raised cuts require exact per-target retained coverage; missing rows require a separate historical donor protocol. | rule | [Drop contract](../../docs/peer-lifecycle.md#unequal-confirmation-frontiers); #188 retains receipt-raised cut and range backfill acceptance. |

| Manual model packets omitted the new status trailer, bypassing their intended conflict and mutation gates. | technique | Full460-case suites fail the original fixtures; corrected v3 fixtures pass both pins without changed assertions. |
| Teardown disconnections must not start new drop decisions after a terminal cause commits. | rule | `commit_deadline` detects duplicate timeout/missing-history outcomes after draining teardown events. |

| Honest coordinator selection did not validate a follower's receipt-inclusive candidate boundary. | rule | `peer_drop_barrier.gd` candidate guard lacked its captured receipt maximum; a role-valid lower candidate could certify. |

## Actions Taken

| Action | Canonical home | Verification |
| --- | --- | --- |
| Extend existing status/rollback guidance to cover the complete spectator bridge and a status-sensitive canonical gate. | [Rollback fundamentals](../skills/rollback-fundamentals/SKILL.md) | `make llm-index`, `make lint-llm`, `make test-llm` |
| Replace stale byte-only spectator and local-frontier fallback claims. | `PLAN.md`, `docs/spectators.md`, `docs/peer-lifecycle.md` | Production tests and cold diff review |
| Keep dependency drill results separate from exported Fortress acceptance and pin review. | [Qualification](../../docs/reference/spectator-relay-qualification.md) | Actual public SDK drill on both engine pins |

| Expand format-change sweeps to spectator header builders and authenticated model fixtures. | [Networking transport](../skills/networking-transport/SKILL.md) | Full spectator model suite on both pins |

| Validate agreement candidates against receiver-owned receipt evidence. | [Networking transport](../skills/networking-transport/SKILL.md) | Role-valid receipt-excluding candidate regression |

## Prune Ledger

- Fixed at source: byte-only spectator limitation replaced with explicit v3 compatibility and finalized-status contract.
- Fixed at source: unsafe fallback description replaced with fail-closed behavior and the remaining recovery gap.
- Considered consolidation: existing rollback skill owns status propagation; no overlapping skill or knowledge file added.
- Verify-on-touch: existing spectator model command passes and rejects its unsafe mutant.

## Outcome

- State: `findings-acted`.
- Follow-ups: #188 full missing-history donor transfer; #131 dependency review and exported authenticated spectator witness; #47 upstream differential acceptance.
