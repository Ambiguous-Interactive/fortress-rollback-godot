#!/usr/bin/env python3
"""Prune machine-local caches and agent scratch so sessions cannot fill the disk.

Agent sessions leave three kinds of machine-local growth behind: the
repository's gitignored `.cache/` tree, scratch directories under the
container's `/tmp`, and container-layer package caches. None of it is
evidence, all of it survives across sessions, and an unattended agent can
therefore fill the disk (measured: 634 GB of stale `/tmp` scratch beside a
36 GB `.cache/` tree in one devcontainer).

This tool removes only what is provably disposable:

* a path named by a tracked file -- or by a machine-local `progress/` note --
  is evidence and is never removed, whatever its age;
* the pinned reference toolchain under `.cache/reference/` is never removed;
  only its `results/` run outputs are prunable;
* an archive whose extracted sibling exists is a redundant duplicate;
* everything else is removed once it is older than the retention age.

Dry run is the default: `--apply` is required to delete anything.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / '.cache'

# The only reference subtree that holds run output rather than pinned
# toolchain, sources, or artifacts. Everything else under `.cache/reference/`
# is required to reproduce the baseline and is never pruned.
PRUNABLE_REFERENCE = ('results',)

# Machine-local notes that are never committed but still name real evidence.
LOCAL_NOTE_DIRS = ('progress',)

# Container paths that hold live runtime state. Pruning them breaks the
# running session, so they are never touched.
SCRATCH_NEVER_TOUCH = (
    'arg0-linux',
    'codex-daemon-1000',
    'codex-bwrap-synthetic-mount-targets-1000',
    'build-features-src',
    'cc-socks',
    'claude-1000',
    '.X11-unix',
    'xvfb-run.*',
    '.*.so',
    '.*.node',
)

# A citation is any `.cache/...` path spelled out in a tracked file. The
# comma is part of the class so a brace alternative such as
# `results/pair-{4.3,4.7.2}/out.json` is captured whole.
CITATION = re.compile(r'\.cache/[A-Za-z0-9_./{},*\-]*')
BRACE = re.compile(r'\{([^}]*)\}')


class Plan:
    """One removal the tool intends to make."""

    def __init__(self, path: Path, scope: str, reason: str, bytes_: int = 0) -> None:
        self.path = path
        self.scope = scope
        self.reason = reason
        self.bytes = bytes_

    def as_dict(self) -> dict:
        return {'path': str(self.path), 'scope': self.scope, 'reason': self.reason, 'bytes': self.bytes}


def tree_bytes(path: Path) -> int:
    """Size of a file, or of every file under a directory, in bytes."""
    if path.is_symlink() or path.is_file():
        try:
            return path.lstat().st_size
        except OSError:
            return 0
    total = 0
    for root, _, files in os.walk(path):
        for name in files:
            try:
                total += os.lstat(os.path.join(root, name)).st_size
            except OSError:
                continue
    return total


def measure(paths: list[Path]) -> dict[Path, int]:
    """Size of every path in bytes, measured in one pass.

    Nested paths are collapsed to the outermost one so a parent and its
    child are never counted twice.
    """
    tops: list[Path] = []
    for path in sorted(paths, key=lambda item: len(item.parts)):
        if any(path == top or path.is_relative_to(top) for top in tops):
            continue
        tops.append(path)
    sizes: dict[Path, int] = {}
    if not tops:
        return sizes
    payload = ''.join(f'{path}\0' for path in tops)
    try:
        result = subprocess.run(['du', '-sb', '--files0-from=-'], input=payload,
                                capture_output=True, text=True)
    except OSError:
        for path in tops:
            sizes[path] = tree_bytes(path)
        return sizes
    for line in result.stdout.splitlines():
        size, _, name = line.partition('\t')
        if not size.isdigit():
            continue
        sizes[Path(name)] = int(size)
    for path in tops:
        sizes.setdefault(path, tree_bytes(path))
    return sizes


def tracked_files(root: Path) -> list[Path]:
    """Tracked files plus machine-local notes; both can cite evidence."""
    files: list[Path] = []
    try:
        listing = subprocess.run(['git', '-C', str(root), 'ls-files', '-z'],
                                 capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        listing = ''
    for name in listing.split('\0'):
        if name:
            files.append(root / name)
    if not files:
        # Not a checkout (or a fixture): fall back to the working tree so
        # evidence is still protected.
        for base, dirs, names in os.walk(root):
            dirs[:] = [name for name in dirs if name not in ('.git', '.cache', 'node_modules', '__pycache__')]
            for name in names:
                files.append(Path(base) / name)
    for directory in LOCAL_NOTE_DIRS:
        notes = root / directory
        if notes.is_dir():
            files.extend(sorted(notes.rglob('*')))
    # Ignore rules describe what to exclude, not evidence. A pattern such as
    # `/.cache/session-*/` would otherwise protect every session directory.
    return [path for path in files if path.name != '.gitignore']


def cited_paths(root: Path) -> set[Path]:
    """Absolute paths named by a tracked file or a machine-local note.

    Brace alternatives and glob wildcards are expanded so a citation like
    `results/session037-replay-{4.3,4.7.2}/replay.json` protects the real
    artifacts it names.
    """
    found: set[Path] = set()
    for path in tracked_files(root):
        try:
            text = path.read_text(encoding='utf-8', errors='ignore')
        except OSError:
            continue
        for match in CITATION.findall(text):
            cleaned = match.rstrip('.,;:)')
            alternatives = [cleaned]
            brace = BRACE.search(cleaned)
            if brace:
                alternatives = [BRACE.sub(option, cleaned) for option in brace.group(1).split(',')]
            for alternative in alternatives:
                absolute = root / alternative
                if '*' in alternative:
                    parent = absolute.parent
                    if not parent.is_dir():
                        continue
                    pattern = absolute.name
                    for child in parent.iterdir():
                        if fnmatch.fnmatch(child.name, pattern):
                            found.add(child)
                else:
                    found.add(absolute)
    return found


def protection_set(cited: set[Path]) -> set[Path]:
    """Expand citations into the set of paths they protect.

    A citation protects the path it names and every path above it: a
    receipt named at `.cache/reference/results/run/receipt.json` keeps
    `run/` and `results/` alive, because removing either would take the
    receipt with it. A cited path does *not* protect its children, so a
    generic citation of `.cache/reference/results` leaves the uncited
    artifacts written there prunable.

    Expanding once turns the check into a set lookup. Comparing every
    candidate against every citation instead cost 96 of the 99 seconds
    the first full report took, because the cache holds hundreds of
    thousands of paths.
    """
    protected: set[Path] = set()
    for reference in cited:
        protected.add(reference)
        protected.update(reference.parents)
    return protected


def is_protected(candidate: Path, protected: set[Path]) -> bool:
    """True when a citation names the candidate or something inside it."""
    return candidate in protected


def age_days(path: Path) -> float:
    try:
        return (time.time() - path.lstat().st_mtime) / 86400.0
    except OSError:
        return 0.0


def plan_workspace(root: Path, ttl_days: float, protected: set[Path]) -> list[Plan]:
    """Prunable entries under the repository's gitignored `.cache/` tree."""
    plans: list[Plan] = []
    cache = root / '.cache'
    if not cache.is_dir():
        return plans

    for name in sorted(os.listdir(cache)):
        path = cache / name
        if name.startswith('session-'):
            plans.extend(plan_session(path, ttl_days, protected))
        elif name == 'tests':
            plans.extend(plan_entries(path, ttl_days, protected, 'workspace', 'test output'))
        elif name == 'reference':
            for sub in sorted(os.listdir(path)):
                if sub in PRUNABLE_REFERENCE:
                    plans.extend(plan_entries(path / sub, ttl_days, protected, 'workspace', 'run output'))

    plans.extend(redundant_archives(cache, protected))
    return plans


