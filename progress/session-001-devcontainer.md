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

- RED data point 2: first build failed — BuildKit could not run the Godot
  layer: `ARG TARGETARCH` was dropped during the uv-stage restructure, so
  `${TARGETARCH}` expanded empty and the arch `case` hit `*) exit 1`. Fix:
  re-declared `ARG TARGETARCH` inside the build stage (predefined BuildKit
  args still require stage-level declaration to be visible in RUN).
- RED data point 3: image built; post-create failed with
  `/home/vscode/.cache/uv/CACHEDIR.TAG: Permission denied`. Cause: Docker
  creates missing named-volume mount-point parents as root, so the `vscode`
  user could not write into the uv cache volume. Fix (canonical): pre-create
  every mount point in the image and `chown -R vscode:vscode /home/vscode`;
  Docker's first-mount copy then preserves ownership. Stale root-owned
  volumes from the failed run had to be removed manually (volumes persist
  across `--remove-existing-container`).
- RED data point 4: devcontainers-extra `opencode` feature failed at build:
  its installer pins `REPO="sst/opencode"`, but the project moved to
  `anomalyco/opencode`, so the GitHub Releases lookup fails. This is the
  maintenance-mode failure mode flagged during planning. Fix: dropped the
  feature; OpenCode now installs in the Dockerfile via the official install
  script (run with a throwaway HOME — the script hardcodes
  `INSTALL_DIR=$HOME/.opencode/bin` — then moved into `/usr/local/bin` and
  validated with `opencode --version` at build time).
- RED data point 3 fix verified: image built past the Godot layer; failure
  moved to feature stage (i.e., ownership fix worked).

### T3 — Secrets via `.env` (GREEN target)

- `initializeCommand` confirmed working: `devcontainer.env` auto-created from
  the example on first `up`; `git check-ignore` confirms it is ignored.

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
