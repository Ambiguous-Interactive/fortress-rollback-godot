"""Bounded subprocess execution that keeps the whole descendant tree owned.

A deadline that kills only the direct child leaves its living descendants
running: a Playwright browser or engine process outlives the failed witness,
is adopted by init and competes for the responsive host the next run needs.
Every owned command carries a unique run token in its environment and launches
in its own session. After any exit, ownership is checked twice: the command's
process group must be gone, which catches a descendant that stayed in the
session and scrubbed its environment, and the /proc token sweep names any
surviving carrier so it can be killed and recorded. Kills are pinned through
pidfds where the kernel supports them, so a recycled pid never receives a
signal meant for an owned process. The known residual hole is stated plainly:
a descendant that both setsid's away and scrubs the token leaves no kernel
marker this module can see; containing that case needs cgroup-backed
ownership and remains open work in issue #290.
"""
import os
import select
import signal
import subprocess
import time
import uuid
from pathlib import Path

TOKEN_VARIABLE = 'FORTRESS_OWNED_RUN'
MAX_PROCESSES = 4096
MAX_IDENTITY_LENGTH = 160
MAX_NAMED_SURVIVORS = 8
# After the direct child exits, an escaped descendant can hold the output
# pipes open forever. Draining stops at this idle grace instead of waiting
# for an EOF that would never come; bytes that arrive after the child's exit
# are withheld from the command's output, because only a descendant could
# have written them.
DRAIN_IDLE_SECONDS = 0.5
POLL_SECONDS = 0.1
DRAIN_CHUNK = 65536
# After exit, a dead child can leave at most one pipe capacity of unread data
# per stream. The settle pass is bounded in time and bytes so a same-group
# descendant that keeps writing can never turn the trusted snapshot into an
# unbounded hang; everything it cannot attribute is withheld later anyway.
SETTLE_SECONDS = 2.0
SETTLE_MAX_BYTES = 4 * DRAIN_CHUNK


class EscapedDescendants(ValueError):
    """A command ended while descendants carrying its ownership were still alive."""

    def __init__(self, survivors):
        super().__init__(f'owned descendant survived the command: {_named(survivors)}')
        self.survivors = survivors


def _named(survivors):
    shown = survivors[:MAX_NAMED_SURVIVORS]
    suffix = '' if len(survivors) <= MAX_NAMED_SURVIVORS else f' and {len(survivors) - MAX_NAMED_SURVIVORS} more'
    return ', '.join(f"pid {item['pid']} ({item['name']})" for item in shown) + suffix


def _name(entry):
    try:
        command = (entry / 'cmdline').read_bytes().split(b'\0')
    except OSError:
        command = []
    return command[0].decode('utf-8', errors='replace')[:MAX_IDENTITY_LENGTH] if command and command[0] else ''


def identities(token_value):
    """Name every live process carrying the run token, bounded and redacted."""
    marker = (TOKEN_VARIABLE + '=' + token_value).encode('utf-8') + b'\0'
    found = []
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        if len(found) > MAX_PROCESSES:
            raise ValueError('owned process scan exceeded its process bound')
        try:
            environment = (entry / 'environ').read_bytes()
        except OSError:
            continue
        if marker not in environment:
            continue
        found.append({'pid': int(entry.name), 'name': _name(entry)})
    return sorted(found, key=lambda item: item['pid'])


def group_members(group, proc=None):
    """Name the live members of one process group; zombies are already dead.

    A grandchild that exited before its parent is a zombie until init reaps
    it, and a zombie still holds its process group open. It cannot write,
    hold a pipe or come back, so it is skipped: naming it as a terminated
    survivor would record a dead process, and counting it would fail healthy
    runs whenever reap latency exceeds the drain grace.
    """
    found = []
    for entry in (proc or Path('/proc')).iterdir():
        if not entry.name.isdigit():
            continue
        try:
            fields = (entry / 'stat').read_text().rsplit(') ', 1)[-1].split()
        except OSError:
            continue
        if not fields or fields[0] in ('Z', 'X') or int(fields[2]) != group:
            continue
        found.append({'pid': int(entry.name), 'name': _name(entry)})
    return sorted(found, key=lambda item: item['pid'])


