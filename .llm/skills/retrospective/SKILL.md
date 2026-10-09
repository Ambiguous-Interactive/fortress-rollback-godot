---
name: retrospective
description: "MANDATORY post-work self-improvement loop: after any large change or incident, analyze the work with evidence, distill durable lessons into skills/knowledge/research, prune what became stale, and record the outcome. Use after finishing a large task, subsystem, harness change, or debugging incident; when the user asks to reflect, retro, self-improve, capture lessons, or update skills; before ending any session that hit corrections, surprises, or rework."
metadata:
  category: core
---

# Retrospective (Post-Work Self-Improvement Loop)

Every large piece of work ends against the harness that guided it:
analyze the finished work with evidence, move durable knowledge to its
canonical home, prune what the work made stale, and record the outcome.
Skipping is allowed only through an explicit waiver — never by silence.

## Why

Three results drive this loop (evidence and citations:
[../../research/agent-self-improvement-2026.md](../../research/agent-self-improvement-2026.md)):

1. Curated lessons measurably improve later work; uncurated capture adds
   nothing (SkillsBench: curated +16.2pp, self-generated +0.0pp).
2. Knowledge stores rot silently: unpruned skill libraries degrade agent
   performance below the no-skill baseline ("library drift"), and
   overlapping skill descriptions degrade selection by up to 21%
   ("shadowing").
3. Reflection works as a separate, evidence-first phase — not as an
   afterthought inside the task session.

## When Mandatory

Run the full loop after any of these (when in doubt, run it):

| Trigger | Threshold / example |
| --- | --- |
| Large change | > ~300 changed lines or > 10 files (excluding generated) |
| New capability | new subsystem, new skill, new workflow, harness change |
| Incident | debugging session, flaky test, desync, >= 3 failed hypotheses |
| Corrections | user pushed back on approach or output during the task |
| External knowledge | research, doc dives, or tool archaeology were needed |
| On request | "reflect", "retro", "self-improve", "capture lessons" |

## Waiver (explicit, never silent)

Small work may skip the loop, but the skip must be stated in one line
before the task is called done: `Retro: waived — <reason>` (e.g. "typo
fix, nothing generalizable"). "No findings" is also a recorded outcome,
not an omission. Unstated is not a state.

## The Loop

### 1. Evidence (data before vibes)

Collect before judging: diff stat, test/lint output, commands that
failed, corrections received, dead ends, time sinks. Quote file:line.
A finding that cannot cite evidence is discarded.

### 2. Harvest

With the evidence in hand, ask:

- What was harder or slower than it should have been? Why?
- What did I look up twice? What surprised me? What did I get wrong first?
- What worked unusually well? (Reinforce successes, don't just fix pain.)
- Did any documented knowledge turn out stale, wrong, or missing?
- Which failures are systematic (need a technique) vs one-off trivia?

### 3. Distill — route each finding to its canonical home

| Finding is... | Route to | Form |
| --- | --- | --- |
| Reusable procedure/technique | [skills](../../skills/) | update an existing SKILL.md first; new skill only if triggers don't overlap |
| Operational fact / gotcha / trivia | [knowledge](../../knowledge/) | one fact + evidence + verify date |
| External evidence / research | [research](../../research/) | cited note, ADR entry |
| Critical invariant | `context.md` rule + owning skill | one line, link out |
| Harness/tooling gap | `scripts/tests/` + `scripts/llm/` | red-green: failing test first |
| Nothing durable | retro artifact only | explicit "no finding" row |

Bias to UPDATE over CREATE: `grep -ri <topic> .llm/` before writing;
extending an existing skill beats a new one that shadows it.

### 4. Prune — the loop is bidirectional

The store, not the backlog, is the asset. Every retro that writes must
also consider:

- **Retire**: entries the work proved wrong, superseded, or obsolete.
- **Merge**: duplicates and near-duplicates (overlap degrades selection).
- **Fix at source**: contradictions get one corrected authoritative
  entry — never a second, conflicting one.
- **Verify on touch**: rerun any command a touched entry claims works.
- **Erosion guard**: do not retire an old claim until its replacement is
  verified (lint + tests green). Over-pruning is a documented failure
  mode too.

### 5. Verify and record

- Tooling changed? The failing test was written first (red), then the
  code (green).
- `make llm-index && make lint-llm && make test-llm` — regenerated index
  and stubs are committed together with the content.
- Findings existed? Write the retro artifact from
  [../../templates/RETROSPECTIVE.template.md](../../templates/RETROSPECTIVE.template.md)
  into [../../retrospectives/](../../retrospectives/) as
  `YYYY-MM-DD-<slug>.md`. A waiver line replaces it only when nothing
  was learned.
- End the task report with exactly one outcome line:
  `Retro: findings-acted | waived — <reason> | no-findings`.

## Curation Gates (every write passes all of these)

- [ ] Evidence cited: command + output, file:line, or measurement
- [ ] `.llm/` searched first; no duplicate home for the same knowledge
- [ ] Placed at the lowest level that fits (fact < technique < rule)
- [ ] New skill: description states what + when with concrete triggers,
      does not overlap an existing skill's triggers; `make llm-index` run
- [ ] No rot-prone phrasing ("as of version X" gets a verify-on-touch
      date instead)

## Budgets (revisit these numbers in retros)

| Signal | Action |
| --- | --- |
| `skills/` exceeds ~20 skills | consolidation pass: merge shadowing skills |
| knowledge entry unreferenced for ~10 retros | retirement candidate (verify first) |
| retrospectives/ exceeds ~15 files | distill recurring patterns into skills; summarize old retros |
| same finding appears in 3 retros | it was never actually addressed — fix the system, not the symptom |

## Roles

- Default: the task agent runs the loop itself, immediately after
  verification and before reporting done.
- Large or contentious changes: dispatch a fresh-context subagent as
  curator with the diff + collected evidence, mirroring
  [../adversarial-review/SKILL.md](../adversarial-review/SKILL.md) —
  authors are the worst judges of what they learned.

## Checklist

- [ ] Trigger evaluated; waiver stated if skipped
- [ ] Evidence collected before conclusions
- [ ] Every persisted item passed the curation gates
- [ ] Prune ledger considered (retire / merge / fix / verify)
- [ ] `make llm-index && make lint-llm && make test-llm` green
- [ ] Outcome line recorded: `findings-acted | waived | no-findings`

## Related

- [debugging](../debugging/SKILL.md) — incident reports feed retrospectives
- [code-review](../code-review/SKILL.md) — findings triage reused here
- [adversarial-review](../adversarial-review/SKILL.md) — fresh-context curator
- [llm-harness](../llm-harness/SKILL.md) — editing the stores safely
