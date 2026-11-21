# Goal

Complete all objectives, then open a PR that achieves a fully green state:
all required CI checks pass on the PR head, all reviewer feedback is addressed,
and the result is structurally sound.

## Objective

- Carry forward any in-progress work.
- Address open [issues](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues), most gameplay impacting first.
- Drive any open dependency to green (incorporate) if relevant.
- If main CI is red, RCA the failure and implement a comprehensive fix before finishing.
- Drive any draft or in-progress PR from a previous session to completion.
- Drive `PLAN.md` improvements as far forward as possible towards the next major milestone(s).
- Aggregate all of one session's work into one PR; do not stack PRs.
- Follow [.llm/skills/ship-session/SKILL.md](.llm/skills/ship-session/SKILL.md) for delivery.
- Merge through the merge queue after the current-head Gate is green and the
  complete feedback scan is clean. The full matrix qualifies the merge and
  nightly owns the remaining axes, so do not wait on them before merging.
  Verify the queue's grouped qualification outcome and update local `main`.
- Apply [.llm/skills/user-copy/SKILL.md](.llm/skills/user-copy/SKILL.md) to comments, PR titles/descriptions, commit messages and CHANGELOG entries.
- Set editor and formatter maximum source line lengths to 180, and verify all source files with `make lint-source`.
- Target a session shorter than two hours; retain precise follow-up issues for unfinished roadmap work.
- Open detailed issues for any issues or follow-up items.

## Work Style

- **Task-based, red-green, data-backed, exploratory, science-driven.**
- Research modern best practices and relevant SOTA techniques.
- **Small, coherent commits** — keep behavior changes and refactors in separate commits; ship the regression test with its fix.
- Commit and push freely.
- Address all non-trivial reviewer feedback and CI failures before moving to the next task.
- Prefer a deterministic check (test, linter, generator) over a rule the agent must remember.
- Leave touched code better, but do not expand scope into an opportunistic rewrite.

## Fix Philosophy

| Failure type | Fix target |
| --- | --- |
| Production bug | Production code |
| Test bug | Test code |
| Fragile / unnecessary check | Remove or rewrite it |
| Structural problem | The design, not the wording |

- Prefer **data-driven tests** over repeated similar test cases.
- Add **diagnostics** when an issue is hard to understand without them.
- When a bug is found, **sweep the codebase** for the same class of problem and fix all instances — eliminate the entire failure mode, not just the immediate symptom.
- **Simplify aggressively.** Do not add tests, scripts, or abstractions unless they prevent a real, recurring issue.

## Quality Bar

Every change must be:

- **Robust and reliable** — not fragile or coupled to implementation details.
- **Complete** — the whole class of problem is addressed, not just the one example.
- **Structurally simple** — prefer the change that deletes a branch, helper, mode, or layer over one that rearranges the same complexity.
- **Non-bloating** — no unnecessary files, tests, or scaffolding, and no file grows past its length cap or healthy size by accretion.

Before landing, review the diff for a "code judo" move: a behavior-preserving
restructuring that makes the result dramatically simpler. If one exists, take
it; if not, say why the current shape is the simplest credible one.

Target: consensus among all reviewers that the result needs zero revisions.

## Review

- Run the structural pass in [.llm/skills/code-review/SKILL.md](.llm/skills/code-review/SKILL.md) on every non-trivial change.
- Run a fresh-context adversarial review for risky changes, per [.llm/skills/adversarial-review/SKILL.md](.llm/skills/adversarial-review/SKILL.md).
- Do not explicitly trigger bot reviews. The adversarial review and complete feedback scan are the review; no human approval is needed.
- An actionable finding is addressed by a pushed fix with a green check, or by a recorded, reproducible evidence-backed reason it is not a defect. Non-actionable findings are recorded as advisory.

## Progress Tracking

- Log work in `progress/session-NNN-brief-description.md` (literal `progress/` at repo root).
  This directory is machine-local and git-ignored: never commit it, not even with `git add -f`.
- Unified formatting; descriptive names for easy discovery.
- Keep `PLAN.md` current: remove completed or obsolete items after each session.

## Sub-agent Loop

1. Use sub-agents for parallel or specialized work; give each implementation
   sub-agent its own worktree and a fresh context.
2. After a sub-agent completes, have an **adversarial sub-agent** review it
   critically when possible (fresh context: the diff plus the relevant spec
   excerpt, never the author's rationale). If a fresh session is unavailable,
   record the review as unavailable; do not substitute the author's context or
   treat it as a pass.
3. Address actionable findings in **at most one fix round**, then re-review the
   updated diff once. An in-scope actionable finding blocks merge: fix it or
   record reproducible evidence that it is not a defect. Do not loop past the
   one fix round; repeated rounds past that point burn tokens without
   measurably improving the result.
4. If not using sub-agents, apply the same one-round adversarial review loop on
   the main thread.
