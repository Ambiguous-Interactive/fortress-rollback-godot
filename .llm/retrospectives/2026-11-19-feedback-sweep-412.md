# Retrospective: 2026-11-19 unaddressed merged-PR feedback sweep (#412)

## Work Under Review

- Scope: PR #412 (squash `569bfd7`) — adjudicated 54 unresolved review
  threads on merged PRs #398/#400/#401/#403 with current-main evidence;
  fixed the one live defect the sweep found (unbounded deadline-path
  drain, `DRAIN_TOTAL_SECONDS` cap + per-wait budget); strengthened two
  tests per review asks; filed #411 for the documented post-reap
  residual and re-pointed all seven stale owners; dated rechecks on
  #131/#249; 5 commits, ~120 changed lines.
- Trigger: large change (feedback-surface sweep over 4 PRs), external
  knowledge (Linux pidfd UAPI archaeology), corrections (two adversarial
  FIX-FIRST rounds + bot round).
- Evidence base: red-green receipts (external-timeout red exit 124;
  mutation red at 0.017 s; watchdog-shape red re-witness), test_owned_process
  86/86, make test-reference 42/42, lint-source 0 violations, Gate +
  Reference Baseline + Devcontainer Verify + OpenAI (0 findings) green on
  every pushed head; merge-queue grouped candidate qualified.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | Unbounded-loop regression tests need an internal watchdog, and red is witnessed by simulating the broken shape, not by an outer timeout | technique | first drain-test shape hung the runner (external `timeout 25`, exit 124); watchdogged shape re-witnessed red with the bound inflated to 3600 (fired at 6 s) |
| 2 | A corrected factual claim must be swept across prose in the same round — the CHANGELOG contradicted the corrected code comment one commit later | rule | round-1 fixed `owned_process.py` wording; round-2 caught the identical claim still in the new CHANGELOG entry (`8b2c0b2` fixed it) |
| 3 | GitHub MCP `search_issues` ignores offset/limit (duplicate pages); GraphQL brace tails should be generated, not hand-counted | harness | search returned the same issue 3x per page; two GraphQL RCURLY parse errors before `'}' * 7` |
| 4 | The flag-4 pidfd knowledge row verified on touch: live probe 2026-11-19 accepts 1/2/4, rejects 8 (3/5 EINVAL via the kernel's single-scope check) | none (verify-on-touch) | local probe on 6.12.76 against the session-201 row |
| 5 | Bot review findings cluster by file and often duplicate one shape with varied wording; grouping replies by shared evidence text (one SUPERSEDED_405 template) resolved 6 near-identical majors coherently | technique | #403's recycled-zombie cluster — all six resolved with the same #405 supersession evidence |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Watchdogged-regression-test technique + evidence | `../knowledge/transport-tooling.md` | `make lint-llm` |
| 2 | Corrected-claim prose-sweep rule + evidence | `../knowledge/transport-tooling.md` | `make lint-llm` |
| 3 | GraphQL/MCP enumeration gotchas | `../knowledge/harness-tooling.md` | `make lint-llm` |
| 4 | #411 filed; seven stale `#404 owns` pointers → #411 | PR #412 commit `13d7160` | grep + lint |
| 5 | No skill changes; existing skills (ship-session, adversarial-review, user-copy, retrospective) guided the session as written | — | n/a |

## Prune Ledger

- Retired / merged / fixed at source: none — the session-201 pidfd-flag
  row and the session-202 CORRECTED zombie-probe row were verified on
  touch (live probe; docstring grep) and stay accurate.
- Verify-on-touch: flag probe re-run on 6.12.76 (1/2/4 accepted, 8
  EINVAL); `LOCAL_ONLY_DIRS` whitelist confirmed in
  `scripts/llm/llm_paths.py` before adjudicating the #401 link thread.

## Outcome

Retro: findings-acted
