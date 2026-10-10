#!/usr/bin/env bash
# Tool probes shared by the acceptance harness; caller supplies ok()/bad().
# check_cmd <name> <args...>: command must exist; prints first version line.
check_cmd() {
  local name="$1"
  shift
  if command -v "$name" >/dev/null 2>&1; then
    local version
    if ! version="$("$name" "$@" 2>/dev/null)"; then
      bad "${name} failed to run"
      return
    fi
    version="${version%%$'\n'*}"
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

# check_major <name> <min>: tool must run and report major >= min. Guards
# against silently staying on an old major line when an install path moves.
# Anchors on the first *version-shaped* token (v2.0.26, 2.0.26) rather than
# the first digit run anywhere, so unrelated leading numbers cannot satisfy it.
check_major() {
  local name="$1" min="$2" version token major
  if ! command -v "$name" >/dev/null 2>&1; then
    bad "${name} not found"
    return
  fi
  if ! version="$("$name" --version 2>/dev/null)"; then
    bad "${name} failed to run"
    return
  fi
  version="${version%%$'\n'*}"
  token="$(printf '%s' "$version" | grep -oE 'v?[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1 || true)"
  major="${token#v}"
  major="${major%%.*}"
  if [ -n "$major" ] && [ "$major" -ge "$min" ]; then
    ok "${name}: ${version:-<no version output>} (major >= ${min})"
  else
    bad "${name} on the wrong major line: '${version:-<no version output>}', need major >= ${min}"
  fi
}

# check_codex_package: verify the global npm package layout installed by the
# Dockerfile. This is an offline packaging check, not a runtime health check.

check_codex_package() {
  local pkg
  if ! command -v codex >/dev/null 2>&1; then
    bad "codex not found"
    return
  fi
  if ! pkg="$(npm root -g 2>/dev/null)"; then
    bad "cannot locate the global Codex package"
    return
  fi
  pkg="$pkg/@openai/codex"
  if [ -f "$pkg/package.json" ] &&
      [ "$(readlink -f "$(command -v codex)")" = "$(readlink -f "$pkg/bin/codex.js")" ]; then
    ok "codex: executable resolves to the installed npm package"
  else
    bad "codex executable does not resolve to the npm package; install npm i -g @openai/codex"
  fi
}

# Source inspection starts asynchronous workspace initialization in v2.0.26.
# Poll actual runtime discovery until every name appears, including pending or
# failed connections; remote connectivity is not an acceptance requirement.
# Suppress raw config/list output because it may contain credential diagnostics.
check_opencode_runtime() {
  local root="$1" budget="${2:-60}" servers name deadline remaining discovered=""
  if ! (cd "$root" && timeout "$budget" opencode debug config >/dev/null 2>&1); then
    bad "OpenCode workspace initialization failed or timed out"
    return
  fi
  deadline=$((SECONDS + budget))
  while :; do
    remaining=$((deadline - SECONDS))
    if [ "$remaining" -le 0 ]; then
      break
    fi
    if ! servers="$(cd "$root" && timeout "$remaining" opencode mcp list 2>/dev/null)"; then
      bad "OpenCode MCP discovery failed or timed out"
      return
    fi
    discovered=""
    for name in godot context7 github; do
      if printf '%s\n' "$servers" | grep -E "^(✓|✗|○)[[:space:]]+${name}[[:space:]]+" >/dev/null; then
        discovered="${discovered:+$discovered }$name"
      fi
    done
    if [ "$discovered" = "godot context7 github" ]; then
      for name in $discovered; do
        ok "OpenCode discovered MCP server ${name}"
      done
      return
    fi
    sleep 1
  done
  bad "OpenCode MCP discovery timed out; discovered expected names: ${discovered:-none}"
}
