# Retrospective: 2026-11-01 browser recovery

## Work Under Review

Session 133 repairs browser replay import ownership and extends actual-browser
spectator admission, relay survivor agreement and recording pressure evidence.
The trigger is a reproduced user-flow defect plus new integration acceptance cells.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Native import guards did not protect asynchronous browser completion. | `examples/online/replay_scene.gd` guarded `_native_file` but not `_web_file`; the new `dropped_file` completion matrix fails main at recording length, frame and canonical state. | Apply the same drag/busy guard before success or error handling; extend the existing browser testing procedure. |
| A stale local server build receipt can name the wrong source pin. | The default local build named `9c2fb8f`; current launcher requires `8cbf5d9`. The source-bound launcher refuses it; corrected runs use the verified current build. | Preserve the existing identity gate and correct the invocation; do not relax tool validation or rebuild without evidence. |
| The new pressure label lacked room-budget regression coverage. | Automatic review found the omission in `test_signalfish_webrtc_probe.py`; selecting three rooms fails at 1,500 versus 540 seconds after adding its data row. | Extend the existing label table; preserve the launcher and every watchdog duration. |

## Verification

The replay viewer's ten cases pass twice on Godot 4.7.2. The minimum engine
passes those cases plus all eight replay-speed cases, also twice.
Healthy idle browser import and refused native drops remain controls. No earlier
known-good revision is claimed for the browser omission.
Session receipts and full delivery evidence live in the local session 133 log;
current-head CI supplies the final candidate-wide verification.

## Prune Ledger

The existing browser/network integration testing reference already owns held
control tests. One sentence extends it to file-read completion; no new skill.
Existing infrastructure guidance already requires source-pinned tools, so it
needs no duplicate warning. No guidance was proved obsolete.
`make prune` reports 2.30 GB of pre-existing reclaimable entries; no new build
or full-worktree copy was needed for this session.

## Outcome

State: `findings-acted`.
Broader source recording recovery, exported spectator host gameplay and remaining
physical room/process departure cases stay with their existing open issues.