def _send_kill(pid):
    """SIGKILL one pinned pid; the pidfd keeps the signal off a recycled pid."""
    try:
        descriptor = os.pidfd_open(pid)
    except (AttributeError, OSError):
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        return
    try:
        signal.pidfd_send_signal(descriptor, signal.SIGKILL)
    except (AttributeError, OSError):
        pass
    finally:
        os.close(descriptor)


def terminate(token_value):
    """Kill every live token carrier and return their terminal identities."""
    survivors = identities(token_value)
    for item in survivors:
        _send_kill(item['pid'])
    return survivors


def terminate_group(group):
    """Kill every live member of one process group and return their identities."""
    members = group_members(group)
    for item in members:
        _send_kill(item['pid'])
    return members


class _Deadline(Exception):
    """The direct child was still running when its deadline passed.

    The buffers drained before the deadline travel with it, because that
    partial output is the command's real evidence and must reach its log.
    """

    def __init__(self, buffers, stdout):
        super().__init__()
        self.buffers = buffers
        self.stdout = stdout


def _read_available(streams, buffers):
    """One nonblocking pass: drain every descriptor select reports until EOF."""
    added = 0
    for descriptor in select.select(list(streams), [], [], 0)[0]:
        chunk = os.read(descriptor, DRAIN_CHUNK)
        if chunk:
            buffers[descriptor] += chunk
            added += len(chunk)
        else:
            streams.pop(descriptor)
    return added


def _collect(process, deadline):
    """Wait for the direct child while concurrently draining both pipes.

    Draining runs alongside the wait, so a command that writes more than the
    pipe capacity still finishes inside its deadline instead of blocking on a
    full pipe. Once the child has exited, one immediate read pass captures
    everything it had already written; later bytes can only come from an
    escaped descendant and are withheld from the returned output. Draining
    after exit stops at EOF or the idle grace, whichever comes first.
    """
    stdout = process.stdout.fileno()
    streams = {stdout: bytearray(), process.stderr.fileno(): bytearray()}
    buffers = {descriptor: bytearray() for descriptor in streams}
    exit_observed = False
    trusted = {}
    post_exit_bytes = 0
    group_alive = False
    exit_deadline = None
    while True:
        if not exit_observed and process.poll() is not None:
            exit_observed = True
            # The child's own writes are already in the kernel buffers; repeat
            # nonblocking passes until no more arrives, so its queued final
            # output stays trusted even when it exceeded one chunk. The pass is
            # bounded in time and bytes: a descendant that keeps writing after
            # the child exited must not turn the snapshot into a hang.
            settle_deadline = min(time.monotonic() + SETTLE_SECONDS, deadline)
            settle_budget = SETTLE_MAX_BYTES
            while streams and settle_budget > 0 and time.monotonic() < settle_deadline:
                added = _read_available(streams, buffers)
                settle_budget -= added
                if not added:
                    break
            trusted = {descriptor: len(buffers[descriptor]) for descriptor in buffers}
            exit_deadline = time.monotonic() + DRAIN_IDLE_SECONDS
            group_alive = bool(group_members(process.pid))
        if exit_observed:
            if not streams or time.monotonic() >= exit_deadline:
                break
            if not _wait_readable(streams, min(exit_deadline - time.monotonic(), DRAIN_IDLE_SECONDS)):
                break
            post_exit_bytes += _read_available(streams, buffers)
            continue
        now = time.monotonic()
        if now >= deadline:
            raise _Deadline(buffers, stdout)
        if not _wait_readable(streams, min(deadline - now, POLL_SECONDS)):
            continue
        _read_available(streams, buffers)
    process.wait()
    text = bytes(buffers[stdout][:trusted[stdout]]).decode('utf-8', errors='replace')
    for descriptor, data in buffers.items():
        if descriptor != stdout:
            text += bytes(data[:trusted[descriptor]]).decode('utf-8', errors='replace')
    return process.returncode, text, post_exit_bytes, group_alive


