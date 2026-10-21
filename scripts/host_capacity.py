"""Explicit ownership of the development host's CPU capacity.

The local Godot test runner starts one process per suite. Its default worker
count is the number of CPUs, so on a sixteen core host `make test-godot`
saturates the machine. A browser witness that runs at the same time then
loses the CPU it needs to deliver a packet inside the two second production
deadline, and its session ends with `PROTOCOL_FAILED`. The failure looks like
a transport fault, but a scheduling pause causes it.

A probe that needs a responsive host takes the host before it starts. The
runner reads the owner before it starts its parallel wave and runs that wave
serially while another owner holds the host. The runner takes the host of its
own while its wave runs, so a witness that starts later waits for it instead
of competing for it.

The host is one exclusive file lock, so exactly one process owns it. The
operating system releases the lock when its owner ends, so a lease of a
process that is gone never holds the host and a stale file never blocks it.

The lock lives under the machine-local cache, never in a tracked path.
"""

import fcntl
import json
import os
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LEASE_DIR = ROOT / ".cache" / "host-capacity"
LEASE_FILE = LEASE_DIR / "host.lock"
# The owner of this process, its lock handle and its name.
_state = {"handle": None, "name": None}


def _ours() -> bool:
    """True when this process holds the host."""
    return _state["handle"] is not None


def acquire(name: str) -> bool:
    """Take the host for one named owner. False when another owner holds it.

    A process that already holds the host keeps it, so one probe can run its
    next stage without taking the host twice.
    """
    if _ours():
        return True
    LEASE_DIR.mkdir(parents=True, exist_ok=True)
    handle = open(LEASE_FILE, "a+", encoding="utf-8")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        return False
    handle.seek(0)
    handle.truncate()
    handle.write(json.dumps({"name": name, "pid": os.getpid()}, sort_keys=True))
    handle.flush()
    _state["handle"] = handle
    _state["name"] = name
    return True


def release() -> None:
    """Give the host back. The lock ends with this process either way."""
    handle = _state["handle"]
    if handle is None:
        return
    _state["handle"] = None
    _state["name"] = None
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    except OSError:
        pass
    handle.close()


def holder() -> str | None:
    """The name of the owner that holds the host, or None when it is free."""
    if _ours():
        return str(_state["name"])
    if not LEASE_FILE.exists():
        return None
    try:
        handle = open(LEASE_FILE, "r", encoding="utf-8")
    except OSError:
        return None
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        # Another owner holds the lock. Its record names the owner.
        try:
            handle.seek(0)
            name = json.loads(handle.read()).get("name")
        except (OSError, ValueError, AttributeError):
            name = None
        handle.close()
        return name if isinstance(name, str) and name else "unknown"
    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    handle.close()
    return None


def wait_for_free(timeout_seconds: float) -> bool:
    """Wait until no other owner holds the host. False when the wait ran out.

    A process does not conflict with itself, so a probe that already holds the
    host does not wait for it.
    """
    deadline = time.monotonic() + max(0.0, float(timeout_seconds))
    while True:
        if _ours() or holder() is None:
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.5)


def acquire_when_free(name: str, timeout_seconds: float) -> bool:
    """Wait for the host and take it. False when the wait ran out."""
    deadline = time.monotonic() + max(0.0, float(timeout_seconds))
    while True:
        if wait_for_free(0.0) and acquire(name):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.5)


def worker_count(requested: int) -> int:
    """The worker count the runner may use for its next parallel wave.

    Another owner holds the host, so the wave runs serially. The requested
    count is otherwise unchanged.
    """
    if requested < 1:
        raise ValueError("requested worker count must be positive")
    return requested if _ours() or holder() is None else 1
