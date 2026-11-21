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

## Prune Ledger

- Retired / merged / fixed at source: `PLAN.md` drops the completed live
  missing-history and second-departure items; `docs/reference/jobs.md` now
  counts twelve direct labels and seven waves. No new knowledge topic file.
- Verify-on-touch: `make gate`, `make test-reference`,
  `python3 -m unittest test_webrtc_drop test_signalfish_webrtc_probe`.

## Outcome

- State: `findings-acted`
- Follow-ups: room departure, process death, rollback-time departure and
  foreign proposals remain in #166; the Firefox axis is wired into nightly and
  was not run locally.
