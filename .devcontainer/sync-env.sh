#!/usr/bin/env bash
# Sync machine-local secrets into /etc/environment so every process in the
# container (login shells, VS Code, OpenCode, the gh CLI) inherits them.
#
# Sources, highest precedence first:
#   1. $ROOT/.env.local                     (machine-local, gitignored)
#   2. $ROOT/.devcontainer/devcontainer.env (docker --env-file; applied at
#                                           container creation, but re-read
#                                           here so edits need no recreate)
#   3. `gh auth token`                      (GITHUB_TOKEN fallback only)
#
# Rules:
#   - Empty values are NEVER synced. A missing secret must not overwrite a
#     working one; this is the failure mode that once blanked GITHUB_TOKEN.
#   - Values are never printed. Logs contain key names, sources, and lengths
#     only.
#   - Idempotent: /etc/environment is rewritten only when a value changes.
#
# Runs on every container start via post-start.sh; safe to run by hand.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(dirname "$SCRIPT_DIR")"
TARGET=/etc/environment

declare -a ORDER=()
declare -A SOURCE=()
declare -A VALUE=()

# record KEY VALUE SOURCE — the only place values pass through; never echoed.
record() {
    local key="$1" val="$2" src="$3"
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "[sync-env] skipping invalid key name in $src" >&2
        return 0
    fi
    if [[ "$val" == *$'\n'* ]] || [[ "$val" == *$'\t'* ]]; then
        return 0
    fi
    # Defensive: strip surrounding quotes (corrupts docker --env-file semantics),
    # then refuse empty values: a missing secret must not overwrite a working one.
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    if [[ -z "$val" ]] || [[ -n "${SOURCE[$key]:-}" ]]; then
        return 0  # empty values never win; the first source to set the key wins
    fi
    VALUE[$key]="$val"
    SOURCE[$key]="$src"
    ORDER+=("$key")
}

