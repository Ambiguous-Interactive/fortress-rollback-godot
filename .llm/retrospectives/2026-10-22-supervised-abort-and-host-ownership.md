# Retrospective: 2026-10-22 supervised abort and explicit host ownership

## Work Under Review

- Scope: the runner's abort report on Godot 4.3 (a supervised child with
  `--log-file`), and an explicit development-host lease for every host-sensitive
  probe. Thirteen files across the runner, the reference probes, the harness
  tests, the policy and the knowledge stores.
- Trigger: a new capability (the 4.3 supervised child) and an incident (two
  bugs the reference tests caught in this session's own edits).
- Evidence base: both pinned engines in `.cache/reference/editors/`, the runner
  receipt (426 records, two repetitions, clean tree at `13722e7`), the
  reference suite (154 tests), and the harness suite (152 tests).

## Findings

| # | Finding | Type | Evidence (file:line / command / measurement) |
| --- | --- | --- | --- |
| 1 | Godot 4.3 has no `Logger` class and no `OS.add_logger`, so an in-process watch cannot report an aborted case; the runner starts itself as a child with `--log-file` and reads the merged stream instead. | fact | `OS.has_method("add_logger")` is false on 4.3 against true on 4.7.2; the control prints `FORTRESS_TEST_ABORT_WATCH {"available":true,"errors":2}` on both pins |
| 2 | `--log-file` must appear before `--` on the Godot command line, or the engine parses it as a user argument; Godot 4.3 also prefixes error lines in that file with `USER ` (`USER SCRIPT ERROR:`). | fact | The supervisor builds `[exe, --headless, --path, --log-file, path, --script, ..., --, *user]`; the merged log held `USER SCRIPT ERROR:` with the expected `at:` line |
| 3 | `OS.get_temp_dir()` does not exist on Godot 4.3, so the supervisor must use `OS.get_cache_dir()` for its scratch log. | fact | `OS.has_method("get_temp_dir")` is false on 4.3 |
| 4 | A probe under `scripts/reference/` cannot `import host_capacity` from `scripts/` without adding `scripts/` to `sys.path`; the reference tests import the probe directly, so the failure is an `ImportError`, not a lint error. | incident | `python3 -m unittest discover -s scripts/reference ...` raised `ModuleNotFoundError: No module named 'host_capacity'` before the `sys.path.insert` fix |
| 5 | `test_fetch.py` copies a fixed file list beside a copied launcher, so a new cross-directory import needs its module added to that list or the launcher argument tests fail. | incident | Adding `host_capacity` broke nine `test_rejected_launcher_arguments_invalidate_only_the_selected_receipt` cases until `scripts/host_capacity.py` was copied |
| 6 | A host lease taken before cheap argument checks makes a rejected invocation wait for a busy host (900 s), which turns a fast validation failure into a test timeout. | incident | `test_webrtc_matrix` timed out after 10 s on `--version not-pinned`; the lease moved after the version check fixed it |
| 7 | A structural AST test can lock wiring that is otherwise invisible: the lease call, its named owner, its bounded wait, and the ordering against validation. | technique | `scripts/tests/test_host_capacity.py` fails when a launcher's lease is removed (negative control confirmed) |
| 8 | A runner must take the host without waiting, so it never blocks on a witness; only witnesses wait. | technique | `scripts/run_godot_tests.py:514` uses `acquire`; `test_the_local_runner_takes_the_host_without_waiting` forbids `acquire_when_free` there |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Recorded the 4.3 abort facts, the `--log-file` placement, the `USER ` prefix and the missing `OS.get_temp_dir` | `../knowledge/gdscript-runtime.md` | `make lint-llm` |
| 2 | Recorded the `sys.path` requirement and the lease-after-validation ordering | `../knowledge/transport-tooling.md` | `make lint-llm` |
| 3 | Described the supervised child in the runner guide | `docs/test-runner.md` | `make lint-source` |
| 4 | Named the host-sensitive probes in the verification policy | `docs/verification-policy.md` | `make lint-source` |
| 5 | Added structural lease and ordering tests (red-green: the negative control fails without a lease) | `scripts/tests/test_host_capacity.py` | `make test-llm` (152 tests) |
| 6 | Copied `scripts/host_capacity.py` beside the launchers under test | `scripts/reference/test_fetch.py` | `make test-reference` (154 tests) |

Routing: procedures -> `.llm/skills/`; facts -> `../knowledge/`;
external evidence -> `../research/`; invariants -> `context.md` + owning
skill; tooling gaps -> `scripts/tests/` first (red), then `scripts/llm/`
(green).

## Prune Ledger

- Retired / merged / fixed at source: the `gdscript-runtime.md` row that said
  4.3 "keeps the engine's own verdict" was replaced with the supervised-child
  route, one authoritative entry instead of a stale claim beside a new one.
- Verify-on-touch: `make test-llm`, `make test-reference`, `make lint-source`,
  `make lint-llm`, and the full 4.3 unit receipt (426 records, clean tree at
  `13722e7`).

## Outcome

- State: `findings-acted`
- Follow-ups: a held-host integration control (wait then diagnose) beyond the
  structural test; issue #125 still asks for a reproducible overlapped run to
  confirm the scheduling hypothesis.
