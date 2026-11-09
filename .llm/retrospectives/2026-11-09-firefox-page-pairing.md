# Retrospective: Firefox page pairing and npm cache

## Work Under Review

Session 165 surveyed all open issues against the <2h budget, then reduced
Reference Baseline cost by pairing Firefox ownership pages inside a measured
native budget and sharing one npm download cache. PR #339 squash merged as
`b41bba2` (four commits: pairing, review hardening, baseline docs, review
adjudications). Trigger: large change (5 files, +173/−48) plus incident (a
~50-minute intermittent 504 outage across main and PR runs).

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | Hosted 504 download outages need classification, not fixes: breadth across untouched jobs plus the 504 error class in probe logs proves environment; spaced `--failed` reruns land in healthy windows without a tree change (15→10→8→4→3→0). | fact | main run `42579030814`, four rerun cycles, 2026-11-09; every failure log `urllib.error.HTTPError: HTTP Error 504` |
| 2 | Per-step CI timing is extractable from job logs when the Jobs API returns null step timestamps — `##[group]Run <step>` markers carry millisecond stamps. This identified ~18s npm+playwright setup vs ~1m48s witness work, killing the "shard overhead dominates" hypothesis before any restructuring. | technique | `gh run view --job 128981763159 --log`, run `42562496243` |
| 3 | The Firefox witness cost is page-count-bound, not suite-bound: one page per suite (25) at ~9s overhead versus Chromium's four-suite pages measured 415.5s vs 274.6s rounds. Pairing by *same-runner measured native cost* keeps #224's deadline margin while halving pages (hosted: 25→14 pages, 415.5s→217.4s). | fact | artifacts `13650551283` (before) vs `13654006164` (after); #224's 195s four-suite rejection bounds the ratio |
| 4 | Deriving a fixture's expected plan from the production planner is not fully tautological once invariants are asserted alongside (≤2 per page, parity singleton, ≥1 measured pair) — it detects caller regressions (lost measurement → singletons) without duplicating policy text. | technique | `ownership_rejection_fixture.py` Firefox block; adversarial review finding + CodeRabbit outside-diff finding |
| 5 | The reviewer-adjudication flow from the ship-session skill worked unchanged for bot reviews: reproduce, fix valid items in one commit, decline with evidence in one comment. CodeRabbit's final review moved to APPROVED without a re-review request. | none (reinforcement) | PR #339 reviews 5822490069 (CHANGES_REQUESTED) → 5822690445 (APPROVED) |

## Actions Taken

- Finding 1+2 routed to `.llm/knowledge/ci-hosted-runners.md` (new topic
  file, README index updated) — outage classification + spaced-rerun
  policy, and the log-marker timing technique with verify dates.
- Finding 3 documented at its canonical home `docs/reference/jobs.md`
  (before/after baseline table, reproduce command pinned to attempt 4).
- No new skill: the procedures fit existing ship-session/testing skills;
  nothing was looked up twice.

## Prune Ledger

- Retired: `docs/reference/jobs.md`'s pre-sharding 13-job baseline table
  (replaced by the current 48-job shape; the old total is cited by run ID
  where historical sections reference it).
- Considered and kept: PLAN.md job-shape sentences (still accurate — this
  change is witness-internal scheduling, already pointed at jobs.md).
- Verify-on-touch: `make lint-source`, `make test-reference` (36 files OK),
  targeted unittest modules — all rerun on the final head.

## Outcome

- State: `findings-acted`
- Follow-ups: signalfish `online` leg serial-probe parallelism (wall
  critical path, needs a session that can burn CI cycles); #104 adaptive
  prototype with the rejected-traffic correction; #164/#148 room-count and
  export-work levers.
