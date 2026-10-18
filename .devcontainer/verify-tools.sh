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

# check_npm_global_writable: prove the container user can install, REPLACE and
# remove a global npm package. The image installs the agentic CLIs as root, so
# a root-owned global root makes every global write fail with EACCES (mkdir for
# a new package, rename for an update or a removal) while read-only npm
# commands keep working -- a state no version or `npm ls` check can detect,
# and `npm doctor` does not detect it either because it only reports
# group/world-writable directories, never "not writable by me".
#
# Two assertions, because neither alone is sufficient. The permission
# precondition walks every directory under the global root: a package installed
# as root AFTER the repair ran (devcontainer features build after the
# Dockerfile) leaves its scope directory unwritable, and creating a brand-new
# package still succeeds there, so a create-only probe reports a false PASS.
# The functional round trip then packs two versions of one synthetic package and
# installs the second over the first, which is what forces npm down the rename
# path this bug lives on. Offline by construction, so it needs neither the
# registry nor network access. npm-global-perms.sh is the documented repair.
check_npm_global_writable() {
  local prefix root bindir unreadable verdict detail
  # Root can always write, so every assertion below would pass while the
  # container user is locked out. Refuse rather than report a false green.
  if [ "$(id -u)" -eq 0 ]; then
    bad "npm write probe must run as the container user, not root"
    return
  fi
  prefix="$(npm prefix -g 2>/dev/null || true)"
  if [ -z "$prefix" ]; then
    bad "cannot determine the npm global prefix"
    return
  fi
  root="${prefix}/lib/node_modules"
  bindir="${prefix}/bin"
  if [ ! -d "$root" ] || [ ! -d "$bindir" ]; then
    bad "npm global layout is missing under ${prefix}"
    return
  fi

  # `|| true` because this is the failure path: under pipefail, head closing the
  # pipe early makes find exit 141 once its output exceeds the pipe buffer, which
  # would abort the harness before bad() could name the repair. Reproduced with
  # 3001 directories (~210 KB of paths).
  unreadable="$(find "$root" "$bindir" -type d ! -writable 2>/dev/null | head -4 || true)"
  if [ -n "$unreadable" ]; then
    bad "npm global directories are not writable by $(id -un); repair: sudo .devcontainer/npm-global-perms.sh"
    printf '%s\n' "$unreadable" | sed 's/^/         /'
    return
  fi
  ok "every npm global directory is writable by $(id -un)"

  # Run the round trip in a subshell so its EXIT/INT/TERM trap is scoped to it:
  # verify-tools.sh is sourced, so a trap set here would otherwise outlive the
  # function and fire against variables that no longer exist. The trap is what
  # keeps an interrupted run (CI cancellation, Ctrl-C) from leaving a real
  # package and a PATH symlink in the image.
  verdict="$(
    set -uo pipefail
    name="@frg-probe/npm-global-write-probe"
    work="$(mktemp -d)" || exit 90
    cleanup() {
      npm uninstall -g --prefix "$prefix" "$name" >/dev/null 2>&1 || true
      rm -rf "$work"
    }
    trap cleanup EXIT INT TERM
    pack() {
      rm -rf "$work/pkg"
      mkdir -p "$work/pkg/bin"
      printf '{"name":"%s","version":"%s","bin":{"frg-npm-probe":"bin/probe.js"}}\n' "$name" "$1" >"$work/pkg/package.json"
      printf '#!/usr/bin/env node\nconsole.log("frg-npm-probe ok");\n' >"$work/pkg/bin/probe.js"
      chmod +x "$work/pkg/bin/probe.js"
      npm pack --silent --pack-destination "$work" "$work/pkg" 2>/dev/null
    }
    out=""
    # Derive the tarball path from npm's own output: it drops the scope and
    # replaces '/' with '-', and a guessed path fails as "tarball ... seems to
    # be corrupted", which is a red that never reaches the permission check.
    tgz="$(pack 1.0.0)" || { echo pack-failed; exit 0; }
    out="$(npm install -g --prefix "$prefix" "$work/$tgz" 2>&1)" || { echo "$out"; echo install-failed; exit 0; }
    [ -f "$root/$name/package.json" ] || { echo layout-failed; exit 0; }
    [ -e "$bindir/frg-npm-probe" ] || { echo link-failed; exit 0; }
    "$bindir/frg-npm-probe" >/dev/null 2>&1 || { echo run-failed; exit 0; }
    # Replacing the installed package is the path the reported bug broke: npm
    # must rename the existing directory aside before extracting the new tree.
    tgz="$(pack 1.0.1)" || { echo pack-failed; exit 0; }
    out="$(npm install -g --prefix "$prefix" "$work/$tgz" 2>&1)" || { echo "$out"; echo replace-failed; exit 0; }
    grep -q '"version": *"1.0.1"' "$root/$name/package.json" || { echo replace-not-applied; exit 0; }
    out="$(npm uninstall -g --prefix "$prefix" "$name" 2>&1)" || { echo "$out"; echo uninstall-failed; exit 0; }
    if [ -e "$root/$name" ] || [ -e "$bindir/frg-npm-probe" ]; then
      echo residue
      exit 0
    fi
    echo ok
  )" || verdict="probe-aborted"
  # npm does not prune empty scope directories, so assert on the package and the
  # symlink only, then tidy the empty scope directory ourselves.
  rmdir "$root/@frg-probe" 2>/dev/null || true

  case "$verdict" in
    ok)
      ok "npm global install, replace and uninstall work as $(id -un)"
      ;;
    install-failed | replace-failed | uninstall-failed)
      detail="$(printf '%s\n' "$verdict" | grep -oE 'EACCES: permission denied, [a-z]+' | head -1 || true)"
      bad "npm global ${verdict%-failed} is not permitted for $(id -un) [${detail:-see npm output}]; repair: sudo .devcontainer/npm-global-perms.sh"
      ;;
    layout-failed) bad "npm global install succeeded but the package is missing from ${root}" ;;
    link-failed) bad "npm global install succeeded but no bin symlink appeared in ${bindir}" ;;
    run-failed) bad "the npm global probe package installed but its binary would not run" ;;
    replace-not-applied) bad "npm global replace reported success but the old version is still installed" ;;
    residue) bad "npm global uninstall left the probe package or its symlink behind" ;;
    pack-failed) bad "npm pack of the write probe failed" ;;
    *) bad "npm global write probe did not complete: ${verdict}" ;;
  esac
}

# Source inspection starts asynchronous workspace initialization in v2.0.26.
# Poll actual runtime discovery until every name appears, independent of
# connection/authentication status; remote connectivity is not required.
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
    if ! servers="$(cd "$root" && timeout "$remaining" opencode api mcp.list --param "location[directory]=$root" 2>/dev/null)"; then
      bad "OpenCode MCP discovery failed or timed out"
      return
    fi
    # The API command calls the same runtime catalog as `mcp list`, without
    # human status glyphs. Authentication state never affects name discovery.
    if ! discovered="$(printf '%s\n' "$servers" | jq -r '
      if (.data | type) == "array" and
          all(.data[]; (.name | type) == "string") then
        [.data[].name] as $names |
        ["godot", "context7", "github"] |
        map(select(. as $name | $names | index($name) != null)) | join(" ")
      else error("invalid runtime catalog") end
    ' 2>/dev/null)"; then
      bad "OpenCode returned an invalid MCP runtime catalog"
      return
    fi
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
