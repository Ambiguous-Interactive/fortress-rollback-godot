#!/usr/bin/env bash
# Post-create setup: git hooks, GDScript tooling, and environment verification.
# Runs once per container build/rebuild. Every step is idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(dirname "$SCRIPT_DIR")"
GDTOOLKIT_VERSION="${GDTOOLKIT_VERSION:-4.5.0}"

# The devcontainer CLI buffers lifecycle-script output, so a hung step's log can
# surface only its already-printed lines when the job is cancelled. Every step
# stamps its start time in UTC, so the last surviving line localizes a silent
# hang to one step even when nothing after it is ever flushed (issue #249).
step() {
    echo "[post-create $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"
}

# Devcontainer features are appended as layers AFTER the Dockerfile, and the
# claude-code feature installs a global npm package as root. Those packages are
# created after the Dockerfile's own repair ran, so they come out root-owned
# and un-updatable again -- every rebuild would reintroduce EACCES for them.
# Re-apply the repair here, where features have already run. postCreateCommand
# runs as the remote user, so this needs sudo, which is passwordless here.
step "restoring npm global write access (features install after the Dockerfile)"
sudo "$SCRIPT_DIR/npm-global-perms.sh"

step "installing git hooks"
make -C "$ROOT" hooks

step "installing gdtoolkit ${GDTOOLKIT_VERSION} (gdformat + gdlint)"
uv tool install --force "gdtoolkit==${GDTOOLKIT_VERSION}"

# uv tool shims land in ~/.local/bin; make sure interactive shells see them.
if ! grep -qs '\.local/bin' "$HOME/.bashrc"; then
    printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >>"$HOME/.bashrc"
fi
export PATH="$HOME/.local/bin:$PATH"

step "acquiring the pinned browser witnessing capability (chromium, firefox, playwright)"
"$SCRIPT_DIR/acquire-browsers.sh"

step "verifying environment"
"$SCRIPT_DIR/verify.sh"
