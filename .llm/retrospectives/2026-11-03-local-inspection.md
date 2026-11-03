# Retrospective: local inspection and host failure feedback

## Work under review

Add paused offline and two-peer inspection, and preserve spectator host failure evidence.
The new controls use ordinary drivers and packet service, including prediction stalls.
Trigger: new capabilities, more than 300 changed lines, and a callback-reporting defect.

## Evidence and findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Forwarding a host error to the viewer preserves its code but loses callback context. | `test_spectator_host_step.gd::host_failure_feedback` fails on main at the result and originating report assertions, with no engine errors. | Keep host callback/frame evidence visible; extend GDScript guidance at its existing error-handling home. |
| Paused scenes still need ownership and lifecycle refresh. | Offline ownership and peer inspection cases exercise held expert work and external termination without simulation service. | Apply the existing guidance; no duplicate rule. |
| Layout and input routing require a live tree. | Deferred navigation probe passes 255 checks on Godot 4.3 and 4.7.2, including clicks, keys and two viewport sizes. | Wrap offline instructions and keep the CI inventory marker aligned. |

The healthy host-step control passes before and after the repair. No historically
correct version of the longstanding host-report omission was identified.
New capability controls fail on main at their explicit missing-control assertions.
Focused candidate suites pass nine cases with repeated fresh processes.
Full native and candidate/main CI checks remain pending at this writing.
The session log and linked issues retain their later results. These focused
results do not establish complete browser or upstream parity.

## Prune ledger

Existing paused-lifecycle and GUI-inventory guidance remains correct and was reused.
No obsolete guidance or duplicate knowledge entry was found. The host-error rule
extends the existing style skill; no new skill or generated discovery entry is needed.
The old offline screenshot is replaced with the current paused controls.

## Verification correction

CI's existing scene-exit ownership test exposed a result-code regression:
the new offline readiness preflight displayed waiting but left `_code` at OK.
The same `active_batches` probe passes against main's offline scene, fails the
initial candidate at exactly the expected BUSY assertions, and passes after
restoring explicit BUSY observation before the service gate. The new paused
ownership case now checks this result too. Shared integration/spectator loops
already preserve BUSY; no test expectation was weakened. The initial full
native run was canceled with exit 130 and is not qualification evidence.

## Outcome

State: findings-acted. Broader #34, #40 and #47 acceptance stays open.


## Terminal preflight forwarding

Automatic review identified a host-step preflight exit that terminated the host
without retiring the viewer. The new scene failure latch made that omission
persistent. Frame and request-counter exhaustion controls reproduced active
buffered playback after host termination, with no engine errors. The repair
forwards terminal preflight results in the shared spectator demo and preserves
a previously stopped host's first cause through both tick entry points.
Existing nonterminal input/ownership refusals remain retryable, and clean endings
retain final-tail service. This applies the existing wrapper terminal-preflight
guidance; no additional overlapping rule was added.
The related scene-service assertions now require the original `PROTOCOL_FAILED`
cause in scene, viewer and result state, replacing the old generic `TERMINATED`
expectation. The focused host, viewer and recording suites pass with that stronger
contract; fresh adversarial review finds no remaining preflight issue.


Callback-request completion can also return generic `TERMINATED` after the game
explicitly terminates its host with another reason. Table controls cover SAVE,
LOAD and ADVANCE through ordinary and single-step service, with a healthy or
previously failed viewer. The red case loses the original host cause, with no
engine errors. Both host-operation boundaries now normalize from retained host
status, matching the existing viewer-result pattern. The existing style rule
now names the first terminal cause as well as callback/frame provenance.
