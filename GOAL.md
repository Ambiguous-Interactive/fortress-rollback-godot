# Goal

Complete all objectives, then open a PR that achieves a fully green state:
all required CI checks pass on the PR head, all reviewer feedback is addressed,
and the result is structurally sound. Done means the acceptance check passes
and the evidence (command and output) is quoted; a green claim without evidence
is not a result.

## Objective

- Start from the baseline (main CI, open issues, open PRs, last retrospective)
  and carry forward any in-progress work.
- Address open [issues](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues), most gameplay impacting first.
- Drive any relevant open dependency to green and any draft or in-progress PR from a previous session to completion.
- If main CI is red, RCA the failure and implement a comprehensive fix before finishing.
- Drive `PLAN.md` improvements as far forward as possible towards the next major milestone(s).
- Aggregate all of one session's work into one PR; do not stack PRs.
- Follow [.llm/skills/ship-session/SKILL.md](.llm/skills/ship-session/SKILL.md) for delivery.
- Merge through the merge queue after the current-head Gate is green and the complete feedback scan is clean; the full matrix qualifies the merge and nightly owns the remaining axes, so do not wait on them. Verify the grouped qualification outcome and update local `main`.
- Apply [.llm/skills/user-copy/SKILL.md](.llm/skills/user-copy/SKILL.md) to comments, PR titles/descriptions, commit messages and CHANGELOG entries.
- Set editor and formatter maximum source line lengths to 180, and verify all source files with `make lint-source`.
- Target a session under two hours; open precise follow-up issues for unfinished roadmap work.
- Close with the retrospective: distill the session's lessons into a skill, check or knowledge note and prune what became stale.

## Work Style

- **Task-based, red-green, data-backed, exploratory, science-driven.**
- **Design before code.** Write the smallest spec that fixes the contract:
  goal, invariants, data shape, edge cases and the acceptance check. A design
  that emerges only from local test steps is usually not a design.
- **Red-green means evidence, not theater.** A test is red only when it fails
  for the stated reason; record why, then make it green. The triple proof is in
  [testing](.llm/skills/testing/SKILL.md).
- **Quote the evidence.** For every claim that something is fixed, green or faster, show the command and its output; a conclusion is not data.
- **Exercise the real path.** Where behavior is observable end to end, the acceptance check runs the real system, not only a unit seam.
- **Small, coherent commits** — keep behavior changes and refactors separate; ship the regression test with its fix; each commit leaves the tree green and easy to revert.
- **Make the change easy, then make the easy change.** Refactor under green tests before adding behavior.
- Commit and push freely.
- Treat confirmed CodeRabbit rate limiting on the current PR head as non-blocking once all
  prior CodeRabbit findings are addressed and a complete feedback scan meets the repository's review
  requirements. Check inline threads, submitted review bodies, and PR comments, including out-of-diff
  findings. Record the head SHA, the CodeRabbit rate-limit evidence, and the disposition of its prior
  findings. A pending or missing review alone is insufficient evidence of throttling. Continue through
  normal required CI, review, and approval gates without waiting for another CodeRabbit run. A stale
  CodeRabbit changes request that still blocks GitHub can be dismissed only with existing repository
  authorization and a recorded rationale tied to the addressed head.
- Address all non-trivial reviewer feedback and CI failures before moving to the next task.
- Prefer a deterministic check (test, linter, generator) over a rule the agent must remember.
- **Extract determinism.** If you correct the same thing twice, encode it as a check, a script or a skill; do not rely on prose to prevent a repeat.
- **Three-strike stop rule.** After three failed attempts at the same hypothesis, stop, record the evidence, and re-scope or ask. Do not retry the same approach.
- Leave touched code better, but do not expand scope into an opportunistic rewrite.
- Research modern best practices and relevant SOTA techniques; record the evidence when it changes a decision.

## Fix Philosophy

| Failure type | Fix target |
| --- | --- |
| Production bug | Production code |
| Test bug | Test code |
| Fragile / unnecessary check | Remove or rewrite it |
| Structural problem | The design, not the wording |

- Prefer **data-driven tests** over repeated similar test cases.
- Prefer property, differential or table-driven checks over repeated examples; add an example only when it documents a real boundary.
- Add **diagnostics** when an issue is hard to understand without them.
- When a bug is found, **sweep the codebase** for the same class of problem and fix all instances — eliminate the entire failure mode, not just the immediate symptom.
- **Never weaken a check to make it pass.** A change may not modify the test, lint rule, gate or fixture that judges it; fix the check in a separate commit, with evidence.
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
Because a reviewer asked to find problems will always find something, the bar
is no unresolved actionable finding, not an empty comment list.

## Review

- Run the structural pass in [.llm/skills/code-review/SKILL.md](.llm/skills/code-review/SKILL.md) on every non-trivial change.
- Run a fresh-context adversarial review for risky changes, per [.llm/skills/adversarial-review/SKILL.md](.llm/skills/adversarial-review/SKILL.md).
- A finding must quote the code and name a reproducible failure or a simpler alternative; a finding that cannot do either is advisory, not a blocker.
- Review the current head. After the first fix round, re-review only the new diff; new findings are advisory unless they are correctness, security or structural defects.
- Do not explicitly trigger bot reviews. The adversarial review and complete feedback scan are the review; no human approval is needed.
- An actionable finding is addressed by a pushed fix with a green check, or by a recorded, reproducible evidence-backed reason it is not a defect. Non-actionable findings are recorded as advisory.

## Progress Tracking

- Log work in `progress/session-NNN-brief-description.md` (literal `progress/` at repo root).
  This directory is machine-local and git-ignored: never commit it, not even with `git add -f`.
- Unified formatting; descriptive names for easy discovery.
- Keep `PLAN.md` current: remove completed or obsolete items after each session.

## Sub-agent Loop

1. Use sub-agents for parallel or specialized work; give each implementation sub-agent its own worktree, a fresh context, and a written spec plus the acceptance check.
2. After a sub-agent completes, have an **adversarial sub-agent** review it
   critically when possible (fresh context: the diff plus the relevant spec
   excerpt, never the author's rationale). If a fresh session is unavailable,
   record the review as unavailable; do not substitute the author's context or
   treat it as a pass.
3. Address actionable findings in **at most one fix round**, then re-review the new diff once. An in-scope actionable finding blocks merge: fix it or record reproducible evidence that it is not a defect. Do not loop past the one fix round; repeated rounds burn tokens without measurably improving the result.
4. If not using sub-agents, apply the same one-round adversarial review loop on the main thread.
