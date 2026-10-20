#!/usr/bin/env bash
# Post-start hygiene: drop stale agent scratch before a session begins.
#
# Agent sessions write scratch into the container's /tmp and never remove
# it, so a long-lived container accumulates it. One session left 634 GB of
# stale copies behind -- 19 full workspace copies, each carrying the
# repository's 33 GB .cache/ tree. This hook removes scratch that is older
# than the retention age and is not held open by a running process.
#
# It runs on every container start and is idempotent. The repository's own
# .cache/ is only reported here, never deleted: cited evidence must survive.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(dirname "$SCRIPT_DIR")"
PRUNE="${ROOT}/scripts/prune_caches.py"

if [ -f "$PRUNE" ]; then
    echo "[post-start] pruning stale scratch and container caches"
    python3 "$PRUNE" --scope scratch --scope container --apply || \
        echo "[post-start] prune skipped (nothing removable or tool unavailable)"
    echo "[post-start] repository cache (not modified):"
    python3 "$PRUNE" --scope workspace 2>/dev/null | head -n 1 || true
fi
