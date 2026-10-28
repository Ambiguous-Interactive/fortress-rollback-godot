# Retrospective: acknowledgement and host loss

## Work under review

Session 109 addresses replay diagnostics (#45), coordinated drop acknowledgement
loss (#188), and physical selected-host departure for an exported spectator (#245/#131).
The replay change preserves a missing-digest comparison domain and computed row
evidence. The other changes extend executed acceptance without changing wire formats.

## Findings and actions

| Finding | Evidence | Action |
| --- | --- | --- |
| A missing recorded digest is distinct from mismatching complete evidence. | `core/replay_player.gd` previously returned DESYNC before setting comparison metadata; the expanded `test_replay_prefix.gd` matrix fails those diagnostic assertions on the original code. | Preserve `input_digest_missing`, empty expected evidence and owned computed row evidence through callback and expert playback, including paused validation. |
| Sender direction cannot identify the owner of a forwarded certificate. | The pinned-source drop witness forwards COMMITTED participant reports; selecting only follower-to-coordinator traffic initially discarded another participant's certificate. | Select the actual follower participant and extend the existing oracle-validation reference with certificate ownership and retry chronology. |
| Preserved canonical gameplay cannot establish acknowledgement retry liveness. | Disabling committed retries preserves both frozen cuts and twenty canonical boundaries, but the new parser rejects the missing exact ACK retry receipt. | Record emissions, losses and receipts independently; require Godot's repeated COMMIT receipt before its ACK response while retaining the source journal policy. |
| One valid late response can hide an invalid earlier response. | Fresh review inserted an exact premature ACK while retaining the later legitimate retry; the original chronology observer accepted both. | Add a paired valid/invalid retry control and require the earliest delivered ACK after the repeated COMMIT. |
| Physical host loss must be observed before polling can retire buffered viewing. | The exported viewer attempts its driver step before relay polling, checks unchanged canonical state and simulation count, and independently observes the exact selected host UUID. | Extend the existing physical-loss witness and CI matrix; keep the viewer's own socket connected to distinguish remote departure from local teardown. |

## Evidence and review

Commands and raw receipts live in the machine-local `progress/session-109-*.md`
logs and the linked task issues. Replay focused controls pass on both pinned
engines. Browser host-loss controls use actual SDK/server sockets, authenticated
pause coordination and independent canonical histories. The acceptance gates
freeze authored sources and reject concurrent changes before publishing success.
Fresh reviewers receive the scoped diff and acceptance excerpt, without author rationale.
Final delivery evidence belongs in the session log and issues after the gates finish.

## Prune ledger

Updated the existing oracle-validation reference instead of adding another skill.
Removed the now-qualified physical-host-loss restriction from the exported-viewer
scope, retaining exported host/seated transport, replacement and browser-matrix gaps.
Existing comparison-domain and immediate-callback guidance already covers the other
lessons and needs no duplicate rule. No historical evidence or source policy was removed.

## Outcome

State: `findings-acted`. Full source parity and release acceptance remain separately gated.
