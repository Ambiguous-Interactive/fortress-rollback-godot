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

## Adversarial review round 1 (gate: RAN, FINDINGS)

Fresh-context subagent; triage below (C=critical, M=major, m=minor).

| ID | Finding (quoted ref) | Triage | Action |
| --- | --- | --- | --- |
| C1 | Claude Code reads credential-like vars (open-ended set incl. GITHUB_TOKEN-class names) as EMPTY in remote MCP headers, no warning (code.claude.com/docs/en/mcp "Credential variables that read as empty"); committed `.mcp.json` used `Bearer ${GITHUB_TOKEN}` | AUTO-FIX, doc-confirmed | Header re-keyed to `${MCP_GITHUB_PAT}`; `remoteEnv` derives it from `GITHUB_TOKEN` (`${containerEnv:...}`); env example + README updated |
| M1 | Godot bump path broke verify (build args invisible to runtime; 3 copies of version) | AUTO-FIX | `containerEnv.GODOT_VERSION` added; version now lives in devcontainer.json (build+runtime) + Dockerfile default; README documents both spots |
| M2 | `api.github.com/meta` has 40 duplicate CIDRs; bare `ipset add` aborts script post-flush pre-DROP = fail-open | AUTO-FIX | `sort -u` + `ipset add ... || true`; `aggregate` dep dropped; HOST_IP guarded with `head -n1` |
| M3 | post-create + verify hard-depended on npm registry (npx download each fresh container) | AUTO-FIX | `@coding-solo/godot-mcp@0.1.1` pinned globally in image; MCP configs keep `npx` (resolves global first) for out-of-container portability |
| M4 | POSIX `initializeCommand` fails on Windows hosts (cmd.exe) | DOC | README Quick Start states macOS/Linux; Windows via WSL2 |
| M5 | Firewall IPv4-only; IPv6 egress fails open | AUTO-FIX | ip6tables added: IPv6 egress blocked except loopback/established/ICMPv6 (fail closed) |
| m1 | Unguarded `$(godot --version)` could abort harness without FAIL line | AUTO-FIX | `\|\| true` added; check still fails the run |
| m2 | Stale-volume repair undocumented | DOC | README maintenance section names exact `docker volume rm` command |
| m3 | CI blind to Makefile/scripts/.githooks changes; no arm64 coverage | AUTO-FIX | paths extended; arm64 job added (ubuntu-24.04-arm) |
| m4 | Latest downloads lack checksums; cache makes "latest" stale locally | ADVISORY | Documented trust model in README (TLS + official endpoints; agent CLIs latest-by-design, engine pinned) |
| m5 | opencode `{env:GITHUB_TOKEN}` unset-behavior unverified outside container | ADVISORY | Failure mode is a 401 on one server (non-fatal); documented in README |
| m6 | env-file quoting pitfalls corrupt tokens silently | AUTO-FIX | Format rules + broken-example added to env template |
| m7 | Stale TODO block contradicted completed sections in progress log | AUTO-FIX | Removed |
| m8 | README CLI workflow omitted `--remove-existing-container` (own recorded trap) | AUTO-FIX | Rebuild command now includes the flag |
| m9 | CI used `@latest` CLI + default token permissions | AUTO-FIX | CLI pinned to 0.89.0; `permissions: contents: read` |
| — | Node feature removed: npm needed godot-mcp install at Dockerfile time; feature ordering made that impossible (same class as RED point 5) | AUTO-FIX | Node 22.23.3 pinned tarball in Dockerfile; node feature dropped; claude-code feature reuses installed node |

Verification after fixes: rebuild + full verify green (see T5 update below).

## Adversarial review round 2 (gate: RAN, FINDINGS)

Fresh-context reviewer on the full revised diff. Triage:

