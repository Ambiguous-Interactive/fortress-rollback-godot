# Retrospective: 2026-11-21 goal and structural quality

## Work Under Review

- Scope: `GOAL.md`, `code-review`, `testing`, `context.md`, `llm-harness`,
  the goal length cap, the repository-state contract tests, and a cited
  research note.
- Trigger: harness change plus external knowledge (upstream goal, thermo-nuclear
  review, Kite bootstrap, current TDD/mutation/review evidence).
- Evidence base: red repository-state test (13 failures), `make gate` (265
  harness tests plus 158 selected unit suites), and a fresh-context adversarial
  review with 16 findings.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | Copying the upstream goal verbatim dropped the repository's one-round review cap and worktree isolation, making the loop unbounded. | rule | Adversarial finding 1 and 3; `GOAL.md` sub-agent loop |
| 2 | A "fix or nothing" review rule contradicts the existing evidence-backed decline path. | rule | Adversarial finding 2; `ship-session` feedback section |
| 3 | "Keep behavior changes separate from tests" contradicts shipping a regression test with its fix. | rule | Adversarial finding 4; `testing` characterization section |
| 4 | Structural "presumptive blockers" must be routed through the existing ASK/ADVISORY triage and recorded-decision suppression. | technique | Adversarial findings 5-6; `code-review` structural pass |
| 5 | A phrase test that ignores Markdown wrapping is brittle for the wrong reason. | harness | Adversarial finding 7; `collapsed()` helper in `test_llm_repo_state.py` |
| 6 | A cap documented only in a test is not enforced by the pre-commit hook or `make lint-llm`; the length linter must own it. | harness | Adversarial finding 16; `check_llm_file_lengths.check_goal` |
| 7 | The research note overclaimed a 1,000-line `gdlint` cap and misdescribed the Kite scout rule, TDD MCP, canary and AGENTS.md evidence. | research | Adversarial findings 11-15; corrected note |
| 8 | The goal's own "encode mechanical rules as checks" rule applied to this change: the cap and required phrases now have mechanical owners. | rule | `GOAL.md` work style; `check_llm_file_lengths`; `test_llm_repo_state` |
| 9 | External review found edge cases in the new rules: a shared-path branch can be necessary, a surviving mutant can be equivalent, a branch can be unreachable, fresh review can be unavailable, and only actionable findings need a fix. | rule | CodeRabbit review on PR #429; OpenAI review finding on the main-CI rule |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Keep the upstream contract as the opening and restore the one-round cap, worktree isolation and evidence-backed accept path. | `GOAL.md` | repository-state test |
| 2 | Add the structural pass and route its findings through ASK/ADVISORY with the recorded-decision exception. | `.llm/skills/code-review/SKILL.md` | repository-state test |
| 3 | Add characterization-before-refactor, make-the-change-easy and targeted mutation guidance. | `.llm/skills/testing/SKILL.md` | repository-state test |
| 4 | Enforce the 120-line goal cap in the length linter and keep the phrase contract in the repository-state test. | `scripts/llm/check_llm_file_lengths.py`, `scripts/tests/` | `make gate` |
| 5 | Record the adopted and rejected practices with corrected citations. | `.llm/research/goal-and-code-quality-2026.md` | link lint and source test |
| 6 | Make the branch, mutant and unreachable-branch rules conditional; record an unavailable fresh review; scope finding resolution to actionable findings; state the red-main recovery rule explicitly. | `GOAL.md`, `.llm/skills/code-review/SKILL.md`, `.llm/skills/testing/SKILL.md` | repository-state tests and `make gate` |

## Prune Ledger

- Retired / merged / fixed at source: replaced the stale goal intro and the
  downstream-only review rules; corrected the research note's file-size,
  scout-rule, MCP, canary and AGENTS.md claims instead of adding a second note.
- Verify-on-touch: `make gate`; `python3 -m unittest tests.test_llm_repo_state
  tests.test_llm_length_linter tests.test_llm_instructions_lint`.

## Outcome

- State: `findings-acted`
- Follow-ups: measure the structural pass against a seeded defect corpus; keep
  the goal phrase list split by contract if it grows.
