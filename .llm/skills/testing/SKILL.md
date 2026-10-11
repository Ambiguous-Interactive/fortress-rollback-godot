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

Every bug fix ships its regression test, proven in three steps:

1. **Fails at HEAD** — the test fails on the buggy code (bug is real, fixture
   is honest).
2. **Passes at base** — the test passes on the pre-regression revision or
   recorded replay (test encodes the contract, not the bug).
3. **Passes after fix** — green after repair, plus the full suite.

This is mandatory and needs no permission; ask *how* to cover a regression,
never *whether*. See [debugging](../debugging/SKILL.md).

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

## Infrastructure evidence

Tool probes must check process exit status before accepting version text or a
completion marker. Test both empty failures and plausible output followed by
nonzero exit. A completed result stream must account for every selected test,
including expected-panic cases; reject partial output even if listed tests pass.

Decode structured UTF-8 child-process output with explicit `encoding="utf-8"`
and strict errors. A successful JSON parse after locale decoding can still
contain corrupted feedback. Exercise real emitted bytes under a forced non-UTF-8
parent decoder, including malformed stdout and stderr; mocks returning decoded
strings cannot expose this boundary. Decoding failures must report sanitized
errors without revealing captured CLI output or credentials.

Invalidate a prior success report before starting a new attempt, clear only the
runner-owned logs, and preserve partial stdout/stderr on timeout. Capture
bounded in-loop state snapshots before the outer watchdog when
the inner timeout can occur later: include pending work and receipt/status
gossip needed to distinguish throughput from confirmation stalls. Local passes
do not supersede CI failures for the same source candidate. A failed rerun
must never leave a stale success receipt beside logs from its replacement.
Finalize fixtures before declaring a verification snapshot frozen. An intervening
edit restarts affected fresh-process and source-inventory checks.
Validate fresh service startup as well as warm state: asynchronous catalogs may
need bounded readiness polling rather than one successful configuration read.
Integration witnesses must capture every applicable SDK failure signal and
recheck latched errors after the final event drain and before publishing success.
Inject each actual failure signal at that last boundary and require nonzero exit
with no success marker. Correct game state can outlive a late connection failure.

Duck-typed engine doubles must expose only publicly bound methods. Check the
real engine method list before treating a native double as interface evidence.
A passing fake getter cannot prove an exported PacketPeer supports it. Verify
browser constructor options and resulting properties: an ignored option can
leave healthy gameplay on the wrong reliability policy.

Validate embedded scenarios/results independently before comparing their identity
to submitted artifacts. Python equality treats booleans, integral floats and
integers as equal; it is not schema validation. Standalone executables also need
their own complete schema and nonempty-work boundary.
Run the full CI entry point with its declared per-process watchdog. Size the
full-suite budget from completed runs without relaxing focused hang controls.
Preserve decoded wire fields instead of substituting scenario expectations.
Mutate actual encoded bytes before observation to test the observer itself.
Validate nullable fields before normalization; false and empty strings cannot
silently become the same observation. Test omitted and explicit-null optional
objects separately through every standalone executable. Require field presence
when explicit null is part of the observed contract; parser defaults can alias
them before shared validation runs. Constrain omitted setup records to their
exact allowed position. Formal projection must account for the observed initial
state and every supported post-state, not just action names and final success.

