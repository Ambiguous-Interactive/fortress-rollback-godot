# Retrospective: plain-language stop causes and the /done disposal abort

## Work Under Review

Session 166 shipped two squash merges: PR #341 (shared
`FortressSessionTypes.reason_text()` swept through seven example scenes,
with an exhaustive reason/endpoint test suite) and PR #343 (precise
classification of the exported spectator witness's `/done` disposal
abort, the demonstrated cause #322 could not see before its diagnostics
landed). Trigger: large change plus a merge-triggered main incident.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | Separate numeric enums that share a value space will be misrendered by any shared "reason text" helper — the peer example fed `InputEndpointTypes.Code` into the session helper and rendered INPUT_FAILED (12) as "request expired". Protocol-level fields need their own local mapping or their own helper. | fact | adversarial review finding 1 on `20e7aeb`; `peer.gd` `_endpoint_failure_text` now covers all 14 endpoint members with tests |
| 2 | A fix that classifies a report after the gate that rejects its exit code is dead code: the first #343 candidate ran `acknowledge_disposal_abort` after `_execute` raised on `process.returncode != 0`, so the real witness path would still have failed despite green unit tests on the helper. | fact | CodeRabbit major on PR #343; `classify_browser_output` now owns parsing, classification and the exit-code decision, tested at exit codes 0/1/3 |
| 3 | GitHub API degradation can materialize a partial matrix: a main-push run created 22 of 48 jobs, concluded `failure` with zero failed jobs, and even the rerun request returned 502. Job completeness must be verified (`/jobs total_count`) before diagnosing run failures, and reruns land in healthy windows. | technique | runs `42671297806` attempts 1–3 (22→22→48 jobs) vs PR run `42667396686` (48/48 same tree) |
| 4 | Request-failure instrumentation (#323) turned an intermittent CI flake into a one-look diagnosis: the captured six-field identity (origin/path/method/resourceType/failure/phase) plus the page's published result pinned the `/done` abort as post-completion disposal, not a lost request. | fact | main run 42671297806 attempt 3 browser.log tail; issue #322 |
| 5 | Bot review and the adversarial sub-agent found the same critical defect independently (enum mix-up), and bot review found the ordering defect the sub-agent missed — running both loops is not redundancy. | fact | session log review loop; PR #341 thread + PR #343 major |

## Actions Taken

- Finding 1+2: repairs carry binding tests (exhaustive endpoint coverage;
  execution-path tests for exit codes 0/1/3, stderr, malformed output,
  and nine fatal mutations).
- Finding 3: extends the existing `ci-hosted-runners` knowledge (spaced
  rerun policy) with the job-subset signature; verify `/jobs` total_count
  before RCA.
- Finding 4: the classification keeps the observation visible in the
  receipt (`acknowledged_disposal_abort`) instead of deleting it, so a
  recurrence of a *different* artifact cannot hide behind it.
- #342 opened for the remaining protocol/transport bare codes in the
  online example.

## Prune Ledger

- Considered and rejected: a page-side deferral of HTTPRequest disposal —
  the abort fires long after the page freed the node, so the deferral had
  no evidence; skipped rather than shipping speculative code.
- Existing ship-session, testing and adversarial-review guidance covered
  everything else; no new skill.

## Outcome

- State: `findings-acted`.
- Main CI: 48/48 Reference Baseline jobs plus Devcontainer and Harness
  green on `27a5b18` (51/51 check runs).
- Session length: ~3h50m against the <2h target — the overage came from
  the main-CI incident chain (partial matrix + one real witness failure +
  one review repair); the scoped work itself fit the budget.
