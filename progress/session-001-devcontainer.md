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
  feature; OpenCode now installs in the Dockerfile.
- RED data point 5: image + container built; post-create ran verify.sh to
  21 passed / 2 failed — only `make lint-llm` and `make test-llm` failed,
  with `ModuleNotFoundError: No module named 'dataclasses'` / `unittest`.
  Root cause (from `/var/log/apt/history.log` inside the container): the
  devcontainers base image ships NO python3; a feature's installer ran
  `apt-get install --no-install-recommends python3-minimal` (enough for its
  own logic) leaving the container without the real stdlib. Fix: install the
  full `python3` package in the Dockerfile's apt layer, which runs before
  features — features then see python3 present and skip their minimal stub.
- RED data point 6: OpenCode's official install script queries the
  unauthenticated GitHub API (`api.github.com/.../releases/latest`), which
  rate-limits during builds -> "Failed to fetch version information". Fix:
  fetch the release asset directly via the redirect URL
  `releases/latest/download/opencode-linux-<arch>.tar.gz` (single binary at
  tarball root, verified); no API call at all.
- RED data point 7 (process lesson, not a code bug): `devcontainer up`
  without `--remove-existing-container` REUSED the stale container after the
  Dockerfile changed — `up` returned success with the same containerId as the
  previous failed run, because postCreateCommand only runs on container
  CREATE. Lesson: after image changes, rebuild with
  `--remove-existing-container`; CI runs on a fresh runner so it always
  creates fresh.
- RED data point 3 fix verified: image built past the Godot layer; failure
  moved to feature stage (i.e., ownership fix worked).

### T3 — Secrets via `.env` (GREEN target)

- `initializeCommand` confirmed working: `devcontainer.env` auto-created from
  the example on first `up`; `git check-ignore` confirms it is ignored.
- GREEN: injected `TEST_SECRET_KEY=abc123` into `devcontainer.env`, recreated
  the container, `printenv` inside showed the value (PASS), env file restored.
  Secrets flow container-wide via `runArgs --env-file`.

### T4 — MCP servers (GREEN target)

- GREEN: `.mcp.json` and `opencode.json` valid JSON, all three servers wired
  in both (verify.sh checks); godot MCP stdio handshake answers `initialize`
  with `serverInfo` (live npx run inside the container).
- Incidental external validation: the harness's own MCP client picked up the
  new `.mcp.json` and connected the godot server mid-session.

### T5 — Project gates inside container (GREEN target)

- GREEN: full verify inside the container = **23 passed, 0 failed**, ~5.5s
  wall: engine version, agentic CLIs, CLI tools, gdformat/gdlint, hooks,
  wiring JSON, MCP handshake, `make lint-llm`, `make test-llm`,
  `godot --headless --import`.

### T6 — Docs + .gitignore (GREEN target)

- `.devcontainer/README.md` written (harness style, <300 lines);
  `.gitignore` gained `.devcontainer/devcontainer.env`.

### T7 — CI workflow (GREEN target)

- `.github/workflows/devcontainer.yml` added: shellcheck (warning level),
  JSON validation, `devcontainer up` on a fresh runner, verify.sh in the
  container. Fresh runners always create fresh containers, which sidesteps
  RED data point 7.

## Timings (measured)

| Operation | Wall time |
| --- | --- |
| Full image rebuild (Dockerfile layer changed) | ~70–75s |
| Container recreation, warm image cache | ~14s |
| Full verify.sh inside container | ~5.5s |
| `up` on a fresh runner (CI worst case) | covered by 30min timeout |

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
