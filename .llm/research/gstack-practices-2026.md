# Research: gstack (garrytan/gstack) Practices Analysis

Evidence base for adapting agentic-workflow practices from
[garrytan/gstack](https://github.com/garrytan/gstack) (v1.91.68.0, MIT,
analyzed 2026-10 by cloning the repo and running four parallel deep-dive
reviews of its ~70 skills, `lib/` enforcement code, docs, and eval
infrastructure). Companion note:
[agentic-verification-2026](./agentic-verification-2026.md) holds the
independent research evidence for/against each pattern.

## What gstack Is

A Claude Code skill suite (23 specialist "roles" as slash commands: review,
QA, ship, investigate, plan-eng-review, cso, retro, ...) plus TS/bash helpers
in `lib/` that make gates mechanically verifiable. Defining trait: **distrust
of the agent itself** — gates fail closed, evidence is classified separately
from transport success, and a different context (ideally a different model)
reviews the producer's work.

## Top Transferable Patterns (with gstack sources)

| # | Pattern | gstack source | Adaptation here |
| --- | --- | --- | --- |
| 1 | Three-state gate outcomes: `ran` / `not_run` / `unavailable`; "missing coverage is never a pass" | `lib/gate-outcomes.ts`, `review/sections/adversarial.md` | verification skill + all future gates |
| 2 | Quote-to-claim review gate: findings need verbatim `file:line` quotes; confidence 1-10; <5 suppressed to appendix; explicit DO-NOT-FLAG list | `review/checklist.md` | new `code-review` skill |
| 3 | Iron Law debugging: no fixes without root cause; 3 failed hypotheses -> stop and question architecture; hypothesis table | `investigate/SKILL.md` | new `debugging` skill |
| 4 | Regression-before-repair triple proof: fails at HEAD (bug is real), passes at base (test is valid), passes after fix (repair works) | `ship/sections/test-coverage.md` | extend `testing` |
| 5 | Test Value Bar: 4 questions + one-line value card header on every new test | `docs/test-value-bar.md` | extend `testing` |
| 6 | Coverage taxonomy: positive / negative / error / boundary (0,1,max) / extreme / user-flow (double-submit, stale input, concurrency) | `qa/sections/system-functional.md`, `plan-eng-review` | extend `testing` |
| 7 | Fresh-context (zero-knowledge) review: reviewer gets only diff + spec + rubric; never the author's rationale; structured verdict | `codex/sections/challenge-mode.md` | new `adversarial-review` skill |
| 8 | Plan-completion audit: DONE/PARTIAL/NOT DONE/UNVERIFIABLE; "code that *handles* a deliverable is not the deliverable"; `[ -f path ]` for path-named items | `review/sections/plan-completion.md` | planning template + gate |
| 9 | EARS acceptance criteria: `WHEN <cond> THE SYSTEM SHALL <behavior>` maps 1:1 to test names | AWS Kiro (see companion note) | new plan template |
| 10 | Anti-sycophancy: banned-phrase list, "take a position + state what evidence would change it", third-person reviewer framing | `office-hours/sections/phase-2a` | review/adversarial skills |
| 11 | Freeze-tests gate: agents may not modify/delete existing tests without explicit override label | gstack test-churn discipline; Agenhood | hook + review gate |
| 12 | Mechanical safety hooks, fail-closed polarity by tier: deny-tier boundaries deny on unreadable input; ask-tier conservatively escalates | `freeze/bin/check-freeze.sh`, `careful/bin/check-careful.sh` | future `.githooks` additions |
| 13 | Generated-artifact hygiene: every generated file carries a do-not-edit banner + regen command; digest has a size budget enforced by test | `scripts/gen-agents-digest.ts` | already partial; add banners if stubs drift |
| 14 | STOP-and-Read section loading: skills are decision-tree skeletons; "Read sections/X.md in full; do not work from memory" | all large skills | apply to any skill approaching the 300-line cap |
| 15 | Learnings log: JSONL `{type, key, insight, confidence, source, files}`; `files` enables staleness detection; explicit "no learnings" is required output | `learn/SKILL.md` | defer; research notes cover design-time knowledge |
| 16 | Suppression pragmas with provenance: `gstack:test-value keep reason=...`; orphan debt markers are flagged as forged | `review/checklist.md` | defer until tests exist |
| 17 | Sync-test + first-divergent-tick reporting + flake canary (N runs, assert identical) | GGRS SyncTestSession pattern | extend `testing` when sim code lands |
| 18 | Cross-model review: helps weak generators (+18pp), can HURT strong ones; context separation captures most of the benefit | `scripts/resolvers/outside-voice.ts`; arXiv:2607.21656 | prefer fresh-context subagents; measure before adding a second provider |

