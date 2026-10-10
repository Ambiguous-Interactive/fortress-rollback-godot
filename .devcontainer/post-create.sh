#!/usr/bin/env bash
# Post-create setup: git hooks, GDScript tooling, and environment verification.
# Runs once per container build/rebuild. Every step is idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(dirname "$SCRIPT_DIR")"
GDTOOLKIT_VERSION="${GDTOOLKIT_VERSION:-4.5.0}"

echo "[post-create] installing git hooks"
make -C "$ROOT" hooks

echo "[post-create] installing gdtoolkit ${GDTOOLKIT_VERSION} (gdformat + gdlint)"
uv tool install --force "gdtoolkit==${GDTOOLKIT_VERSION}"

# uv tool shims land in ~/.local/bin; make sure interactive shells see them.
if ! grep -qs '\.local/bin' "$HOME/.bashrc"; then
    printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >>"$HOME/.bashrc"
fi
export PATH="$HOME/.local/bin:$PATH"

echo "[post-create] verifying environment"
"$SCRIPT_DIR/verify.sh"
