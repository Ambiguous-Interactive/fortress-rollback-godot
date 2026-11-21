# Retrospective: 2026-11-21 room-departure lifetime fence

## Work Under Review

- Scope: the decision that a live room-roster change ends the frozen
  membership; the `peer-drop-room` exported witness and its
  `peer-drop-room-continue` negative control; the Python and Node validators;
  runner and workflow wiring; docs, CHANGELOG, PLAN and the documentation-count
  check.
- Trigger: #433, the contract follow-up from the coordinated-drop live witness.
- Evidence base: live exported Chromium and headed Firefox runs on both pinned
  engines, an ordinary `peer-drop` regression, `make gate`,
  `make test-reference`, `make test-oracle`, `make lint-source`, the Node and
  Python controls, two fresh-context adversarial rounds, the current-head Gate
  and the feedback scan.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | A real room departure is a membership-seam lifetime end, not an endpoint-silence drop. The survivors receive `player_left`, the adapter latches `restart_required`, and the first harness treated the expected signal as a frozen-membership failure. `CONTINUE` covers only a silent endpoint while the frozen roster holds. | design | `docs/signalfish-membership.md`; `webrtc_setup.gd` `membership_frozen`; the red `peer_drop_room_fence` run |
| 2 | After the fence the adapter has detached the mesh, so the survivor wait must poll only the SDK signaling client; the generic `_service` health check rejects the terminal route. | fact | `webrtc_drop.gd` `_run_room_fence`; final rows `fence_route: restart_required`, `fence_error: 2` |
| 3 | The first continuation control appended `peer_drop_room_continued` unconditionally and discarded the advanced row, so a refused or absent step still passed. A named failure without the mutation's evidence is theater. | review | adversarial round 1, `webrtc_drop.gd` control branch; fixed row `frames_submitted: 8`, `final_frame: 8`, `frames_after_fence: 1`, `continue_code: 0` |
| 4 | The first clean no-continuation evidence hardcoded `7`/`0` and sampled only a window; the re-review showed an already-advanced survivor passed a relative before/after check. Write `fence_frame` into the page when the fence latches and require both samples to be exactly that frame. | review | adversarial round 2, `webrtc.cjs` absolute sample; final rows `final_frame: 7` |
| 5 | The shared `_run` teardown ordering is a contract: the generic path must set `fortressGameplayDone` and then wait for the Node's teardown arm. Moving the wait before the marker would deadlock ordinary drop labels; the room branch had to stay separate. | bug | first `_run` restructure; the ordinary `peer-drop` regression then passed in 11 s |
| 6 | `docs/reference/jobs.md` counts drift when a label is added. The label table, wave planner and prose now have a deterministic test that compares the documented counts with `LABELS`, `ROOM_COUNTS` and `label_waves`. | process | `test_direct_job_counts_documented_in_jobs_md_match_runner_tables` |
| 7 | The repeated OpenAI finding that `events` is undefined was false: it is a class field on `webrtc_drop.gd`. The current head parses and the label passes live on both pins; the threads were answered and resolved. | review | `var events: Array[Dictionary] = []` at line 11; `godot --check-only` exit 0 |
| 8 | A killed process and a committed drop followed by a room event are not separately witnessed. The contract states the expected behavior; the docs and probe limits say so explicitly instead of claiming coverage. | scope | `docs/peer-lifecycle.md`; probe `limits` |
| 9 | The Node and Python control validators must agree exactly: one row, `fence_frame: 7`, `frames_submitted: 8`, `final_frame: 8`, `frames_after_fence: 1`, `continue_code: 0`, integers only. Peers are classified by their failure and `departed` flags, not page index. | review | `isRoomContinueFailure`; `_room_continue_row`; reordered-page tests |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Record that a live room-roster change ends the session and that `CONTINUE` is only endpoint silence. | `docs/signalfish-membership.md`, `docs/peer-lifecycle.md` | docs review |
| 2 | Add the `peer-drop-room` witness and its `peer-drop-room-continue` control. | `webrtc_drop.gd`, `webrtc.cjs`, `webrtc_drop.py` | live Chromium/Firefox on 4.3 and 4.7.2 |
| 3 | Publish the advanced control row inside the failure and require it in both validators. | `webrtc_drop.gd`, `webrtc_drop.py`, `webrtc.cjs` | control rows with the six exact fields |
| 4 | Count real steps and record `final_frame`; write the fence frame into the page and require absolute samples. | `webrtc_drop.gd`, `webrtc.cjs` | final survivor rows `frames_submitted: 7`, `final_frame: 7` |
| 5 | Wire both labels through `LABELS`, the launcher, `PEAK_PLAYERS`/`ROOM_COUNTS`, owned logs and both workflow lists. | `signalfish_webrtc_probe.py`, `webrtc_runner.py`, `webrtc.cjs`, both workflows | `test_signalfish_webrtc_probe` 25 tests |
| 6 | Bind the direct-job counts in `docs/reference/jobs.md` to the runner tables. | `test_signalfish_webrtc_probe.py` | 25 tests pass |
| 7 | Record the terminal-fence and teardown-order facts. | `.llm/knowledge/transport-tooling.md` | two rows with session evidence |

## Prune Ledger

- Retired / merged / fixed at source: `PLAN.md` now says the room/process
  lifetime fence is recorded and leaves only pinned-source comparison and the
  remaining schedules; #433 is closed by this session. The probe's `limits`
  text names the room label and states the process-death and drop-then-room
  limits. The temporary `ROOM_CHECK` diagnostic was removed; `ROOM_FENCE`
  remains as the single fence line.
- Verify-on-touch: `make gate`, `make test-reference`, `make test-oracle`,
  `make lint-source`, the Chromium and Firefox `peer-drop-room` and
  `peer-drop-room-continue` labels, and an ordinary `peer-drop` regression.

## Outcome

- State: `findings-acted`
- Follow-ups: #166 keeps the pinned-source comparison and the remaining
  boundary schedules; #188 keeps unequal confirmation frontiers. A future
  process-kill label or a drop-then-room ordering label is separate work, not
  a claim of this witness.
