# Retrospective: 2026-11-21 second browser departure

## Work Under Review

- Scope: the exported `peer-drop-second` witness, its validator and negative
  controls, the direct-label wiring check, the goal evidence contract, docs,
  changelog, plan and knowledge note.
- Trigger: a live coordinated-drop case named in #166 plus a goal contract
  refinement carried from the previous session.
- Evidence base: the first live Chromium run that stalled, the clean
  two-engine Chromium run, `make gate`, `make test-reference`,
  `make lint-source`, and the external and adversarial reviews.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | A "departed" browser page that keeps polling its endpoint never looks departed: the survivor resets `last_recv_us` on any received packet, so the default 2 s disconnect timer never fires. The first live run left the survivor in `peer_drop_second_departure` with frame 11 unchanged for 20 s. | fact | [Session 214](../../progress/session-214-second-browser-departure.md); `endpoint_lifecycle.gd` `received()`; first run log and the 20 s watchdog diagnostic |
| 2 | The inherited witness never enabled the second-departure validator for the new label, so the run would have been checked as an ordinary one-departure witness and rejected its own records. | bug | `signalfish_webrtc_probe.py` `validate_drop_browser` call; the label now passes `second_departure=label == 'peer-drop-second'` |
| 3 | The last survivor's row recorded `active_comparisons: 2` because it was built before the second continuation loop, hiding 28 comparisons. The exact gate (`== 30`) now fails that shape. | bug | First clean run row; validator test mutation `active_comparisons=29` |
| 4 | A new label was added to `LABELS`, `ROOM_COUNTS` and `PEAK_PLAYERS` but not to either workflow's direct label list, so CI would never run it. | harness | `reference-baseline.yml`, `nightly.yml`; new `test_direct_label_lists_bind_the_runner_tables` |
| 5 | The validator accepted `True` for `departure_sequence` and `drop_events` because `True == 1`; a bool is not the int the witness records. | bug | Negative controls for both fields |
| 6 | The external review found the second-departure branch did not name the first departing identity before its early `continue`, leaving the identity check implicit in later general checks. | rule | OpenAI review thread `4650010223`; `_departing_row` now binds uuid, slot and roster before continuing |
| 7 | Editing tracked reference sources while a witness run is in flight invalidates its source-inventory check even when every label passed. | process | The first two-engine run ended with `source or tool inventory changed during execution`; the clean rerun passed |
| 8 | The last survivor's branch required its publication count and active comparisons but not its canonical comparison count, so a row with `canonical_comparisons: 0` still validated. | bug | OpenAI review thread `4650088163`; the `canonical_comparisons=0` negative control |
| 9 | The witness counted `peer_dropped` events but never checked their `frame`, so a core that published the current frame instead of the agreed cut passed. | bug | Adversarial finding 1; `drop_frames` now binds each departing identity to its published frame |
| 10 | The docs called the second departure a "new operation", but a lone survivor takes the last-survivor path, which opens no barrier and publishes no pending event. | rule | Adversarial finding 2; `peer_drop_barrier.gd` last-survivor branch; docs and changelog now say one-member freeze |
| 11 | The first operation's closure was unproven: the proposer row did not export whether the departing follower's commit acknowledgement arrived, so a fast second departure could pass while the first operation was still open. | bug | Adversarial finding 3; live rows show the proposer's `acknowledged_peers` holding the participant before the second departure |
| 12 | The label exercises one second-departure frame (12 inputs); the earliest post-commit and last-tick departures are unrepresented. | coverage | Adversarial finding 4; recorded as a named gap in #166 |
| 13 | The last survivor's `frames_submitted` and `departed` were not validated in second mode, so `frames_submitted: 0` or `departed: 'yes'` passed. | bug | Adversarial finding 5; required fields and negative controls |
| 14 | A malformed peer-1 payload raised `KeyError`/`TypeError` from the cross-check instead of the validator's `ValueError` contract. | bug | Adversarial finding 6; shape checks and the cross-check after the per-peer loop |
| 15 | The first departed row could be retargeted to another valid roster slot while the survivors still named the original slot. | bug | OpenAI review thread `4650187826`; slot/UUID tie and negative control |
| 16 | Integer zero passed the last survivor's `departed: False` expectation because the type guard covered only integer expectations. | bug | OpenAI review thread `4650187829`; bool identity guard and negative control |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Stop endpoint service on both departing pages and let them wait on the non-polling teardown check. | `signalfish_webrtc_probe.gd` | both `peer-drop-second` labels pass in 15 s |
| 2 | Pass the second-departure flag from the launcher and record the departing identities. | `signalfish_webrtc_probe.py`, `webrtc_drop.gd` | clean two-engine run |
| 3 | Set `active_comparisons` after the continuation loop and require exactly 30. | `webrtc_drop.gd`, `webrtc_drop.py` | live rows and the new mutation |
| 4 | Pin both workflow direct-label lists to the runner tables. | `test_signalfish_webrtc_probe.py` | test fails when a label is removed |
| 5 | Require ints for the sequence and event counts. | `webrtc_drop.py` | negative controls |
| 6 | Bind uuid, slot and roster in `_departing_row` for both departed pages. | `webrtc_drop.py` | negative controls |
| 7 | Record the silence rule and the mid-run inventory rule. | `.llm/knowledge/transport-tooling.md`, this retro | knowledge note |
| 8 | Require the survivor's 38 canonical comparisons as well as the 30 active ones. | `webrtc_drop.py`, `test_webrtc_drop.py` | negative control |
| 9 | Export each publication's peer and frame, require the first pending publication and both published frames. | `webrtc_drop.gd`, `webrtc_drop.py` | live rows and negative controls |
| 10 | Describe the one-member freeze instead of a second operation. | `docs/peer-lifecycle.md`, `CHANGELOG.md` | review of the wording against `peer_drop_barrier.gd` |
| 11 | Export commit acknowledgement peers and require the proposer saw the participant before the second departure. | `webrtc_drop.gd`, `webrtc_drop.py` | live rows show `acknowledged_peers` with the participant on both pins |
| 12 | Keep the single schedule as an explicit gap instead of claiming boundary coverage. | #166 comment | named follow-up |
| 13 | Require the survivor's 40 submitted frames and `departed: False`. | `webrtc_drop.py` | negative controls |
| 14 | Type-check each peer's `result` and `rtc`, and resolve the second-departure cross-check after the loop. | `webrtc_drop.py` | negative controls for a missing `records`, a null `result` and a null `rtc` |
| 15 | Tie the first departed row's slot and UUID to the survivors' departing slot. | `webrtc_drop.py`, `test_webrtc_drop.py` | retargeted-row negative control |
| 16 | Require a real bool for boolean expectations. | `webrtc_drop.py`, `test_webrtc_drop.py` | integer-zero negative control |

## Prune Ledger

- Retired / merged / fixed at source: `PLAN.md` drops the completed live
  missing-history and second-departure items; `docs/reference/jobs.md` now
  counts twelve direct labels and seven waves. No new knowledge topic file.
- Verify-on-touch: `make gate`, `make test-reference`,
  `python3 -m unittest test_webrtc_drop test_signalfish_webrtc_probe`.

## Outcome

- State: `findings-acted`
- Follow-ups: room departure, process death, rollback-time departure, foreign
  proposals and the earliest/last-tick second-departure schedules remain in
  #166; the Firefox axis is wired into nightly and was not run locally.
