# Session 007 — Stateful oracle and faster iteration

Goal: advance PLAN.md, reduce issue debt, preserve coverage and CI time, and
substantially improve local agent iteration.
Base: `6fdf4ee8a03fd23b6ecb66ade940458a0ad5a5ce`.
Branch: `session-007-stateful-oracle-and-speed`.
The session PR owns final head, feedback, squash merge and main-CI evidence.

## Starting evidence and chosen work

Clean main matched origin/main. No open/draft PR existed. All three main
workflows were green: 38092450452, 38092450471 and 38092450467.
Audited every open issue. Gameplay priority selected #28's missing shared
stateful game. Baseline/specification/runner acceptance and #58's CI maintenance
could proceed independently. Existing P2P and semantic-audit gates remain open.

## Stateful oracle

Version 1 and its 21 scenarios remain unchanged. Version 2 adds another 21
scenarios across every player count 2–8 and distance/delay 0/0, 2/2 and 7/7.
The complete canonical state includes PRNG seed 8173 and pending-event input
state; both influence continuation. Rust invokes actual pinned upstream APIs.
Godot runs actual shipped session operations. An independent offline history
oracle verifies every callback prefix, not just final state or request agreement.

`docs/oracle.md` specifies exact arithmetic/layout and a neutral first-tick
known answer. Public-driver tests intentionally omit each field from restore,
use constant checksums, and require DESYNC localized to saved frame 2.
Healthy clients match uninterrupted canonical bytes after every step.
Truncated/negative-frame restores preserve state. Version/width and coherently
checksummed forged field controls fail at their intended boundaries.

Red: `make test-oracle` rejected the new format before implementation.
Green: both pins pass all 42 scenarios, twice in fresh Rust, game-replay and
production-session processes. Receipts:
`.cache/reference/results/session-007-oracle{43,472}/receipt.json`.
Full native units: `.cache/tests/session-007-all{43,472}.json`.
Original omission-independent local rollback/correction tests remain intact.

## Iteration and CI

On Linux aarch64, Godot 4.3 and Rust 1.94.0, warm offline measurements:

| Workload | Before | After | Coverage |
| --- | ---: | ---: | --- |
| Queue Cargo preparation | 2.84 s | 0.12 s | Exact verified source/adapter comparison |
| Full queue differential | 12.684 s | 9.845 s | Same 711 cases / 8353 operations and mutants |
| Focused queue suite | Existing full suite command | 1.043 s | Both repeat layers retained |
| Same 42-case oracle | 61.081 s serial | 26.472 s four workers | Identical ordered complete receipts |
| Earlier 21-case oracle | 36.611 s serial | 26.472 s for 42 cases | Doubled corpus, 27.7% lower local duration |

`make test-focus` delegates to the existing fail-closed runner. Full gates remain
mandatory at delivery. Source reuse compares complete byte/mode/entry/symlink
identity against fresh hash-verified extraction. Modified or injected files are
replaced. The isolated queue adapter is reconciled too; injected build.rs is
removed. The timestamp regression demonstrably fails against the base.

Oracle setup/build and controls remain serial. Independent scenarios own unique
logs; four bounded workers retain corpus order in the receipt. Failures cancel
queued work and join live workers before returning without success evidence.
A reviewer reproduced stale receipts for invalid worker bounds. Five real CLI
controls failed before repair, then passed after moving validation behind cleanup.

CI caches only hash-verified downloads, Cargo crate archives and registry indexes.
An independent review demonstrated that Cargo compiles altered unpacked source
without checksum validation; registry/src, build targets and results are excluded.
New cache keys prevent restoring prior broad entries.

For #58, workflows select reproducible Ubuntu 24.04 x64 and arm64 runners.
Official action manifests confirm Node24 for checkout v5, setup-python v6,
setup-node v5, upload-artifact v6 and cache v5. Upload-artifact v5 still uses
Node20, so v6 is required. Pinned game/browser/compiler versions stay unchanged.
Remote job/step timings must confirm the user CI-time condition before completion.

## Baseline and prerequisite audit

#12's representative baseline and artifact pins existed, but its addon packaging
check had not run. The audit found omitted runtime attribution. The addon now
carries repository and upstream MIT notices. An addon-only tar, extracted into a
clean temporary project, executes an actual driver/session tick on both pins.
No Rust, tool script, cache or reference fixture enters the candidate. This is a
native package audit, not a supported release or browser networking claim.

#14's specification acceptance is documented by requirement and failure
walkthrough. #15's policy witness rejects invented coverage, omitted operations
and a reordered input history retaining the same final sum. #16's actual runner
controls pass on both pins (six methods each), with error/watchdog/incomplete
execution and both repetition layers. Outstanding semantic-audit dependencies
stay explicit; audited documents do not establish missing P2P/release behavior.

## Reviews, validation and follow-ups

Fresh documentation review completed clean. Fresh oracle review found only the
invalid-worker stale receipt; re-review completed clean after its repair.
Independent cache/package review repaired missing/empty/mismatched attribution,
nonregular filesystem entries and a symlinked addon root. Eight data-driven
controls reject before engine startup and supersede prior success. Final review
completed clean; both package audits were independently rerun and matched the
checked-in source/archive/engine evidence. Fresh upstream baseline repeats queue
115, sync 8, network 3, trace 1 and independent divergence 1 on both runs.
Native units pass 33 cases / 45696 assertions per in-process run on each pin.
Oracle receipts cover 42 cases / 4704 requests per run on each pin.
Current-head remote CI remains the delivery gate.
`make test-oracle`, `make test-reference`, source lint, GDScript lint, and full
harness regeneration/lint/self-tests run before push. CI repeats full native,
Chromium/reference and dual-architecture devcontainer gates.

Retrospective: [artifact](../.llm/retrospectives/2026-10-10-stateful-oracle-and-iteration.md).
Retro: findings-acted.
