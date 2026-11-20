# Plan Hygiene (PLAN.md Is a Map, Not a Log)

Facts about keeping the root plan short and current. The audit that produced
these facts is in
[2026-11-20-plan-hygiene](../retrospectives/2026-11-20-plan-hygiene.md).

| Fact (one assertable sentence) | Evidence (command + output, file:line, or measurement) | Verified |
| --- | --- | --- |
| Root `PLAN.md` has its own 180-line cap: over the cap is an error, exactly at it is critical, and over 150 lines warns with `--verbose`; `make lint-llm`, the pre-commit hook and CI all run the check. | `scripts/llm/llm_paths.py` (`PLAN_MAX_LINES`, `PLAN_SOFT_WARN_LINES`, `PLAN_PATH`); `scripts/llm/check_llm_file_lengths.py` (`check_plan`, `check_scope`, staged and explicit branches) | 2026-11-20 |
| The plan cap has a red-green test pair: unit tests cover over/at/missing limits, and the repo-state integration test fails when the real `PLAN.md` is absent or over budget. | `scripts/tests/test_llm_length_linter.py` `CheckFileTest.test_plan_*`; `scripts/tests/test_llm_repo_state.py` `test_plan_is_present_and_within_its_own_limit` | 2026-11-20 |
| The plan owns only purpose, product decisions, architecture boundaries, milestone gates, open-work navigation, a truth-owner map and the session loop; task status, contracts, evidence and history live elsewhere. | `PLAN.md` "Where truth lives"; the section-to-owner audit in the 2026-11-20 retrospective | 2026-11-20 |
| Unpruned session prose was the bloat mechanism: the plan reached 954 lines / 82,843 bytes by 2026-11-20, and the last 10 merges added 59 lines / 4,789 bytes without removing completed material. | `git show 9446996:PLAN.md \| wc -lc` -> `954 82843`; `git show e6ccd30:PLAN.md \| wc -lc` -> `895 78054`; the completed audit reduced it to 146 lines / 13,218 bytes | 2026-11-20 |
| Durable status belongs in GitHub issues, contracts/evidence in `docs/`, session narrative in machine-local `progress/`, past work in git history/CHANGELOG, and lessons in `.llm/retrospectives/`; none of those belong in `PLAN.md`. | `PLAN.md` routing table; `GOAL.md` "Progress Tracking" (`progress/` is ignored and never committed) | 2026-11-20 |
| Removing a plan section requires proving its durable content already has an owner; the cleanup moved the performance contract to `docs/verification-policy.md` and the primary references to `docs/reference/README.md` instead of deleting them. | `docs/verification-policy.md` "Performance claims"; `docs/reference/README.md` "Primary references"; cleanup retrospective action table | 2026-11-20 |
| Always-loaded navigation competes for a finite attention budget, so the plan must hold the smallest high-signal set; extra status prose worsens recall rather than preserving it. | [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) (context rot, smallest set of high-signal tokens); [AGENTS.md](https://agents.md) (living documentation) | 2026-11-20 |
