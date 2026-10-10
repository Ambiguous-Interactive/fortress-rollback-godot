#!/usr/bin/env bash
# Acceptance harness for the fortress-rollback-godot devcontainer.
#
# Defines the red/green contract for the environment: every requirement the
# devcontainer promises is checked here, so implementation tasks close green
# against data instead of opinion.
#
# Usage:
#   .devcontainer/verify.sh           # full check (used by post-create and CI)
#   .devcontainer/verify.sh --quick   # skip slow checks (godot import, harness
#                                     # tests, MCP handshake)
#
# Environment overrides:
#   GODOT_VERSION        expected Godot version, e.g. "4.7.2-stable"
#   VERIFY_SKIP_HEAVY=1  same as --quick
set -euo pipefail

GODOT_EXPECTED="${GODOT_VERSION:-4.7.2-stable}"
QUICK=0
for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[ "${VERIFY_SKIP_HEAVY:-0}" = "1" ] && QUICK=1

# Script lives in <repo>/.devcontainer/, so the repo root is its parent.
# This works both inside the container and on the host, with or without git.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(dirname "$SCRIPT_DIR")"

# uv tool shims (gdformat/gdlint) land in ~/.local/bin, which plain
# `docker exec` sessions (devcontainer exec, CI) do not source from .bashrc.
: "${HOME:?HOME not set — cannot locate uv tool shims}"
export PATH="$HOME/.local/bin:$PATH"

pass=0
fail=0
ok() { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
section() { printf '\n== %s ==\n' "$1"; }

# check_cmd <name> <args...>: command must exist; prints first version line.
check_cmd() {
  local name="$1"
  shift
  if command -v "$name" >/dev/null 2>&1; then
    local version
    version="$("$name" "$@" 2>/dev/null | head -n 1 || true)"
    ok "${name}: ${version:-<no version output>}"
  else
    bad "${name} not found"
  fi
}

# check_secret <name>: report SET/UNSET without printing values.
check_secret() {
  local name="$1"
  if [ -n "${!name:-}" ]; then
    ok "${name}: set"
  else
    printf '  \033[33m opt\033[0m %s: unset (optional)\n' "$name"
  fi
}

section "Environment"
if [ -f /.dockerenv ] || grep -qE '(docker|containerd)' /proc/1/cgroup 2>/dev/null; then
  ok "running inside a container"
else
  bad "not running inside a container (host: $(uname -s)) — build with: npx @devcontainers/cli up"
fi

section "Engine"
if command -v godot >/dev/null 2>&1; then
  # `|| true` keeps a crashing engine binary from aborting the whole harness
  # under pipefail; the version check below still fails the run.
  version="$(godot --version 2>/dev/null | head -n 1 || true)"
  expected="${GODOT_EXPECTED//-/.}"
  if [ "${version#"${expected}"}" != "$version" ]; then
    ok "godot ${version} (expected ${expected})"
  else
    bad "godot version mismatch: got '${version}', expected prefix '${expected}'"
  fi
else
  bad "godot not found"
fi

section "Agentic CLIs"
check_cmd claude --version
check_cmd opencode --version
check_cmd gh --version
check_cmd node --version
check_cmd uv --version

section "Modern CLI tools"
check_cmd rg --version
check_cmd fd --version
check_cmd bat --version
check_cmd fzf --version
check_cmd jq --version

section "GDScript tooling (gdtoolkit via uv)"
check_cmd gdformat --version
check_cmd gdlint --version

section "Secrets (.env passthrough; all optional)"
for secret in GITHUB_TOKEN OPENROUTER_API_KEY ZAI_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN; do
  check_secret "$secret"
done

section "Wiring"
hooks="$(git -C "$ROOT" config core.hooksPath || true)"
if [ "$hooks" = ".githooks" ]; then
  ok "git hooks installed (core.hooksPath=.githooks)"
else
  bad "git hooks not installed (core.hooksPath='${hooks:-<unset>}') — run: make hooks"
fi

for cfg in "$ROOT/.mcp.json" "$ROOT/opencode.json"; do
  if jq -e . "$cfg" >/dev/null 2>&1; then
    ok "$(basename "$cfg") is valid JSON"
  else
    bad "$(basename "$cfg") is missing or invalid JSON"
  fi
done

if jq -e '.mcpServers | has("godot") and has("context7") and has("github")' \
  "$ROOT/.mcp.json" >/dev/null 2>&1; then
  ok ".mcp.json wires godot, context7, github servers"
else
  bad ".mcp.json missing one of: godot, context7, github"
fi

if jq -e '.mcp | has("godot") and has("context7") and has("github")' \
  "$ROOT/opencode.json" >/dev/null 2>&1; then
  ok "opencode.json wires godot, context7, github servers"
else
  bad "opencode.json missing one of: godot, context7, github"
fi

if [ "$QUICK" = "1" ]; then
  printf '\n  (--quick: skipped godot import, harness tests, MCP handshake)\n'
else
  section "MCP handshake (godot server over stdio)"
  handshake='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"verify","version":"1.0"}}}'
  # Exercises the image-installed `godot-mcp` binary directly (not npx), so
  # the pinned version in the image is what gets validated.
  # `|| true` neutralizes pipefail/SIGPIPE from `head`; the response content
  # alone decides pass/fail below.
  response="$(cd "$ROOT" && printf '%s\n' "$handshake" | \
    timeout 120 env GODOT_PATH="$(command -v godot)" godot-mcp 2>/dev/null | head -n 5 || true)"
  if printf '%s' "$response" | grep -q '"serverInfo"'; then
    ok "godot MCP server answered initialize"
  else
    bad "godot MCP server did not answer initialize (response: ${response:-<empty>})"
  fi

  section "Repository harness"
  if make -C "$ROOT" lint-llm >/dev/null 2>&1; then
    ok "make lint-llm"
  else
    bad "make lint-llm"
  fi
  if make -C "$ROOT" test-llm >/dev/null 2>&1; then
    ok "make test-llm"
  else
    bad "make test-llm"
  fi

  section "Godot headless import"
  if godot --headless --path "$ROOT" --import >/dev/null 2>&1; then
    ok "godot --headless --import"
  else
    bad "godot --headless --import"
  fi
fi

printf '\n== Summary: %d passed, %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
