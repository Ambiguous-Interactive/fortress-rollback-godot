# Retrospective: 2026-10-22 aborted cases and survivor agreement

## Work Under Review

- Scope: the coordinated drop of a departed peer, proved in real peer sessions
  (`tests/unit/test_peer_drop_survivors.gd`), and the test launcher fix that
  fails a case which dies before its last assertion
  (`scripts/run_godot_tests.py`, `scripts/reference/test_godot_runner.py`,
  `tests/runner-controls/control_suite.gd`, `docs/test-runner.md`), plus the
  matching documentation in `docs/peer-lifecycle.md`, `PLAN.md` and
  `CHANGELOG.md`. Eight files, 576 added and 29 deleted lines.
- Trigger: large change and a harness change - the test runner's failure
  contract changed.
- Evidence base: PR #169, squash commit `5fddc8b`; the native suite (418 cases,
  229 089 assertions), 150 reference tests, 68 oracle tests, the 15 runner
  controls, the merge-triggered main workflows, and two adversarial mutations
  of the production barrier.

## Findings

| # | Finding | Type | Evidence (file:line / command / measurement) |
| --- | --- | --- | --- |
| 1 | A GDScript runtime error aborts the innermost function and the caller resumes, so a case that died inside a nested helper was reported as passed. The engine cannot detect it: `try`/`catch` does not exist and `OS.add_logger` never sees the error. | fact | `tests/runner-controls/control_suite.gd:29-31` with the runner prints `{"passed":true,…}` for `nested_abort`; the parse error on `try:` on 4.3 and 4.7.2 |
| 2 | The engine writes the error to stderr and the progress records to stdout, so the order that names the executing case only survives in one merged stream. Two separate pipes lose it. | fact | `scripts/run_godot_tests.py:229-230`; the attribution in `engine_errors` walks the merged order |
| 3 | The coordinated-drop suite did not prove that the drop was coordinated. A survivor that froze its own frontier published the same event, so removing the barrier entirely left the suite green. | technique | Removing `peer_drop_barrier.gd:140-142` left the suite passing before the review; after the fix the same mutation fails `agreed_frame` |
| 4 | The last survivor's frozen frame was not compared with its own frontier, so a stale frame was invisible. | technique | Freezing `upper - 3` instead of `upper` left the suite green before the fix; now it fails `second_departure` |
| 5 | The launcher blamed a case for every engine error, including generic `ERROR:` lines that name a condition of the engine rather than an aborted case. | harness | `scripts/run_godot_tests.py` now attributes only a script level header |
| 6 | The rule that picked the aborted repetition was wrong when the abort came after the last assertion: the receipt said one repetition died while both carried the entry. | harness | `scripts/run_godot_tests.py` marks the truncated repetition and documents the equal-count case |
| 7 | The fresh-process comparison passed a missing result into the divergence lookup, which raised a TypeError and left the `in_progress` receipt behind. The automatic review found it. | harness | `scripts/run_godot_tests.py` `first_divergence` names the missing result; a new control covers it |
| 8 | A session-level witness needs a symmetry break to be interesting: with a symmetric mesh the two survivors hold the same window, so the cut agreement and the backfill are not exercised. | technique | The barrier's unit tests carry the asymmetric windows; the exported witness in #166 must carry the live one |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Recorded the runtime facts of an aborted function and the merged-stream attribution. | `../knowledge/gdscript-runtime.md` | `make lint-llm` |
| 2 | Added the rule that a test of an agreement must fail when the agreement is removed. | `../skills/testing/SKILL.md` | `make lint-llm` |
| 3 | The suite reads the coordination's own record and compares the last survivor's frozen frame with its own frontier; both mutations now fail it. | `tests/unit/test_peer_drop_survivors.gd` | `godot --headless --path . --script res://tests/runner/run_tests.gd -- --suite res://tests/unit/test_peer_drop_survivors.gd` |
| 4 | The launcher attributes only a script level error, names the truncated repetition, reports a malformed completion with a stable reason, and survives a run without a result. | `scripts/run_godot_tests.py` | `python3 scripts/reference/test_godot_runner.py --godot $(which godot)` |
| 5 | Opened the follow-up for the engine-side report and for the exported witness. | [#170](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/170), [#166](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/166) | issue comments |

Routing: procedures -> `.llm/skills/`; facts -> `../knowledge/`; invariants ->
`context.md` + owning skill; tooling gaps -> `scripts/tests/` first (red), then
`scripts/llm/` (green).

## Prune Ledger

- Retired / merged / fixed at source: none - considered: the testing skill's
  "Evidence references" section (the runner's failure contract belongs to
  `docs/test-runner.md`, which the change updated) and the determinism skill
  (the GDScript facts are engine facts, not simulation rules).
- Verify-on-touch: `python3 scripts/reference/test_godot_runner.py --godot
  $(which godot)` (15 controls) and the two barrier mutations were re-run
  against the merged head.

## Outcome

- State: `findings-acted`
- Follow-ups: #170 (report an aborted case in the engine result), #166 (the
  exported Chromium witness of the coordinated drop, including a survivor that
  is behind the others and needs the backfilled value).
