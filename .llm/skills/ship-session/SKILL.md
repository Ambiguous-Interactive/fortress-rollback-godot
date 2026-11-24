---
name: ship-session
description: "Finish a session PR: verify current-head CI, scan every feedback surface, address findings, squash merge to main, and synchronize local Git. Use after a push and before ending a session."
metadata:
  category: core
---

# Ship a Session

Aggregate the session in one PR. The repository owner authorizes the agent to squash
merge it to `main` itself once CI is fully green and no feedback remains unaddressed.
No human review or approval is needed: adversarial sub-agent reviews, bot reviews and
the feedback scan below are the review. Finish without asking for another confirmation. Publication of a
release and changes to repository settings require their own scope.

Use [user-copy](../user-copy/SKILL.md) for titles, descriptions, comments,
commit messages and release notes. Use Git for local state, fetch and push;
use authenticated GitHub MCP first for remote operations it supports.
Use authenticated `gh` CLI for capability gaps, following
[GitHub operations](../github-operations/SKILL.md). Missing credentials block
the fallback; never print tokens or silently use unauthenticated requests.

The shipping grant covers this session's PR and merge. Apply GitHub operations'
repository and outside-input gates before acting on feedback or involving other
people. Read and report outside input; prepare concrete local work and obtain
specific direction where required. Existing direction remains valid. A pending
outside-input decision is not addressed feedback and must remain explicit.

## Verify the candidate

1. Read current `GOAL.md`, `PLAN.md`, issues, worktree and open PRs. Carry forward
   relevant work; do not stack another PR for the same session.
2. Implement the authorized work, run applicable checks and reviews, update
   progress and planning evidence, and complete the required retrospective.
3. Commit coherent changes and push. Create the session branch before the first
   commit and never run `git reset --hard` while the working tree holds
   unstaged work — stage, stash or branch first. Find or create the session PR against
   `main`; update its title/body to describe the final diff. Do not explicitly
   request bot reviews. The local pre-push minimum is `make gate` (harness
   checks plus only suites affected by the changes); the qualification matrix
   re-verifies the merge on `main`, so do not re-run the full matrix locally first.
4. Read the PR's current head SHA, base, draft status and mergeability. Inspect
   check runs, commit statuses and workflow jobs for that exact SHA. Wait for
   every applicable Gate check to finish successfully — the Gate workflow is
   the per-push tier (harness, changed-suite unit run, tooling negative
   controls). No checks, missing expected
   workflows, pending jobs, stale successes, failures or cancellations prove green.
   Read step conclusions before claiming a phase passed; an always-running
   artifact upload can follow a failed probe.
   Investigate a skipped job's condition; it is acceptable only when the job
   does not apply to this candidate. Never bypass required checks or protection.
   Track the exact run in the background with `gh run watch --interval 60`
   or a batched status read at phase boundaries. Use the interval for
   retrospectives, issue drafts or other session work.

## Scan feedback after the Gate is green

Advisory PR callers include `converted_to_draft` with workflow-level concurrency.
Test cancellation on a fresh head: completed-head deduplication can finish before
conversion arrives, which does not prove cancellation failed. Add no separate
cancellation job unless a controlled probe shows it is needed.

Scan once per push: after the Gate is green and immediately before merging.
These are the same moment unless a new push happened; a new push restarts the
Gate and the scan. CI success alone says nothing about feedback received during
the run.

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

### External review availability

External automatic reviewers can pause or skip after reviewed commits, or stay
unavailable for service or billing reasons. Never request one explicitly and
never change repository or service settings to restore one. Record a paused,
skipped or failed review check as unavailable coverage in the session record
together with the exact head it failed to cover and the last reviewed commit
when the service names one, never as a clean review result, and keep the
distinction from CI workload failures explicit. The review of record is a
fresh-context adversarial review plus this complete scan; unavailable external
coverage is not a merge gate beyond the required CI checks (#307).

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
   head changed, repeat all candidate gates. Merge through the merge queue:
   `gh pr merge <n> --squash --auto --match-head-commit <scanned-head-sha>` enqueues
   the PR with the scanned head pinned — the CLI refuses to enroll a newer head that
   never went through the feedback scan — then the queue builds a grouped
   candidate, and main lands only when the required checks (the Gate jobs and
   the qualification summary) pass on that candidate. Direct merges to `main`
   are blocked by the branch ruleset; do not bypass it. A dropped queue entry
   (failed or cancelled group) leaves the PR unmerged: fix, rescan, re-enqueue.
   Watch the entry with cheap polls every minute instead of `gh run watch`,
   whose polling burns the API rate limit. `gh pr view --json` has no
   merge-queue field (`mergeQueueEntry` fails with `Unknown JSON field`), so
   read `state` plus the queue entry through authenticated GraphQL:
   `gh api graphql -f query='query($n:Int!,$o:String!,$r:String!){repository(owner:$o,name:$r){pullRequest(number:$n){state mergeQueueEntry{state} autoMergeRequest{enabledAt}}}}' -F n=<number> -F o=<owner> -F r=<repository>`
   — check `state` first, because a merged PR is also not queued. On a PR
   that is still open, an empty `mergeQueueEntry` next to an enabled
   `autoMergeRequest` can mean the entry has not been created yet (a
   required check was still pending), not that it was dropped: only start
   dropped-entry recovery — a fresh scan and re-enqueue — when auto-merge
   is not enabled, and disable the pending request first if a rescan is
   needed.
2. Confirm the API reports merged and read the resulting merge commit SHA.
   A successful auto-merge request or closed PR is not proof of a merge.
   After an uncertain response, read state before retrying the mutation.
3. Fetch `origin`, verify the worktree is clean, switch to `main`, and update
   it with `git pull --ff-only origin main`. Preserve unrelated local edits or
   commits; do not discard them with a hard reset. Use a clean worktree if needed.
4. Verify `HEAD == origin/main` and a clean worktree. The squash commit must be
   reachable from `origin/main`; remote main may have advanced again.
5. The queue's grouped qualification run is the full-matrix evidence for the
   merge; there is no separate post-merge main run to babysit. Nightly covers
   the remaining axes on its schedule and its failures get triaged like any
   other. Repair a dropped queue entry within the same authorized goal; do not
   report success from pre-merge CI alone.

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