| ID | Finding | Triage | Action |
| --- | --- | --- | --- |
| M1 | Firewall flushed iptables, then did network work (curl/dig) before setting DROP — transient failure (e.g. rate-limited meta call, runs every postStart) leaves container fail-open | AUTO-FIX | Restructured into gather phase (all fetch/DNS/route before any mutation) + apply phase (flush → DROP policies back-to-back, policies set immediately after flush); added tcp/53, `claude.ai`, extension-V hosts; verified by inspection + shellcheck |
| M2 | Claim "`npx` resolves the global package first" is FALSE (empirically tested: npx hits registry even with global install) — runtime godot-mcp was unpinned registry fetches; image pin never validated | AUTO-FIX | MCP configs invoke `godot-mcp` binary directly; verify.sh handshake uses the image binary; Dockerfile smoke test non-vacuous (`npm ls -g` + `command -v`); false portability claims removed (configs also hardcode container Godot path) |
| m1 | README claimed "gdformat on save" but `DoHe.godot-format` bundles GDQuest's formatter — different engine than pinned gdtoolkit | AUTO-FIX (doc) | README states the divergence explicitly |
| m2 | Firewall allowlist gaps: extension VSIX hosts, `claude.ai` (native login path), TCP/53 DNS | AUTO-FIX | Added `gallery.vsassets.io`, `vscode.download.prss.microsoft.com`, `claude.ai`, `nodejs.org`; DNS allowed over tcp+udp |
| m3 | CI never enforced committed lock file (silent rewrite) | AUTO-FIX | `up --frozen-lockfile` in CI |
| m4 | Hardcoded `/usr/local/bin/godot` contradicted claimed config portability | AUTO-FIX (doc) | Portability claim dropped; outside-container install documented |
| m5 | CI ran full verify twice (up runs it via post-create, then exec again) | AUTO-FIX | exec step now `--quick`; post-create full run is the gate |
| m6 | `latest` opencode can skew between matrix legs of one CI run | ADVISORY | Accepted: latest-at-build is the declared policy |
| I1 | remoteEnv `${containerEnv:...}` → extension-host propagation unverified with a real token | DOC | env template documents direct `MCP_GITHUB_PAT` fallback |
| I2 | npx non-resolution under container's npm 10.9 untested | MOOT | configs no longer use npx |
| — | VERIFIED-OK ledger: all pinned asset URLs exist both arches; lock file consumed by CLI 0.89.0; ARG scoping sound; volume chown complete; verify fails closed; no secrets on disk | — | — |

Verification after fixes: rebuild clean (0 errors), verify 23/0.

## Adversarial review round 3 (gate: RAN, FINDINGS)

| ID | Finding | Triage | Action |
| --- | --- | --- | --- |
| M1 | Fail-closed contract still violated: fallible mangle flush + `xargs -L1` NAT restore sat between filter flush and DROP policies (abort window = flushed + ACCEPT) | AUTO-FIX | Reordered: filter flush → DROP policies immediately; nat/mangle ops guarded behind policies; `xargs -r … \|\| true`; ipset destroy restored for idempotent re-runs; ip6tables policies set BEFORE flush |
| M2 | CI exec would deterministically fail: gdformat/gdlint live in ~/.local/bin, which plain `docker exec` (devcontainer exec) never sources from .bashrc; verify always checks them | AUTO-FIX | verify.sh exports PATH="$HOME/.local/bin:$PATH" itself; proven green through the same exec path CI uses |
| m1 | Unguarded `ip6tables -F` could abort with v6 still ACCEPT | AUTO-FIX | policies-before-flush (see M1) |
| m2 | jq guard: empty meta sections ([] truthy) would brick firewall on every start | AUTO-FIX | explicit `${#GH_CIDRS[@]} -eq 0` refusal |
| m3 | No curl --max-time on meta fetch; AAAA-only domain failure message lacked context | AUTO-FIX | --max-time 20 added (per-domain error already lists the name) |
| m4 | Docker Desktop proxy env makes firewall decorative + self-check false-fail | AUTO-FIX | proxies unset at script start |
| m5 | CI jq gate spec-invalid for devcontainer.json (JSONC-legal) | AUTO-FIX | dropped from jq gate (up validates); comment explains |
| m6 | Allowlist missing apt mirrors + GitHub asset hosts (later apt use would fail under firewall) | AUTO-FIX | archive/security.ubuntu.com, objects/raw.githubusercontent.com, codeload.github.com added |
| — | VERIFIED-OK: --frozen-lockfile semantics (fails on missing/drift, CLI 0.89.0 source-inspected), godot-mcp bin name + smoke test non-vacuous, --quick-as-display-only accurate, arm64 runner label valid for public repos, firewall second-invocation idempotency, containerEnv syntax, godot dash→dot prefix check | — | — |

Verification after fixes: verify.sh 23/0 through `devcontainer exec` (CI's
exact context), static checks clean.

## Findings / Data

- Measured timings and red-data-point ledger are above; the recurring
  failure class this session was **ordering assumptions** (feature vs
  Dockerfile layer, create vs start, build args vs runtime env) — every
  instance surfaced only through building and running the actual container.
- OpenCode upstream moved `sst/opencode` -> `anomalyco/opencode`, breaking
  the devcontainers-extra feature (maintenance-mode risk, realized).

