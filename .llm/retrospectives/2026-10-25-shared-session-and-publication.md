# Retrospective: shared session notifications and host publication

## Work under review

Session 080 advances client driver #40, replay #45 and spectator relay #131.
It adds host SDK publication and replay failure downloads, and repairs shared
session mutation during completion notifications. New capabilities and the
reproduced callback defect trigger this retrospective.

## Evidence and findings

| Finding | Evidence | Action |
| --- | --- | --- |
| A guard on one driver cannot protect a shared session. | `test_driver_termination.gd` reproduces another driver advancing frame 1 to 2 and expert reconfiguration resetting frame 1 to 0 during notification. | Put the guard on the session; test both facades and first-cause cancellation. |
| A mutation guard cannot double as read eligibility once notifications use it. | Independent review reproduces empty `confirmed_checksums(true)` during notification and one completed checksum immediately afterward. | Preserve completed checksum exports with explicit read eligibility and regression coverage. |
| Optional SDK observations can invalidate the owner before a send. | The host suite's getter-detach control requires zero subsequent SDK sends. | Capture revision before the getter and recheck lifetime before publishing. |
| Same-poll fallback is not independent liveness at the minimum send budget. | Independent review finds one-send polls retrying refused rows forever; refused END also skips the heartbeat branch. | Require fair bounded turns across polls and test both refused ROW and END. |
| A facade can turn a recoverable completion wait into a terminal-looking error. | Automated review identifies `finish_host()` mapping `PREDICTION_STALL` to `PEER_FAILURE`. | Preserve the retryable outer result and test settlement followed by clean END. |
| Historical replay checksums omit the terminal state. | FRRP rows checksum state before each input; completed validation has no terminal SAVE. | Keep historical semantics and track the complete versioned repair in issue #205. |

Regression evidence is machine-local in
[the session log](../../progress/session-080-client-progress.md).
The permanent tests cover the real public API boundaries; reports identify
observed failure state without claiming it passed validation.

## Durable guidance

Updated [rollback fundamentals](../skills/rollback-fundamentals/SKILL.md)
where callback guard ownership already lives. The added rule requires shared
notification protection, alternate-facade tests and completed read-only exports.
Extended the existing transport liveness rule with one-send budget acceptance.
No new skill or duplicate knowledge entry was needed.

## Prune ledger

- Searched existing rollback, testing and transport guidance before writing.
- Extended the existing guard rule instead of creating a second procedure.
- Retained the distinction between transport acceptance and actual delivery.
- Retained reviewed dependency pins and the live spectator qualification limits.
- No existing fact was disproven or retired.

## Verification and limits

Focused driver regression passes on minimum/current engines after review repairs.
Replay tests pass twice on the current engine; the new case passes on minimum.
Native replay download was exercised and the 960×640 failure screen inspected.
Host SDK doubles compare canonical playback and player isolation; they do not
qualify a live exported SignalFish spectator game. Full source-bound native/Web
checks and delivery receipts belong in the session log and linked issues.

## Outcome

State: `findings-acted`.
Follow-ups remain in #40, #45, #131 and terminal-checksum issue #205.
