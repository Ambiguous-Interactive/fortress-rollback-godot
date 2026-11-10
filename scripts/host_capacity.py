"""Explicit ownership of the development host's CPU capacity.

The local Godot test runner starts one process per suite. Its default worker
count is the number of CPUs, so on a sixteen core host `make test-godot`
saturates the machine. A browser witness that runs at the same time then
loses the CPU it needs to deliver a packet inside the two second production
deadline, and its session ends with `PROTOCOL_FAILED`. The failure looks like
a transport fault, but a scheduling pause causes it.

A probe that needs a responsive host takes the host before it starts. The
runner waits within a bounded budget before starting its engine children, then
keeps its requested parallel capacity while it owns the host. A witness that
starts later waits for it instead of competing for it.

An overlapping probe wave takes the host once for all its members. The wave
owner runs its probe children with `FORTRESS_HOST_LEASE_HELD` naming the wave
owner's lease identity — the lease name and the wave owner's pid — so each
member acquires at once without contending with its own wave and never
releases the host while a sibling still runs; the wave owner releases when the
last probe joins. The inheritance holds only while that exact owner still
holds the host: if the wave owner died, the lease died with it and the member
takes the host itself, and a member left over from an earlier wave cannot
falsely inherit just because a later wave reused the lease name.

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
# Names the wave owner's lease identity — "name:pid" — for the children of
# one probe wave. While that named owner still holds the host, a member
# inherits the lease instead of contending with its own wave or releasing it
# while a sibling still runs. The pid makes the inheritance ownership-scoped,
# not name-scoped: a grandchild that outlives its wave cannot inherit again
# from a later wave that reused the lease name, because the live record names
# a different pid. A stray value naming no live owner changes nothing: the
# process takes the host itself, so the flag can never silently disable
# contention protection.
WAVE_HELD_ENV = "FORTRESS_HOST_LEASE_HELD"
# The owner of this process, its lock handle and its name.
_state = {"handle": None, "name": None}


def wave_owner_value(name: str) -> str:
    """The lease identity a wave owner publishes to its probe children.

    The owner calls this while it holds the host, so the pid matches the lock
    record it wrote and its members can require that exact owner.
    """
    return f"{name}:{os.getpid()}"


def _wave_owner() -> tuple[str, int] | None:
    """The (name, pid) the environment names, or None for a stray value.

    The parse cannot raise: a tail that is not an integer, in whatever
    spelling `int()` accepts, leaves the value a stray that changes nothing.
    """
    value = os.environ.get(WAVE_HELD_ENV)
    if not value:
        return None
    name, _, pid = value.rpartition(":")
    if not name:
        return None
    try:
        return name, int(pid)
    except ValueError:
        return None


def _holder_record() -> tuple[str, int | None] | None:
    """Who holds the host: (name, pid), or None when it is free.

    A record without a usable pid keeps its name with a None pid, and an
    unreadable record reports the name "unknown"; holder() depends on both.
    """
    if _state["handle"] is not None:
        return _state["name"], os.getpid()
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
            record = json.loads(handle.read())
            name = record.get("name")
            pid = record.get("pid")
        except (OSError, ValueError, AttributeError):
            name, pid = None, None
        handle.close()
        if isinstance(name, str) and name:
            if isinstance(pid, int) and not isinstance(pid, bool):
                return name, pid
            return name, None
        return "unknown", None
    fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    handle.close()
    return None


def _ours() -> bool:
    """True when this process holds the host."""
    if _state["handle"] is not None:
        return True
    wave = _wave_owner()
    if wave is None:
        return False
    record = _holder_record()
    if record is None:
        return False
    name, pid = record
    return name == wave[0] and pid == wave[1]


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
    record = _holder_record()
    if record is None:
        return None
    return record[0]


def wait_for_free(timeout_seconds: float) -> bool:
    """Wait until no other owner holds the host. False when the wait ran out.

    A process does not conflict with itself, so a probe that already holds the
    host does not wait for it.
    """
    deadline = time.monotonic() + max(0.0, float(timeout_seconds))
    if _ours() or holder() is None:
        return True
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        time.sleep(min(0.5, remaining))
        if time.monotonic() >= deadline:
            return False
        if _ours() or holder() is None:
            return True


def acquire_when_free(name: str, timeout_seconds: float) -> bool:
    """Wait for the host and take it. False when the wait ran out."""
    deadline = time.monotonic() + max(0.0, float(timeout_seconds))
    if acquire(name):
        return True
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        time.sleep(min(0.5, remaining))
        if time.monotonic() >= deadline:
            return False
        if acquire(name):
            return True


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
