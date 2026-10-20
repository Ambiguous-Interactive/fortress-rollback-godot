# Retrospective: 2026-10-20 case timing and session hot path

## Work Under Review

- Scope: the per-case timing observation in the test runner and the browser
  ownership host (#153), and the measured session hot path with the snapshot
  copy change (#43). Fifteen files, about 750 changed lines.
- Trigger: large change, a new measurement workflow, and two corrections from
  fresh-context adversarial reviews.
- Evidence base: the unit category passes twice in fresh processes, the
  reference and oracle control suites pass (127 and 68 tests), the benchmark
  runs on both pinned engines, and the ownership matrix runs in CI.

## Findings

| # | Finding | Type | Evidence (file:line / command / measurement) |
| --- | --- | --- | --- |
| 1 | The first rollback workload never rolled back. The remote inputs arrived one frame after the session could advance, so the run spent 1585 iterations in the prediction stall and reported a number for a workload that did nothing. | technique | `scripts/benchmark_session_hot_path.gd` before the fix: `steps=1600, stalls=1585, loads=1`; after the fix: `steps=400, stalls=0, loads=50`, the deepest correction the eight-frame window allows |
| 2 | A benchmark that verifies its own result inside the measured region measures the verification. The checksum over the written bytes cost about as much as the write it checked, and the reported write cost rose from 2.9 to about 74 microseconds per write. | technique | `scripts/benchmark_session_hot_path.gd` `_snapshot_run`: the hash moved after the timed region, and the write cost returned to 2.9 microseconds |
| 3 | A wall-clock lower bound in a unit test is a machine-speed gate. The ten-millisecond bound had a 1.14 to 1.19 margin on the local CPU, and CI runs on a different architecture. | technique | `tests/unit/test_scenario_runner.gd` before the fix: `elapsed["slow"] > 10000`; the case now injects a scripted clock and asserts the exact elapsed time |
| 4 | The minimum and maximum columns of the benchmark reported the first and last sample instead of the extremes, so the spread claim was unsupported. | technique | `scripts/benchmark_session_hot_path.gd` `_summary`: the raw output showed `max_us` below `min_us` for the codec workload |
| 5 | A GDScript lambda captures a local variable by value, so a counter inside the lambda never advanced and the injected clock always returned the same reading. | fact | `tests/unit/test_scenario_runner.gd`: the scripted clock returned `0` for every case until the counter moved into an array |
| 6 | Two fresh-context adversarial reviews found six real defects that the author's own review had not. | technique | The reviews reported the stalled rollback workload, the mismeasured minimum and maximum, the stale source hash, the weak checksums, the wall-clock threshold and the unexercised summary helper; all are fixed |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Added the measurement rules: verify outside the measured region, fail when the workload did not run, compare with a published baseline, and no machine-dependent threshold in a unit test | `../skills/testing/SKILL.md` | `make lint-llm`, `make test-llm` |
| 2 | Recorded the lambda capture rule next to the other GDScript language facts | `../skills/gdscript-style/SKILL.md` | `make lint-llm` |
| 3 | The benchmark now fails when the workload does not reach its target state or when the checksum differs from the published baseline | `scripts/benchmark_session_hot_path.gd` | `make hot-path-probes` on both pinned engines |
| 4 | The timing case injects a scripted clock and asserts exact elapsed times, and uses the real clock only to order the two cases | `tests/unit/test_scenario_runner.gd` | the unit category passes; a mutation that stops the clock fails the case |

Routing: procedures -> `.llm/skills/`; facts -> `../skills/gdscript-style/`;
external evidence -> none; invariants -> unchanged; tooling gaps -> the
benchmark and its cases in `scripts/` and `tests/`.

## Prune Ledger

- Retired / merged / fixed at source: the published report's rollback row, the
  minimum and maximum claim, the source hash of the changed test file and the
  checksum table were wrong or unsupported and are replaced with the measured
  values. The browser summary helper had no test and was removed instead of
  kept.
- Verify-on-touch: `make lint-llm`, `make test-llm` and the unit category were
  re-run against the stored claims.

## Outcome

- State: `findings-acted`
- Follow-ups: the allocation-count, sustained-memory and release-matrix gates of
  #43 stay open. The loaded reproduction of the original ownership timeout
  stays open in #132.
