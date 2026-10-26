---
name: testing
description: "Deterministic test strategy: headless Godot test runner, seed-fixed tests, run-twice equality, replay regression tests, checksum assertions, CI setup. Use when writing tests or debugging flaky/divergent behavior."
metadata:
  category: core
---

# Testing

Flaky tests in a deterministic engine are not noise — they are desync bugs
you have not understood yet. The test suite is the determinism oracle.

## Layout

```
tests/
  runner/        # headless SceneTree test runner (zero addon dependencies)
  unit/          # per-class tests
  determinism/   # run-twice, replay, and cross-tick equality tests
  integration/   # two fake peers exchanging inputs locally
```

The runner is a plain GDScript `SceneTree` script so CI needs nothing but the
Godot binary:

```sh
godot --headless --path . --script tests/runner/run_tests.gd
```

(If the project later adopts GUT or gdUnit4 for scene-level tests, keep the
determinism suites addon-free — they must run in the most minimal environment
possible.)

## Test Categories

1. **Unit**: one class, no engine loop. Pure GDScript, instant, deterministic
   by construction.
2. **Determinism (the core of this repo)**:
   - *Run-twice*: simulate N ticks with seed S, snapshot checksum sequence;
     rerun; sequences must be identical.
   - *Save/restore*: at tick K, snapshot; continue to K+M; restore; continue
     to K+M again; checksums must match the uninterrupted run.
   - *Replay*: feed a recorded input log; final checksum must equal the
     recorded one. Store replays as small binary fixtures.
   - *Input fuzz*: random (seeded!) input streams across two fake peers; no
     desync, no stuck prediction.
3. **Integration**: two sessions in one process exchange packets through
   queues with explicit time. Assert ordered save/load/advance requests and
   actual event sequences such as `NetworkInterrupted` and `NetworkResumed`.

## Test Value Bar

A test earns its place by protecting behavior a real regression would break.
Test count is not a goal. Before adding any test, answer all four:

1. What observable behavior, invariant, or contract does it protect?
2. What credible regression would make it fail?
3. Why doesn't existing coverage already catch that? (Prefer adding a case to
   an existing table-driven test over a near-duplicate.)
4. Does it need a test-only seam (export, flag, hook) no production caller
   needs? If yes, test at the real boundary instead.

Record the answer as a one-line header comment on the test:

```
# Value: protects=Session.restore() reapplies pending inputs; fails_when=restore skips the pending-input queue; why_new=determinism tests cover snapshot round-trip only; seam=none
```

Quality bars: ★★★ = behavior + edge cases + error path; ★★ = happy path
only; ★ = smoke/existence. Weak (★) tests never count as coverage of a
changed path. A test that breaks under a behavior-preserving refactor asserts
implementation: rewrite it at the owning boundary.

## Coverage Taxonomy

A changed code path is covered only when the applicable buckets have tests:

| Bucket | Examples in this domain |
| --- | --- |
| Positive | Expected checksum sequence for a scripted input log |
| Negative | Malformed replay input rejected; invalid frame addressed |
| Error | Checksum mismatch raises `desync_detected` with frame + both hashes |
| Boundary | Tick 0; first tick after restore; checksum tick == input tick; window edge |
| Extreme | Max entities, max input rate (every tick), max session length |
| User flows | Input spam every tick for both peers; disconnect mid-prediction; restore-then-continue past a saved tick |

## Regression Triple Proof

Before trusting a probe's red result, run the same probe against a control where
the target contract is satisfied and confirm green. Change one relevant variable
between control and failing experiment. Verify the intended diagnostic: an
unrelated failure does not establish the regression. An npm uninstall probe that
rejects an allowed empty scope directory, or a permissions probe that cannot read
its own tarball, is a broken instrument. Repair the probe before interpreting red.

Every bug fix ships its regression test, proven in three steps:

1. **Fails at HEAD** — the test fails on the buggy code (bug is real, fixture
   is honest).
2. **Passes at base** — the test passes on the pre-regression revision or
   recorded replay (test encodes the contract, not the bug).
3. **Passes after fix** — green after repair, plus the full suite.

This is mandatory and needs no permission; ask *how* to cover a regression,
never *whether*. See [debugging](../debugging/SKILL.md).

## Measurement

A benchmark is a test of a measurement, and it fails like a test.

1. **Verify outside the measured region.** A checksum over the bytes a
   benchmark measures costs as much as the work it checks. Collect the
   evidence while the clock runs and hash it afterwards.
2. **Fail when the workload did not run.** A workload that stalls instead of
   exercising the path still reports a number. Assert the state the workload
   must reach, such as the last frame or the correction count, and exit
   non-zero when it does not get there.
3. **Compare the result with a published baseline.** The canonical checksum
   is the equivalence proof: it must be identical before and after the
   change, on every pinned engine.
4. **No machine-dependent threshold in a unit test.** A lower bound on a
   measured duration fails on a faster machine. Inject a scripted clock and
   assert the exact elapsed time, and use a real clock only to order two
   cases against each other.

## Rules

1. **Never call `randomize()`** in test code; derive every random sequence
   from an explicit seed so failures are reproducible.
2. **Never gate on wall-clock** (`await get_tree().create_timer(...)` in sim
   tests). Drive ticks manually.
3. Tests assert on **checksums and event sequences**, not floating-point
   equality of accumulated state.
4. A failing determinism test must print: seed, frame, diverging checksum
   pair, and a state-diff hint. Fix the diagnosis loop before the bug.
5. Every bug fix adds the regression test that would have caught it, proven
   with the triple proof above (fails at HEAD, passes at base, passes after
   fix).
6. A test of an **agreement** must fail when the agreement is removed. Assert
   the mechanism, not only the outcome: a survivor that freezes its own
   frontier publishes the same event as a coordinated freeze, so the test reads
   the coordination's own record and compares the agreed value with the
   contract. The engine's runtime semantics are in
   [GDScript runtime facts](../../knowledge/gdscript-runtime.md).

## Evidence references

Read the applicable reference before changing a runner or witness. These are part
of this skill's contract; load only the domains involved in the task.

| Changed boundary | Required reference |
| --- | --- |
| Child processes, receipts, source/tool identity, staging, caches, local iteration | [Infrastructure evidence](references/infrastructure.md) |
| SDK signals, browser observers, live network clocks, rendering, watchdogs | [Browser and network integration](references/browser-integration.md) |
| Differential traces, schemas, projections, mutations, canonical history | [Oracle validation](references/oracle-validation.md) |

Cross-domain work reads every applicable reference. A browser trace validator,
for example, needs both browser integration and oracle validation.

## Faster local iteration

Use `make test-focus SUITE=res://tests/unit/x.gd` for one suite and
`make test-changed` for suites reaching files changed since `origin/main`.
The launcher's repeatable `--suite` option selects suite paths; `--filter` matches case names only.
Inspect the selected case inventory before claiming a subsystem passed; a matching word can cover only a few unrelated cases.
Deliver the full suite. Process isolation, worker order and cache verification
are described in [infrastructure evidence](references/infrastructure.md#faster-local-iteration).

## CI

`.github/workflows/` runs harness self-tests (`make test-llm`), source widths
(`make lint-source`), pinned reference baselines and minimum/current Godot
runner controls. Runtime suites must be wired into CI when added; a test file
or local receipt alone does not establish CI coverage. Cross-platform native
and full browser matrices remain release gates in PLAN.md.
Any test that cannot run headless must justify itself in review.

Related: [determinism](../determinism/SKILL.md),
[rollback-fundamentals](../rollback-fundamentals/SKILL.md),
[debugging](../debugging/SKILL.md).
