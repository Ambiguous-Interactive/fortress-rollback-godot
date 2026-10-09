# Retrospective: 2026-10-09 Retrospective Loop

Worked example and first artifact of the loop it documents.

## Work Under Review

- Scope: added a mandatory post-work self-improvement loop to the
  harness — `retrospective` core skill, `RETROSPECTIVE.template.md`,
  `knowledge/` store (README + 6 seeded facts), evidence note
  (`research/agent-self-improvement-2026.md`), `context.md` rule 7 and
  repo-map rows, and an 8-case self-test.
- Trigger: new capability / harness change (user request).
- Evidence base: `python3 -m unittest scripts.tests.test_retrospective_loop`
  red (8/8 failures) before content existed; green after content +
  `make llm-index`; `make lint-llm` clean.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | The harness had authoring-side review skills (adversarial-review, code-review) but no loop feeding lessons back into skills/knowledge — improvement depended on ad-hoc goodwill. | technique | pre-change `.llm/skills/index.md`: 9 skills, none retrospective |
| 2 | Research synthesis: curation fidelity (+16.2pp vs +0.0pp), library drift (below-baseline performance), shadowing (up to -21%), and erosion make governance load-bearing; a capture-only loop would be net-harmful. | research | `../research/agent-self-improvement-2026.md` §2-3 |
| 3 | Placeholder paths must stay in backticks in templates; a markdown link to a nonexistent placeholder breaks link integrity. | fact | `knowledge/harness-tooling.md`, row 2 |
| 4 | The meta-lint scope is automatic for all `.llm/**/*.md` — the new stores inherited enforcement with zero tooling changes. | fact | `knowledge/harness-tooling.md`, row 3 |
| 5 | The existing test suite's red-green convention ("update tests FIRST") extended cleanly to a content-only harness change: the new test file was the spec. | none | test run evidence above |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Core skill: triggers, waiver, 5-step loop, curation gates, budgets, roles | `../skills/retrospective/SKILL.md` | `make lint-llm` |
| 2 | Knowledge store + contract + 6 verified facts | `../knowledge/` | `make lint-llm` |
| 3 | Evidence note with citations and ADR decisions | `../research/agent-self-improvement-2026.md` | `make lint-llm` |
| 4 | Artifact template (placeholders link-safe) | `../templates/RETROSPECTIVE.template.md` | `make lint-llm` |
| 5 | `context.md` rule 7 + repo map rows for the two new stores | `../context.md` | `make lint-llm` |
| 6 | 8-case self-test pinning the loop's structure | `scripts/tests/test_retrospective_loop.py` | `make test-llm` |
| 7 | Cross-link from debugging incidents to the loop | `../skills/debugging/SKILL.md` (Related) | `make lint-llm` |

## Prune Ledger

- Retired / merged / fixed at source: none needed — no prior loop or
  contradicting documentation existed.
- Verify-on-touch: all six knowledge facts were gathered by reading the
  tooling this session; the evidence commands (unit tests, linters) were
  re-run during the green phase.

## Outcome

- State: `findings-acted`
- Follow-ups: after ~10 real retrospectives, revisit the budget
  thresholds (skill § Budgets) against actual volume.
