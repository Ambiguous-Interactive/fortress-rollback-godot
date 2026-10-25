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

The lock lives on the local machine outside every checkout and scratch tree.
"""

import errno
import fcntl
import json
import os
import stat
import time
from pathlib import Path
from typing import TextIO


def _lease_directory() -> Path:
    configured = os.environ.get("FORTRESS_HOST_CAPACITY_DIR")
    if configured is None:
        return Path("/tmp") / f"fortress-rollback-host-capacity-{os.getuid()}"
    if not configured.strip() or not Path(configured).is_absolute():
        raise ValueError("FORTRESS_HOST_CAPACITY_DIR must be a nonempty absolute directory")
    return Path(configured).resolve()


LEASE_DIR = _lease_directory()
LEASE_FILE = LEASE_DIR / "host.lock"
# The owner of this process, its lock handle and its name.
_state = {"handle": None, "name": None}


def _ours() -> bool:
    """True when this process holds the host."""
    return _state["handle"] is not None


def _open_lock(create: bool) -> TextIO:
    if create:
        LEASE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory = os.open(LEASE_DIR, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(directory)
        if metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) & 0o022:
            raise PermissionError("host capacity directory must be owned by this user and deny group/world writes")
        flags = os.O_RDWR | os.O_CREAT if create else os.O_RDONLY
        descriptor = os.open(LEASE_FILE.name, flags | os.O_NOFOLLOW, 0o600, dir_fd=directory)
    finally:
        os.close(directory)
    return os.fdopen(descriptor, "r+" if create else "r", encoding="utf-8")


def acquire(name: str) -> bool:
    """Take the host for one named owner. False when another owner holds it.

    A process that already holds the host keeps it, so one probe can run its
    next stage without taking the host twice.
    """
    if _ours():
        return True
    handle = _open_lock(True)
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        handle.close()
        if error.errno not in (errno.EACCES, errno.EAGAIN):
            raise
        return False
    try:
        handle.seek(0)
        handle.truncate()
        handle.write(json.dumps({"name": name, "pid": os.getpid()}, sort_keys=True))
        handle.flush()
    except Exception:
        handle.close()
        raise
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
    try:
        handle = _open_lock(False)
    except FileNotFoundError:
        return None
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        if error.errno not in (errno.EACCES, errno.EAGAIN):
            handle.close()
            raise
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


def protects_path(path: Path) -> bool:
    """Keep the lock inode and its ancestors, even while the host is idle."""
    candidate = path.resolve()
    directory = LEASE_DIR.resolve()
    return candidate == directory or candidate in directory.parents or candidate == LEASE_FILE.resolve()
