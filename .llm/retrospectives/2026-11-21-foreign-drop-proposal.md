# Retrospective: 2026-11-21 foreign drop proposal and Firefox placement

## Work Under Review

- Scope: the exported `peer-drop-foreign` witness, its barrier counter, validator,
  negative controls, runner/workflow wiring, docs, CHANGELOG, the bounded
  Firefox first-window retry from #431, the follow-up contract issue and the
  knowledge notes.
- Trigger: the remaining #166 live cases (foreign proposal, room departure,
  process death) and the nightly Firefox placement failure tracked as #431.
- Evidence base: two live exported Chromium runs on the pinned engines, the
  adjacent live drop labels, the Firefox `clean` label on a normal and a
  two-CPU-pinned display, `make gate`, `make test-reference`,
  `make lint-source`, the Node and Python controls, and the feedback scan.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | A real room departure closes the SDK socket; the survivors receive `player_left` and the membership seam latches `restart_required`, which the live harness records as a frozen-membership failure. The core's `CONTINUE` policy covers a silent endpoint, not a changed room roster, so the process-death witness cannot truthfully continue the match without first deciding that contract. | design | `docs/signalfish-membership.md` lifetime fence; `webrtc_setup.gd` `membership_frozen`; follow-up #433 |
| 2 | A live witness cannot count a received barrier control through `peer.drain_events()`: `FortressPeerSession._collect_events` consumes every `drop_barrier` endpoint event internally and publishes only the drop lifecycle events. The first foreign run recorded `foreign_sent: 1` and `foreign_received: 0` although the coordinator refused the bytes. | fact | `peer_session.gd` `_collect_events`; first `peer-drop-foreign` run |
| 3 | The forged prepare was sent to the browser page index rather than the session's remote-peer index, so it went to the departed link and never reached the coordinator. | bug | First run: follower sent 1, coordinator received 0; the destination is now derived from the only live remote |
| 4 | The coordinator-only rejection happens in ``FortressPeerDrop.received`` before `_receive_prepare`, so the counter added only inside `_receive_prepare` read zero. | bug | `peer_drop_barrier.gd` coordinator-only check; the barrier suite's `stale_messages` case failed until the rejection was counted at the decision site |
| 5 | One forged copy crosses the real unreliable channel, so a lost copy would fail the label despite correct behavior. Three copies are published and the validator accepts 1–3 received copies no larger than the sends. | robustness | `webrtc_drop.gd` publication loop; live rows `sent: 3`, `received: 3` |
| 6 | The nightly Firefox `clean` setup failed before gameplay because the first owned window did not appear within the 2 s `xdotool search --sync` bound. | infra | Nightly `44860872955` `4.3-clean.log`: `spawnSync /usr/bin/xdotool ETIMEDOUT`; #431 |
| 7 | Retrying every xdotool call would weaken the ambiguity and malformed-geometry checks, so only the window search retries, only after `ETIMEDOUT`, and only once with a 4 s bound. | rule | `webrtc_display.cjs`; `webrtc_display.test.cjs` delayed, ambiguous and never-appearing controls |
| 8 | `run_godot_tests.py --suite test_peer_drop_barrier` is read as a resource path and reports `missing_or_duplicate_suite`; the suite argument must be `res://tests/unit/test_peer_drop_barrier.gd`. | process | First focused run: count 0 and the named error; the resource-path run passed |
| 9 | The first process-death design added survivor-only watchdog and launcher plumbing that the chosen foreign witness does not need. The final change reuses the ordinary three-page flow and adds one refused-proposal counter. | code judo | Reverted `webrtc_watchdog.cjs` and the launcher `survivors`/`processDeath` shape before landing |
| 10 | A generic refused-proposal count does not prove the witness's own payload was delivered: another mismatched prepare could increment it. The barrier now keeps the refused prepare's cut and digest, and the validator requires the forged values (2/999). | review | OpenAI review thread on PR #434; both pins report `foreign_cut: 2`, `foreign_digest: 999` |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Record the membership-fence conflict and the two possible contracts with an acceptance check. | #433 (sub-issue of #166) | issue body |
| 2 | Add `Barrier.refused_proposals` at the coordinator-only rejection and the identity/roster refusals. | `peer_drop_barrier.gd` | barrier suite `stale_messages` asserts the counter |
| 3 | Publish three well-formed forged prepares from the follower to the only live remote. | `webrtc_drop.gd` | live rows `foreign_sent: 3` |
| 4 | Record each survivor's own barrier refusal count as `foreign_received`. | `webrtc_drop.gd`, `webrtc_drop.py` | live rows `foreign_received: 3` on the coordinator, `0` on the follower |
| 5 | Validate delivery, the sender split and the absence of the forged cut. | `webrtc_drop.py`, `test_webrtc_drop.py` | `test_webrtc_drop` 10 tests |
| 6 | Wire the label through the runner tables, both workflows, the launcher list, owned logs and limits text. | `webrtc_runner.py`, `signalfish_webrtc_probe.py`, `webrtc.cjs`, both workflows | `test_signalfish_webrtc_probe` 24 tests |
| 7 | Retry the first-window search once with a 4 s bound after `ETIMEDOUT`; keep every other call and every rejection at 2 s. | `webrtc_display.cjs` | `webrtc_display.test.cjs` 27 tests |
| 8 | Run the Firefox `clean` label on a normal and a two-CPU-pinned display. | receipts | `4.3 clean passed in 17s`, `WALL 42s`; pinned `passed in 50s`, `WALL 76s` |
| 9 | Record the delivery-evidence, room-lifetime and window-retry facts. | `.llm/knowledge/transport-tooling.md` | three rows with evidence |
| 10 | Keep the refused prepare's cut and digest and require the forged values in the validator. | `peer_drop_barrier.gd`, `webrtc_drop.gd`, `webrtc_drop.py`, `test_webrtc_drop.py` | live rows cut 2/digest 999; negative controls for a wrong cut and digest |

## Prune Ledger

- Retired / merged / fixed at source: `PLAN.md` drops foreign proposals from the
  coordinated-drop remainder and removes #431 from maintenance; the probe's
  `limits` text names the new label and keeps room departure/process death out
  of the claim. The process-death launcher and watchdog scaffolding was removed
  rather than left unused.
- Verify-on-touch: `make gate`, `make test-reference`, the Chromium
  `peer-drop`, `peer-drop-foreign` and `peer-drop-rollback` labels, the Firefox
  `clean` label, and `test_webrtc_drop` + `test_signalfish_webrtc_probe`.

## Outcome

- State: `findings-acted`
- Follow-ups: #433 owns the room-departure/process-death contract and its live
  witness; the remaining #166 live case is that contract decision.
