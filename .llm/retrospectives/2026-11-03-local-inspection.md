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
Full native and candidate/main CI evidence remains in the session log and linked issues;
these focused results do not establish complete browser or upstream parity.

## Prune ledger

Existing paused-lifecycle and GUI-inventory guidance remains correct and was reused.
No obsolete guidance or duplicate knowledge entry was found. The host-error rule
extends the existing style skill; no new skill or generated discovery entry is needed.
The old offline screenshot is replaced with the current paused controls.

## Outcome

State: findings-acted. Broader #34, #40 and #47 acceptance stays open.
