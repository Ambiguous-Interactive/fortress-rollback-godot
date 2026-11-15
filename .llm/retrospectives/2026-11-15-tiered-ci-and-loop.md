# Retrospective: `2026-11-15 tiered-ci-and-loop`

## Work Under Review

- Scope: split the single-tier CI matrix (52 jobs on every push) into the
  three tiers PLAN.md had always defined — Gate (per push), Qualify (merges
  to main), Nightly (Firefox axis + Java model checks) — plus the process
  changes that stop sessions from re-verifying the matrix locally and
  triple-scanning feedback. PR #367, 2 commits. Session log:
  `progress/session-184-tiered-ci.md`.
- Trigger: large change; recurring pain (CI waits dominating session wall
  time; 100 runs / 25 failures in six days).
- Evidence base: `gh run list` measurements, `docs/reference/jobs.md`
  baselines, `.cache/tests/durations.json`, progress/ session history
  (200 thread scans, 27 CI polls in one session), local measurements
  (focused suite 2.8s; full unit wave 2m54s wall / 16m CPU on 16 cores;
  dirty-tree fail-closed full inventory 1m47s), full local gates
  (`make gate` green before push).

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | The tier model existed in PLAN.md's "Test tiers and release acceptance" table since the start but was never implemented: the workflow ran the release-grade matrix on every push. The gap was invisible because no contract test asserted *which* jobs run on *which* events — only per-job shape tests existed. | rule (new, harness-owned) | PLAN.md tier table vs `.github/workflows/` trigger list at session start; the new `scripts/tests/test_workflow_tiers.py` now pins composition |
| 2 | Nightly Firefox ownership rows reuse the compact `-part-N` suffixes across phases, so the first artifact name dropped the phase and upload-artifact v4+ would fail the second upload of every pair (8 colliding pairs). The fresh-context reviewer found it mechanically; neither the author nor any existing test caught it. | defect (caught by fresh-context review, now contract-pinned) | old workflow's `format('-firefox-{0}', matrix.phase)` disambiguator lost in the rewrite; `test_nightly_ownership_matrix_rows_and_artifacts_are_unique` |
| 3 | The runner's hard-coded two repetitions ARE the determinism evidence (`validate_result` rejects `len(runs) != 2` and fails on divergence), so the planned `--repetitions` iteration flag would have weakened a core contract to save ~80 seconds on a path `make gate` makes unnecessary. Dropped from the plan. | fact (docs-owned) | `scripts/run_godot_tests.py` report validation; session log "Dropped from the original plan" |
| 4 | The "48 jobs" baseline figure repeated in docs was stale: the real old matrix was 52 jobs (the Firefox SignalFish pair postdated the last count). A docs section whose purpose is reproducible baselines carried a wrong number until the reviewer recounted. | fact (docs-fixed) | `git show HEAD` matrix count: 32+8+10+1+1; jobs.md corrected |
| 5 | `git diff <sha>` in `changed_suites.changed_files` diffs against the working tree, so a dirty local tree correctly fails closed to the full inventory while a clean CI checkout selects nothing (vacuous `no_affected_suites` pass, exit 0). CI-correct, but the vacuous green is only distinguishable by reading the step log — now mitigated with a results artifact. | fact | `changed_suites.py` `changed_files`; `run_godot_tests.py` no_affected_suites branch; gate.yml upload |
| 6 | One reference contract test (`test_ownership_probes`) parsed the qualify workflow for Firefox rows and split on the if/else the rewrite removed — the kind of hidden coupling a tier split produces. It failed on the first full run and was re-homed to parse each tier's own file. | rule (test seams must follow the split) | first `make test-reference` run: 1 failed file; updated test reads `nightly.yml` for Firefox rows |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Tier-composition contract tests added and kept red-first (8 failures + 6 errors before the split). | `scripts/tests/test_workflow_tiers.py` (12 tests) | red run recorded; 12/12 green after |
| 2 | Artifact phase disambiguator restored; uniqueness pinned by contract. | `nightly.yml`; `test_workflow_tiers.py` | 12/12 tiers + 29/29 ownership tests |
| 3 | Detect/base resolution made fail-closed on unresolvable bases (explicit failure branch, `set -o pipefail`, `origin/main` fallback order) in both gate jobs that use it. | `gate.yml` | `test_gate_base_resolution_fails_closed_in_both_jobs` |
| 4 | Gate unit-fast: 30-minute budget, 180s suite timeouts matching qualify, `latest.json` receipt artifact uploaded `if: always()`. | `gate.yml` | file + tier tests |
| 5 | Nightly serialized behind a concurrency group; gate acquisitions pinned to zero so tooling cannot silently re-enter the fast tier. | `nightly.yml`; `test_workflow_tiers.py` | 12/12 tiers |
| 6 | Session loop changes: one feedback scan per push, background `gh run watch`, `make gate` pre-push minimum, GOAL.md review loop capped at one fix round. | `.llm/skills/ship-session/SKILL.md`, `GOAL.md`, `Makefile` | `make lint-llm`; this session ran the new flow end to end |

## Prune Ledger

- Dropped from the plan with reason: the `--repetitions` runner flag
  (finding 3). Recorded in the session log and CHANGELOG rather than
  implemented.
- Deleted: `.github/workflows/llm-lint.yml` (absorbed check-for-check into
  the Gate harness job); absence is contract-pinned.
- No knowledge entries invalidated; jobs.md's stale 48-job count corrected
  in place.

## Outcome

Retro: findings-acted. One fresh-context adversarial review round (8
findings: 1 critical artifact collision, 3 minor, 4 advisory — all acted;
none deferred). `make gate` green before push; PR Gate evidence recorded in
the session log. The qualification matrix validates the merge on main, and
nightly is dispatched once against the merge commit before its first
scheduled run.
