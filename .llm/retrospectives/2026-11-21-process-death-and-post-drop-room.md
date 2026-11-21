# Retrospective: 2026-11-21 process death and post-drop room fence

## Work Under Review

- Scope: the `peer-drop-process` and `peer-drop-room-after-drop` exported
  witnesses; the `peer-drop-process-missing` and `peer-drop-room-before-drop`
  controls; the Node, GDScript and Python evidence paths; runner, workflow,
  owned-log and probe-limit wiring; docs, CHANGELOG and PLAN.
- Trigger: #436, the remaining orderings from the coordinated-drop live
  witness.
- Evidence base: exported Chromium and headed Firefox runs on 4.3 and 4.7.2,
  `peer-drop` and `peer-drop-room` regressions, `make gate`,
  `make test-reference`, `make test-oracle`, `make lint-source`, the Node and
  Python unit suites, the current-head Gate and the feedback scan.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | A process death is a server-announced membership event like an explicit leave, but the departing page cannot publish evidence after its context closes. Read the UUID in the Node harness before the close and collect only the two survivor rows; a departed row would prove the harness had not actually killed the page. | design | `webrtc.cjs` `evidencePages = pages.slice(0, 2)`; real rows `fence_frame: 7`, `player_left_events: [departed]`, no third row |
| 2 | A post-drop room event must keep the normal drop row intact and add the fence fields; the follower is committed with `certified: false` because only the coordinator carries the certificate. Requiring `certified` on both survivors failed the follower before it published `fortressDropComplete`. | bug | first `peer-drop-room-after-drop` run: survivor 1 `peer_drop_room_after_drop_uncertified`; final rows `freeze_frame: 6`, `frozen_value: 67`, 38 canonical prefixes, fence at 40 |
| 3 | Browser `SceneTree` timers are frame-bound, so `3000 x 2 ms` is about 50 s at 60 Hz, not 6 s. The missing-event control outlived the Node deadline until the fence wait used a wall-clock ten-second bound. | bug | first control run timed out the Node's 30 s wait; final control passes in 15 s |
| 4 | Withholding the room event is not just "do nothing": when the departing page stops polling, the server announces its closed socket at the 4 s gate timeout and manufactures the `player_left` the control exists to withhold. The departing page must keep polling its signaling client and the Node must release it only after both survivor fence waits fail. | design | first two control runs both fenced; `_wait_gate_keepalive` + `fortressDropRoomGiveUp` |
| 5 | A room event before the drop commit must park the survivors before the barrier can commit: service the peer until `peer_drop_pending`, then poll only the signaling client. The final rows record `barrier_state: pending`, `barrier_certified: false`, `barrier_value: ''`, `freeze_frame: -1`, 6 unchanged canonical prefixes and no drop event. | design | `_run_pending_room_fence`; real `peer-drop-room-before-drop` rows |
| 6 | The process-death identity must come from the harness, not a survivor. The Python validator requires `departedUuid` on the run record, a UUID, and that it matches the frozen roster slot; a missing or forged field is rejected before any survivor row is trusted. | review | `_validate_process_evidence`; mutation tests |
| 7 | A control that reports `peer_drop_room_gate` is not a fence failure. Classify the two survivor waits and the departing gate separately by `local_index`, and require empty control records so an unrelated failure cannot pass as the withheld event. | review | `_validate_process_missing`; 11 mutations |
| 8 | The room-departure docs and probe limits still claimed process death and the post-drop ordering were not witnessed. Leaving that text after adding the labels would make the limits lie in the other direction. | process | `docs/peer-lifecycle.md`, `docs/signalfish-membership.md`, probe `limits` |
| 9 | The process witness could pass without the context close causing the departure: page 2's own 4 s gate timeout closes its socket, and the survivors then fence on that manufactured event. A Node sentinel immediately before the close must prove `fortressWebrtc` and `fortressTeardownArmed` are unset, `fortressDropGo` is false and the page is still at frame 6; the page holds for 120 s instead of the ordinary gate. | review | adversarial round 1 finding 1; `processHeld` record and Python check |
| 10 | The missing-event control had the same hole on its 30 s hold: a timeout would close the page's socket and manufacture the event. Give-up and timeout need distinct codes, and the departing failure must carry the hold duration and the departed UUID so the validators can tell a Node release from a timeout. | review | adversarial round 1 finding 2; `peer_drop_room_gate` vs `peer_drop_room_gate_timeout`, `hold_ms`, `uuid` |
| 11 | The new room rows wrote `final_frame` and `frames_after_fence` as literals, so the Node's 500 ms sample re-read a stale dataset and could not fail. Measure the post-fence frame over a wall-clock window, exactly like the plain room path. | review | adversarial round 1 finding 3; `_measure_post_fence` |
| 12 | The Node and Python process-missing validators disagreed on identity: Node ignored `local_index`, Python ignored `stage`, and Python did not require the departure UUID. Both must check the same tuple. Derive the after-drop barrier fields from the retained barrier instead of literals. | review | adversarial round 1 findings 4-5 |
| 13 | The before-drop control parks the barrier after its pending event, so it proves the pending fence and unchanged history, not a live commit race. That is the deterministic realization of the requested pre-commit ordering; state the limit rather than claim a race the harness does not run. | review | adversarial round 1 finding 7; docs/probe limits |
| 14 | The pre-close sentinel checked only DOM markers; a page that had already recorded a connection failure or lost its room still passed. The hold must check the live signaling client every iteration and publish its health (`connected`, `authenticated`, room code, errors) for the Node and Python validators. | review | adversarial round 2 finding A; live `processHeld` `healthy: true, room: 28SMZR, errors: 0` |
| 15 | The Python frame-sum formula ran before the `frames_after_fence` type check, so a missing or non-integer field raised `KeyError`/`TypeError` instead of the named rejection. Survivor failure UUIDs were also unbound, and the room-leave wait disagreed with the Node's 30 s deadline. | review | adversarial round 2 findings B-D; `survivorUuids`, reordered checks, 30 s leave wait |
| 16 | `fortressDropProcess` had no unit test; deleting the flag would silently restore the old 4 s gate. The after-drop marker wait could also hang 120 s on a page that had already failed. Pin the flag wiring and race the marker with a published failure. | review | adversarial round 2 findings E-F; Node `process death routes...` test, failure-aware 30 s markers |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Add the process-death witness and close the departing context after the Node reads its identity. | `webrtc.cjs`, `webrtc_drop.gd`, `webrtc_drop.py` | live Chromium/Firefox on 4.3 and 4.7.2 |
| 2 | Add the post-drop room witness with the certified freeze, frozen value, 38-prefix canonical history and terminal fence in one survivor row. | `webrtc_drop.gd`, `webrtc_drop.py` | survivor rows `freeze_frame: 6`, `frozen_value: 67`, `canonical_comparisons: 38`, `fence_frame: 40` |
| 3 | Add the withheld-event and pre-commit-order controls. | `webrtc.cjs`, `webrtc_drop.gd`, `webrtc_drop.py` | live 4.3/4.7.2 Chromium and Firefox, Python mutation tables |
| 4 | Replace iteration-count fence waits with wall-clock bounds and state the ten-second server-notice window. | `webrtc_drop.gd`, probe `limits`, docs | missing control passes in 15 s |
| 5 | Wire every label through `LABELS`, `PEAK_PLAYERS`, `ROOM_COUNTS`, owned logs and both workflow label lists. | probe, runner, workflows | `test_signalfish_webrtc_probe` 40 tests; documented counts 20 labels/24 rooms/11 waves |
| 6 | Extend the Node and Python controls and tests. | `webrtc_instrument.test.cjs`, `test_webrtc_drop.py` | Node 207 tests; Python 40 tests |
| 7 | Update the limits and lifetime docs and record the timer/keepalive facts. | docs, `.llm/knowledge/transport-tooling.md` | docs review, `make lint-llm` |
| 8 | Add the pre-close departing-page sentinel and the 120 s process hold. | `webrtc.cjs`, `webrtc_drop.gd`, `webrtc_drop.py` | `processHeld` sentinel in every process run |
| 9 | Split the missing-event give-up from the timeout and record the hold duration and UUID. | `webrtc_drop.gd`, `webrtc_drop.py`, Node helper | control row `hold_ms: 10067`, `uuid: departed` |
| 10 | Measure the post-fence frame over a real window and derive the retained barrier fields. | `webrtc_drop.gd` | rows `final_frame: 40/7`, `frames_after_fence: 0`, `barrier_committed: true` |
| 11 | Align the Node and Python failure tuples and add every mutation. | `webrtc.cjs`, `webrtc_drop.py`, both test suites | Node 207 tests; Python 40 tests |
| 12 | Check the live signaling client during the process hold and publish its health for the pre-close sentinel. | `webrtc_drop.gd`, `webrtc.cjs`, `webrtc_drop.py` | live `processHeld` `healthy/connected/authenticated/errors`; Python 40 tests |
| 13 | Bind the missing control's survivor UUIDs and reorder the frame formula after its type checks. | `webrtc.cjs`, `webrtc_drop.py` | `survivorUuids`; mutation tables |
| 14 | Pin the process flag wiring and make the marker waits failure-aware. | `webrtc_instrument.test.cjs`, `webrtc.cjs` | Node 208 tests |

## Prune Ledger

- Retired / merged / fixed at source: the docs and probe limits no longer say
  process death and the drop-then-room ordering are unwitnessed; PLAN's
  coordinated-drop row now names the live drop, room and process fence. #436
  is closed by this session. The shared `_wait_membership_fence` and
  `_live_roster` helpers carry the mechanical fence work, and the Node
  `evidencePages` selection keeps the process-death path on the same teardown
  and collection code instead of a second launcher. The three row builders stay
  separate because each row is the evidence contract for a different ordering;
  a shared builder would hide which fields that witness promises.
- Verify-on-touch: `make gate`, `make test-reference`, `make test-oracle`,
  `make lint-source`, the new labels on both pins and both browsers, and the
  `peer-drop`/`peer-drop-room` regressions.

## Outcome

- State: `findings-acted`
- Follow-ups: #166 keeps the pinned-source comparison and remaining boundary
  schedules; #188 keeps unequal confirmation frontiers.