#!/usr/bin/env python3
"""Give one local run at a time the right to use the shared reference cache.

Two local probes that share `.cache/reference/` damage each other. The
ownership probe rewrites `results/ownership.json` and deletes the
`ownership-*.log` files of a run that is still in flight, and both runs
write the same `ownership-projects/<label>` and `ownership-exports/<label>`
trees. Overlapping runs also starve each other, which is how a slow run
turned into a watchdog timeout.

This module makes that ownership explicit. A run claims the shared paths
it needs before it touches them, and releases the claim when it ends.
The claim names its holder, so a second run can say who owns the cache
instead of corrupting it.

Continuous integration never contends: every job has its own checkout
and its own cache directory, so the claim is always free there.
"""

from __future__ import annotations

import fcntl
import json
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LOCKS = ROOT / '.cache' / 'reference' / 'locks'


class Claim:
    """One held claim. Releasing it gives the shared paths back."""

    def __init__(self, resource: str, path: Path, handle) -> None:
        self.resource = resource
        self.path = path
        self.handle = handle

    def release(self) -> None:
        """Give the shared paths back."""
        if self.handle.closed:
            return
        try:
            self.path.write_text(json.dumps({'holder': None, 'released': True}) + '\n', encoding='utf-8')
            fcntl.flock(self.handle, fcntl.LOCK_UN)
        finally:
            self.handle.close()

    def __enter__(self) -> 'Claim':
        return self

    def __exit__(self, *_exception) -> None:
        self.release()


def holder(path: Path) -> dict:
    """Read the recorded holder of a lock file."""
    try:
        value = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def describe(path: Path) -> str:
    """A short description of who holds a lock file."""
    record = holder(path)
    if not record or record.get('released'):
        return 'the holder did not record itself'
    pid = record.get('pid', 'unknown')
    command = record.get('command', 'unknown command')
    return f'process {pid} running "{command}"'


def claim(resource: str, timeout: float = 0.0, directory=None) -> Claim:
    """Take the exclusive right to use a shared reference path.

    The claim is taken at once. When it is already held, the claim waits
    up to `timeout` seconds and then fails with a message that names the
    holder and the remedy.
    """
    locks = Path(directory) if directory is not None else LOCKS
    locks.mkdir(parents=True, exist_ok=True)
    path = locks / f'{resource}.lock'
    handle = path.open('a+')
    deadline = time.monotonic() + max(0.0, timeout)
    while True:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except OSError:
            if time.monotonic() >= deadline:
                handle.close()
                raise ValueError(
                    f'the {resource} reference cache is owned by another local run: '
                    f'{describe(path)}. Wait for it to finish, or stop it before running this probe again.'
                ) from None
            time.sleep(0.25)
    record = {'pid': os.getpid(), 'command': ' '.join(sys.argv), 'since': time.time(), 'released': False}
    handle.seek(0)
    handle.truncate()
    handle.write(json.dumps(record) + '\n')
    handle.flush()
    return Claim(resource, path, handle)