def _wait_readable(streams, timeout):
    return bool(select.select(list(streams), [], [], timeout)[0])


def _drain_after_kill(process):
    """Collect whatever a killed command flushed, bounded by the idle grace."""
    streams = {process.stdout.fileno(): bytearray(), process.stderr.fileno(): bytearray()}
    buffers = {descriptor: bytearray() for descriptor in streams}
    while streams and _wait_readable(streams, DRAIN_IDLE_SECONDS):
        _read_available(streams, buffers)
    stdout = buffers.pop(process.stdout.fileno()).decode('utf-8', errors='replace')
    return stdout + ''.join(data.decode('utf-8', errors='replace') for data in buffers.values())


def run(command, environment, log, timeout, cwd=None):
    """Run one bounded command whose entire descendant tree stays owned.

    The launcher writes the started command, the owned identities it had to
    terminate and a TIMEOUT marker into the same log the caller already reads,
    so a rejected or escaped run keeps its diagnosis where the watchdog looks.
    The return value and the raised TimeoutExpired match the previous
    subprocess.run contract, including the partial output a deadline captured.
    """
    owned = dict(environment or os.environ)
    token_value = uuid.uuid4().hex
    owned[TOKEN_VARIABLE] = token_value
    if not (hasattr(os, 'killpg') and Path('/proc').is_dir()):
        completed = subprocess.run(command, cwd=cwd, env=owned, capture_output=True, text=True, timeout=timeout)
        return completed.returncode, completed.stdout + completed.stderr
    process = subprocess.Popen(command, cwd=cwd, env=owned, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        try:
            returncode, output, post_exit_bytes, group_alive = _collect(process, time.monotonic() + timeout)
        except _Deadline as expired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except OSError:
                pass  # The child exited in the deadline race; the sweeps below still run.
            survivors = terminate(token_value)
            process.poll()
            text = expired.buffers[expired.stdout].decode('utf-8', errors='replace')
            for descriptor, data in expired.buffers.items():
                if descriptor != expired.stdout:
                    text += data.decode('utf-8', errors='replace')
            text += _drain_after_kill(process) + '\n'
            log.write_text(text + f'TIMEOUT: command exceeded {timeout} seconds\n'
                           + f'OWNED_PROCESSES: terminated {survivors}\n')
            raise subprocess.TimeoutExpired(command, timeout, output=text) from None
        except BaseException:
            # An interruption must not strand the tree either: the new session
            # never saw the terminal signal, so both ownership checks run and
            # the child is reaped before the interrupt propagates.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except OSError:
                pass
            members = terminate_group(process.pid)
            survivors = terminate(token_value)
            process.poll()
            if members or survivors:
                log.write_text(f'OWNED_PROCESSES: terminated {members + survivors}\n')
            raise
        if post_exit_bytes:
            output += ('\nPOST_EXIT_OUTPUT: '
                       f'{post_exit_bytes} byte(s) arrived after the command exited and were withheld\n')
        # Both ownership checks always run before any escape raises: a command
        # can leave a same-group descendant and a setsid token carrier at once,
        # and reporting only the first would strand the second.
        members = terminate_group(process.pid) if group_alive else []
        survivors = terminate(token_value)
        if members or survivors:
            output += f'OWNED_PROCESSES: terminated {members + survivors}\n'
            log.write_text(output)
            raise EscapedDescendants(members + survivors)
        if post_exit_bytes:
            log.write_text(output)
        return returncode, output
    finally:
        for stream in (process.stdout, process.stderr):
            if stream is not None:
                stream.close()
