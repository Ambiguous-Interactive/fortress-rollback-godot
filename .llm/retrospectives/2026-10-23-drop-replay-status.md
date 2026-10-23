# Retrospective: Drop deadlines and replay player status

## Work under review

Session 065 addresses integration-guide discovery, coordinated-drop expiry,
and replay integrity after a dropped slot. Trigger: production debugging and a format extension.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Pending control could commit at an expired deadline. | `test_peer_drop_commit.gd` rejects COMMIT at equality and one microsecond after; the old guard failed six assertions. | Check expiry before dispatch; preserve committed duplicate acknowledgements. |
| Byte-only replay loses disconnect semantics. | `test_peer_drop.gd` exported row reported status 1 instead of 3 after drop. | Format 5 records statuses in each row digest; format 4 retains explicit all-confirmed defaults. |
| Receipt-only staging is provisional, even when all samples are actual. | `test_replay_drop.gd` holds mesh confirmation behind receipt progress, freezes the tail, then compares independent status-sensitive canonical states. | Export only finalized prefixes; rewrite staged rows and remove stale checksum coverage. |
| Equal predicted bytes can still require drop correction. | The predicted-tail control reported no pending rollback, wrong live state and replay DESYNC. | Both queue freeze APIs inspect requested simulation progress as well as actual receipt. |
| Online download verification kept its old format tuple despite the core/golden upgrade. | Candidate browser jobs on both pins rejected version 5; updating only their synthetic packing fixtures reproduced four verifier errors locally. | Update the independent verifier and add status rejection cases; record the format-consumer sweep in the transport skill. |
| Hosted package downloads can consume the outer verification budget. | Ownership setup fetched25.9MB in9m18s, leaving5m08s before its15-minute timeout. A Java apt step spent over17 minutes downloading on another runner. | Preserve internal probe deadlines, reserve30 minutes outside them, and verify/reuse hosted Java17 while retaining apt fallback and receipt provenance. |

## Curation and pruning

Updated the existing rollback skill with status-sensitive drop correction and private replay staging.
Corrected the recorder's stale receipt-finality comment at its source.
No duplicate knowledge file or new skill was needed. Existing feature claims now link the actual API boundaries.
The spectator byte-only status gap remains explicit in issue #187 and its owning guide.

## Verification

Red and green receipts live in the machine-local session log. Focused tests repeat
in fresh processes and within each process on both native pins. Independent Python
fixtures cover versions 4 and 5, and the pinned replay oracle exercises version 5.
Source and harness lint, tooling tests, review, candidate CI and merged-main CI are delivery gates.
The session log records their terminal evidence rather than assuming completion here.

## Outcome

State: findings-acted. Remaining spectator status transport is tracked separately;
full wire-participant/journal parity and live drop fault acceptance remain in their owning issues.