def plan_session(path: Path, ttl_days: float, protected: set[Path]) -> list[Plan]:
    """A session scratch directory.

    An uncited session directory is disposable as a whole. A session
    directory that a note still points into is kept, but its uncited
    children -- the bulky build trees -- are not.
    """
    if not is_protected(path, protected):
        if age_days(path) < ttl_days:
            return []
        return [Plan(path, 'workspace', f'session scratch older than {ttl_days:g} days')]
    if path.is_dir() and not path.is_symlink():
        return plan_entries(path, ttl_days, protected, 'workspace', 'session scratch')
    return []


def plan_entries(directory: Path, ttl_days: float, protected: set[Path], scope: str, label: str) -> list[Plan]:
    """Entries inside a directory that are neither cited nor recent.

    A protected directory is kept, but the pruner still looks inside it for
    uncited children: a directory that holds one cited receipt must not
    shelter an uncited archive beside it.
    """
    plans: list[Plan] = []
    if not directory.is_dir():
        return plans
    for name in sorted(os.listdir(directory)):
        path = directory / name
        if is_protected(path, protected):
            if path.is_dir() and not path.is_symlink():
                plans.extend(plan_entries(path, ttl_days, protected, scope, label))
            continue
        if age_days(path) < ttl_days:
            continue
        plans.append(Plan(path, scope, f'uncited {label} older than {ttl_days:g} days'))
    return plans


