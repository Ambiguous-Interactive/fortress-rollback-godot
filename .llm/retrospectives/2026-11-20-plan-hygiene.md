# Retrospective — PLAN.md audit: a map, not a log

## Work Under Review

- Scope: root `PLAN.md` reduced from 954 lines / 82,843 bytes to 146 lines /
  13,218 bytes; plan-specific 180-line enforcement added; durable rationale
  recorded in knowledge, context, the harness skill and research.
- Trigger: on request (plan audit and cleanup) plus harness change.
- Evidence base: `git show 9446996:PLAN.md | wc -lc` (`954 82843`);
  `wc -lc PLAN.md` after the rewrite (`146 13218`); red-green unit and
  repo-state tests; `make lint-llm`.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | The plan grew by appending session status prose under existing sections; the last 10 merges added 59 lines / 4,789 bytes while completed material stayed. A length cap alone did not exist for the root file. | fact | `git show e6ccd30:PLAN.md \| wc -lc` -> `895 78054`; `git show 9446996:PLAN.md \| wc -lc` -> `954 82843` |
| 2 | Most of the old plan duplicated owners that already existed: interface/frame/time contracts in `docs/contracts.md`, evidence policy in `docs/verification-policy.md`, drift flow in `docs/reference/README.md`, supported scope in `docs/supported.md`, and feature evidence in the oracle/replay/spectator docs. | fact | Section-to-owner audit below; `grep` hits for `FortressConfig`, `TLA+`, `Drift Report` in `docs/` |
| 3 | Two durable pieces had no other home and needed moving, not deleting: the performance contract and the primary upstream reference list. | fact | `docs/verification-policy.md` "Performance claims"; `docs/reference/README.md` "Primary references" |
| 4 | An always-loaded plan competes for a finite attention budget; context rot makes extra status prose a recall cost, not free storage. Progressive disclosure is the correct shape. | research | [Anthropic context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents); [AGENTS.md](https://agents.md); `.llm/research/agent-instruction-files-2026.md` |
| 5 | The failure recurs unless tooling checks it. Documentation alone did not stop 200 sessions of append-only growth; a red test on the real file makes the next growth fail the gate. | technique | `scripts/tests/test_llm_repo_state.py` failed at 954 lines before the rewrite and passes at 146; `scripts/tests/test_llm_length_linter.py` covers over/at/missing |

## Section Routing

| Removed from PLAN.md | Durable owner |
| --- | --- |
| Reference revisions and primary references | `docs/reference/pins.json`, `docs/reference/README.md` |
| Per-task navigation table | GitHub roadmap #2 and epic checklists #3–#11 |
| Oracle/architecture implementation narratives | `docs/contracts.md`, `docs/session.md`, `docs/oracle*.md`, CHANGELOG |
| Parity, formal, fault and test-tier policy | `docs/verification-policy.md`, `docs/reference/INVENTORY.md` |
| SignalFish/browser status detail | `docs/signalfish-*.md`, `docs/supported.md`, open issues |
| Advanced parity status log | `docs/integration.md`, `docs/spectators.md`, `docs/peer-lifecycle.md`, `docs/supported.md`, open issues |
| Upstream drift procedure | `docs/reference/README.md` |
| Session completion and copy rules | `.llm/context.md`, `.llm/skills/ship-session`, `.llm/skills/user-copy` |
| Planning retrospective findings | Historical; retained in git history and this artifact |
| Performance contract | `docs/verification-policy.md` "Performance claims" |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Rewrote the plan as purpose, decisions, architecture boundaries, milestone map, open-work pointers, truth-owner map and session loop. | `PLAN.md` | `wc -lc` -> `146 13218`; `make lint-llm` |
| 2 | Added plan-specific over/at/soft limits and wired them into scope, staged and explicit checks. | `scripts/llm/llm_paths.py`, `scripts/llm/check_llm_file_lengths.py` | `test_llm_length_linter` 17 tests green |
| 3 | Added the real-repo red test that fails on an absent or oversized plan. | `scripts/tests/test_llm_repo_state.py` | red at 954 lines, green at 146 |
| 4 | Recorded the routing rule and measured bloat evidence. | `.llm/knowledge/plan-hygiene.md`, `.llm/knowledge/README.md` | `make lint-llm` link check |
| 5 | Added one critical rule and the editing procedure. | `.llm/context.md`, `.llm/skills/llm-harness/SKILL.md` | `make lint-llm` |
| 6 | Recorded the external context-engineering evidence. | `.llm/research/agent-instruction-files-2026.md` | link and length checks |

## Prune Ledger

- Retired: duplicate pin table, task table, test-tier table, drift procedure,
  session contract and the append-only parity/status narratives from PLAN.md.
  Their owners are listed above; no unique contract was dropped.
- Merged: primary references moved to the existing reference README; performance
  contract moved to the existing verification policy.
- Verify-on-touch: `make lint-llm` and the length-linter unit tests were rerun
  after every harness edit.

## Outcome

- State: `findings-acted`
- Follow-ups: root `PLAN.md` relative links are not covered by the `.llm` link
  linter; this audit checked them manually. Add a plan link check only if a
  broken plan link occurs in practice.
