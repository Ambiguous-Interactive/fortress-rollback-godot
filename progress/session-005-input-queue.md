# Session 005 — Bounded input queue

Goal: advance PLAN.md through a green, reviewed, squash-merged session PR.
Base: `6dca6669d6fd622da3b7f26c81b5dc91811b206e`.
Branch: `session-005-input-queue`.
The session PR and linked task updates own final current-head checks, complete
feedback scans, merge SHA and merge-triggered main CI evidence.

## Starting audit

Clean main matched origin/main. No open PR or dependency PR existed.
Main was fully green: devcontainer 38084746083, reference 38084746069,
harness 38084746092. The gameplay core remained planned. C1/C2 queue work was
selected from the audited input/prediction contracts; V2/V3 session prerequisites
remain open, so standalone raw-queue evidence does not close their gates.

## Implementation and evidence

`FortressInputQueue` is a SceneTree-independent RefCounted runtime component.
It owns copied fixed-width history in a bounded tagged ring and supports delay,
frozen repeat-latest prediction, first mismatch, reset and clamped discard.
Invalid configuration and capacity failures preserve state. Raw duplicates are
rejected; stalled local-sample idempotence belongs to the future session wrapper.

The development Rust adapter calls pinned `__internal::InputQueue`; it does not
translate queue algorithms. Godot executes its actual production queue on the
same bundles. Exact normalized results include acceptance, scheduled frame,
bytes/status, first mismatch and delay. Missing or extra records fail comparison.
Strict schemas and nonzero process exits reject malformed artifact controls.

A source sweep distinguished ordinary insertion from transactional delay
changes and global-floor reclamation. An over-capacity upstream startup add
retains a partial neutral prefix. Godot rejects that entire operation atomically.
A separate witness asserts both retained-byte outcomes; the ordinary corpus is
an exact comparison only within its declared overlap.

Source contract and commands: [queue contract](../docs/input-queue.md).
[Follow-up #61](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues/61)
records global rollback-floor reclamation, its side slot and asymmetric session
acceptance. C1/C2 remain open until the session and prerequisite evidence gates
are satisfied. Freeze, coordinated drop, hot join and browser queue execution
remain separately gated.

## Red-green and reviews

Before implementation, queue tests failed at the missing production preload;
Python schema/comparator controls failed at the missing queue contract module.
Both passed after implementation. This new component has no pre-regression
working version. Unit tables check neutral and submit/read aliases, atomic
initial/setter failure, duplicate/skipped input, logical versus physical history,
matching/mismatching episodes, wraparound and numeric/configuration rejection.

The main-thread code review inspected the full diff and contract boundaries.
A fresh-context adversarial subagent reviewed the whole candidate and all six
attack surfaces, explicitly waiving absent async callbacks and network packets.
It reported no actionable findings and independently compared an additional
300 seeded cases and 30300 operations across capacities 2–20, with exact parity.
The formal gate state was ran-clean; no unavailable review was counted as pass.

## Verification

| Gate | Observed result |
| --- | --- |
| Queue differential per native engine | 705 cases, 7961 operations per repetition |
| Differential scope | Player indices 0–7, widths 1/4/8/32, capacities 2/3/4/8, wrap and prediction |
| Scoped exhaustive exploration | Every depth-three sequence from seven operations, after valid frame-zero insertion, capacities 2 and 3 |
| Fresh-process equality | Rust and production Godot ran twice; exact records matched |
| Malformed process controls | Empty/stale/unknown-field/fractional artifacts rejected by both binaries |
| Reviewed divergence | Retained default prefix versus atomic rejection asserted after failed startup |
| Queue unit cases | Five cases, 94 assertions per run, repeated twice within two fresh processes |
| Native versions/platform | Godot 4.3.77dcf97d8 and 4.7.2.ed1daf0bf, Linux arm64 |
| Offline tooling | 13 oracle tests, 90 harness tests; 27 reference methods with two native controls skipped offline |
| Format and source | GDScript formatter/linter passed; every source maximum is 180 |
| Inventory | 632 files and 337 source families verified; coverage statuses remain pending |

Receipts: `.cache/reference/results/queue-4.3/receipt.json`,
`.cache/reference/results/queue-4.7.2/receipt.json` and
`.cache/tests/session-005-unit-{4.3,4.7.2}.json`.
Local receipts record the inspected source hashes and dirty candidate state;
current-head CI supplies commit-bound x86_64 minimum/current evidence.
No whole-program, session, browser, zero-allocation or release-parity claim.

## Retrospective

Updated the context, README and rollback skill at their canonical sources.
The scoped semantic audit cannot certify mixed source families; pending ledger
statuses were preserved. Recorded explicit startup failure divergence and
raw/session boundaries without creating duplicate knowledge stores.

Artifact: [input queue retrospective](../.llm/retrospectives/2026-10-10-input-queue.md).
Retro: findings-acted
