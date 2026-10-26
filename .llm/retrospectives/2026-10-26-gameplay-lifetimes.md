# Retrospective: gameplay lifetime boundaries

## Work under review

Session 089 addresses replay completion, spectator SDK capacity and actual-source donor recovery evidence.
Debugging and oracle expansion trigger this retrospective. Original wider issue acceptance stays open.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| A final exposed frame can coexist with unfinished navigation or validation. | `test_replay_final_coverage.gd` fails completion assertions during LOAD/SAVE and callbacks before repair; paired completed controls pass. | Extend the existing rollback skill's callback/lifetime rule to completion getters. |
| Setup-only SDK capacity validation can allow queued history after configuration becomes incompatible. | `test_signalfish_spectator_relay.gd` exact minimum controls pass; one-byte-below changes previously delivered and simulated the queued row. | Reuse host-side runtime capacity policy at the viewer gate; document the terminal result. |
| A repeated identical emission and later receipt do not establish that an earlier emission was lost. | Fresh review relabeled a clean donor trace as lost and recovered; the initial comparator accepted it. | Reconcile emission/drop/receipt evidence, validate full operation identities and require new mutation controls before acceptance. |

## Prune ledger

Existing rollback callback and oracle mutation guidance were extended in place; no competing skill was added.
Existing SDK capacity checks and donor witness were reused. No obsolete behavioral claim was found to retire.
The original source/live/platform gaps remain explicit in the public guides and issues.

## Verification

Focused failing controls and passing repairs are recorded in the local session log.
Fresh reviewers independently inspect all three scopes; final harness, full runtime, CI and delivery gates remain pending.
No pending check is counted as passing evidence here.

## Outcome

Retro: findings-acted
