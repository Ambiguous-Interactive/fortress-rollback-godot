---
name: code-review
description: "Structured code review: two-pass checklist (critical then informational), quote-to-claim evidence gate, confidence calibration, AUTO-FIX/ASK/ADVISORY triage, and a do-not-flag suppression list. Use when reviewing a diff, branch, or PR; before landing changes; or when asked to 'check my code'."
metadata:
  category: core
---

# Code Review

Review exists to find the bugs that pass CI but fail in production — here,
that means determinism and rollback-contract violations. Zero findings is a
valid outcome. Flag only what a senior engineer on this team would change.

## The Rule

One candidate per pass: review the whole diff against its base before editing
anything. Prefer one intent per diff; a refactor mixed with a behavior change
is two diffs. Every finding must quote the motivating code. Findings you
cannot quote are unverified and must not be reported.

## Pipeline

| Step | Do |
| --- | --- |
| 1. Scope | `git diff <base>` (or staged changes). Note diff size; list touched files. |
| 2. Plan check | If the change claims to implement a plan/spec, verify each deliverable. A path-named item is checked with a file/test run, never assumed. Code that *handles* a deliverable is not the deliverable. |
| 3. Critical pass | Work the checklist below, in order. |
| 4. Informational pass | Style, naming, completeness gaps, weak tests. |
| 5. Triage | Classify each finding (see Fix Classification), then fix or report. |

## Critical Checklist (determinism/rollback domain)

1. **Determinism hazards** — any diff line entering simulation code: global
   RNG, wall-clock, transcendentals, physics calls, threads, unsorted
   iteration feeding checksums. Full table:
   [determinism](../determinism/SKILL.md).
2. **State-contract completeness** — a new field in sim state MUST be traced
   through every consumer: serialize, restore, checksum, replay, and
   debug-display. Read each consumer; do not grep. The broken code is usually
   *outside* the diff (a restore path that misses one field only desyncs
   mid-match).
3. **Rollback contracts** — save/restore round-trip completeness, input delay
   accounting, prediction window bounds, checksum including frame + input
   prefix. See [rollback-fundamentals](../rollback-fundamentals/SKILL.md).
4. **Order and aliasing** — `await`/deferred calls inside sim, signal
   ordering assumptions, shared containers mutated across save boundaries.
5. **Enum/value completeness** — a new enum value or state flag: trace it
   through every consumer (serializer, checksum, UI, replay parser). A value
   added to the writer but not the reader corrupts replays silently.
6. **Silent failures** — empty catches in sim or transport, error paths that
   swallow a checksum mismatch, fallbacks that mask divergence.

## Structural Pass

Correctness is necessary but not sufficient. For every non-trivial change, look
for the "code judo" move: a behavior-preserving restructuring that makes the
result dramatically simpler and more inevitable. Treat structure as a design
problem, not a style nit.

1. **Reduce, do not relocate.** Count the concepts a reader must hold. If a
   "cleaner" version leaves that count unchanged, it is not cleaner. Prefer the
   change that deletes whole branches, helpers, modes, or layers.
2. **No spaghetti growth.** A new ad-hoc conditional in an unrelated flow, a
   one-off boolean, or a feature-specific check in a shared path is a missing
   abstraction, unless the branch encodes genuinely different behavior and a
   helper would not reduce the reader's work. Move it behind a typed model,
   dispatcher, policy, or owned module.
3. **Abstractions must earn their keep.** Delete thin wrappers, pass-through
   helpers, and identity layers. Prefer direct, boring code over magic.
4. **Respect the boundary.** Put logic in the canonical layer and reuse the
   existing helper. Do not duplicate a canonical utility or leak feature
   details through a public API.
5. **Keep type contracts honest.** Question unnecessary optionality, casts,
   and silent fallbacks; make the invariant explicit at the boundary.
6. **Watch total size.** A small diff can push a file past a healthy size.
   Decompose when the file stops being scannable; length is an investigation
   trigger, not a correctness defect.
7. **Keep orchestration atomic.** Partial updates that leave state half-applied
   are a design smell. Parallelize only when it also simplifies the flow.

Presumptive blockers when a viable alternative is named and the changed flow
introduces the problem: a refactor that relocates complexity without reducing
it, a new special case in a shared flow, a near-duplicate canonical helper, a
file pushed past a healthy size by accretion, or a wrapper/cast that hides a
real invariant. Route them through the existing classification: a structural
regression in the changed flow is ASK; a pre-existing or speculative
simplification is ADVISORY; a recorded decision in `.llm/research/` is not a
finding. Do not weaken the correctness gates for a structural improvement.

Report structural findings with the same evidence bar: quote the code, name
the simpler move, and state the contract it must preserve.

## Informational Checklist

Completeness gaps (an 80% implementation where 100% costs little — say so),
test quality (see [testing](../testing/SKILL.md) value bar), dead code, stale
comments, style vs [gdscript-style](../gdscript-style/SKILL.md).

## Finding Format and Confidence

```
[CRITICAL] (confidence: 9/10) path/file.gd:42 — <defect>
  Evidence: <verbatim quoted line(s)>
```

| Confidence | Meaning | Display |
| --- | --- | --- |
| 9-10 | Quoted code verifies a concrete defect | report |
| 7-8 | Strong pattern match, plausible failure | report |
| 5-6 | Needs author confirmation | report with caveat |
| 1-4 | Speculation | drop, or note in appendix |

## Fix Classification

| Class | When | Action |
| --- | --- | --- |
| AUTO-FIX | Mechanical; a senior engineer would apply without discussion | Fix directly; say what was fixed |
| ASK | Design decisions, behavior changes, fixes > ~20 lines, anything touching replay format or state layout | Propose, wait for approval |
| ADVISORY | Simplification/extraction suggestions | Recommend only; never auto-apply |

**Regression rule (mandatory, no permission needed):** if the diff breaks
previously working behavior, write the failing regression test first — ask
how to cover it, never whether. Triple-proof protocol:
[testing](../testing/SKILL.md).

## Do NOT Flag

- "Add a comment explaining this" — comments rot; require them only for
  genuinely non-obvious invariants.
- "Function too long" for exhaustive switches, test tables, or data-driven
  setup — length is not complexity.
- Hardcoded expectations in test fixtures — tests are supposed to hardcode.
- Style nits the linter already owns (see
  [llm-harness](../llm-harness/SKILL.md) and gdscript-style).
- A deviation covered by a recorded decision in `.llm/research/` — verify the
  note exists; if it does not, the deviation is unacknowledged debt: report it.

## Checklist

- [ ] Read the full diff before any finding
- [ ] Every finding quotes file:line verbatim
- [ ] New sim-state fields traced through serialize/restore/checksum/replay
- [ ] Regression tests written for any broken behavior (before the fix)
- [ ] Structural pass run; a code-judo move was taken or explicitly ruled out
- [ ] A new special-case branch in a shared path or near-duplicate helper is flagged only with a named simpler alternative; otherwise it is justified as genuinely different behavior
- [ ] Suppression list consulted before reporting nitpicks
- [ ] For high-risk changes: adversarial pass requested (see
      [adversarial-review](../adversarial-review/SKILL.md))

Read remote PR evidence through [GitHub operations](../github-operations/SKILL.md):
authenticated MCP first, then authenticated `gh` for missing capabilities.

## Related

- [debugging](../debugging/SKILL.md) — when review finds a live defect
- [adversarial-review](../adversarial-review/SKILL.md) — fresh-context red team
- Method evidence: `.llm/research/gstack-practices-2026.md`,
  `.llm/research/agentic-verification-2026.md`,
  `.llm/research/goal-and-code-quality-2026.md`
