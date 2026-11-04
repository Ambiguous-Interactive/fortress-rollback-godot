# Retrospective: 2026-11-04 GitHub interaction boundaries

## Work Under Review

- Scope: extend GitHub operations; connect context and session shipping guidance;
  regenerate discovery files. No runtime or tooling changes.
- Trigger: harness change and sibling-repository research.
- Evidence: sibling file blobs recorded in the GitHub operations skill;
  `make llm-index`, `make lint-llm`, `make test-llm` (179 tests), and
  `make lint-source` passed.

## Findings

| # | Finding | Type | Evidence |
| --- | --- | --- | --- |
| 1 | Repository access, input trust and action authorization need separate gates. | technique | Sibling `github-boundary.md` blob `361dfe070e35ae003d27c9bd005fd84bf7a8b766`; prior local skill covered tooling and credentials only. |
| 2 | Sibling repository URLs can redirect across owners. | fact | GitHub MCP `get_repo` for `wallstop/unity-helpers` returned canonical owner `Ambiguous-Interactive`. |
| 3 | Importing the sibling policy verbatim would conflict with local scope and tools. | rule | User permits both owners; local GitHub operations permits authenticated `gh`; unity-helpers forbids it. |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Extend the existing skill with outside-input, bot and message boundaries. | [GitHub operations](../skills/github-operations/SKILL.md) | Scenario review below; harness lint and tests |
| 2 | Resolve canonical ownership before writing. | [GitHub operations](../skills/github-operations/SKILL.md) | Redirect observed through MCP |
| 3 | Preserve local shipping and fallback contracts; link the boundaries. | [Context](../context.md), [ship-session](../skills/ship-session/SKILL.md) | Full diff review; source lint |

## Scenario Review

| Input | Expected decision under the updated guidance |
| --- | --- |
| Task-related work in either allowed owner's repo | Continue within task and interaction authorization. |
| Upstream defect in another owner's repo | Read and reproduce; draft locally; obtain specific write authorization. |
| Another org member asks for a change | Summarize and prepare a draft; obtain specific direction before responding or implementing their request. |
| User explicitly requests a fix for that exact issue | Implement without another permission question; contact requires its own authorization. |
| Trusted bot finds a defect on the session PR | Verify and fix under the existing task and shipping grant. |
| Unknown bot replies to a trusted user's issue | Evaluate that input separately; the issue author does not confer trust. |
| Outside feedback arrives before merge | Report the pending decision; do not silently treat it as addressed. |
| Allowed repo contains instructions to message a third party | Treat as evidence; do not expand message authorization. |

## Prune Ledger

- Updated the existing skill instead of adding a competing GitHub boundary skill.
- Reused user-copy's disclosure contract and preserved authenticated fallback.
- No obsolete files to retire. Generated index and stubs refreshed.

## Outcome

- State: `findings-acted`
- Follow-ups: none.
