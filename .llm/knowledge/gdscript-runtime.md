# GDScript Runtime Facts

Verified facts about how the GDScript runtime reports a failure. Evidence cites
a command, a file:line or a measurement; re-verify on touch.

| Fact | Evidence | Verified |
| --- | --- | --- |
| A GDScript runtime error aborts the innermost function and the caller resumes, so a test case that dies inside a nested helper still reaches `context.finish()` and the engine reports that case as passed with a truncated assertion count. | `tests/runner-controls/control_suite.gd:29-31` with `godot --headless --path . --script res://tests/runner/run_tests.gd -- --suite res://tests/runner-controls/control_suite.gd --filter nested_abort` prints `FORTRESS_TEST_RESULT {"passed":true,…}` | 2026-10-22 |
| GDScript has no `try`/`catch`, so a case cannot catch its own runtime error. | `try:` is a parse error ("Expected end of statement after expression, found \":\" instead.") on Godot 4.3 and 4.7.2 | 2026-10-22 |
| Moving the completion marker into the case body does not detect an abort: the body resumes after the aborted helper and still reaches the marker. | A suite whose marker sits at the end of the case body printed `FORTRESS_TEST_RESULT {"passed":true,…}` with `assertions: 1` for a case that died inside a nested helper, on Godot 4.3 and 4.7.2 | 2026-10-22 |
| A Godot 4.7.2 engine hands a script error to a custom logger: `OS.add_logger` with a `Logger` subclass that overrides `_log_error` receives the message, the file and the line. | The logger printed `LOGGER ERROR: res://probe.gd:13 Out of bounds get index '4' (on base: 'Array[int]')` for the same runtime error | 2026-10-22 |
| Godot 4.3 has neither the `Logger` class nor `OS.add_logger`, so that engine cannot observe a script error in process. | `Could not find base class "Logger".` on 4.3 and `OS.has_method("add_logger")` is false there, against true on 4.7.2 | 2026-10-22 |
| The engine writes the script error to stderr and the runner's progress records to stdout, so the order that names the case that was executing only survives in one merged stream. | `scripts/run_godot_tests.py:229-230` merges the two streams; the attribution walks the merged order in `engine_errors` | 2026-10-22 |
