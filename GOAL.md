# Goal

Advance PLAN.md through a green, reviewed, squash-merged session PR

## Objective

- Carry forward any in-progress work.
- Address any [Open Issues](https://github.com/Ambiguous-Interactive/fortress-rollback-godot/issues), ordered by most-gameplay impacting first.
- Drive any open dependency to green (incorporate) if relevant.
- Ensure main CI is green; if it is not, RCA the issue and implement a comprehensive fix.
- See if there were any draft/in-progress PRs from previous sessions and drive those to completion.
- Drive `PLAN.md` improvements as far forward as possible towards accomplishing the full work for the next major milestone(s). Then, open a PR that achieves a fully green state (all CI checks passing, all reviewer feedback addressed). Do not explicitly trigger bot reviews.
- Aggregate all of one session's work into one PR, do not stack PRs.
- After all current-head CI is green, scan every PR feedback surface with complete pagination, including resolved/outdated thread state and check annotations.
- Address all actionable feedback, repeat gates after fixes, and recheck feedback immediately before merge. Follow [.llm/skills/ship-session/SKILL.md](.llm/skills/ship-session/SKILL.md).
- Squash merge the session PR to `main` once green and feedback-complete; this is standing authorization. Verify the merge, fetch, and update local `main` to match `origin/main`.
- Verify merge-triggered main CI before completion.
- Apply [.llm/skills/user-copy/SKILL.md](.llm/skills/user-copy/SKILL.md) to comments, PR titles/descriptions, commit messages and CHANGELOG entries.
- Set editor and formatter maximum source line lengths to 180, and verify all source files with `make lint-source`.
- Target a session shorter than two hours; retain precise follow-up issues for unfinished roadmap work.
- Open detailed issues for any issues or follow-up items.

## Work Style

- **Task-based, red-green, data-backed, exploratory, science-driven.**
- Commit and push freely. Small, coherent commits.
- Address all non-trivial reviewer feedback and CI failures before moving to the next task.

## Fix Philosophy

| Failure type | Fix target |
| --- | --- |
| Production bug | Production code |
| Test bug | Test code |
| Fragile / unnecessary check | Remove or rewrite it |

- Prefer **data-driven tests** over repeated similar test cases.
- Add **diagnostics** when an issue is hard to understand without them.
- When a bug is found, **sweep the codebase** for the same class of problem and fix all instances — eliminate the entire failure mode, not just the immediate symptom.
- **Simplify aggressively.** Do not add tests, scripts, or abstractions unless they prevent a real, recurring issue.

## Quality Bar

Every change must be:

- **Robust and reliable** — not fragile or coupled to implementation details.
- **Complete** — the whole class of problem is addressed, not just the one example.
- **Non-bloating** — no unnecessary files, tests, or scaffolding.

Target: consensus among all reviewers that the result needs zero revisions.

## Progress Tracking

- Log work in `progress/session-NNN-brief-description.md` (literal `progress/` at repo root).
- Unified formatting; descriptive names for easy discovery.
- Keep `PLAN.md` current: remove completed or obsolete items after each session.

## Sub-agent Loop

1. Use sub-agents for parallel or specialized work.
2. After a sub-agent completes, have an **adversarial sub-agent** review it critically.
3. If recommendations exist, have another sub-agent evaluate and implement them.
4. Repeat until all sub-agents agree the result is exceptional with zero issues (minor or otherwise).
5. If not using sub-agents, apply this adversarial review loop on the main thread.
