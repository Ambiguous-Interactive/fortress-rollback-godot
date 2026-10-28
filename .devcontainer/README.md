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
| Node.js | pinned `26.12.1` (Dockerfile arg) | MCP server runtime |
| Claude Code CLI | latest at build | Anthropic coding agent |
| OpenCode | **v2** latest at build (npm `@opencode/cli`) | Vendor-neutral coding agent |
| Codex CLI | latest at build (npm `@openai/codex`) | OpenAI coding agent (reads `AGENTS.md`, `.agents/skills/`) |
| godot-mcp server | pinned `0.1.1` (npm global) | `godot` MCP server; no npm dependency at runtime |
| gh | latest | GitHub CLI (reads `GITHUB_TOKEN`) |
| uv | pinned `0.13.6` | Python tooling; installs `gdtoolkit` |
| gdformat / gdlint | pinned `4.5.0` | GDScript formatter/linter (via `uv tool`) |
| ripgrep, fd, bat, fzf, jq | apt, Ubuntu 24.04 | Fast search/navigation for humans and agents |

Version policy rationale: the engine and infrastructure (uv, node, MCP
server) are pinned for reproducibility; the agentic CLIs track latest at
build time by design. Downloads come from official endpoints over TLS;
checksums are not pinned for the latest-tracking tools.

"Latest at build" means *newest when that image layer was built* — Docker
caches the layer, so a plain rebuild will not fetch a newer CLI.

Because the global npm root is writable by the container user, updating in
place is the fast path and needs no rebuild:

```sh
npm install -g @openai/codex@latest        # also @opencode/cli, @anthropic-ai/claude-code
npm ls -g --depth=0                        # confirm what is installed
```

A cache-free rebuild still exists, and is what CI exercises:

```sh
npx @devcontainers/cli@0.89.0 up --workspace-folder . --remove-existing-container --build-no-cache
```

This does **not** refresh Claude Code: it arrives via a devcontainer feature
locked to a digest in `devcontainer-lock.json` (and CI builds with
`--frozen-lockfile`). To move it, delete its entry from the lock file (or run
`up` without `--frozen-lockfile`), then rebuild. `npm install -g
@anthropic-ai/claude-code@latest` does update it in place, overriding the
feature's digest until the next rebuild.

### npm global permissions

The Dockerfile installs every CLI from npm's global prefix (`/usr/local`) as
root, which leaves `/usr/local/lib/node_modules` and `/usr/local/bin` owned by
`root`. The container then runs as `vscode`, and on Unix replacing or removing a
file requires write permission on its **parent** directory — so
`npm install -g`, `npm update -g` and `npm uninstall -g` all failed with
`EACCES` (`mkdir` for a new package, `rename` for an update or a removal) while
read-only npm commands kept working and hid the breakage. `npm doctor` does not
catch this: it reports group/world-writable directories, never "not writable by
me".

`npm-global-perms.sh` keeps the single global root (so `npm root -g`, `PATH`
and every existing binary are unchanged) and adds group write plus setgid for
`vscode`'s own primary group. This grants no new privilege — `vscode` already
has passwordless sudo. It is idempotent, fails closed, and verifies as `vscode`
rather than as root. It does not change the ownership of existing entries, so
they stay `root`; a package the user installs afterwards is owned by `vscode`.
It applies group write recursively under `lib/node_modules`, where npm extracts
and empties package trees, but only to the `bin` **directory**, because npm
only creates and unlinks symlinks there — so unrelated binaries such as the
pinned Godot engine keep their original permissions.

It runs twice, and both steps are required. The Dockerfile step covers the
CLIs the image installs. Devcontainer features are appended as layers *after*
the Dockerfile, and the claude-code feature installs a global npm package as
root, which would land root-owned again — so `post-create.sh` re-applies the
repair once features have run. Without that second step every rebuild
reintroduces `EACCES` for `@anthropic-ai/claude-code` while leaving the
Dockerfile-installed CLIs working, which is a confusing half-broken state.

`verify.sh` checks the contract two ways: it requires every directory under the
global root to be writable by the current user, and it installs, **replaces**
and removes a synthetic package offline. The replace step matters — a probe
that only creates a new package passes even when the packages the features
installed are still locked. The check also refuses to run as root, because root
can always write and would report a false pass.

If the state is ever lost, re-apply it with:

```sh
sudo .devcontainer/npm-global-perms.sh
```

Do **not** install global packages with `sudo npm install -g`. Root creates
directories with its own umask, so they come out group-readable but not
group-writable (`2755`), even inside a setgid parent. The package can then no
longer be updated or removed without sudo: `npm uninstall -g` either fails with
`ENOTEMPTY` (packages with dependencies) or appears to succeed while leaving an
undeletable `.pkg-XXXX` tree behind. Plain `npm install -g` is the supported
path; if sudo was used anyway, run the repair command above. `verify.sh`
detects the regression, names the offending directory and states the repair.

Codex and OpenCode are installed from **npm global** packages. `verify.sh`
checks the Codex package layout and the OpenCode major version. OpenCode v2
uses `@opencode/cli`; the older `opencode-ai` package is the v1 line. The
image requires major version 2. (Claude Code comes from a devcontainer
feature instead, locked by digest in `devcontainer-lock.json`.)

The build resolves each CLI's latest wrapper once and keeps that exact version.
If matching native packages are still publishing, it retries readiness and installation
up to 30 times within a ten-minute total budget per CLI. Build output retains the
first npm failure, each retry, and the final installed version. Authentication,
permissions, unsupported package metadata, and runtime failures stop immediately.
An expired budget fails the build; it never substitutes an older release.
Codex's native npm aliases use the same checks. The pinned Godot MCP package and
digest-locked Claude Code feature keep their separate installation paths.

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
| Refresh Codex / OpenCode | nothing to edit — they track latest; `npm install -g <pkg>@latest` in place, or rebuild with `--build-no-cache` (see Version policy) |
| Refresh Claude Code | it is digest-pinned in `devcontainer-lock.json`; drop that entry and rebuild — `--build-no-cache` does not affect it |
| Change CLI publication budget | `--timeout`, `--attempts`, and `--interval` on the installer calls in `Dockerfile` |
| Change who may run `npm i -g` | `npm-global-perms.sh` (target user argument); it must stay the last image step that touches the global npm root |
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
