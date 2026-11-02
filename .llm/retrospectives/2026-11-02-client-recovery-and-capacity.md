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
| Waiting-only cancellation tests did not establish active-wave cleanup. | Fresh adversarial review reproduced four surviving engines and a newly acquirable lease after launcher SIGTERM. | Require active-wave cancellation coverage and owned-child cleanup before final review. |

## Curation and pruning

Updated the existing testing infrastructure reference at its canonical home.
Its one-worker contention description became stale with the bounded-wait policy;
replace that description rather than keeping conflicting policies. Retain the
existing rules for lock ownership, source freezes, per-case watchdogs and real GUI
routing. Scope tool setup to the matrix legs that actually use it.

No new skill or knowledge topic is needed. The existing fresh-review and
source-bound verification procedures already cover the observed review and
concurrent-edit failures. Early `source_changed` receipts remain disqualified;
final qualification uses a coordinated source freeze.

Verification commands: `make llm-index`, `make lint-llm`, `make test-llm`.
The harness run passed 171 tests before the final cancellation additions;
final frozen-tree evidence belongs in the session log and linked issues.

## Outcome

State: `findings-acted`.
Broader spectator, replay, browser-workload and source-helper acceptance remains
in the linked open roadmap issues. Final tests, fresh reviews, current-head CI,
feedback, merge and main verification remain session delivery gates.