# 1-2. env files
for f in "$ROOT/.env.local" "$ROOT/.devcontainer/devcontainer.env"; do
    [ -f "$f" ] || continue
    src="$(basename "$f")"
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"   # ltrim
        case "$line" in
            ''|\#*) continue ;;
            [A-Za-z_]*=*)
                key="${line%%=*}"
                val="${line#*=}"
                val="${val%"${val##*[![:space:]]}"}"  # rtrim
                record "$key" "$val" "$src"
                ;;
        esac
    done < "$f"
done

# 3. gh CLI fallback for GITHUB_TOKEN only
if [[ -z "${SOURCE[GITHUB_TOKEN]:-}" ]] && command -v gh >/dev/null 2>&1; then
    if token="$(gh auth token 2>/dev/null)" && [ -n "$token" ]; then
        record "GITHUB_TOKEN" "$token" "gh auth token"
    fi
fi

# Ensure MCP_GITHUB_PAT is available alongside GITHUB_TOKEN for MCP configs
# that reference it (e.g. Claude Code's ${MCP_GITHUB_PAT} header expansion).
# Derived keys are environment-only: they are never written back into a source
# file, so a rotated GITHUB_TOKEN can never leave a stale derived PAT behind.
declare -A DERIVED=()
if [[ -n "${VALUE[GITHUB_TOKEN]:-}" && -z "${VALUE[MCP_GITHUB_PAT]:-}" ]]; then
    VALUE[MCP_GITHUB_PAT]="${VALUE[GITHUB_TOKEN]}"
    SOURCE[MCP_GITHUB_PAT]="derived from GITHUB_TOKEN"
    DERIVED[MCP_GITHUB_PAT]=1
    ORDER+=("MCP_GITHUB_PAT")
fi

if [ "${#ORDER[@]}" -eq 0 ]; then
    echo "[sync-env] no non-empty secrets found; nothing to sync"
    exit 0
fi

# Build the update sidecar (tab-separated; chmod 600 — it holds values).
updates="$(mktemp)"
newfile="$(mktemp)"
trap 'rm -f "$updates" "$newfile"' EXIT
chmod 600 "$updates"
for key in "${ORDER[@]}"; do
    printf '%s\t%s\n' "$key" "${VALUE[$key]}" >> "$updates"
done

# Merge into a fresh copy of /etc/environment: replace matching lines (keep
# only the first occurrence of each key), append keys not yet present.
# Keys contain no regex metacharacters ([A-Za-z0-9_], validated above).
awk -F'\t' '
    NR == FNR {
        val[$1] = $2; keys[++n] = $1; next
    }
    {
        replaced = 0
        for (i = 1; i <= n; i++) {
            if ($0 ~ "^" keys[i] "=") {
                seen[keys[i]] = 1
                if (!(keys[i] in printed)) {
                    print keys[i] "=" val[keys[i]]
                    printed[keys[i]] = 1
                }
                replaced = 1
            }
        }
        if (!replaced) print
        next
    }
    END {
        for (i = 1; i <= n; i++) if (!(keys[i] in seen)) print keys[i] "=" val[keys[i]]
    }
' "$updates" "$TARGET" > "$newfile"

# Rewrite only on change, preserving root:root 644.
if ! cmp -s "$newfile" "$TARGET"; then
    if sudo -n install -o root -g root -m 644 "$newfile" "$TARGET" 2>/dev/null; then
        for key in "${ORDER[@]}"; do
            echo "[sync-env] $key <- ${SOURCE[$key]} (length ${#VALUE[$key]})"
        done
    else
        echo "[sync-env] WARNING: could not write $TARGET (no passwordless sudo)" >&2
        echo "[sync-env] secrets remain available in the source files only" >&2
        exit 0
    fi
else
    echo "[sync-env] $TARGET already up to date"
fi

# Export to a profile script so new interactive/non-login shells in a
# running container inherit updated secrets without requiring a rebuild.
# The staging file stays private (mktemp 600) and is removed on both paths;
# only the installed copy in /etc/profile.d survives.
profile="/etc/profile.d/99-devcontainer-secrets.sh"
tmp_profile="$(mktemp)"
{
    echo '# Generated by .devcontainer/sync-env.sh; do not edit by hand.'
    for key in "${ORDER[@]}"; do
        # printf %q escapes for safe shell re-sourcing
        printf 'export %s=%q\n' "$key" "${VALUE[$key]}"
    done
} > "$tmp_profile"
if sudo -n install -o root -g root -m 644 "$tmp_profile" "$profile" 2>/dev/null; then
    echo "[sync-env] updated $profile"
else
    echo "[sync-env] WARNING: could not write $profile" >&2
fi
rm -f "$tmp_profile"

# Keep devcontainer.env in sync with values sourced from .env.local so
# container recreates (which load --env-file devcontainer.env) pick up
# the same secrets without manual duplication. Derived keys are excluded:
# they must be recomputed from the current GITHUB_TOKEN, never stored.
dev_env="$ROOT/.devcontainer/devcontainer.env"
dev_updates="$(mktemp)"
stored=0
for key in "${ORDER[@]}"; do
    if [[ -n "${DERIVED[$key]:-}" ]]; then
        continue
    fi
    printf '%s\t%s\n' "$key" "${VALUE[$key]}" >> "$dev_updates"
    stored=$((stored + 1))
done
tmp_dev=""
if [ "$stored" -gt 0 ] && [ -f "$dev_env" ] && [ -w "$dev_env" ]; then
    tmp_dev="$(mktemp)"
    awk -F'\t' '
        NR == FNR { val[$1]=$2; keys[++n]=$1; next }
        {
            replaced=0
            for (i=1;i<=n;i++) {
                if ($0 ~ "^" keys[i] "=") {
                    if (!(keys[i] in printed)) {
                        print keys[i] "=" val[keys[i]]
                        printed[keys[i]]=1
                    }
                    replaced=1
                }
            }
            if (!replaced) print
            next
        }
        END { for (i=1;i<=n;i++) if (!(keys[i] in printed)) print keys[i] "=" val[keys[i]] }
    ' "$dev_updates" "$dev_env" > "$tmp_dev"
    if ! cmp -s "$tmp_dev" "$dev_env"; then
        mv "$tmp_dev" "$dev_env"
        echo "[sync-env] updated .devcontainer/devcontainer.env"
    else
        rm -f "$tmp_dev"
    fi
fi
rm -f "$dev_updates"
