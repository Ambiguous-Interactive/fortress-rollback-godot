# Retrospective: `2026-11-18 pr-feedback-sweep`

## Work Under Review

- Scope: session 201's cross-PR feedback sweep — triage and adjudication of
  every unresolved review thread on the PRs merged 2026-11-03..11-18
  (#321–#402: 50 threads on #367/#369/#370/#382/#398/#400), plus the fixes
  in session PR #403 (owned-process tail containment, report-phase
  reservation, zombie-aware reaped probe, drift classifier fail-closed
  gates, merge-queue docs) and the three in-PR review rounds that followed
  (OpenAI, adversarial subagent, CodeRabbit/Bugbot at each head).
- Trigger: large change; multiple review rounds with actionable findings
  (adversarial round 1: post-settle emit corruption; OpenAI: anomaly
  ordering + GraphQL variable bindings; final-head CodeRabbit: atomic
  phase ownership, emit-drain restoration, registration lifetime).
- Evidence base: owned_process 90/90 + drift (combined run), reference
  suite 42 files 0 failed, harness suite green, lint-source 552 files 0
  violations, red-checked probes for each fix (recorded per commit), the
  pidfd flag matrix and live group-kill witness in `.cache/redcheck/`,
  thread scans in `progress/thread-*.txt/jsonl`.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | Bots post inline threads after a PR's merge-time scan (CodeRabbit/Bugbot landed 29 threads on #398 and 10 on #400 after those PRs merged); a scan at green is a snapshot, so cross-PR feedback needs a standing sweep, and a session PR needs a re-scan at each new head immediately before merge. | fact | `progress/thread_scan.py` results: unresolved threads existed on 7 of the 60 merged PRs; #398's Bugbot/CodeRabbit piles arrived post-merge (session-200's scan saw only the OpenAI thread) |
| 2 | Two bot rounds gave contradictory pidfd flag values (1 and 4); only the UAPI header plus a live group-kill witness settled it — `PIDFD_SIGNAL_PROCESS_GROUP` is bit 2 (4) and only reaches the group when the pinned leader owns it. When reviewers disagree on a kernel constant, run the kernel: header + probe matrix + live witness. | technique | `.cache/redcheck/` matrix (0/1/2 accepted, 3/5/8 rejected, 4 kills a leader-owned group, 2 kills only the thread group); v6.12 `pidfd.h`; the live test `test_the_pinned_group_signal_reaches_a_same_group_descendant` |
| 3 | The pidfd probe fails on a zombie (signal state already released), so "probe failure" means "zombie or reaped", never "reaped": the group kill must stay armed for zombies (their id cannot recycle) and skip only genuinely reaped leaders (`/proc` state `Z` vs gone). | fact | the round-1 probe test first asserted the wrong transition and failed until the zombie case was separated; `test_the_pinned_leader_probe_never_lies_about_a_reaped_pid` pins live → `Z` → reaped |
| 4 | A reservation that releases before its owner's last write hands the next registration the first run's log and report stream; release at the last consumer, and make defensive cleanups identity-checked and atomic (check + drain in one lock hold) so a reuse race cannot steal the next run's report. Same-log-object reuse kills a log-identity check — mint a unique registration identity. | fact | adversarial round 1 (post-settle emit corruption, reproduced against 662eafd) and the final-head CodeRabbit follow-up (same-log-object race); fixed by `write_final`, then `settle_if_owned(registration)` |
| 5 | A red probe that passes on the pre-fix code is not a test of the fix: the first cancel-wins-anomaly test passed pre-fix because the cancel's own report made candidates non-empty; re-derive the schedule until the failure is exactly the reported one. | technique | `test_a_cancelled_run_with_a_tail_anomaly_keeps_both_markers` read `CANCELLED` alone on the pre-fix ordering only after the flip moved to post-collect with no survivors |
| 6 | Worked well: fresh-context triage subagents turned 50 unresolved threads into per-finding verdicts with line evidence, and the one-round adversarial loop plus per-head bot scans caught three real defects in the session's own fixes before merge. Reinforce: run the adversarial review against the PR head, not the working tree — the reviewer re-ran probes in a detached worktree when the tree moved. | technique | triage verdict tables; adversarial round 1 finding 1; re-review verdict "merge-ready" with two adopted advisories |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Recorded the zombie-probe rule and the registration-identity rule as development facts | `.llm/knowledge/transport-tooling.md` | `make llm-index` + lint |
| 2 | Module docstrings carry the phase-ownership, containment and probe contracts | `scripts/reference/owned_process.py`, `scripts/reference/drift.py` | the review rounds' "addressed" confirmations |
| 3 | The recycle-proof identity residual is a named follow-up with a hostile-recycle acceptance | issue #404 | created this session; CodeRabbit accepted the deferral in-thread |
| 4 | This artifact | `.llm/retrospectives/2026-11-18-pr-feedback-sweep.md` | committed with the session close |

## Prune Ledger

- Considered and kept: the session-200 knowledge facts (two-writer log
  serialization) remain accurate and are load-bearing for this session's
  `write_final`/append design.
- Nothing stale found in `.llm/knowledge/` for this area; no entries
  retired.
