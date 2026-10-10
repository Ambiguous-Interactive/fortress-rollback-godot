# Retrospective: `2026-10-09` devcontainer bootstrap

## Work Under Review

- Scope: `.devcontainer/` (Dockerfile, devcontainer.json, env template,
  post-create/verify/firewall scripts, README), root `.mcp.json` +
  `opencode.json`, CI workflow, progress log; ~1,250 insertions over 8
  commits on `feat/devcontainer` (PR #1).
- Trigger: large change (new infrastructure capability).
- Evidence base: `progress/session-001-devcontainer.md` (red→green ledger,
  7 build findings, timings); adversarial review rounds 1-5 gates; final
  `verify.sh` 23 passed / 0 failed via `devcontainer exec`; CI green on x64
  + arm64.

## Findings

| # | Finding | Type | Evidence (file:line / command / measurement) |
| --- | --- | --- | --- |
| 1 | The recurring failure class was **ordering assumptions**: features vs Dockerfile layers, create vs start lifecycle, build args vs runtime env, flush vs policy — every instance surfaced only by building and running the real container | rule | progress log RED points 2, 5, 7; knowledge `devcontainer-tooling.md` rows 1-4 |
| 2 | Author claims must be empirically tested: "npx resolves global installs" was asserted in a Dockerfile comment and refuted by a dead-registry test | rule | review round 2 M2; knowledge row 5 |
| 3 | Claude Code silently expands credential-like env names to empty in remote MCP headers — committed configs must use custom names for secret-bearing headers | fact | code.claude.com/docs/en/mcp; knowledge row 6 |
| 4 | "Latest" downloads that call the GitHub API break under build-time rate limits; `releases/latest/download/` asset URLs do not | fact | knowledge row 7; RED point 6 |
| 5 | Acceptance harnesses written first (`verify.sh`) caught three self-inflicted harness bugs (path precedence, pipefail/SIGPIPE, line-join under `set -u`) before they could become silent CI failures | technique | RED baseline 13/10; T0-T1 log entries |
| 6 | Fresh-context adversarial review with restricted inputs found 1 CRITICAL + 5 MAJOR defects the author missed, including a doc-confirmed silent auth failure; severity converged 1C/5M → 0 over five rounds | technique | review round gates in progress log; skill `../skills/adversarial-review/SKILL.md` |

## Actions Taken

| # | Action | Where it landed | Verified by |
| --- | --- | --- | --- |
| 1 | Recorded 10 container/tooling facts with evidence | `../knowledge/devcontainer-tooling.md` | `make lint-llm` |
| 2 | Fail-closed firewall ordering invariants encoded in script header + structure | `.devcontainer/init-firewall.sh` | review rounds 3-5 |
| 3 | MCP header secret indirection documented (custom var name + fallback) | `.mcp.json`, env template, README | round 1 C1 fix |

Routing: facts → `../knowledge/`; no new skill warranted (this work is
infrastructure, not a repo procedure); no external research note needed
(primary-source links live in the knowledge table and README).

## Prune Ledger

- Retired / merged / fixed at source: none — considered and rejected:
  checksum pinning for latest-tracking CLIs (conflicts with declared
  latest-by-design policy; documented in README instead).
- Verify-on-touch: Godot/Node/uv/gdtoolkit/godot-mcp pinned versions re-checked
  this session (round 5 VERIFIED-OK ledger); re-verify before any bump.

## Outcome

- State: `findings-acted`
- Follow-ups: none blocking. Optional (documented policy choices, revisit if
  they bite): checksum pinning for latest CLIs; opencode version skew across
  CI matrix legs; unified GDScript formatter strategy (GDQuest extension vs
  gdtoolkit CLI divergence documented in README).
