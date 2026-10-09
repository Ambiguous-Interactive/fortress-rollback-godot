---
name: debugging
description: "Root-cause debugging discipline: the Iron Law (no fixes without investigation), deterministic reproduction, testable hypotheses, 3-strike stop rule, triple-proof regression repair, and a structured incident report. Use when a bug, desync, misprediction, flaky test, or 'something doesn't work' appears."
metadata:
  category: core
---

# Debugging

## The Rule (Iron Law)

**No fixes without root-cause investigation first.** Fixing symptoms creates
whack-a-mole: every un-root-caused fix makes the next bug harder to find.
Never say "this should fix it" — verify and prove it.

## Pipeline

| Phase | Do | Exit condition |
| --- | --- | --- |
| 1. Reproduce | Deterministically, by construction: fixed seed + fixed input log + checksum trace. A sim bug you cannot reproduce is not understood yet. | Minimal repro captured (seed, inputs, tick) |
| 2. Localize | For desyncs: print the diverging checksum pair + frame + input prefix; bisect the input log to the first divergent tick. Check `git log` — a recent regression means the cause is in that diff. | One testable hypothesis: "X is wrong because Y" |
| 3. Predict | Before touching code, state what the hypothesis predicts: "if true, checksum diverges at tick N only when input I arrives at tick M". | Written prediction |
| 4. Test | One variable at a time. Temporary logging/assertions are removed after. A falsified hypothesis sends you to Phase 2 — do not guess. | Hypothesis confirmed or 3-strike rule |
| 5. Repair | Smallest change at the root cause. Regression test FIRST (see below), then fix. | Triple proof green |
| 6. Verify | Rerun the ORIGINAL repro + the full determinism suite. Fresh evidence only — a prior pass on old code is not verification. | Report written |

## Failure Signature Table

| Signature | Likely cause class | First checks |
| --- | --- | --- |
| Desync mid-match only | Missing field in save/restore, or unsnapshotted RNG state | Diff state layout; walk every field through restore |
| Desync on specific input | Non-deterministic ordering (Dictionary/set iteration, signal order) | Sort keys; force the ordering in a test |
| Diverges on other platform/build only | Transcendental math, `hash()` builtin, float reordering, `String.to_float` | Grep sim path for forbidden ops ([determinism](../determinism/SKILL.md)) |
| Misprediction storm | Input delay misaccounted, prediction window overrun | Trace one input end-to-end with tick stamps |
| Works in editor, fails exported | `@export` bypassing constructor, debug-only gates inside sim | Check `OS.is_debug_build()` usage in sim path |
| Flaky (passes N-1 of N runs) | It is NOT flaky — it is a desync with unseeded entropy somewhere in the test harness | Seeded everything? See [testing](../testing/SKILL.md) |

## The 3-Strike Rule

If three hypotheses fail, STOP. Question the architecture, not your luck:
(A) continue with a new, explicitly-reasoned hypothesis, (B) escalate to the
user — "this may be an architectural issue rather than a bug", or (C) add
instrumentation and pause. Red flags that you are off-track:

- "Quick fix for now" — there is no "for now".
- Each fix reveals a new problem elsewhere — wrong layer, not wrong code.
- Proposing a fix before tracing the data flow — you are guessing.

## Repair Protocol (triple proof)

1. **Fails at HEAD**: the new regression test fails on the current code,
   proving the bug is real (not a bad fixture).
2. **Passes at base**: the same test passes on the base revision (e.g. the
   recorded replay/checksum from before the regression), proving the test
   tests the contract, not the bug.
3. **Passes after fix**: green after the repair, plus the full suite.

When uncertain whether something is a regression, err on the side of writing
the test. Test-only commits are always allowed; product fixes are rationed by
evidence.

## Report Format

```
Symptom: <observed, with seed/tick/checksum>
Root cause: <one paragraph, file:line>
Fix: <file:line, one sentence why this is the root cause>
Evidence: repro output before/after; suite output
Regression test: tests/... (fails-at-HEAD proof noted)
Status: DONE | deferred (with follow-up note)
```

## Checklist

- [ ] Reproduction is deterministic (seed + inputs recorded)
- [ ] Root cause stated as a testable claim before any fix
- [ ] Fewer than 3 failed hypotheses, or escalated
- [ ] Regression test written before the fix; triple proof recorded
- [ ] Temporary instrumentation removed
- [ ] Full determinism suite green on the final state

## Related

- [testing](../testing/SKILL.md) — suite layout, value bar, triple proof
- [determinism](../determinism/SKILL.md) — forbidden-op table
- [rollback-fundamentals](../rollback-fundamentals/SKILL.md) — session contracts
- [retrospective](../retrospective/SKILL.md) — incidents close with a retrospective update
