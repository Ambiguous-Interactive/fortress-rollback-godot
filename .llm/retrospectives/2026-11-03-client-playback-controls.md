# Client and playback controls

## Scope and evidence

The session advances client controls (#40), replay inspection (#45), and
spectator playback (#47). The peer example gains pointer actions sharing its
keyboard gates. Replay navigation can isolate one player's control/status
changes. Spectator host single-step keeps viewer policy independent.
Original parity and release acceptance remains open.

The peer investigation reproduced a real ownership omission: keyboard fault
handlers directly changed packet policy during completion callbacks. The
baseline probe changes loss from zero to seven; the guarded implementation
preserves zero while the outer step succeeds. Evidence:
`progress/session-149-peer-keyboard-baseline.log` and
`progress/session-149-peer-keyboard-fixed.log`. The new scene-control suite
covers callbacks, completion notifications, expert batches and reset.
No historically correct revision is known for this scene omission.

Capability controls fail before the new features, without engine errors:
`progress/session-149-replay-filter-red-direct.log` and
`progress/session-149-host-step-red.log`. Ordinary unfiltered navigation and
continuous host playback supply the positive controls. Both pins pass the
focused peer and spectator inventories; the new host case compares original
canonical state through prediction stalls, rollback and the exact clean tail.

The first live GUI run exposed two incorrect probe assumptions. Reset preserves
selected fault policy, and a preceding action can move a button before its next
pointer release. The narrow spectator experiment observes the Step host center
move from (299.871,345.3333) to (298.5841,355.2655). Waiting for layout before
measuring the next target fixes the click. See
`progress/session149-host-pointer.log` and `.cache/session149-gui-first.log`.
The repaired live probe passes exactly 237 checks with no engine errors in
`.cache/session149-gui-second.log`.

CI then exposed a missed consumer: the suites job passed the complete GUI
probe with 237 checks, but the workflow still required its old 210-check marker.
Run 41706160728, jobs 126161925238 and 126161925277, identify the failure after
`FORTRESS_REPLAY_NAVIGATION_OK 237`. The source sweep found the sole remaining
old marker at `.github/workflows/reference-baseline.yml:258`. Its exact match
now requires 237. The original grep fails against the successful local GUI log;
the updated grep passes. Full native qualification was interrupted deliberately
(exit130) before editing this source; its old receipt is not qualification.

## Harvest and actions

| Finding | Action |
| --- | --- |
| Keyboard fault assignments lacked the composed mutation gate. | Route pointer and keyboard actions through one guarded handler; add real callback and expert regressions. |
| Consecutive pointer actions measured a target before prior layout settled. | Extend the existing browser integration testing guidance with this measured timing boundary. |
| Probe inventory changes also alter CI marker consumers. | Update the exact workflow marker and extend the existing inventory-alignment guidance. |
| Reset intentionally retains selected fault policy. | Correct the live probe; preserve the documented product contract. |

No separate runner, skill or simulation algorithm was added. Existing GUI focus,
shared-operation ownership and source-freeze guidance remains applicable.
No conflicting or obsolete entry was found to retire. The specific pointer
layout rule extends its existing canonical guidance rather than duplicating it.

## Verification and limits

Reproduce the direct feature selections through `tests/runner/run_tests.gd`
with suites `test_peer_scene_controls.gd`, `test_replay_input_navigation.gd`,
and `test_spectator_host_step.gd`. Run the GUI witness through
`scripts/reference/replay_navigation_probe.gd` under a graphical display.
Screenshots: [peer](../../docs/images/session149-peer-after.png),
[replay](../../docs/images/session149-replay.png), and
[spectator](../../docs/images/session149-spectator.png).

Frozen-source full native, browser, final fresh reviews and delivery gates
remain pending at artifact authoring. Final evidence belongs in the ignored
session log and linked issues. No format, source pin or release claim changes.

Retro: findings-acted
