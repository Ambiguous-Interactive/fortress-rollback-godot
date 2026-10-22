# GDScript Runtime Facts

Verified facts about how the GDScript runtime reports a failure. Evidence cites
a command, a file:line or a measurement; re-verify on touch.

| Fact | Evidence | Verified |
| --- | --- | --- |
| A GDScript runtime error aborts the innermost function and the caller resumes, so a test case that dies inside a nested helper still reaches `context.finish()` and the engine reports that case as passed with a truncated assertion count. | `tests/runner-controls/control_suite.gd:29-31` with `godot --headless --path . --script res://tests/runner/run_tests.gd -- --suite res://tests/runner-controls/control_suite.gd --filter nested_abort` prints `FORTRESS_TEST_RESULT {"passed":true,…}` | 2026-10-22 |
| GDScript has no `try`/`catch`, and `OS.add_logger` never receives a `SCRIPT ERROR:`, so the engine cannot detect an aborted case. The host must attribute it. | `try:` is a parse error ("Expected end of statement after expression, found \":\" instead.") on Godot 4.3 and 4.7.2; a custom `Logger` printed no line for the same runtime error on 4.7.2 | 2026-10-22 |
| The engine writes the script error to stderr and the runner's progress records to stdout, so the order that names the case that was executing only survives in one merged stream. | `scripts/run_godot_tests.py:229-230` merges the two streams; the attribution walks the merged order in `engine_errors` | 2026-10-22 |
