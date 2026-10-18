# Knowledge Base (Distilled Operational Facts)

Facts, gotchas, and environment quirks learned by doing work in this
repo — the semantic-memory tier. Skills hold procedures
([skills](../skills/index.md)); external evidence lives in
[research](../research/); the episodic record lives in
[retrospectives](../retrospectives/). One home per fact: cross-link,
never duplicate. Feeding this store happens through the retrospective
loop ([skills/retrospective](../skills/retrospective/SKILL.md)).

## Entry contract

Each topic file (`<topic>.md`) groups related facts in a table:

```
| Fact (one assertable sentence) | Evidence (command + output, file:line, or measurement) | Verified |
```

`Verified` is the date the fact was last confirmed by re-running its
evidence. Facts without evidence do not get in (curation gate).

## Lifecycle

- **Retire** entries proven false or obsolete by later work; note the
  retiring retro in `../retrospectives/`.
- **Fix at source**: a contradiction gets one corrected entry — never a
  second, conflicting one.
- **Verify on touch**: rerun the evidence command before relying on a
  fact.
- Budget: past ~10 topic files, consolidation belongs on the next
  retrospective's agenda (see the skill's Budgets section).

## Files

- [harness-tooling.md](./harness-tooling.md) — `.llm/` enforcement
  tooling: lint scope, frontmatter rules, test bootstrap
- [devcontainer-tooling.md](./devcontainer-tooling.md) — container
  build/runtime facts: feature ordering, volume ownership, npx/Claude Code
  MCP semantics, fail-closed firewall ordering, npm global-root permissions
- [transport-tooling.md](./transport-tooling.md) — browser SignalFish
  secure-context and development-hosting facts
