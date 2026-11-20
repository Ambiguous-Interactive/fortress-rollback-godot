# Retrospective: 2026-11-20 READY-to-commit drop overlap

## Work Under Review

- Scope: the coordinated-drop commit-confirmation closure, one new native
  regression suite, the revised late-ack participant-loss expectation, the
  serial second-departure control, the lifecycle contract and the changelog.
- Trigger: issue #425, a cross-survivor ordering defect in the fixed
  participant set; the change is below the large-change line.
- Evidence base: `make gate`, both pinned engines running every
  `tests/unit/test_peer_drop_*.gd` suite twice, the drop-history differential
  receipt against pinned `d124c890`, and the source-width and harness checks.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | A survivor that committed a drop could keep the frozen match running while a still-pending survivor detected the same operation's participant loss and ended the match. The committed survivor had no local proof that every participant applied the decision, so the two survivors took different outcomes for one operation. | production bug | pre-fix `tests/unit/test_peer_drop_overlap.gd` fails at "the committed survivor freezes no later departure on its way out" (actual 5, expected -1); `test_peer_drop_late_ack.gd::late_ack_participant_loss` also expected the old single-sided continuation |
| 2 | Committing followers can apply the same COMMIT in either delivery order. A confirmation sent by the faster follower can reach a slower follower before the slower one applies that COMMIT, so a confirmation handler gated only on `state == COMMITTED` loses the earlier confirmation and leaves the slower follower permanently unconfirmed. | implementation hazard | the first fix draft failed `early_committed_ack` for the proposer and risked dropped follower confirmations; the final handler retains a follower's early confirmation in `commit_acks` while the proposer still refuses a pre-commit ACK |
| 3 | The pinned source runs its participant-loss check only while the operation is not committed (`active.phase != CoordinatedDropPhase::Committed`), so the pinned committed survivor may keep running while a pending one fails closed. The Godot tier deliberately closes the committed-but-unconfirmed operation as well. | deliberate divergence | `src/sessions/p2p_session.rs` lines 2395-2412 in pinned `d124c890`; documented in `docs/peer-lifecycle.md` |
| 4 | Local acknowledgement sets are not common knowledge. The automated review found a case where the proposer has every follower acknowledgement while one follower missed another follower's report; a later departure then left the proposer confirmed and the follower unconfirmed, so only the follower ended. A committed survivor must accept a shared participant-loss abort even when its local acknowledgements look complete. | review finding | `asymmetric_ack_departure` reproduces the split and fails without the abort acceptance (`actual 5, expected -1` for the later freeze); the abort acceptance makes both survivors end with `participant_lost` |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Record every survivor's commit acknowledgement on every survivor and close a committed operation only when every non-coordinator participant confirmed it; a participant that departs before confirmation ends the match with `participant_lost` without rewriting the certified freeze. | `addons/fortress_rollback/core/peer_drop_barrier.gd` | new overlap suite plus all drop suites pass twice on Godot 4.3 and 4.7.2 |
| 2 | Retain follower confirmations that arrive before the local COMMIT, while keeping the proposer's pre-commit-ACK refusal. | `addons/fortress_rollback/core/peer_drop_barrier.gd` | `early_committed_ack`, `late_ack_partial`, `late_ack_recovery` and the serial control pass |
| 3 | Replace the single-sided participant-loss expectation with the uniform terminal outcome and strengthen the serial control to prove the first operation was confirmed by every participant. | `tests/unit/test_peer_drop_late_ack.gd`, `tests/unit/test_peer_drop_barrier.gd` | both suites pass twice per pin |
| 4 | Record the new closure rule, the READY-to-commit outcome and the pinned-source divergence. | `docs/peer-lifecycle.md`, `PLAN.md`, `CHANGELOG.md` | `make lint-source`, `make lint-llm` |
| 5 | Broadcast a participant-loss abort from a committed-but-unconfirmed survivor and accept it on a committed barrier, so a locally confirmed survivor ends with the sender. Add the asymmetric-acknowledgement regression. | `addons/fortress_rollback/core/peer_drop_barrier.gd`, `tests/unit/test_peer_drop_overlap.gd` | all 124 `test_peer_drop_*` cases pass twice per pin; `make gate` re-run |

## Prune Ledger

- Retired / merged / fixed at source: the resolved #425 pointer was removed
  from `PLAN.md`; the old `late_ack_participant_loss` continuation assertion
  was replaced rather than kept as an obsolete expectation.
- Verify-on-touch: `make gate`, all `test_peer_drop_*` suites on both pins and
  `make drop-history-probes` were re-run for this change.

## Outcome

- State: `findings-acted`
- Follow-ups: live missing-history transfer and the exported fault matrix stay
  in #166/#188; the stricter committed-operation check is documented as a
  deliberate pinned-source divergence.