def redundant_archives(cache: Path, protected: set[Path]) -> list[Plan]:
    """Archives whose extracted sibling already exists.

    CI uploads keep both the archive and its extraction; the archive is the
    larger copy and adds nothing once the extraction is present. Age does
    not matter here -- the duplicate is redundant now, not later.
    """
    plans: list[Plan] = []
    for base in (cache / 'tests', cache / 'reference' / 'results'):
        if not base.is_dir():
            continue
        for root, dirs, files in os.walk(base):
            dirs[:] = [name for name in dirs if name != 'target']
            for name in files:
                if not name.endswith('.zip'):
                    continue
                archive = Path(root) / name
                sibling = archive.with_suffix('')
                if not sibling.is_dir() or is_protected(archive, protected):
                    continue
                plans.append(Plan(archive, 'workspace', 'redundant archive; extracted sibling present'))
    return plans


def in_use(path: Path) -> bool:
    """True when a running process holds the path as its cwd or open file.

    Another user's process may make its descriptor directory unreadable, so
    every read is best-effort: an unreadable handle is never proof of use.
    """
    target = str(path)
    try:
        entries = list(Path('/proc').iterdir())
    except OSError:
        return False
    for entry in entries:
        if not entry.name.isdigit():
            continue
        for link in (entry / 'cwd', entry / 'exe', entry / 'root'):
            try:
                if os.readlink(link) == target:
                    return True
            except OSError:
                continue
        try:
            handles = list((entry / 'fd').iterdir())
        except OSError:
            continue
        for handle in handles:
            try:
                if os.readlink(handle).startswith(target + '/'):
                    return True
            except OSError:
                continue
    return False


def plan_scratch(root: Path, ttl_hours: float) -> list[Plan]:
    """Stale top-level entries under a scratch root such as `/tmp`."""
    plans: list[Plan] = []
    if not root.is_dir():
        return plans
    for name in sorted(os.listdir(root)):
        if any(fnmatch.fnmatch(name, pattern) for pattern in SCRATCH_NEVER_TOUCH):
            continue
        path = root / name
        try:
            age_hours = (time.time() - path.lstat().st_mtime) / 3600.0
        except OSError:
            continue
        if age_hours < ttl_hours:
            continue
        if in_use(path):
            continue
        plans.append(Plan(path, 'scratch', f'scratch older than {ttl_hours:g} hours'))
    return plans


