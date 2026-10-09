# Research: Agent Self-Improvement Loops (2026)

Evidence base for the mandatory post-work retrospective loop
(`skills/retrospective`). Compiled 2026-10 from current agent-memory and
skill-library literature plus practitioner write-ups. Update whenever a
design decision changes; cite sources inline. Companion notes:
[agentic-verification-2026](./agentic-verification-2026.md) (review
evidence), [agent-instruction-files-2026](./agent-instruction-files-2026.md)
(harness layout).

## 1. Post-task reflection works — as a separate phase

- Reflexion: verbal self-reflection stored across attempts improves
  retry success without weight updates.
  https://arxiv.org/abs/2303.11366
- ExpeL: contrasting successful and failed trajectories extracts
  transferable insights; but concatenating every insight into prompts
  scales poorly — retrieval must be relevance-gated.
  https://arxiv.org/abs/2308.10144
- Agent Workflow Memory: inducing reusable workflows from trajectories
  beats one-off experience; workflows must be curated, not dumped.
  https://arxiv.org/abs/2409.07429
- Grounding Agent Memory: post-task curation is best run by a *separate*
  curator phase, not as a tail end of the task session — the curator
  evaluates outcomes the task agent cannot judge neutrally.
  https://arxiv.org/pdf/2609.11060
- Implication: the retro is a distinct loop with its own evidence step,
  and a fresh-context curator is preferred for large or contentious work
  (mirrors the fresh-context rule in
  [agentic-verification-2026](./agentic-verification-2026.md) §1).

## 2. Curation fidelity — not capture — is the active ingredient

- SkillsBench result (via the compression-spectrum paper): curated
  skills improved pass rates by +16.2pp while LLM-self-generated skills
  provided +0.0pp. Compression alone is worthless; the quality gates
  around it decide whether an artifact is knowledge or noise.
  https://arxiv.org/html/2604.15877v2
- ACE-style loops (reflect -> curate -> grow -> *refine* with
  deduplication and pruning) exist specifically to prevent context bloat.
  https://github.com/kvyb/llmace
- Implication: every write in the loop passes an evidence gate (cite a
  command, file:line, or measurement), a dedup gate (search `.llm/`
  first), and a placement gate (lowest level that fits).

## 3. Knowledge stores rot without lifecycle governance

- Library drift: unbounded skill accumulation degrades agent performance
  *below the no-skill baseline* (silent failure; end-task metrics decline
  without an explicit error). The verified fix is outcome-driven
  retirement + a bounded active cap.
  https://arxiv.org/html/2605.19576v1
- The same paper's ablations show the opposite failure too: harsh
  retirement ("erosion") collapses the library and *also* drops
  performance below baseline. Governance must be moderate.
- Skill shadowing: growing a library from a helpful set to 202 skills
  dropped pass rates up to 21%, driven by *selection failures* from
  overlapping descriptions — not by context size. Bias updates toward
  existing skills; new skills need non-overlapping triggers.
  https://www.alphaxiv.org/abs/2605.24050v1
- Memory rot: stale facts, unresolved contradictions, compression drift,
  and "retrieval pollution" (reversed decisions still matching queries);
  deletion is the least-implemented operation in most memory systems.
  https://memoryrot.com/essay
- Skill drift as contract violation: skills referencing external tools
  and commands decay silently; verify-on-touch (rerun the command a fact
  or skill claims works) is the cheap defense.
  https://arxiv.org/pdf/2605.10990
- Implication: the loop is bidirectional — every retro that writes must
  also consider retiring, merging, fixing at source, and re-verifying;
  and it guards against over-pruning (never retire before the
  replacement is verified).

## 4. Store knowledge at the right compression level

The compression-spectrum paper unifies episodic traces, procedural
skills, and distilled rules on one axis: raw experience is cheap but
low-value; distilled, verified procedures are the high end, and
"distilling traces into abstract skills consistently outperforms storing
them in retrieval memory banks". https://arxiv.org/html/2604.15877v2

This repo's mapping:

| Level | Store | Contents |
| --- | --- | --- |
| Episodic | `.llm/retrospectives/` | dated retro artifacts (what happened, evidence, actions) |
| Semantic | `.llm/knowledge/` | verified operational facts and gotchas |
| Procedural | `.llm/skills/` | reusable techniques and workflows |
| Normative | `.llm/context.md` | one-line critical rules linking to skills |
| Evidence | `.llm/research/` | external citations justifying the above |

## 5. Practitioner patterns agree

- CLAUDE.md self-improvement loops (community pattern): log every user
  correction, distill it into a prevention rule, promote broadly
  applicable lessons into instruction files. Recurrence-based promotion
  thresholds (e.g. seen >= 3 times across >= 2 tasks) keep noise out.
  https://github.com/TobiasEdman/agentic-workflow-lessons
- Anthropic skill authoring guidance: iterate on skills based on real
  usage ("refine descriptions if triggering is inconsistent"); the
  description (what + when) is the trigger surface; avoid time-sensitive
  phrasing that rots.
  https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices
- Small libraries (< ~20 skills) need light governance; ritual-heavy
  versioning costs more than it prevents.
  https://www.agentpatterns.ai/tool-engineering/skill-library-evolution
- Implication: thresholds and budgets in the skill are deliberately
  soft (~300 lines, ~20 skills, ~10 retros) and revisited by the loop
  itself.

## 6. Decisions for this harness (ADR-style)

1. **Mandatory after a threshold, with an explicit waiver** — trigger
   list in the skill; skipping is a recorded one-liner, never silence.
   Small work should not pay ceremony; large work may not skip.
2. **Fails-closed outcome states**: every task ends `findings-acted`,
   `waived — reason`, or `no-findings`. Unstated is not a state.
3. **Evidence gate on every write** (decision 2 above): no vibes in the
   stores; unquotable findings are discarded, matching the review rule.
4. **Update-over-create bias** to prevent shadowing; new skill
   descriptions must not overlap existing triggers.
5. **Bidirectional loop**: prune ledger (retire/merge/fix/verify) is a
   required retro section, with the erosion guard (verify replacement
   first).
6. **Enforcement reuses the existing three layers**: the new self-test
   (`scripts/tests/test_retrospective_loop.py`) pins structure; the
   meta-lint, length linter, hooks, and CI cover everything under
   `.llm/` automatically — no new tooling paths.
7. **Dogfood at birth**: the loop's first retro documents the loop's own
   construction, serving as the worked example.
