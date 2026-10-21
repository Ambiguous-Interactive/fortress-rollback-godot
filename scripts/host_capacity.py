"""Explicit ownership of the development host's CPU capacity.

The local Godot test runner starts one process per suite. Its default worker
count is the number of CPUs, so on a sixteen core host `make test-godot`
saturates the machine. A browser witness that runs at the same time then
loses the CPU it needs to deliver a packet inside the two second production
deadline, and its session ends with `PROTOCOL_FAILED`. The failure looks like
a transport fault, but a scheduling pause causes it.

A probe that needs a responsive host takes a lease before it starts. The
runner reads the lease before it starts its parallel wave and runs that wave
serially while the lease is held. Nothing changes on a CI runner: every job
has its own machine and no lease file, so the runner keeps its full
parallelism.

The lease lives under the machine-local cache, never in a tracked path.
"""

import json
import os
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LEASE_DIR = ROOT / ".cache" / "host-capacity"
# A lease without a live owner expires, so a killed probe never blocks the host.
DEFAULT_TTL_SECONDS = 3600.0


def lease_path(name: str) -> Path:
    """The file that records the lease of one named owner in this process."""
    return LEASE_DIR / f"{name}.{os.getpid()}.lease"


def acquire(name: str, ttl_seconds: float = DEFAULT_TTL_SECONDS) -> Path:
    """Take the lease for one named owner and return its file."""
    LEASE_DIR.mkdir(parents=True, exist_ok=True)
    path = lease_path(name)
    payload = {
        "name": name,
        "pid": os.getpid(),
        "expires_at": time.time() + max(0.0, float(ttl_seconds)),
    }
    path.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")
    return path


def release(name: str) -> None:
    """Give the lease of one named owner in this process back."""
    path = lease_path(name)
    if path.exists():
        path.unlink()


def holder() -> str | None:
    """The name of the live lease holder, or None when the host is free.

    A lease whose owner is gone, or whose lifetime ended, does not hold the
    host. An unreadable lease file is ignored for the same reason.
    """
    if not LEASE_DIR.is_dir():
        return None
    for path in sorted(LEASE_DIR.glob("*.lease")):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
            expires_at = float(payload["expires_at"])
            pid = int(payload["pid"])
        except (OSError, ValueError, KeyError, TypeError):
            continue
        if expires_at <= time.time() or not _alive(pid):
            continue
        name = payload.get("name")
        if isinstance(name, str) and name:
            return name
    return None


def wait_for_free(timeout_seconds: float) -> bool:
    """Wait until no owner holds the host. False when the wait ran out."""
    deadline = time.monotonic() + max(0.0, float(timeout_seconds))
    while True:
        if holder() is None:
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.5)


def _alive(pid: int) -> bool:
    """True when the process of a lease owner still runs."""
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def worker_count(requested: int) -> int:
    """The worker count the runner may use for its next parallel wave.

    A live lease means a witness is running on this host, so the wave runs
    serially. The requested count is otherwise unchanged.
    """
    if requested < 1:
        raise ValueError("requested worker count must be positive")
    return 1 if holder() else requested
