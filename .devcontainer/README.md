# Devcontainer — Fortress Rollback Godot

A fast, reproducible, agent-ready environment for this repo: Godot 4.7.2,
GDScript formatting/linting, modern CLI tooling, and the agentic CLIs
(Claude Code, OpenCode, gh) pre-installed, with secrets supplied through a
gitignored `.env` file and MCP servers wired for both Claude Code and
OpenCode.

## Quick Start

Host requirements: macOS or Linux, or Windows via WSL2 (the container-seeding
hook is a POSIX shell command).

1. Install [Docker](https://www.docker.com/products/docker-desktop/) and
   [VS Code](https://code.visualstudio.com/) with the **Dev Containers**
   extension.
2. Open this folder in VS Code and run **Dev Containers: Reopen in Container**
   (or accept the "Reopen in Container" toast).
3. On first open, `.devcontainer/devcontainer.env` is created from the
   committed template. Add any API keys you use (see below), then
   **Dev Containers: Rebuild Container** so they are injected.

CLI-only workflow (no VS Code):

```sh
npx @devcontainers/cli@0.89.0 up --workspace-folder .
npx @devcontainers/cli@0.89.0 exec --workspace-folder . -- bash

# After changing the Dockerfile or build args, force a fresh container
# (postCreateCommand only runs on container CREATE):
npx @devcontainers/cli@0.89.0 up --workspace-folder . --remove-existing-container
```

## What's Inside

| Tool | Version policy | Purpose |
| --- | --- | --- |
| Godot | pinned `4.7.2-stable` (build arg) | Headless import/tests, LSP, engine determinism |
| Node.js | pinned `22.x` (Dockerfile arg) | MCP server runtime |
| Claude Code CLI | latest at build | Anthropic coding agent |
| OpenCode | latest at build | Vendor-neutral coding agent |
| godot-mcp server | pinned `0.1.1` (npm global) | `godot` MCP server; no npm dependency at runtime |
| gh | latest | GitHub CLI (reads `GITHUB_TOKEN`) |
| uv | pinned `0.13.0` | Python tooling; installs `gdtoolkit` |
| gdformat / gdlint | pinned `4.5.0` | GDScript formatter/linter (via `uv tool`) |
| ripgrep, fd, bat, fzf, jq | apt, Ubuntu 24.04 | Fast search/navigation for humans and agents |

Version policy rationale: the engine and infrastructure (uv, node, MCP
server) are pinned for reproducibility; the agentic CLIs track latest at
build time by design. Downloads come from official endpoints over TLS;
checksums are not pinned for the latest-tracking tools.

VS Code extensions are declared in `devcontainer.json` (`customizations`):
Godot Tools, Godot Files, Godot Format, Claude Code, GitLens, EditorConfig,
Makefile Tools, Code Spell Checker, Error Lens, Even Better TOML.

Formatter note: the Godot Format extension bundles **GDQuest's** GDScript
formatter for format-on-save. The CLI `gdformat`/`gdlint` tools (used by
agents) come from the pinned **gdtoolkit** — a different engine; don't expect
byte-identical output between them.

## Secrets (`.devcontainer/devcontainer.env`)

Everything is optional; the container works with an empty file. The template
`.devcontainer/devcontainer.env.example` documents each key:

| Key | Used by |
| --- | --- |
| `GITHUB_TOKEN` | `gh` CLI, GitHub MCP server |
| `OPENROUTER_API_KEY` | OpenCode OpenRouter provider |
| `ZAI_API_KEY` | OpenCode `zai-coding-plan` provider |
| `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` | optional Claude Code rerouting |

The file is passed via `runArgs: ["--env-file", ...]`, so values are visible
container-wide (terminals, VS Code, all CLIs). It is gitignored — never commit
real keys. Format rules: no quotes around values, no inline comments after
values (both are silently kept as part of the value by `docker --env-file`).

### Claude Code provider routing

Default is **native Anthropic** (`claude /login`). To reroute, uncomment the
corresponding block in `devcontainer.env` and rebuild:

- **z.ai GLM Coding Plan**: `ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic`
  + `ANTHROPIC_AUTH_TOKEN=<ZAI_API_KEY value>`
- **OpenRouter** (Anthropic models only): `ANTHROPIC_BASE_URL=https://openrouter.ai/api`
  + `ANTHROPIC_AUTH_TOKEN=<OPENROUTER_API_KEY value>` + `ANTHROPIC_API_KEY=`
  (kept present and **empty** on purpose, or Claude Code may bypass OpenRouter)

## MCP Servers

Configured for Claude Code in `/.mcp.json` and for OpenCode in
`/opencode.json` (same three servers, no secrets on disk — values come from
the environment):

| Server | Type | Notes |
| --- | --- | --- |
| `godot` | stdio (`godot-mcp` binary, pinned `0.1.1` in image) | Run projects, capture debug output, scene ops; `GODOT_PATH=/usr/local/bin/godot`. Configs assume this devcontainer — outside it, `npm i -g @coding-solo/godot-mcp@0.1.1` |
| `context7` | HTTP | Up-to-date library docs (Godot included) for agents |
| `github` | HTTP | GitHub MCP; uses `Authorization: Bearer ${MCP_GITHUB_PAT}` |

`MCP_GITHUB_PAT` is derived from `GITHUB_TOKEN` via `remoteEnv` — you only
set `GITHUB_TOKEN`. The rename is deliberate: Claude Code refuses to expand
credential-like variable names (its own tokens, and credential-carrying names
such as `GITHUB_TOKEN`) into remote MCP headers — they read as empty with no
warning — while custom names expand normally. Without a token the `github`
server fails to connect (401); every other server and CLI is unaffected.
The same applies to OpenCode's `{env:GITHUB_TOKEN}`: unset token = one failed
server, non-fatal.

The `godot` server can launch the editor, but headless containers have no
display; run/debug/debug-output tools are the headless-friendly subset.

## Godot Editor + Language Server

The Godot Tools extension talks to the editor's LSP. Start a headless editor
inside the container:

```sh
godot --headless --editor --path .   # serves LSP on port 6005
```

Ports 6005 (LSP) and 6006 (debug adapter) are forwarded automatically.

## Verification

`.devcontainer/verify.sh` is the acceptance harness; `post-create.sh` runs it
on every rebuild, and CI runs it after a fresh build.

```sh
.devcontainer/verify.sh           # full: tools, secrets, wiring, MCP handshake,
                                  #       make lint-llm, make test-llm, godot import
.devcontainer/verify.sh --quick   # skip the slow checks
```

## Optional: Egress Firewall

`.devcontainer/init-firewall.sh` (adapted from Anthropic's reference
devcontainer) locks container egress to an allowlist: Anthropic, z.ai,
OpenRouter, GitHub (meta CIDRs + asset hosts), npm, PyPI, astral.sh,
nodejs.org, opencode.ai, Context7, Godot, and VS Code update/extension
endpoints, plus the Ubuntu apt mirrors so later package installs work. IPv6
egress is blocked entirely (the allowlist is IPv4-only), and Docker proxy
variables are neutralized inside the script. It is **off by default**. To
enable:

1. Add `"--cap-add=NET_ADMIN"` and `"--cap-add=NET_RAW"` to `runArgs`.
2. Add `"postStartCommand": "sudo bash .devcontainer/init-firewall.sh"`.
3. Rebuild.

## Maintenance

| Change | Where (all spots must move together) |
| --- | --- |
| Bump Godot | `build.args.GODOT_VERSION` **and** `containerEnv.GODOT_VERSION` in `devcontainer.json`; the Dockerfile `ARG` default is a fallback for bare `docker build` |
| Bump Node | `NODE_VERSION` arg in `Dockerfile` |
| Bump uv | `UV_VERSION` arg in `Dockerfile` |
| Bump gdtoolkit | `GDTOOLKIT_VERSION` in `post-create.sh` (env-overridable) |
| Bump godot-mcp | pinned npm install in `Dockerfile` |
| Add a VS Code extension | `customizations.vscode.extensions` |
| Add an MCP server | both `.mcp.json` and `opencode.json` |

Named volumes (`frg-*-${devcontainerId}`) persist Claude/OpenCode state, the
uv cache, Godot import caches, and shell history across rebuilds, which keeps
rebuilds fast. If a volume ever ends up with wrong ownership (e.g. from an
older broken build), reset them and rebuild:

```sh
docker volume ls --filter name=frg- --format '{{.Name}}' | xargs -r docker volume rm
npx @devcontainers/cli@0.89.0 up --workspace-folder . --remove-existing-container
```
