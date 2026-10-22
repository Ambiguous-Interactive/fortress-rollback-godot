# Retrospective: 2026-10-22 runner abort evidence

## Work Under Review

- Scope: the recorded runtime facts about an aborted GDScript case
  (`.llm/knowledge/gdscript-runtime.md`), the runner guide
  (`docs/test-runner.md`), one stale sentence in `PLAN.md`, and the revised
  required work in #170. Three files and one issue comment.
- Trigger: a knowledge correction. The previous session recorded a fact that a
  measurement contradicts, and #170 was opened from that fact.
- Evidence base: the two pinned engines in `.cache/reference/editors/`, the
  runner's own result line, and the harness lint.

## Findings

| # | Finding | Type | Evidence (file:line / command / measurement) |
| --- | --- | --- | --- |
| 1 | The recorded fact "a custom logger never receives a `SCRIPT ERROR:`" is wrong on Godot 4.7.2. `OS.add_logger` with a `Logger` subclass that overrides `_log_error` receives the message, the aborting file and the line. | fact | The logger printed `LOGGER ERROR: res://probe.gd:13 Out of bounds get index '4' (on base: 'Array[int]')` for the same runtime error |
| 2 | Godot 4.3 has neither the `Logger` class nor `OS.add_logger`, so that engine cannot observe a script error in process. | fact | `Could not find base class "Logger".` on 4.3; `OS.has_method("add_logger")` is false on 4.3 and true on 4.7.2 |
| 3 | Moving the completion marker into the case body does not detect an abort. A GDScript runtime error aborts the innermost function, so the body resumes after the aborted helper and still reaches the marker. | fact | A suite whose marker sits at the end of the case body printed `FORTRESS_TEST_RESULT {"passed":true,…}` with `assertions: 1` for a case that died inside a nested helper, on Godot 4.3 and 4.7.2 |
| 4 | #170 asks for the marker move, so its required work and its acceptance rest on finding 3 and cannot be met as written. | process | The issue body asks to "Move the completion marker into the case body" and to keep the nested-helper control |
| 5 | A logger subclass cannot live in the tree as a plain script for both pins: Godot 4.3 cannot parse `extends Logger`, and the parse error is itself engine output. One mechanism cannot cover both pins. | fact | The 4.3 engine reports `Could not find base class "Logger".` for the same file that 4.7.2 loads |
| 6 | The pinned project and the runner guide both repeated the wrong claim, so a reader would implement the marker move and keep the false green. | technique | `docs/test-runner.md` said "a custom logger never receives the script error" |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Replaced the wrong fact with the measured facts, as one corrected entry. | `.llm/knowledge/gdscript-runtime.md` | `make lint-llm` |
| 2 | Corrected the runner guide and recorded the 4.3 limit. | `docs/test-runner.md` | `make lint-source` |
| 3 | Removed the stale sentence that described the pinned barrier as unported. | `PLAN.md` | `make lint-llm` |
| 4 | Revised the required work of #170 with the per-engine routes and the remaining options. | #170 comment | the issue thread |

Routing: procedures -> `.llm/skills/`; facts -> `../knowledge/`; invariants ->
`context.md` + owning skill; tooling gaps -> `scripts/tests/` first (red), then
`scripts/llm/` (green).

## Prune Ledger

- Retired / merged / fixed at source: the "a custom logger never receives the
  script error" entry in `../knowledge/gdscript-runtime.md` and the same claim
  in `docs/test-runner.md`. One corrected entry replaces it; no second,
  conflicting entry was added.
- Considered and dropped: a new skill or research note. The finding is one
  engine fact with a measurement, so the knowledge table is its home.
- Verify-on-touch: `python3 scripts/reference/test_godot_runner.py --godot
  $(which godot)` still passes the 15 controls, including the nested-helper
  abort.

## Outcome

- State: findings-acted
- Follow-ups: #170 (report an aborted case in the engine result, per engine),
  #166 (the exported Chromium witness of the coordinated drop), #48 (the
  pinned participant list, retransmission journal and cut selection).
