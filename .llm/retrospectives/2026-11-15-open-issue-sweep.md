# Retrospective: `2026-11-15 open-issue sweep — frontier drain windows, installer journal, review availability`

## Work Under Review

- Scope: three open issues in one session PR — #375 (close the two residual
  confirmation-frontier re-derivation windows), #249's evidence-capture clause
  (preserve partial npm output across an outer build deadline), #307's
  documentation clause (unavailable review coverage policy) — plus two fresh
  adversarial review rounds, one natural CodeRabbit review disposition, and the
  merge-queue flow end to end. PR #376, squash-merged as `a7dd1d7`. Session
  log: `progress/session-187-open-issue-sweep.md`.
- Trigger: session goal (address open issues by gameplay impact; one PR;
  under two hours). Wall time ≈ 105 minutes including two review rounds.
- Evidence base: red/green runs on the pinned 4.7.2 engine, mutant-isolation
  runs (performed independently by the implementation and re-verified by the
  reviewer), 236 tooling tests, `make gate` (136 affected suites), Gate +
  Devcontainer Verify + Reference Baseline on the queue's grouped candidate.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | Adding cases to an existing suite requires registering them in the ownership receipt inventory (`scripts/reference/ownership_probes.py` `EXPECTED`), and only CI's negative-control job runs that gate locally (`make test-reference`). The lesson exists in two October retrospectives but not in the actionable testing guidance, so it recurred and cost one CI round. | rule (now in the testing skill) | first `fa303f7` Gate run failed `test_selected_suite_declarations_match_inventory`; green after `374ccc0` |
| 2 | A diagnostics feature that writes files must fail open: an `open()` on a hostile or stale path would have converted the evidence journal into a new pre-npm install failure and a symlink into truncation of a foreign file. Caught by the fresh-context reviewer, not by the author. | defect (caught by adversarial review, contract-pinned) | planted read-only file and planted symlink tests; `O_NOFOLLOW` + owner-only + disable-with-note |
| 3 | Streaming evidence must flush per line: the first journal implementation buffered in Python, so a hard kill — the exact #249 failure mode — still lost everything. Caught by the live SIGKILL test going red before the flush existed. | defect (caught by own test) | kill-test red at 0-byte journal; green after per-line `flush()` |
| 4 | The `drain_events()` window the issue names is reachable only through the endpoint event seam, because every production event producer is drained inline by the same facade call; the tests therefore queue the decoded real packet at that seam and say so. The issue's own "or" wording accepted one pinned path; both windows are still closed in code. | fact (docs-owned) | reachability analysis in the session log; Value lines name the seam |
| 5 | A natural CodeRabbit review arrived on the first pushed head (6 findings, CHANGES_REQUESTED) while the newest head's check ran rate-limited: unavailable coverage on one head and real findings on another coexist in one session, exactly the distinction the new #307 policy requires records to keep. | fact (policy exercised) | check run `Review rate limited` (neutral) on `90e3535`; review 5912928934 on `fa303f7`; six replied threads |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Testing guidance gains the inventory-registration rule so it is read before pushing, not after CI fails. | `.llm/skills/testing/SKILL.md` | `make lint-llm` |
| 2 | Journaling made fail-open and kill-safe (owner-only, `O_NOFOLLOW`, per-line flush, disable-with-note, no false retention path). | `.devcontainer/install-native-cli.py` | 15 installer tests incl. planted file/symlink and SIGKILL |
| 3 | Frontier re-derivation closed on both named paths with per-path mutant-pinned cases; docs boundary stated exactly. | `peer_session.gd`, `docs/peer-session.md`, `PLAN.md` | red/green + mutant isolation, twice per runner |
| 4 | Unavailable-review policy documented with the exact-head record requirement. | `.llm/skills/ship-session/SKILL.md`, `.llm/context.md` | `make lint-llm`; exercised on this session's own record |

## Nothing Pruned

No prior guidance became stale: the October inventory lessons remain accurate
history, and the ship-session flow ran unchanged apart from the added policy
paragraph.
