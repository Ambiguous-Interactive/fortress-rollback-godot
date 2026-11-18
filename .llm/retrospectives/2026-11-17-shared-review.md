# Retrospective: shared advisory review

## Work Under Review

Add the pinned shared reviewer. Trigger: new workflow and live review feedback.

## Findings

| Finding | Evidence |
| --- | --- |
| Draft conversion must signal workflow concurrency. | [Review finding](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/pull/393#discussion_r4607054002). |
| Short deduplicated runs cannot establish a cancellation failure. | Fresh-head probes cancelled the active Review step both with and without an extra job; detailed evidence remains in the local migration audit. |

## Actions Taken

Add the conversion event and retain the existing draft guard. Remove the
unnecessary extra job. Record the fresh-head method in ship-session.

## Prune Ledger

Reject the unsupported inference that a runnable cancellation job is required.
No other guidance was retired.

## Outcome

findings-acted. No follow-up work.
