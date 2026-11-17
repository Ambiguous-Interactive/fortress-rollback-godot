# Retrospective: 2026-11-16 capacity-nine wrap flood and the weekly drift report

## Work Under Review

- Scope: session PR #384 (branch `feat/drift-report-capacity-wrap`, seven
  commits): `mesh_4_wrap_flood_capacity_9` (#34/#59), the M2 weekly drift
  report (`scripts/reference/drift_report.py`, scheduled workflow, 23-case
  suite, workflow-tier contract), one adversarial review round plus its
  re-review.
- Trigger: large change (~700 new lines), new capability (an unattended
  scheduled reporter with GitHub write scope), adversarial findings.
- Evidence base: wrap receipts `.cache/results/session192-cap9-{43,472}`
  (match twice per side, both pins); reporter suite 22→23 cases with a
  killed-mutant proof; `make gate`, reference suite 41/41 files, oracle suite
  18/18, `make lint-source` 541 files / 0 violations.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | A negative-control test built with a placeholder value (`deadbeef`) instead of the genuine computed value pins nothing: the reviewer showed the foreign-digest suppression scenario passes under both the defended and the undefended code. Hostile fixtures must carry real derived values, and the pin is only proven by running the test against an in-memory mutant. | rule | round-2 review N1; mutant exec run: unfiltered scan → test fails (killed), honest module passes |
| 2 | A digest used for run-to-run identity must be computed over a path-free and date-free projection of its artifact. The first draft hashed the report JSON including temp-dir paths, so every run produced a fresh identity and the noise-free guarantee was fiction. The reviewer's cross-day silence check found nothing because the projection was in place before review — build identity projections in, not as a patch. | technique | `drift_report.py` identity comprehension excluding `old_tree`/`new_tree` |
| 3 | An unset environment variable expanded into an argument (`--summary ""`) becomes `Path('')`, which pathlib normalizes to the working directory, so the tool appended to a directory after finishing all its work. Guard normalized values at the argument boundary, not just `None`. | fact | round-1 review finding 5 with a reproduced `IsADirectoryError` |
| 4 | GitHub search indexing lags writes, so dedup that must survive uncertain responses reads primary lists (the issue list), never the search API. Marker-based carrier detection over paginated issue lists is also testable offline; search-based dedup would not have been. | fact | design note in `drift_report.py` docstring; round-1 review confirmed the read-before-retry property |
| 5 | `comment_digest` parsing any comment's `report-digest:` line let a foreign comment (all inputs are public, so the digest is computable) suppress an observation silently. Scope every digest/identity read to artifacts the tool itself authored (its marker line), and model the attacker in the fixture with the genuine value. | fact | round-1 finding 2 (actionable); empirically verified in round 2 |
| 6 | Stale carry branches mislead `git cherry`: the session-154 carry branches show unapplied patch-ids while their reworked content landed as PR #325 days earlier. Check merged PRs by title/date and compare blobs before treating a carry branch as unlanded work. | technique | session-start survey; `git diff origin/main...carry/...` showed superseded intermediates only |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Genuine-digest hostile fixture plus the in-memory mutant proof (exec the mutated module, expect exactly the suppression failure) | `test_drift_report.py::test_a_foreign_digest_comment_never_suppresses_the_observation` | mutant killed; honest module green |
| 2 | Near-miss stream issues (marker without title, title without marker) named on stderr instead of silently ignored | `drift_report.py::report_source` | `test_a_near_miss_stream_issue_is_named` |
| 3 | Empty-argument guard at the parse boundary; docs example uses a real file path | `drift_report.py::main_with_args`, docs/reference/README.md | `test_an_empty_summary_argument_is_treated_as_absent` |
| 4 | Retry catches the whole `http.client.HTTPException` class, not one subclass; oversized-download temp files unlinked before re-raise | `drift_report.py::download_archive` | review round 2 verification |

## Prune Ledger

| # | Stale statement | Where | Action |
| --- | --- | --- | --- |
| 1 | "The weekly automation is future work tracked in M2, not activated by this plan" | PLAN.md upstream-tracking section | Updated in this session's PR to name the delivered workflow |
| 2 | "M2 owns wiring the classifier into a weekly/manual report" | PLAN.md drift paragraph | Rewritten to the delivered carrier-issue reporting |

## Session Notes

- The wrap corpus addition ran clean on the first try on both pins; the
  measured shape (16 boundaries per peer on the nine-row ring) matched the
  pre-regeneration estimate (rounds − 8 ≈ boundaries), which is a useful
  sizing rule for future tiny-ring profiles.
- Two commits happened after the initial "final" diff capture (the
  truncated-archive catch and the changelog shortening), which the reviewer
  flagged as a stale snapshot; capture the review diff only after the commit
  sequence has settled.
