# Retrospective: Peer-drop participant lifetime

## Evidence

The participant-loss investigation compared the actual pinned
`src/sessions/p2p_session.rs:2395–2413` against
`peer_drop_barrier.gd:_drive_proposer`. The source retains the attempt's
participant list and aborts on pre-commit loss; the port counted only peers
that were still live. This changes the certificate requirement during an
agreement. The dedicated regression and final delivery results are recorded
in issue #183 and the machine-local session 064 log.

Six-player native tests compare every confirmed state against independent
original-input replay. Interleaved and reversed local ownership exercise
both departed handles. A first-handle-only mutation fails those checks.

## Changes to guidance

Extended the existing networking skill with fixed-participant and before/after
commit checks. No new skill duplicates the agreement guidance. Corrected the
sequence comment and lifecycle guide: the pinned source uses a coordinator-local
sequence, while this Godot tier derives one from target eras. The guide also
separates the Godot timeout fallback from the source's failed-barrier behavior.
Those differences remain named acceptance gaps rather than parity claims.

The browser fixture initially kept servicing the supposedly silent peer during
its teardown wait. Its progress watchdog rejected the run. The corrected fixture
stops rollback servicing while retaining the SDK connection; the resulting
witness is explicitly described as injected endpoint silence. Existing browser
evidence guidance already requires physical-failure claims to match the actual
injected boundary, so no duplicate guidance was added.

## Review and broad checks

Cold review required the receive fence before rejecting an already-gone sender;
a matching buffered coordinator COMMIT must record the known participant loss.
The new coordinator case fails before that reorder and passes afterward.
Browser review required the actual certificate identities/cut/digest rather
than their count, and bounded the corruption diagnostic to frames 8–37.
Fresh reviews of both final boundaries found no actionable findings.

Broad native testing exposed a fixture that replaced its departed peer scalar
on the second departure, then resumed the first departed endpoint. It now
retains all departures and filters both directions. This preserves the original
second-departure scenario rather than weakening the new safety contract.
The first broad integration invocation used 120 seconds for a heavy control
whose CI entry explicitly declares 180. The corrected invocation follows that
existing bound; no watchdog contract changes.

## Outcome

State: `findings-acted`. Keep wire participant certificates, the pinned journal
and unexecuted live fault cases open under #166 and #48.
