# Retrospective: 2026-10-21 graceful peer drop and reference measurement

## Work Under Review

- Scope: the graceful peer drop in the peer session, the core session and the
  input queue; the Reference Baseline exported web probe de-duplication; the
  online probe step timings; the ownership probe rejection diagnosis. Eighteen
  files, about 850 changed lines.
- Trigger: a large gameplay change, a new measurement surface and a new
  workflow gate.
- Evidence base: the whole native suite passes twice in fresh processes
  (including the new `test_peer_drop` suite), the reference control suite
  passes (142 tests), the harness self-tests pass (140 tests), the source-width
  lint passes at 180 characters and the harness lint passes.

## Findings

| # | Finding | Type | Evidence (file:line / command / measurement) |
| --- | --- | --- | --- |
| 1 | A peer that stopped answering ended the match for everybody. The peer session terminated on the first `disconnected` event, so a single dropout closed the match for every survivor. | gap | `addons/fortress_rollback/core/peer_session.gd` `_collect_events` before the change: any `disconnected` event called `_core.terminate(PROTOCOL_FAILED)` |
| 2 | A frozen slot must not keep holding the confirmed frontier back, or the session stalls instead of continuing. The receipt fold and the mesh confirmation fold both had to drop the departed slot. | fact | `addons/fortress_rollback/core/session.gd` `_receipt_minimum` and `addons/fortress_rollback/core/peer_session.gd` `_confirmation_code` skip a frozen slot; the confirmation limit stays monotonic because the fold can only grow |
| 3 | The frames after the agreed frame used a later actual value, so freezing without a correction leaves the survivors simulating bytes the departed player never sent. | bug | `addons/fortress_rollback/core/input_queue.gd` `freeze_at` sets `_first_incorrect` when the queue holds a later actual value, and the session resimulates those frames with the frozen value |
| 4 | A departed peer that never reports another checksum holds the shared checksum window back, so the desync detector stops running. | bug | `addons/fortress_rollback/core/peer_checksums.gd` `abandon` releases the peer's slot in the shared window |
| 5 | The input status vocabulary already promised `DISCONNECTED`, but the queue had no such status and the reference game already accepted a `disconnected` row. | fact | `docs/contracts.md` promised the status before the change; `tests/oracle/reference_game.gd` accepted it while `tests/oracle/p2p_game.gd` rejected it |
| 6 | The Reference Baseline ran the exported web probes in both matrix legs, so every pinned engine exported and drove Chromium twice. | waste | `.github/workflows/reference-baseline.yml`: the `--web` step had no `if:`, and the four `Godot ...` jobs are 23 of the 67 summed minutes in `docs/experiments/reference-baseline-jobs.md` |
| 7 | The online probe named no step durations, so the per-job table could not say which step dominated a job. | gap | `scripts/reference/online_example_probe.py` before the change did not import `time` and the receipt carried no step durations |
| 8 | The ownership probe lost the diagnosis with the error: the browser error inventory and the case in flight only reached the log file. | gap | `scripts/reference/ownership_probes.py` before the change kept only `label` and `outcome` in the receipt |
| 9 | A GDScript typed array rejects an array of arrays, so a fixture that collects one token list per peer silently produced invalid tokens and every `begin` failed with `INVALID_ARGUMENT`. | fact | `tests/unit/test_peer_drop.gd`: `var tokens: Array[PackedByteArray]` holding `Array[PackedByteArray]` values failed every `begin mesh` assertion until the outer array was untyped |
| 10 | The engine probe also installs the pinned editor. Gating the whole probe to the suites leg took the engine with it, so the oracle leg had no engine and its upstream trace comparison failed. | bug | the current-head CI run: `ValueError: godot executable not found: .cache/reference/editors/4.7.2/Godot_v4.7.2-stable_linux.x86_64` in the `Godot 4.7.2 and Chromium oracles` job |
| 11 | A new status value changes the meaning of an existing numeric literal. The oracle control rejected status `3` as invalid, which the disconnected status now claims, so the control accepted a value it meant to reject and the oracle run failed. | bug | the current-head CI run: `ValueError: process failed (1); see .cache/reference/results/p2p-4.7.2/control-godot-game-inputs.log`; the control now rejects status `4` and accepts the disconnected status |
| 12 | The confirmation fold seeded its limit with the first slot, so a dropped player in the first roster slot capped the frontier forever and the survivor stalled. | bug | `addons/fortress_rollback/core/peer_session.gd` `_confirmation_code`: the seed is now above every slot and the fold skips the frozen slot; the `continue` case of `tests/unit/test_peer_drop.gd` fails with the old seed |
| 13 | The exported confirmed row and the recorded replay kept the departed player's real inputs for the frames the simulation consumed as frozen, so a replay or a spectator diverged from the match. | bug | `addons/fortress_rollback/core/session.gd` `confirmed_inputs` and `_record_replay` now read the value the simulation used; the `exported_row` and `confirmed_row` cases fail with the old reads |
| 14 | The freeze overwrote a pending correction that was older than the agreed frame, so the survivor resimulated from the wrong frame and silently diverged. | bug | `addons/fortress_rollback/core/input_queue.gd` `freeze_at` keeps the earliest pending correction; the `frozen_value` case fails with the overwrite |
| 15 | The first test for the drop could not fail for the behaviours it claimed to protect: the sample repeated from the third frame, the expected frozen value was read back from the implementation, and the survivor always owned the second slot. | technique | `tests/unit/test_peer_drop.gd` now varies the sample, compares the export with the simulated rows, uses the survivor in the first slot and plays more frames than the prediction window; four mutations of the production code fail the suite |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Added the graceful drop: a lifecycle policy, a queue freeze at an agreed frame, a session-level frozen slot and a peer session that keeps the survivors playing | `addons/fortress_rollback/core/`, `addons/fortress_rollback/protocol/lifecycle_types.gd` | `tests/unit/test_peer_drop.gd` and the whole native suite |
| 2 | The frozen slot is excluded from the receipt fold and from the mesh confirmation fold, and the confirmation limit stays monotonic | `addons/fortress_rollback/core/session.gd`, `addons/fortress_rollback/core/peer_session.gd` | the continued-match case asserts that the confirmed frontier keeps moving |
| 3 | A later actual value schedules a correction, so the frames after the agreed frame are resimulated with the frozen value | `addons/fortress_rollback/core/input_queue.gd` | the frozen-value case asserts that every later frame repeats one value and reports a disconnected status |
| 4 | The departed peer releases the shared checksum window and is skipped by the poll, submit, confirmation, checksum and teardown paths | `addons/fortress_rollback/core/peer_checksums.gd`, `addons/fortress_rollback/core/peer_session.gd` | the continued-match case |
| 5 | The exported web probes run once per pinned engine, the online probe times every step and the ownership probe keeps its rejection diagnosis | `.github/workflows/reference-baseline.yml`, `scripts/reference/` | `scripts/reference/test_reference_baseline_workflow.py`, `scripts/reference/test_online_example_probe.py`, `scripts/reference/test_ownership_probes.py` |
| 6 | The oracle leg keeps the native engine probes, because its upstream trace comparison needs the pinned editor, and a test now pins that dependency | `.github/workflows/reference-baseline.yml`, `scripts/reference/test_reference_baseline_workflow.py` | the new `test_the_oracle_leg_still_installs_the_pinned_engine` case and the current-head CI run |
| 7 | The oracle control rejects a status that is still invalid, accepts the disconnected status as evidence and keeps its check count in step | `tests/oracle/p2p_game_controls.gd`, `scripts/oracle/p2p_controls.py` | the local control run reports 28 checks and no failures |
| 8 | The confirmation fold, the exported rows and the pending correction are repaired, and the drop test now fails for each of those defects | `addons/fortress_rollback/core/peer_session.gd`, `addons/fortress_rollback/core/session.gd`, `addons/fortress_rollback/core/input_queue.gd`, `tests/unit/test_peer_drop.gd` | four mutations of the production code fail the suite and the clean tree passes |

Routing: procedures -> `.llm/skills/`; facts -> `../skills/gdscript-style/`;
external evidence -> none; invariants -> unchanged; tooling gaps -> the probe
scripts and their tests in `scripts/reference/`.

## Prune Ledger

- Retired / merged / fixed at source: the statement in `docs/peer-lifecycle.md`
  that continued play after a peer leaves needs a separate policy is now
  false, and `docs/contracts.md` described the `DISCONNECTED` status as
  "specified for later advanced parity" while the queue had no such status.
  Both were corrected in the same change.
- Verify-on-touch: `make lint-llm`, `make test-llm`, the reference control
  suite and the unit category were re-run against the stored claims.

## Outcome

- State: `findings-acted`
- Follow-ups: the coordinated drop barrier with its all-survivor certificate
  stays open in #48. The Firefox and mixed browser axes, the eight-player
  browser matrix and the local online timeout stay open under #75, #104 and
  #125.
