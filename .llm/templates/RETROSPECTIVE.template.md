# Retrospective: `<YYYY-MM-DD> <slug>`

> Copy to `.llm/retrospectives/YYYY-MM-DD-<slug>.md`, then delete this
> block. Keep the artifact under 300 lines; depth belongs in the stores
> (skills / knowledge / research), not here. The loop is defined in
> [../skills/retrospective/SKILL.md](../skills/retrospective/SKILL.md);
> artifacts live in `../retrospectives/`.

## Work Under Review

- Scope: <what was built or changed; diff stat or file list>
- Trigger: <large change / new capability / incident / corrections /
  external knowledge / on request>
- Evidence base: <test and lint output, commands, incident report>

## Findings

| # | Finding | Type | Evidence (file:line / command / measurement) |
| --- | --- | --- | --- |
| 1 | <what was learned, what failed, what surprised> | technique / fact / research / rule / harness / none | <citation> |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | <skill updated / fact recorded / stale claim retired / red-green tooling> | `../knowledge/<topic>.md` | `make lint-llm` |

Routing: procedures -> `.llm/skills/`; facts -> `../knowledge/`;
external evidence -> `../research/`; invariants -> `context.md` + owning
skill; tooling gaps -> `scripts/tests/` first (red), then `scripts/llm/`
(green).

## Prune Ledger

- Retired / merged / fixed at source: <entries, or "none — considered:
  ...">
- Verify-on-touch: <commands re-run against stored claims, or "n/a">

## Outcome

- State: `findings-acted` | `waived — <reason>` | `no-findings`
- Follow-ups: <explicitly deferred items, or "none">
