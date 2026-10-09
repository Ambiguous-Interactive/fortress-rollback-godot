# Session 001 — Devcontainer for Agentic Godot Development

Goal: fast-to-build, stable devcontainer with modern Godot 4 tooling, agentic
CLIs (Claude Code, OpenCode, gh), provider secrets via `.env`, curated MCP
servers, and a VS Code extension set. Work style: red-green, data-backed.

Decisions locked with user:

| Decision | Choice |
| --- | --- |
| Godot | 4.7.2-stable, pinned via `ARG GODOT_VERSION` |
| Firewall | `init-firewall.sh` committed, OFF by default |
| MCP | godot-mcp + Context7 + GitHub MCP, all enabled |
| Claude provider | Neutral (native Anthropic); z.ai/OpenRouter documented in env example |

## Task Log

### T0 — Baseline + acceptance harness (RED)

- Baseline committed to `main` (harness bootstrap, `make lint-llm test-llm`
  green before starting).
- `feat/devcontainer` branch created; git hooks installed locally.
- Wrote `.devcontainer/verify.sh` FIRST so acceptance is defined before
  implementation (red: it fails while the environment does not exist).
- Evidence: pre-container run fails on missing godot/claude/opencode/uv.

### T1 — Skeleton: Dockerfile + devcontainer.json (GREEN target)

- Files: `Dockerfile`, `devcontainer.json`, `devcontainer.env.example`,
  `post-create.sh`, `init-firewall.sh`, root `.mcp.json` + `opencode.json`,
  `.gitignore` entry for `.devcontainer/devcontainer.env`, README.
- Pinned facts (verified at decision time): Godot `4.7.2-stable` assets exist
  for x86_64+arm64 (HTTP 302 on release URLs); uv `0.13.0`; gdtoolkit `4.5.0`;
  `devcontainers-extra/features/opencode:1.0.0` exists (GitHub Releases
  installer); no astral uv feature exists -> official `COPY --from` image
  install instead; opencode MCP schema confirmed from docs (incl. `oauth:
  false` for header-auth servers and `{env:VAR}` substitution).
- RED data point 1: BuildKit rejects ARG expansion in `COPY --from`
  (`variable expansion is not supported for --from`). Fix: dedicated
  `FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv-bin` stage.
- Build running.

### T2 — Tooling verification (GREEN target)

- TODO

### T3 — Secrets via `.env` (GREEN target)

- TODO

### T4 — MCP servers (GREEN target)

- TODO

### T5 — Project gates inside container (GREEN target)

- TODO

### T6 — Docs + .gitignore (GREEN target)

- TODO

### T7 — CI workflow (GREEN target)

- TODO

## Findings / Data

- TODO
