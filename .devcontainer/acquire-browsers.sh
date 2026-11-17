#!/usr/bin/env bash
# Acquire the pinned real-browser witnessing capability (#385).
#
# Installs the pinned Playwright npm package and the digest-bound Chromium and
# Firefox builds recorded in docs/reference/pins.json, unpacked into the cache
# layouts the reference harness already reads, for the container's
# architecture. Runs at post-create; safe to re-run by hand. The heavy
# acquisition deliberately lives here (post-create) instead of the image:
# hosted runners do not persist layer caches, so baked artifacts would be
# re-downloaded on every Devcontainer Verify build on both architectures.
# Verification of the settled state, including real browser launches, is
# .devcontainer/verify.sh's browser section; a missing browser there is a
# failed verification, never a silent skip.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(dirname "$SCRIPT_DIR")"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) ARCH=x86_64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "unsupported architecture for the pinned browsers: ${ARCH}" >&2; exit 2 ;;
esac

echo "[browsers] installing the pinned Playwright package (package-lock.json from scripts/reference/browser)"
mkdir -p "$ROOT/.cache/reference/browser"
cp "$ROOT/scripts/reference/browser/package.json" "$ROOT/scripts/reference/browser/package-lock.json" \
  "$ROOT/.cache/reference/browser/"
if ! npm ci --ignore-scripts --prefix "$ROOT/.cache/reference/browser"; then
  echo "npm ci failed for the pinned Playwright package" >&2
  exit 1
fi

echo "[browsers] acquiring the pinned chromium and firefox builds for ${ARCH}"
PYTHONPATH="$ROOT/scripts/reference" python3 "$ROOT/scripts/reference/devcontainer_browsers.py" --arch "$ARCH"

echo "[browsers] acquired; .devcontainer/verify.sh now verifies the capability with real launches"
