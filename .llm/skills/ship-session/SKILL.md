---
name: ship-session
description: "Finish a session PR: verify current-head CI, scan every feedback surface, address findings, squash merge to main, and synchronize local Git. Use after a push and before ending a session."
metadata:
  category: core
---

# Ship a Session

Aggregate the session in one PR. The user's standing instruction authorizes its
squash merge to `main` once CI is fully green and no feedback remains unaddressed.
Finish this sequence without asking for another confirmation. Publication of a
release and changes to repository settings require their own scope.

Use [user-copy](../user-copy/SKILL.md) for titles, descriptions, comments,
commit messages and release notes. Use Git for local state, fetch and push;
use authenticated GitHub MCP first for remote operations it supports.
Use authenticated `gh` CLI for capability gaps, following
[GitHub operations](../github-operations/SKILL.md). Missing credentials block
the fallback; never print tokens or silently use unauthenticated requests.

## Verify the candidate

1. Read current `GOAL.md`, `PLAN.md`, issues, worktree and open PRs. Carry forward
   relevant work; do not stack another PR for the same session.
2. Implement the authorized work, run applicable checks and reviews, update
   progress and planning evidence, and complete the required retrospective.
3. Commit coherent changes and push. Find or create the session PR against
   `main`; update its title/body to describe the final diff. Do not explicitly
   request bot reviews.
4. Read the PR's current head SHA, base, draft status and mergeability. Inspect
   check runs, commit statuses and workflow jobs for that exact SHA. Wait for
   every applicable CI check to finish successfully. No checks, missing expected
   workflows, pending jobs, stale successes, failures or cancellations prove green.
   Read step conclusions before claiming a phase passed; an always-running
   artifact upload can follow a failed probe.
   Investigate a skipped job's condition; it is acceptable only when the job
   does not apply to this candidate. Never bypass required checks or protection.

## Scan feedback after green CI

Scan after every push, **again after all CI is green**, and immediately before
merging. CI success alone says nothing about feedback received during the run.

| Surface | Authoritative read |
| --- | --- |
| Inline comments and complete thread conversations | PR review comments plus GraphQL/MCP review threads |
| Submitted reviews | PR reviews, including request-changes bodies |
| Conversation comments | Issue comments on the PR number |
| Check findings | Current-head check runs and every check's annotations |

Read every page, including nested thread comments and annotations. Prefer human
threads first. Outdated comments can still identify unfixed defects; a reply or
an approval is not proof that a finding was addressed. Read follow-ups too.
Resolve fixed threads after the fix is pushed; explain a declined finding with
evidence and leave any requested decision explicit. Active change requests or
unaddressed actionable findings block merge, even when no thread is open.

Use GitHub MCP to read threads and resolution state. For unsupported surfaces,
use authenticated `gh` CLI. Then run the authenticated coverage backstop, using
the full verified head SHA:

```sh
python3 scripts/github/pr_feedback.py --pr 123 --expected-head <full-head-sha>
```

Read the whole JSON output. This script inventories all four REST surfaces and
annotations; it does not adjudicate findings or infer thread resolution.
If MCP cannot prove pagination/completeness, use authenticated `gh api graphql`
to read every remaining page of threads/comments. Missing authentication, API
failure, rate limits, truncation or incomplete pagination are missing coverage,
never a clean verdict. Do not infer conversation coverage from inline comments.

For each finding, reproduce and classify it; fix valid issues and sweep the
same failure class. Reply with the fix commit or a short evidence-backed reason.
Link a follow-up issue only when the finding is outside the accepted scope;
an issue does not turn an in-scope defect into addressed feedback.
Any code change restarts applicable tests, CI and the post-green feedback scan.
Record the head SHA, scan time, CI evidence and finding dispositions in the
session log or linked issue. Do not make an automated clean claim from counts.

## Squash merge and synchronize

1. Re-read PR head/base, checks, statuses and feedback just before merge. If the
   head changed, repeat all candidate gates. Merge only the reviewed SHA, using
   squash and the API's expected-head precondition where available.
2. Confirm the API reports merged and read the resulting merge commit SHA.
   A successful auto-merge request or closed PR is not proof of a merge.
   After an uncertain response, read state before retrying the mutation.
3. Fetch `origin`, verify the worktree is clean, switch to `main`, and update
   it with `git pull --ff-only origin main`. Preserve unrelated local edits or
   commits; do not discard them with a hard reset. Use a clean worktree if needed.
4. Verify `HEAD == origin/main` and a clean worktree. The squash commit must be
   reachable from `origin/main`; remote main may have advanced again.
5. Observe merge-triggered main CI to its terminal state. Repair new failures
   within the same authorized goal; do not report success from pre-merge CI alone.

## Source precedents

Adapted from sibling repository evidence inspected during session 003:

- `wallstop/unity-helpers` at `28d37d270c495f3e7416cf64a58db1e50212762b`,
  `.llm/references/ship-changes-part-3.md` and `.llm/skills/github-operations.md`:
  four feedback surfaces, post-push and completion scans, current-head merge.
- `wallstop/IshoBoy` at `08bd8a7e19a2edc99c70f7b53a25e27b8dc24754`,
  `.llm/skills/address-review-feedback/SKILL.md`: paginated resolution-aware
  threads, late human feedback, failed scans never treated as clean.

These are procedural precedents. The standing squash-merge authorization and
requirement for fully green CI come from this repository's user instruction.
