# Retrospective: 2026-11-21 rollback-time browser departure

## Work Under Review

- Scope: the exported `peer-drop-rollback` witness, its launcher ordering,
  validator, negative controls, workflow wiring, docs and CHANGELOG.
- Trigger: the remaining live coordinated-drop case named in #166: a departure
  while a survivor has a real correction pending.
- Evidence base: live Chromium and Firefox runs on both engine pins, the
  reference tooling suite, `make gate`, `make lint-source`, and the
  fresh-context adversarial review.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | The first live shape asserted `pending_at_detection > cut`, but both survivors recorded `pending=7 cut=7`: confirmation had advanced to the frame the correction named. The strict assertion rejected a valid departure during an armed correction. | rule | First live run log: `ROLLBACK_DETECTION pending=7 cut=7 confirmed=7 current=8`; final runs pass with the at-or-above contract |
| 2 | The departing page's normal `DropGo` wait serviced its endpoint, so its frame-seven step could carry receipts for the survivors' frame seven and advance confirmation. The shape also allowed the actual input to arrive before a survivor predicted it, erasing the pending correction. | bug | First launcher shape; the final shape steps the departing page first, holds its outbox, lets both survivors predict, then delivers |
| 3 | `prediction_gap >= 1` silently failed the rollback label when the cut reached the current frame (`8 - 7 - 1 = 0`), with no error appended. | bug | Second live run: `passed: false`, empty `errors`, stage `peer_drop_agreement`; rollback now allows a zero gap |
| 4 | The validator's `freeze_frame <= 6` range rejected the legal cut at frame seven. | bug | Third live run: `ValueError: peer-drop frozen boundary or confirmation invalid`; rollback now allows cuts six or seven |
| 5 | The first validator test fixture only covered the above-cut shape; the at-cut shape was added by parameterizing the fixture's freeze frame. | coverage | `evidence(freeze=6)` and `evidence(freeze=7)` positive cases |
| 6 | A new `peer-drop` label could be added to `LABELS`, the room tables and the workflows but omitted from the JS launcher's `peerDrop` list, where it would run as an ordinary 2/4/8 room set. | check | New `test_browser_launcher_routes_every_peer_drop_label` |
| 7 | The workflow label-list test read only one physical line, so wrapping the now 13-label list across two lines would hide the new label. | test | `test_direct_label_lists_bind_the_runner_tables` now reads to the closing parenthesis |
| 8 | The nightly Firefox `clean` setup failed on `0787956` before gameplay because `xdotool search --sync` exceeded its 2 s bound while placing the first owned window. | infra | `4.3-clean.log`: `spawnSync /usr/bin/xdotool ETIMEDOUT` in `webrtc_display.cjs` `placeFirefox`; follow-up #431 |
| 9 | The label is wired into the nightly Firefox list, and the final source passes the headed Firefox pair on both pins; this closes the wiring concern the second-departure session could not run locally. | evidence | `4.3` and `4.7.2` Firefox receipts, 11 s each |
| 10 | A validator test named the above-cut shape after the contract moved to at-or-above. | copy | Renamed to `..._at_or_above_the_cut` in the same change |
| 11 | OpenAI review read the release gate as a deadlock: it waited for a pending marker that the survivors published only inside their drop wait. The marker was written before the dropped check, and six live runs passed, but the sequence let the reader infer a cycle. | review | PR #432 thread `4650568629`; the fix publishes the pending marker in its own wait before the drop wait, and both pins passed again |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Accept a pending correction at or above the agreed cut and pin `pending_at_detection == 7` with `freeze_frame` in six/seven. | `webrtc_drop.gd`, `webrtc_drop.py` | four live Chromium and Firefox receipts |
| 2 | Step the departing page first, hold its outbox, release both survivors' prediction, then deliver and stop. | `webrtc_drop.gd`, `webrtc.cjs` | both survivors report `pending_at_detection: 7` |
| 3 | Allow a zero prediction gap only for the rollback label. | `webrtc_drop.gd`, `webrtc_drop.py` | live rows `prediction_gap: 0` |
| 4 | Allow freeze frames six and seven only for the rollback label. | `webrtc_drop.py` | at-cut and above-cut tests |
| 5 | Parameterize the fixture freeze and add both positive shapes. | `test_webrtc_drop.py` | 33 reference tests pass |
| 6 | Pin the JS launcher's peer-drop list to `LABELS`. | `test_signalfish_webrtc_probe.py` | 33 reference tests pass |
| 7 | Read the complete workflow array across line breaks. | `test_signalfish_webrtc_probe.py` | 33 reference tests pass |
| 8 | Open #431 with the nightly artifact evidence and a bounded-retry acceptance test. | issue #431 | issue body |
| 9 | Run the headed Firefox pair on both pins. | receipts | `4.3` and `4.7.2` pass |
| 10 | Rename the test to match the contract. | `test_webrtc_drop.py` | test name |
| 11 | Publish the pending marker in a dedicated wait before the drop wait; reply with the sequence and live receipts. | `webrtc_drop.gd` | both pins pass after the change |

## Prune Ledger

- Retired / merged / fixed at source: the docs now name the rollback case as
  covered and remove it from the remaining #166 list; `docs/reference/jobs.md`
  counts thirteen direct labels and seventeen rooms.
- Verify-on-touch: `make gate`, `make test-reference`, the Chromium and Firefox
  `peer-drop-rollback` labels, and the `test_webrtc_drop` +
  `test_signalfish_webrtc_probe` suite.

## Outcome

- State: `findings-acted`
- Follow-ups: room departure, process death and foreign proposals remain in
  #166; the Firefox window-placement flake is #431.