def plan_container(home: Path) -> list[Plan]:
    """Container-layer caches that no running tool needs."""
    plans: list[Plan] = []
    npm = home / '.npm' / '_cacache'
    if npm.is_dir():
        plans.append(Plan(npm, 'container', 'npm content cache; reinstallable'))
    releases = home / '.codex' / 'packages' / 'app-server-daemon' / 'releases'
    if releases.is_dir():
        entries = sorted(child for child in releases.iterdir() if child.is_dir())
        for stale in entries[:-1]:
            plans.append(Plan(stale, 'container', 'superseded app-server release'))
    toolchains = home / '.rustup' / 'toolchains'
    if toolchains.is_dir():
        for toolchain in sorted(toolchains.iterdir()):
            docs = toolchain / 'share' / 'doc'
            if docs.is_dir():
                plans.append(Plan(docs, 'container', 'rust-docs; the harness uses .cache/reference/rustup'))
    return plans


def apply_plans(plans: list[Plan]) -> int:
    """Delete every planned path, deepest first; report what stayed."""
    skipped = 0
    for plan in sorted(plans, key=lambda item: len(item.path.parts), reverse=True):
        try:
            if plan.path.is_dir() and not plan.path.is_symlink():
                shutil.rmtree(plan.path)
            else:
                plan.path.unlink()
        except OSError:
            # Another user's files, a live handle, or a read-only mount.
            # Leaving the entry in place is always safe.
            skipped += 1
    return skipped


def report(plans: list[Plan], applied: bool) -> dict:
    total = sum(plan.bytes for plan in plans)
    summary: dict = {'count': len(plans), 'bytes': total, 'applied': applied, 'entries': []}
    for plan in sorted(plans, key=lambda item: -item.bytes):
        summary['entries'].append(plan.as_dict())
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--scope', action='append', default=[], choices=['workspace', 'scratch', 'container'],
                        help='what to prune; repeatable (default: all)')
    parser.add_argument('--root', type=Path, default=ROOT, help='repository root')
    parser.add_argument('--scratch-root', type=Path, default=Path('/tmp'), help='scratch directory to prune')
    parser.add_argument('--session-ttl-days', type=float, default=7.0, help='keep session scratch for this many days')
    parser.add_argument('--scratch-ttl-hours', type=float, default=24.0, help='keep scratch entries for this many hours')
    parser.add_argument('--apply', action='store_true', help='actually delete (default: dry run)')
    parser.add_argument('--json', action='store_true', help='emit a machine-readable report')
    args = parser.parse_args()

    scopes = tuple(args.scope) if args.scope else ('workspace', 'scratch', 'container')
    root = args.root.resolve()
    protected = protection_set(cited_paths(root))

    plans: list[Plan] = []
    if 'workspace' in scopes:
        plans.extend(plan_workspace(root, args.session_ttl_days, protected))
    if 'scratch' in scopes:
        plans.extend(plan_scratch(args.scratch_root.resolve(), args.scratch_ttl_hours))
    if 'container' in scopes:
        plans.extend(plan_container(Path.home()))

    unique: dict[Path, Plan] = {}
    for plan in plans:
        unique.setdefault(plan.path, plan)
    plans = list(unique.values())
    sizes = measure([plan.path for plan in plans])
    for plan in plans:
        plan.bytes = sizes.get(plan.path, 0)

    skipped = 0
    if args.apply:
        skipped = apply_plans(plans)

    summary = report(plans, args.apply)
    summary['skipped'] = skipped
    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        label = 'removed' if args.apply else 'would remove'
        print(f'{label} {summary["count"]} entries ({summary["bytes"] / (1 << 30):.2f} GB)')
        for entry in summary['entries'][:40]:
            print(f'  [{entry["scope"]}] {entry["bytes"] / (1 << 20):8.1f} MB  {entry["path"]}  -- {entry["reason"]}')
        if len(summary['entries']) > 40:
            print(f'  ... and {len(summary["entries"]) - 40} more')
        if skipped:
            print(f'  {skipped} entr{"y" if skipped == 1 else "ies"} could not be removed (permissions or a live handle)')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