## Pattern Details Worth Preserving (verbatim-grade)

1. **Gate epistemics wording**: `unavailable` renders as
   "No review ran; this is missing coverage, not a pass." A timed-out check is
   MISSING COVERAGE, never a clean bill. There is no default branch to PASS;
   PASS must be positively reached.
2. **Pre-emit verification gate**: "If you cannot quote the motivating
   line(s), the finding is unverified. Force its confidence to 4-5."
3. **Regression rule is mandatory, no permission needed**: when an audit
   identifies a regression, the test is written immediately — ask how to
   cover it, not whether.
4. **Base control**: run the new regression test against the base revision in
   a scratch worktree; an assertion failure there marks the test invalid.
5. **Suppression list as anti-nitpick device**: "Zero findings is a valid
   outcome. Flag only what a senior engineer on this team would change."
   Suppressed gems: "add a comment" (comments rot), "function too long" for
   exhaustive switches/test tables (length is not complexity), "possible null
   deref" when a guard in scope already narrows it.
6. **Reviewer isolation**: the reviewer never sees the author's conclusion;
   findings require attacker/boundary/impact framing; agreement is signal,
   never permission. "Repeated self-review in the same session does not help"
   (CCR study) — context separation is the active ingredient.
7. **Plan honesty**: "Code that handles a deliverable is not the deliverable."
   Better to surface 5 items for manual confirmation than silently classify
   them DONE. Discrepancies get a 5-way cause list + IMPACT rating.
8. **Machine checks beat prompt exhortation**: gstack recomputes fingerprints
   and hashes in code so the model cannot self-certify. Our analog: linters +
   generated-file freshness checks (already in place) + future test-churn and
   determinism gates.

## What NOT to Adopt (and why)

| gstack element | Reason to skip |
| --- | --- |
| ~70 skills, 1,100+ line SKILL.mds | Violates our 300-line cap and progressive-disclosure ethos; context rot is evidence-backed (companion note §5) |
| Browser/design/iOS/Supabase skills | Wrong domain (web SaaS vs deterministic Godot sim) |
| Telemetry, model-policy overlays, host rendering | We already solve multi-host via generated stubs; no telemetry by design |
| "Boil the ocean" unconditionally | Half-adopt: completeness is cheap for tests/edge cases; still false for scope creep in a bootstrap repo |
| `rm -rf`-style command blocklists | Godot repo has less destructive surface; revisit when dangerous tooling exists |
| LLM-judge evals of skill docs | No budget until the skill corpus is much larger |

## Decisions (ADR-style)

1. **Adopt the gate vocabulary** (`ran`/`not_run`/`unavailable`) as the house
   standard for any future verification gate; encode it in the planned
   `verification` content rather than ad-hoc prose.
2. **Skills > exhortation**: new disciplines (code review, debugging,
   adversarial review) land as `.llm/skills/<name>/SKILL.md` files following
   the existing template, not as extra rules in `context.md`.
3. **Fresh-context adversarial review is the red/green mechanism**; a second
   model provider is optional and must be measured (companion note §1) before
   becoming a gate.
4. **Determinism tooling is the structural anti-gaming gate**: mutation-style
   checks and checksum canaries cannot be sycophanted; prefer them over
   judge-style gates wherever possible.
5. **Keep the harness small**: gstack proves the ceiling (~70 skills) and the
   cost (87 MB, generated-file sprawl). Our cap discipline stays.

## Open Questions / Future Work

- Validate the proposed `code-review` + `debugging` skills red/green: seed
  known defect classes on a scratch branch, measure detection with vs without
  each skill activated (see companion note §8 for the method).
- Decide the test-churn gate mechanism once `tests/` exists (pre-commit
  classifier A=ok, M/D/R=override-label).
- Re-check gstack releases periodically; its `gate-outcomes` contract and
  test-value bar are still evolving.
