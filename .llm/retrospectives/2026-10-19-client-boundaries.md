# Retrospective: 2026-10-19 client boundaries

## Work under review

Driver input-list completeness, spectator confirmation policy, and replay viewer speeds.
Trigger: new presentation capability and two reproduced client API defects.
Evidence: deterministic red/control/green receipts and source-bound native/Web verification.
Delivery evidence is recorded in the linked issues and local session039 progress log.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Metadata preflight did not catch omitted local samples before retaining other buttons. | `driver.gd` preflight and `test_driver.gd:missing_samples`; corrected retry failed on starting main. | Extend the existing input-list guidance in rollback-fundamentals. |
| Spectator playback could succeed while inherited mesh controls hid confirmed exports. | `test_spectator_policy.gd:confirmation_policy`; original method returned OK and restricted exported rows. | Require inherited capability audits and confirmation/export assertions in rollback-fundamentals. |
| Playback speed needs bounded work and exact simulation frames. | `test_replay_speed.gd` covers cadence, controls, failure and scene selection. | Keep frame service in presentation; retain fixed simulation timestep guidance. |

## Prune ledger

Updated existing rollback guidance rather than creating overlapping skills.
The prior malformed-list guidance remains valid; completeness extends its scope.
No old state, format or timer contract was superseded.
Regenerated skill indexes/stubs; verify-on-touch checks use the documented commands.

## Outcome

State: findings-acted.
Broader driver equivalence, replay parity and live spectator acceptance remain in their issues.
