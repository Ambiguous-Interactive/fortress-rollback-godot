# Research: Goal Contract and Structural Code Quality (2026)

Evidence base for aligning `GOAL.md` with the upstream goal contract and for
adding a structural pass to `skills/code-review`. Compiled 2026-11-21 from
the cited upstream sources and current engineering guidance. Update this note
when a design decision changes; keep the decision table honest about what was
rejected.

## 1. Upstream goal contract

Source:
[wallstop/llm-knowledge `prompts/goal.md`](https://github.com/wallstop/llm-knowledge/blob/main/prompts/goal.md).

The upstream contract is deliberately short:

- Finish every objective, then open a PR with all CI checks passing and all
  reviewer feedback addressed.
- Work task-based, red-green, data-backed, exploratory and science-driven.
- Prefer data-driven tests, add diagnostics, sweep the whole failure class,
  and simplify aggressively.
- Target zero revisions: robust, complete, non-bloating.
- Log work in `progress/session-NNN-*`; use an adversarial sub-agent loop.

Decision: keep the upstream wording as the top-level contract, then add only
the repository-specific delivery mechanics (Gate tier, merge queue, feedback
scan, 180-column source limit, two-hour session target). The goal is a session
contract, not a second plan or backlog. Budget: 120 lines, enforced by the
length linter and a repository-state test.

The upstream loop says "repeat until all sub-agents agree". This repo caps the
loop at one fix round. Fresh-context separation, not repeated rounds, is the
measured active ingredient: repeated self-review in the same session did not
help (see [agentic verification](./agentic-verification-2026.md) §1).

## 2. Structural quality review

Sources:

- [cursor/plugins thermo-nuclear review](https://github.com/cursor/plugins/blob/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review/SKILL.md).
- [nominal-io refined thermo-nuclear review](https://github.com/nominal-io/nominal-client/blob/main/.agents/skills/thermo-nuclear-code-quality-review/SKILL.md).
- [addyosmani/agent-skills PR #304](https://github.com/addyosmani/agent-skills/pull/304),
  which folds structural-depth lenses into an existing code-review skill.

The useful core is not "be harsh". It is a small set of review moves:

1. **Reduce, do not relocate.** A refactor that leaves the same number of
   concepts is not cleaner. Prefer the shape that deletes branches, helpers,
   modes or layers.
2. **Name the simpler move.** "This is messy" is not a finding. Quote the code,
   name the restructuring, and state the contract it must preserve.
3. **Treat spaghetti growth as design failure.** New ad-hoc conditionals in
   shared flows, one-off booleans and feature checks signal a missing
   abstraction, not a style nit, unless the branch encodes genuinely different
   behavior and a helper would not reduce the reader's work.
4. **Make abstractions earn their keep.** Thin wrappers, identity layers and
   magic generic mechanisms add indirection without clarity.
5. **Keep logic in the canonical layer.** Reuse the existing helper; do not
   duplicate a concept or leak feature detail through a public boundary.
6. **Watch total size, not only diff size.** A small diff can push a file past
   a healthy boundary. The upstream 1,000-line trigger is a heuristic, not a
   repository cap: this repo enforces 180 source columns and 300-line `.llm`
   markdown, with `PLAN.md` at 180 lines and `GOAL.md` at 120. File size is an
   investigation trigger, not a correctness defect.
7. **Presumptive blockers** (relocated-not-reduced complexity, a new special
   case in a shared path, a near-duplicate canonical helper, a file pushed past
   a healthy size by accretion) are worth blocking only when the changed flow
   introduces the problem and the reviewer can name a viable simpler
   alternative. Route them through ASK/ADVISORY; a recorded decision is not a
   finding.

Decision: add a structural pass to `skills/code-review`, not a new skill. A
separate `structural-review` skill would overlap the existing review trigger
and increase skill-shadowing risk; the refined upstream PR reached the same
conclusion. File size alone is an investigation trigger, not an automatic
blocker.

## 3. Kite-Flying-Plate-Spinning

Source:
[ChrisLucian-HunterIndustries/Kite-Flying-Plate-Spinning](https://github.com/ChrisLucian-HunterIndustries/Kite-Flying-Plate-Spinning).
It is an agent-instruction bootstrap: `AGENTS.md` composed from `wind/*.md`
elements, with optional skills and MCP servers.

Adopted, because each closes a real gap or reinforces an existing gate:

| Practice | Why it is useful here | Where it landed |
| --- | --- | --- |
| Characterization tests before refactoring | Records current behavior, including quirks, so a behavior-preserving refactor has a safety net | `skills/testing` |
| Make the change easy, then make the easy change | Names the preparatory-refactoring move already implicit in the review discipline | `skills/testing` characterization section |
| Small safe commits; refactor and behavior separate | Keeps each diff provable and reversible; matches Google's small-CL guidance | `GOAL.md` work style |
| Extract determinism | A repeated mechanical rule belongs in a test, linter or generator, not prose | `GOAL.md` work style + `context.md` rule |
| Scout rule, modified | Pay down local debt in touched code, bounded by the no-opportunistic-rewrite rule; the source version's coverage/file/mutation checklist is too broad for a scoped session | `GOAL.md` work style |
| Lean wastes and single/double-loop learning | The retrospective already evaluates process and prunes stale knowledge | Existing `skills/retrospective` |

Rejected, because the cost exceeds the benefit for this repository:

- The RACN commit-notation MCP server and the optional TDD MCP server: no need
  to add a service dependency; the same discipline is already enforced by
  tests and review.
- The canary emoji is harmless but adds nothing here. The per-session "create
  a new skill/MCP server" mandate is the actual problem: it encourages library
  growth without an evidence gate, the documented failure mode behind skill
  shadowing.
- Wholesale OWASP/IoT checklists: useful for a web service, not a GDScript
  rollback library; the relevant untrusted-input boundaries are already
  covered by `networking-transport` and the adversarial review.
- A blanket 500-line file gate: the repository already enforces 300-line
  `.llm`, 180-line `PLAN.md`, 120-line `GOAL.md` and 180-column source limits.
  A source-line gate would duplicate review judgment instead of replacing it.

## 4. Modern practice evidence

| Topic | Evidence | Consequence here |
| --- | --- | --- |
| TDD and short cycles | A 12-experiment family found mixed TDD results ([arXiv:2011.11942](https://arxiv.org/abs/2011.11942)); a review of the evidence found short, steady cycles mattered more than test-first order ([IEEE Software](https://www.cse.unr.edu/~dascalus/Paper_JAMES.pdf)). A three-month industrial study found fewer bugs and better tests with TDD ([IEEE TSE 2022](https://dl.acm.org/doi/10.1109/TSE.2020.3027522)). | Keep red-green, but judge the cycle by a failing test and a small batch, not by ritual. |
| Mutation testing | Scope runs to changed files; a surviving mutant is a missing assertion unless it is equivalent; do not chase 100% because equivalent mutants exist ([Stryker](https://stryker-mutator.io/docs/), [PIT](https://pitest.org/), [Test Double](https://testdouble.com/insights/keep-your-coding-agent-on-task-with-mutation-testing)). | Add a targeted sensitivity rule to `skills/testing`. |
| Review size | Google's small-CL guidance: about 100 lines is reasonable, 1,000 is usually too large; keep refactors separate ([eng-practices](https://google.github.io/eng-practices/review/developer/small-cls.html)). | Goal says small coherent commits; review asks for one intent per diff. |
| Review standard | Google: the standard is improving overall code health, not perfection; design and complexity are first-class review topics ([standard](https://google.github.io/eng-practices/review/reviewer/standard.html)). | Structural findings are legitimate review findings, not optional polish. |
| Small batches | DORA finds small batches predict delivery performance, and AI-assisted teams are tempted into larger changes ([DORA](https://dora.dev/capabilities/working-in-small-batches/)). | Keep the two-hour session target and one-PR aggregation. |
| Agent instructions | The AGENTS.md standard favors short, imperative, command-first files with a brief project overview ([agents.md](https://agents.md/)); the 2026 census measures file contents, not outcomes ([census](https://arxiv.org/abs/2610.31715)). Evidence on the value of long overviews is mixed, so keep them short. | Keep `GOAL.md` outcome-oriented and link procedure into skills. |
| Fresh-context review | The repo's existing evidence note records that fresh-context review beats same-session self-review; the Claude Code team also runs a fresh subagent review before PRs ([agentic verification](./agentic-verification-2026.md), [Claude Code review](https://claude.dev/blog/solving-code-review-at-anthropic/)). | Keep adversarial review for risky changes; do not replace it with repeated self-review. |
| Property-based testing | Seeded properties plus shrinking find unknown unknowns while remaining reproducible ([fast-check](https://fast-check.dev/docs/introduction/why-property-based), [Antithesis](https://antithesis.com/docs/resources/property_based_testing)). | Existing determinism/metamorphic tests remain the right tool; no new framework needed. |
| Definition of done | Outcome-oriented done separates output quality from impact ([Scrum.org](https://www.scrum.org/resources/blog/delivering-not-finish-line-outcome-and-impact)). | The goal names the outcome (green, reviewed, merged) before the task list. |

## 5. Decisions

| Decision | Evidence | Consequence |
| --- | --- | --- |
| Upstream goal stays the top-level contract | Source goal.md | `GOAL.md` opens with completion + fully green + feedback addressed |
| Structural pass in the existing review skill | Thermo-nuclear sources + addyosmani PR #304 | No new overlapping skill; `code-review` gains a "code judo" section |
| Characterization before refactor | Kite + legacy-code practice | `testing` gains a short section and a rule |
| Mechanical rules become checks | Kite "Extract Determinism", existing harness design | The goal cap is enforced by `check_llm_file_lengths`; required phrases and skill sections are pinned by `test_llm_repo_state` |
| No wholesale Kite/OWASP/RACN adoption | Scope and maintenance cost | Keep the harness small; add only evidence-backed practices |

## 6. Open questions

- Measure the structural pass against a seeded defect corpus, using the method
  in [agentic-verification-2026](./agentic-verification-2026.md) §8. Detection
  per class and false-positive count are the dependent variables.
- The goal cap is enforced by `check_llm_file_lengths`; keep the phrase
  contract in the repository-state test. If the phrase list grows too broad,
  split it by contract (upstream, delivery, quality) rather than weakening it.
- Revisit the 120-line goal budget after a few sessions; the linter and test
  make the budget explicit, so changing it is a visible decision rather than
  drift.
