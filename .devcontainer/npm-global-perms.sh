#!/usr/bin/env bash
# Grant the container user write access to npm's global install directories.
#
# Why this exists: the image installs every agentic CLI from npm's global prefix
# as root at build time, which leaves <prefix>/lib/node_modules and <prefix>/bin
# owned by root:root 0755. The container then runs as `vscode` (remoteUser), and
# on Unix replacing or removing a file requires write permission on its *parent*
# directory, not on the file. So `npm install -g`, `npm update -g` and
# `npm uninstall -g` all fail with EACCES -- install fails on mkdir, and updating
# or removing an existing package fails on rename -- while read-only npm
# commands (`npm ls -g`, `npm view`) keep working and hide the problem.
#
# Why fix it this way: it keeps the single global root, so `npm root -g`, PATH
# and every existing binary stay exactly where they are. No second user-level
# prefix, no PATH shadowing, no duplicated packages, and no change to
# verify.sh's package-layout checks. Ownership stays with root; only group write
# is added, for the container user's own primary group, plus setgid so entries
# created later inherit that group. This grants no new privilege: `vscode`
# already has passwordless sudo in this image.
#
# Runs as root (the Dockerfile invokes it that way). Idempotent and fail-closed:
# it refuses to touch anything it does not recognise.
#
# Usage: sudo .devcontainer/npm-global-perms.sh [user]
set -euo pipefail

TARGET_USER="${1:-${NPM_GLOBAL_USER:-vscode}}"

if [ "$(id -u)" -ne 0 ]; then
    echo "npm-global-perms: must run as root; re-run with sudo" >&2
    exit 1
fi

if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
    echo "npm-global-perms: unknown user '$TARGET_USER'" >&2
    exit 1
fi

# Derive the targets from npm's own view of the prefix (which defaults to the
# Node install location) instead of hardcoding /usr/local, so a future prefix
# change does not silently leave this script fixing the wrong directories.
PREFIX="$(npm prefix -g)"
GLOBAL_ROOT="${PREFIX}/lib/node_modules"
BIN_DIR="${PREFIX}/bin"
GROUP="$(id -gn "$TARGET_USER")"

# Group write only helps a user who is a member of that group. Targeting a
# privileged account resolves to group root, which leaves every other user
# unable to write while the runuser verification below still passes (root can
# always write) and the script reports success. Refuse instead of reporting a
# state that is broken for the user this image actually runs as.
if [ "$GROUP" = "root" ]; then
    echo "npm-global-perms: refusing to grant group write to group root via '$TARGET_USER'; pass the unprivileged container user" >&2
    exit 1
fi

# Fail closed. A mis-resolved prefix must not turn this into a recursive chmod
# of an unrelated system tree.
for dir in "$GLOBAL_ROOT" "$BIN_DIR"; do
    if [ ! -d "$dir" ]; then
        echo "npm-global-perms: '$dir' is not a directory; refusing to modify" >&2
        exit 1
    fi
    if [ "$(stat -c '%u' "$dir")" != "0" ]; then
        echo "npm-global-perms: '$dir' is not root-owned; refusing to modify" >&2
        exit 1
    fi
done

# The global root needs recursive group write: npm extracts package trees and
# must empty nested node_modules directories to replace or remove a package.
# g+rwX keeps traversal intact, so a restrictive entry cannot end up
# group-writable but untraversable.
chgrp -R "$GROUP" "$GLOBAL_ROOT"
chmod -R g+rwX "$GLOBAL_ROOT"

# The bin directory needs group write on the DIRECTORY only. npm creates and
# unlinks symlinks there and never writes through them, so granting write on
# the entries would only widen access to unrelated binaries -- including the
# pinned Godot engine and a script the README runs under sudo.
chgrp "$GROUP" "$BIN_DIR"
chmod g+w "$BIN_DIR"

# setgid keeps the group sticky for directories created later, so anything a
# root-side npm install adds still lands in this group. It does NOT propagate
# the write bit: root creates directories with its own umask, so such a package
# comes out group-readable but not group-writable (2755) and its nested
# directories cannot be emptied by the user. Re-run this script after any
# root-side global install to reapply the write bit.
chmod g+s "$BIN_DIR"
# xargs rather than `find -exec ... +`: in batch mode find discards
# per-invocation exit codes, so a partial setgid failure looks successful.
find "$GLOBAL_ROOT" -type d -print0 | xargs -0 -r chmod g+s

# Verify as the target user. Root can always write, so a check performed as
# root would pass whether or not this script did anything. The root-group guard
# above is what keeps this check meaningful.
for dir in "$GLOBAL_ROOT" "$BIN_DIR"; do
    if ! runuser -u "$TARGET_USER" -- test -w "$dir"; then
        echo "npm-global-perms: verification failed, $TARGET_USER cannot write $dir" >&2
        exit 1
    fi
done

# The checks above cannot see two real failure modes. `test -w` passes on a
# directory that is group-writable but untraversable, and a setgid pass that
# fails partway through the tree looks successful. Assert both invariants over
# every directory rather than trusting them.
missing="$(runuser -u "$TARGET_USER" -- find "$GLOBAL_ROOT" "$BIN_DIR" -type d \( ! -writable -o ! -perm -2000 \) -print -quit 2>/dev/null || true)"
if [ -n "$missing" ]; then
    echo "npm-global-perms: post-condition failed, $missing is not group-writable and setgid for $TARGET_USER" >&2
    exit 1
fi

echo "npm-global-perms: $TARGET_USER (group $GROUP) can write $GLOBAL_ROOT and $BIN_DIR"
echo "npm-global-perms: global npm installs, updates and uninstalls now work without sudo"
