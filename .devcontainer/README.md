# Devcontainer — Fortress Rollback Godot

A fast, reproducible, agent-ready environment for this repo: Godot 4.7.2,
GDScript formatting/linting, modern CLI tooling, and the agentic CLIs
(Claude Code, Codex, OpenCode, gh) pre-installed, with secrets supplied
through a gitignored `.env` file and MCP servers wired for both Claude Code
and OpenCode.

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
| OpenCode | **v2** latest at build (npm `@opencode/cli`) | Vendor-neutral coding agent |
| Codex CLI | latest at build (npm `@openai/codex`) | OpenAI coding agent (reads `AGENTS.md`, `.agents/skills/`) |
| godot-mcp server | pinned `0.1.1` (npm global) | `godot` MCP server; no npm dependency at runtime |
| gh | latest | GitHub CLI (reads `GITHUB_TOKEN`) |
| uv | pinned `0.13.0` | Python tooling; installs `gdtoolkit` |
| gdformat / gdlint | pinned `4.5.0` | GDScript formatter/linter (via `uv tool`) |
| ripgrep, fd, bat, fzf, jq | apt, Ubuntu 24.04 | Fast search/navigation for humans and agents |

Version policy rationale: the engine and infrastructure (uv, node, MCP
server) are pinned for reproducibility; the agentic CLIs track latest at
build time by design. Downloads come from official endpoints over TLS;
checksums are not pinned for the latest-tracking tools.

"Latest at build" means *newest when that image layer was built* — Docker
caches the layer, so a plain rebuild will not fetch a newer CLI. To pull the
current release of Codex / OpenCode, rebuild without the build cache:

```sh
npx @devcontainers/cli@0.89.0 up --workspace-folder . --remove-existing-container --build-no-cache
```

This does **not** refresh Claude Code: it arrives via a devcontainer feature
locked to a digest in `devcontainer-lock.json` (and CI builds with
`--frozen-lockfile`). To move it, delete its entry from the lock file (or run
`up` without `--frozen-lockfile`), then rebuild.

Codex and OpenCode are installed from **npm global** packages. `verify.sh`
checks the Codex package layout and the OpenCode major version. OpenCode v2
uses `@opencode/cli`; the older `opencode-ai` package is the v1 line. The
image requires major version 2. (Claude Code comes from a devcontainer
feature instead, locked by digest in `devcontainer-lock.json`.)

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

For repository operations, follow [GitHub operations](../.llm/skills/github-operations/SKILL.md):
authenticated GitHub MCP first, then authenticated `gh` CLI for capability gaps.
Validate available credential sources without printing secrets; rejected environment
tokens must not mask valid stored authentication or configured Git helpers.

### Codex authentication

Codex does not read this file; it authenticates on its own. Either sign in
interactively (ChatGPT Plus/Pro/Edu/Team, or an API key) or point it at an
API key:

```sh
codex login              # ChatGPT account (browser flow)
codex login status       # check current auth
printenv OPENAI_API_KEY | codex login --with-api-key   # API key, no browser
```

`~/.codex` (config + credentials) lives on a named volume, so auth survives
rebuilds and container recreation.

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
OpenCode expands `{env:GITHUB_TOKEN}` when its server loads configuration.
Without that variable, GitHub reports a failed connection (the exact HTTP
status depends on the endpoint); the other servers remain usable. Its shared
background service owns configuration and connections, so after changing
credentials, restart it from a shell with the new environment:
`opencode service restart`.

The `godot` server can launch the editor, but headless containers have no
display; run/debug/debug-output tools are the headless-friendly subset.

### OpenCode v2 configuration

The [v2 MCP documentation](https://opencode.ai/v2/docs/mcp-servers) defines
servers under `mcp.servers`, with `disabled: true` to prevent connections.
The repo uses that shape and relies on CLI validation rather than a remote
editor schema. The [configuration documentation](https://opencode.ai/v2/docs/config)
describes project discovery and precedence: direct `opencode.json(c)` files
are loaded from ancestors to the current directory, followed by configs
inside `.opencode` directories, which take precedence.

Run these commands from the repository root to inspect discovery:

```sh
opencode debug config
opencode mcp list
```

With v2.0.26, `mcp list` alone can report **No MCP servers configured** in a
workspace the shared service has not initialized yet. `debug config` starts
workspace initialization, but the runtime MCP catalog becomes ready
asynchronously; an immediate list can still be empty. Repeat the list until
all three names appear. GitHub may fail without credentials. `verify.sh`
waits within a fixed deadline for actual discovery and fails if names remain
missing; it also validates the configuration shape.

## Godot Editor + Language Server

The Godot Tools extension talks to the editor's LSP. Start a headless editor
inside the container:

```sh
godot --headless --editor --path .   # serves LSP on port 6005
```

Ports 6005 (LSP) and 6006 (debug adapter) are forwarded automatically.

## Verification

`.devcontainer/verify.sh` is the acceptance harness; `post-create.sh` runs it
whenever a container is **created** (on first open and after rebuilds), and
CI runs it inside a freshly built container.

```sh
.devcontainer/verify.sh           # full: tools, secrets, wiring, MCP handshake,
                                  #       make lint-llm, make test-llm, godot import
.devcontainer/verify.sh --quick   # skip the slow checks
```

## Optional: Egress Firewall

`.devcontainer/init-firewall.sh` (adapted from Anthropic's reference
devcontainer) locks container egress to an allowlist: Anthropic, OpenAI
(`api.openai.com`, `auth.openai.com`, `chatgpt.com`), z.ai, OpenRouter,
GitHub (meta CIDRs + asset hosts), npm, PyPI, astral.sh, nodejs.org,
opencode.ai, Context7, Godot, and VS Code update/extension endpoints, plus
the Ubuntu apt mirrors so later package installs work. IPv6 egress is
blocked entirely (the allowlist is IPv4-only), and Docker proxy variables
are neutralized inside the script. It is **off by default**. To enable:

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
| Refresh Codex / OpenCode | nothing to edit — they track latest; rebuild with `--build-no-cache` (see Version policy) |
| Refresh Claude Code | it is digest-pinned in `devcontainer-lock.json`; drop that entry and rebuild — `--build-no-cache` does not affect it |
| Pin Codex / OpenCode | replace `@latest` with an exact version in the `npm install -g` line in `Dockerfile` |
| Add a VS Code extension | `customizations.vscode.extensions` |
| Add an MCP server | both `.mcp.json` and `opencode.json` |

Named volumes (`frg-*-${devcontainerId}`) persist Claude/Codex/OpenCode
state, the uv cache, Godot import caches, and shell history across rebuilds,
which keeps rebuilds fast. If a volume ever ends up with wrong ownership
(e.g. from an older broken build), reset them and rebuild:

```sh
docker volume ls --filter name=frg- --format '{{.Name}}' | xargs -r docker volume rm
npx @devcontainers/cli@0.89.0 up --workspace-folder . --remove-existing-container
```
