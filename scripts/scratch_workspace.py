#!/usr/bin/env python3
"""Create scratch copies of the repository without dragging its caches along.

Copying the repository with a bare `shutil.copytree` also copies the
gitignored `.cache/` tree, which holds pinned toolchains, browser downloads
and Rust build outputs. In this repo that tree reached 36 GB, so a
mutation harness that copied the workspace nineteen times wrote 634 GB of
scratch to `/tmp` before anything was deleted.

Use this helper instead. It copies the tracked working tree and skips the
machine-local trees that are large, regenerable, or irrelevant to a run:

    python3 scripts/scratch_workspace.py create /tmp/run-01
    python3 scripts/scratch_workspace.py create --print-only run-01
    python3 scripts/scratch_workspace.py list
    python3 scripts/scratch_workspace.py remove run-01
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRATCH = ROOT / '.cache' / 'scratch'

# Machine-local trees that must never enter a scratch copy: they are large,
# regenerable, or irrelevant to an isolated run. Every entry is a basename,
# because `shutil.ignore_patterns` matches basenames at every level.
DEFAULT_EXCLUDES = (
    '.cache',      # pinned toolchain, build trees, run outputs
    '.git',        # history; use `git worktree` when history is needed
    '.godot',      # imported engine cache
    'worktrees',   # .claude/worktrees: another agent's whole working set
    'progress',    # machine-local session notes
    '__pycache__',
    'node_modules',
)


def excluded_names() -> set[str]:
    """Basenames a scratch copy skips."""
    return set(DEFAULT_EXCLUDES)


def copy_workspace(destination: Path, source: Path = ROOT, excludes: tuple[str, ...] = DEFAULT_EXCLUDES) -> Path:
    """Copy the working tree to `destination`, skipping the excluded paths."""
    destination = destination.resolve()
    source = source.resolve()
    tops = set(excludes)
    if destination == source:
        raise ValueError(f'scratch destination {destination} must differ from the repository at {source}')
    if destination.is_relative_to(source):
        # A destination inside the tree is only safe when it lives under a
        # path the copy skips; otherwise the copy would copy itself.
        relative = destination.relative_to(source)
        if not relative.parts or relative.parts[0] not in tops:
            raise ValueError(f'scratch destination {destination} must live under an excluded path of {source}')
    if destination.is_dir():
        shutil.rmtree(destination)
    shutil.copytree(source, destination, symlinks=True,
                    ignore=shutil.ignore_patterns(*tops, '*.pyc'))
    return destination


def create(prefix: str, source: Path = ROOT) -> Path:
    """Create a scratch copy and return its path."""
    SCRATCH.mkdir(parents=True, exist_ok=True)
    destination = SCRATCH / prefix
    return copy_workspace(destination, source)


def list_scratch() -> list[Path]:
    """Existing scratch copies, oldest first."""
    if not SCRATCH.is_dir():
        return []
    return sorted((child for child in SCRATCH.iterdir() if child.is_dir()),
                  key=lambda child: child.stat().st_mtime)


def remove(prefix: str) -> bool:
    """Delete one scratch copy; report whether it existed."""
    destination = SCRATCH / prefix
    if not destination.is_dir():
        return False
    shutil.rmtree(destination)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('action', choices=['create', 'list', 'remove'])
    parser.add_argument('name', nargs='?', help='scratch prefix')
    parser.add_argument('--source', type=Path, default=ROOT, help='repository root to copy')
    parser.add_argument('--print-only', action='store_true', help='print the path instead of copying')
    args = parser.parse_args()

    if args.action == 'list':
        for path in list_scratch():
            print(path)
        return 0
    if not args.name:
        parser.error(f'{args.action} needs a name')
    if args.action == 'remove':
        if not remove(args.name):
            print(f'no scratch copy named {args.name}', file=sys.stderr)
            return 1
        return 0
    if args.print_only:
        print(SCRATCH / args.name)
        return 0
    print(create(args.name, args.source))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
