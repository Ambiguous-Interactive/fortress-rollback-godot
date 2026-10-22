# Retrospective: 2026-10-22 aborted cases and a withheld checksum

## Work Under Review

- Scope: the engine-side report of an aborted test case (#170), a production
  fix that kept a live match from dying during a rollback correction, and a new
  supported-features page. Eighteen files across the runner, the shipped
  runtime, the tests, the harness and the docs.
- Trigger: a new capability (the runner's abort watch) and an incident (a
  normal prediction correction ended an online match).
- Evidence base: the two pinned engines in `.cache/reference/editors/`, the
  runner's own result line, the mesh checksum scheduler, and a fresh-context
  adversarial audit of the shipped runtime.

## Findings

| # | Finding | Type | Evidence (file:line / command / measurement) |
| --- | --- | --- | --- |
| 1 | The mesh checksum scheduler treated a snapshot that a pending repair withheld as a lost history, so a normal prediction correction ended the match with `HISTORY_UNAVAILABLE`. | bug | `addons/fortress_rollback/core/peer_checksums.gd:68` armed `checksum_history_unavailable` at frame 11 while `session.status().pending_rollback_frame` was 6 |
| 2 | The publisher side of the same confirmed snapshots already treated the condition as retryable, so the two consumers of one contract disagreed and no test compared them. | technique | `addons/fortress_rollback/core/spectator_publisher.gd` returns `PREDICTION_STALL` for the withheld frame |
| 3 | A logger subclass cannot live in the tree as a plain script for both pins: Godot 4.3 cannot parse `extends Logger`, and the parse error is itself engine output. | fact | The 4.3 engine reports `Could not find base class "Logger".` for a file that 4.7.2 loads |
| 4 | A logger can be compiled at runtime with `GDScript.new()` plus `source_code` and `reload()`, so the repository never needs a script an older pinned engine cannot parse. | fact | `tests/runner/run_tests.gd` compiles its logger source only after `ClassDB.class_exists("Logger")`; the same file parses on Godot 4.3 |
| 5 | A custom logger receives `push_error` and `push_warning` as well, so the error type must be filtered. | fact | The logger recorded `error_type: 2` for a runtime error, `0` for `push_error` and `1` for `push_warning` |
| 6 | The runner's per-case progress record is not enough to name the repetition that died, so the abort entry belongs to the repetition that actually died. | technique | The scenario runner reads the observer before and after every repetition, so a case that dies in one repetition keeps that difference visible |
| 7 | The exported browser ownership matrix pins the fourth copied file by index, so inserting a file into the copy list breaks the negative control that mutates it. | process | `scripts/reference/ownership_probes.py` mutates `FILES[3]`; inserting a new file at that index raised `negative control mutation no longer applicable` |
| 8 | The confirmed snapshot ceiling is lowered by the earliest incorrect frame, so a withheld snapshot and a lost snapshot look identical to a caller that only sees the ceiling. | bug | `addons/fortress_rollback/core/session.gd:320-324` lowers the ceiling; the scheduler could not tell the two apart |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | The scheduler now waits for the pending repair and publishes the boundary after it. A snapshot that no repair will restore still ends the match. | `addons/fortress_rollback/core/peer_checksums.gd` | the new suite, red before and green after |
| 2 | The runner installs a runtime-compiled logger and reports the aborted case in its own result. | `tests/runner/run_tests.gd`, `tests/runner/scenario_runner.gd` | `python3 scripts/reference/test_godot_runner.py --godot <pin>` on both pins |
| 3 | The launcher reads the engine's verdict instead of reporting the same abort twice. | `scripts/run_godot_tests.py` | the control that expects exactly one failure entry |
| 4 | The observer is read once per repetition with the suite, the case and the repetition index, and the registered logger is removed before the process exits. | `tests/runner/run_tests.gd`, `tests/runner/scenario_runner.gd` | the four abort-report cases and the Godot 4.3 integration run |
| 4 | The runner publishes the capability of its engine, so a host never claims an engine result that only one pin provides. | `FORTRESS_TEST_ABORT_WATCH` | the new engine controls |
| 5 | The supported features, browsers and exclusions are published on one page. | `docs/supported.md` | `make lint-source` and the link checks |
| 6 | The remaining Godot 4.3 route and the second failure of the same class became tracked follow-ups. | #175 and #174 | the issue threads |

Routing: procedures -> `.llm/skills/`; facts -> `../knowledge/`; invariants ->
`context.md` + owning skill; tooling gaps -> `scripts/tests/` first (red), then
`scripts/llm/` (green).

## Prune Ledger

- Retired / merged / fixed at source: the runner guide's claim that "the engine
  result cannot detect the abort today" and the same claim in
  `../knowledge/gdscript-runtime.md`. One corrected entry replaces each; no
  second, conflicting entry was added.
- Considered and dropped: a new skill and a research note. The findings are
  engine facts with measurements and one consumer disagreement. The knowledge
  table is their home.
- Verify-on-touch: `python3 scripts/reference/test_godot_runner.py --godot
  $(which godot)` still passes the controls, and the new suite still fails
  without the scheduler repair.

## Outcome

- State: findings-acted
- Follow-ups: #175 (the Godot 4.3 engine-side route), #174 (a mid-match input
  delay raise can still end a match), #166 and #48 (the coordinated drop
  evidence), #47 and #131 (the live spectator boundary).
