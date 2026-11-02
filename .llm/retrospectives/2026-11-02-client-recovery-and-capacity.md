# Retrospective: client recovery and native capacity

## Work under review

Session 144 addresses spectator failure explanations, replay control visibility,
native host contention and unused CI browser setup. Runtime fixes and scheduling
changes trigger this review.

## Findings

| Finding | Evidence | Action |
| --- | --- | --- |
| Native-only matrix legs installed unused browser tooling. | Run 41496019984 spends 40 summed seconds on Node/Playwright setup in the two oracle jobs; their launchers run native Godot, Rust and Java. | Gate setup on the suites leg; retain every verification command and extend the existing workflow contract test. |
| A fixed replay panel hid the game in short windows. | At 960×540, the failure panel ended at y549, beyond the viewport. | Bound the controls viewport and verify settled layout and reachable controls. |
| Numeric stop codes hid available game failure evidence. | The spectator terminal-feedback regression fails against the original `STOPPED: code` text. | Present the existing first cause, failed operation and frame; preserve the underlying session lifecycle. |
| Initial contention permanently limited a native run. | The original launcher overwrites requested jobs with one after failed lease acquisition. | Wait within a bounded budget before engine execution, then retain requested capacity under the exclusive lease. |
| Waiting-only cancellation tests did not establish active-wave cleanup. | Fresh review reproduced surviving engines after SIGTERM; the registration control also left a spawned group alive. | Cover active waves, real descendants, queued work and the spawn-registration boundary. |
| Cleanup began too late after process registration. | `native-boundary-red.log` finds one registered, unreaped child after SIGTERM between registration and body entry. | Put acquisition, registration and body entry in one cleanup scope; observe retirement before returning capacity. |
| A one-worker request can still require case sharding. | `test_contended_single_worker_preserves_slow_case_watchdogs` checks four case shards after a contended one-worker wait. | Preserve the existing slow-case isolation rule while changing capacity scheduling. |

## Curation and pruning

Updated the existing testing infrastructure reference at its canonical home.
Its one-worker contention description became stale with the bounded-wait policy;
replace that description rather than keeping conflicting policies. Retain the
existing rules for lock ownership, source freezes, per-case watchdogs and real GUI
routing. Scope tool setup to the matrix legs that actually use it.

Added cancellation coverage to the existing process-ownership guidance. Ordinary
child-exit checks had not specified waiting, active-wave and registration
boundaries. A second fresh review exposed a gap after registration but before
body entry; extend that same guidance rather than creating another rule.
Distinguish kill delivery, leader reaping and observed descendant retirement.
The missing-retirement mutant verifies the observation itself is required. No new skill or knowledge topic is needed. The existing fresh-review
and source-bound verification procedures cover the concurrent-edit failures.
Early `source_changed` receipts remain disqualified; final qualification uses a
coordinated source freeze.

## Evidence and limits

The following local logs support the findings; they are ignored workspace artifacts.
The tracked probe and control names preserve the contracts in clean checkouts.

- `progress/replay-layout-navigation{43,}-green.log` each records
  `FORTRESS_REPLAY_NAVIGATION_OK 133`. The corresponding `43` and `current` red
  logs reject the original scene because it lacks the bounded scrolling viewport.
  The deferred witness is `scripts/reference/replay_navigation_probe.gd::_replay_layout`.
- `progress/spectator-failure-{43,current}.log` each reports a complete passing
  22-case inventory. `spectator-failure-direct-red.log` fails the callback-feedback
  contract; `spectator-failure-direct-green.log` passes the same selected case.
  The owned regression is `tests/unit/test_spectator_demo.gd::_failure_feedback`.
- `progress/native309/registration-red.log` fails
  `test_signal_between_spawn_and_registration_reaps_the_new_group` because the
  spawned process remains alive. `registration-green.log` and
  `cancel-boundaries.log` each pass eight controls. The active-wave control in
  `scripts/tests/test_native_host_wait.py` starts actual descendants before SIGTERM.
- `progress/native-boundary-red.log` records the post-registration failure:
  one process remains registered and unreaped. Repair `cc3006c` moves process
  acquisition, registration and body entry inside the cleanup scope.
  `progress/native-cleanup-final2.log` finishes 49 controls successfully with
  seven optional engine skips. `progress/native-boundary-stress-green.log`
  passes 30 repeated boundary, descendant and retirement-failure controls.
  `progress/native-retirement-mutant-red.log` rejects removed retirement
  observation. These controls do not replace final pinned-engine receipts.
- `progress/native309/runner-real-engine.log` earlier passed all 27 runner controls;
  `runner-isolated.log` skips seven engine-dependent cases. The failed
  `runner.log` and `runner-final.log` contain source-change contamination and
  do not qualify the final tree.
- Run 41496019984 measured 40 summed seconds of unused Node/browser setup.
  This is removed setup work, not measured workflow speedup. Native capacity
  measurements remain in progress; restored worker counts alone establish no
  elapsed-time improvement.

Verification commands: `make llm-index`, `make lint-llm`, `make test-llm`.
The earlier harness run passed 171 tests before the final cancellation additions;
that result did not qualify the later test tree. The independent curation rerun
passed all 174 harness tests before repair `cc3006c`; it does not qualify that
later source. This follow-up reruns index freshness and instruction lint only
while isolated capacity measurements run. The parent session must rerun final
harness tests after measurement. Final engine receipts and completed capacity
measurements belong in the session log and linked issues.

## Outcome

Final local verification at `2df09fd` passes 179 harness tests and all 779 unit
cases in both fresh repetitions. Exact candidate contention takes 91.522 seconds
versus the original 940.185; the uncontended control takes 82.710 seconds.
The complete benchmark inventory, original GDScript hashes and semantic records match.
These measurements qualify the declared native overlap workload, not CI speed.

An actual Chromium-owned export consumes 120 animation frames without page errors
while native engines wait, then the native launcher uses four workers and passes
18 selected cases. Its first sampler undercounted workers by reading only the
main thread's Linux child list. Inspecting all task child lists repairs the
instrument; the existing infrastructure guidance now records this boundary.
No product fix or new test scaffold was needed for the observation error.

State: `findings-acted`.
Broader spectator, replay, browser-workload and source-helper acceptance remains
in the linked open roadmap issues. Final tests, fresh reviews, current-head CI,
feedback, merge and main verification remain session delivery gates.