Compare intermediate canonical prefixes against original submitted histories.
A final checksum or accumulator sum can match after reordered inputs; replaying
an oracle's own requests can preserve the same mistake. Keep a temporal mutation
that retains the final state while violating an intermediate frame.
For network scenarios, compare corrected confirmed prefixes while faults remain
active and assert a nonzero comparison count for every peer. Confirmation can
advance on delivery before predicted game state is repaired; capture actual
callback boundaries rather than assuming the current state is already canonical.
Compare stalled save/load/advance requests too; unchanged frame numbers do not
mean a session performed no work. Do not gate every new input on global
confirmation when receipt gossip requires later submissions. Pace the witness
by endpoint receipts while retaining independent final confirmation and
corrected-prefix checks; otherwise the test driver can create a cyclic wait.
When every peer must exercise rollback, coordinate an explicit predicted step
before delivering its original inputs. A fast clean run can otherwise receive
all inputs before advancing and never restore a snapshot.
Batch bounded transport polls before yielding an exported host render turn.
Repeated timer yields per input can make integration duration depend on
software rendering, despite unchanged protocol work; verify under CPU limits.
Real socket witnesses must measure transport deadlines with elapsed monotonic
host time from the owned handshake epoch. A requested timer delay is not the
elapsed duration of its render turn. Keep game simulation on original frames
and inputs. Exercise handshake retries as well as input loss: an immediate
handshake can hide a missing caller-owned retry token.
Measure rendering or scheduling costs with paired engine/process/CPU controls
before prescribing a viewport or pacing change. A slow turn alone does not
identify its cause. Reject an optimization when its execution contradicts
the prediction; preserve failed receipts and remove unsupported guidance.
Budget real-browser watchdogs for their actual phase and room count. Track
each unfinished peer independently; only monotone game or protocol evidence
may reset inactivity. Keep separate gameplay and confirmation caps and an
absolute room/launcher/job ceiling. Packet counts, stage names and clocks do not
prove progress. Fresh execution must still satisfy every acceptance gate.
Capture bounded physical channel counters before destroying a failed room; keep
the original rejection and bound each diagnostic independently of gameplay.
Serialize probes that reinstall a shared browser or editor cache. Unique output
paths do not isolate executable extraction; overlapping launches can hit ETXTBSY.
Apply each page observation at its completion time before waiting for sibling
pages. Check that peer's existing deadline first, then rearm the earliest live
deadline. Exercise asymmetric timely completions and exact expired boundaries;
an all-pages barrier can otherwise discard valid progress against stale clocks.
Observe each page independently with one evaluation in flight per page; slower
siblings must not block its next sample. Keep a persistent earliest-deadline timer
active during inter-sample pauses, and test a fast advancing page behind a valid
slow response that finishes just before its own deadline.
Deactivate an observation synchronously on every failure path. Resolve a sibling
in the same turn as timeout/evaluation/validation rejection and prove it cannot
sample or rearm after failure; an awaiting `finally` can run too late.
Exercise the lowest accepted checksum capacity through repeated eviction, with
both lockstep and predictive advancement. Require healthy progress and nonzero
actual comparisons for each peer, then inject a real game mismatch at that same
capacity. Retained/send counts alone can pass while every comparison is skipped.

Validate original numeric tokens when parsing erases integer versus float syntax.
Keep a copied probe's exact case inventory, native selection and Web host selection
aligned when extending a shared suite. Verify preload dependencies are copied;
exercise the affected probe, since the root unit runner cannot prove its staging.
Bind evidence to all executed source inventories, including imported helpers,
and tool identities before use and before publishing a success receipt.
When engine import creates metadata, first verify authored sources are unchanged.
Allow only metadata paired with existing inputs, then freeze the complete
post-import inventory through export and execution.
Verify supplied pinned executables against bytes extracted from the verified
archive; a version string and unchanged execution hash do not prove provenance.
Observe resource construction separately from child creation, so teardown checks
also include abandoned connections that never created channels.

Godot JSON parsers expose numeric fields as floats. After validating integrality
and bounds, reconstruct scenario records with explicit integers before emitting
a strict cross-language trace. Godot 4.3 and 4.7.2 stringify integral floats
differently; never weaken the Python integer schema to compensate. The production
session oracle's canonical scenario conversion protects this boundary.

A mutation must fail at its intended boundary. Require the diagnostic and
consumed-record position so an unrelated parser or later-request failure cannot
satisfy the negative control. Declare expected diagnostics independently before
running the mutant; learning them from the validator makes rejection circular.
Select mutated records by semantic kind. Require scenario-specific nonzero
observations and an expected control inventory before publishing success. A
shortened corpus that never reaches its named event must fail those gates.
For snapshot-omission controls, derive localization from the first serialized
consumer of the missing field. A mutant that omits a field from every snapshot
can hide its immediate difference until a later scheduled event exposes it.

Before projecting intentional source/product differences, validate the excluded
inventory's exact peer membership, payload, count, order and allowed position.
Keep controls for invented local-peer events and duplicate notification suffixes.
Mutants of terminal freeze must preserve earlier frame/state consistency checks
so they reach the intended terminal boundary.
For deliberate gameplay divergence, retain valid serialized-state bounds. Drive
the game to domain edges and force rollback after divergence; require a genuine
checksum mismatch rather than accepting an unrelated callback failure.

## Faster local iteration

Use `make test-focus GODOT=/path/to/godot SUITE=res://tests/unit/test_input_queue.gd`
for one suite while changing it. This retains both in-process and fresh-process
repeat layers. Final delivery still runs all applicable suites and controls.
The oracle launcher defaults to four independent scenario workers; `--jobs 1`
selects serial diagnosis. Preserve deterministic receipt order and unique logs.
Clear owned success receipts before validating new execution options, including
malformed worker values; real subprocess controls protect that failure path.

Keep verified source timestamps when bytes, modes, entry inventories and symlinks
match freshly extracted pinned archives. A timestamp-only cache or a hash of an
old receipt is insufficient. Cache downloaded Cargo crates and registry indexes,
then unpack afresh: Cargo does not revalidate already-unpacked `registry/src`
against crate checksums. Never restore that source tree as trusted CI evidence.

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
