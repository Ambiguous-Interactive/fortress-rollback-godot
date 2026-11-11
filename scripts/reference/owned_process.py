"""Bounded subprocess execution that keeps the whole descendant tree owned.

A deadline that kills only the direct child leaves its living descendants
running: a Playwright browser or engine process outlives the failed witness,
is adopted by init and competes for the responsive host the next run needs.
Every owned command carries a unique run token in its environment and launches
in its own session. The token, not the process group, is the ownership
boundary: a descendant that escapes the group through setsid still carries the
inherited token, so the after-run sweep names it, kills it and records its
terminal identity instead of reporting success over an escaped process.
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
# After the direct child exits, an escaped descendant can hold the output pipes
# open forever. Draining stops at this idle grace instead of waiting for an EOF
# that would never come, so the child's own output is kept without turning a
# finished command into a deadline.
DRAIN_IDLE_SECONDS = 0.5
DRAIN_CHUNK = 65536


class EscapedDescendants(ValueError):
    """A command ended while descendants carrying its token were still alive."""

    def __init__(self, survivors):
        named = ', '.join(f"pid {item['pid']} ({item['name']})" for item in survivors)
        super().__init__(f'owned descendant survived the command: {named}')
        self.survivors = survivors


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
        try:
            command = (entry / 'cmdline').read_bytes().split(b'\0')
        except OSError:
            command = []
        name = command[0].decode('utf-8', errors='replace') if command and command[0] else ''
        found.append({'pid': int(entry.name), 'name': name[:MAX_IDENTITY_LENGTH]})
    return sorted(found, key=lambda item: item['pid'])


def terminate(token_value):
    """Kill every live token carrier and return their terminal identities."""
    survivors = identities(token_value)
    for item in survivors:
        try:
            os.kill(item['pid'], signal.SIGKILL)
        except OSError:
            pass
    return survivors


def _drain(process, deadline):
    """Read both pipes until EOF, the overall deadline or a post-exit idle grace.

    The wait ends early once the direct child has exited and the pipes stayed
    idle for the grace window, because only an escaped descendant could still
    hold them open; its lingering bytes are not this command's output.
    """
    streams = {process.stdout.fileno(): bytearray(), process.stderr.fileno(): bytearray()}
    buffers = {descriptor: bytearray() for descriptor in streams}
    idle_deadline = None
    while streams:
        now = time.monotonic()
        if now >= deadline:
            break
        if process.poll() is not None:
            idle_deadline = now + DRAIN_IDLE_SECONDS if idle_deadline is None else idle_deadline
            if now >= idle_deadline:
                break
        readable, _, _ = select.select(list(streams), [], [], min(deadline - now, 0.1))
        if not readable:
            continue
        for descriptor in readable:
            chunk = os.read(descriptor, DRAIN_CHUNK)
            if chunk:
                buffers[descriptor] += chunk
                if process.poll() is not None:
                    idle_deadline = time.monotonic() + DRAIN_IDLE_SECONDS
            else:
                streams.pop(descriptor)
    stdout = buffers[process.stdout.fileno()].decode('utf-8', errors='replace')
    stderr = buffers[process.stderr.fileno()].decode('utf-8', errors='replace')
    return stdout + stderr


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
    if not hasattr(os, 'killpg'):  # Non-POSIX development hosts keep the old contract.
        completed = subprocess.run(command, cwd=cwd, env=owned, capture_output=True, text=True, timeout=timeout)
        return completed.returncode, completed.stdout + completed.stderr
    process = subprocess.Popen(command, cwd=cwd, env=owned, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        deadline = time.monotonic() + timeout
        try:
            process.wait(timeout=timeout)
            output = _drain(process, deadline)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            survivors = terminate(token_value)
            process.poll()
            text = _drain(process, time.monotonic() + 10) + '\n'
            log.write_text(text + f'TIMEOUT: command exceeded {timeout} seconds\n'
                           + f'OWNED_PROCESSES: terminated {survivors}\n')
            raise subprocess.TimeoutExpired(command, timeout, output=text) from None
        survivors = terminate(token_value)
        if survivors:
            log.write_text(output + f'OWNED_PROCESSES: terminated {survivors}\n')
            raise EscapedDescendants(survivors)
        return process.returncode, output
    finally:
        for stream in (process.stdout, process.stderr):
            if stream is not None:
                stream.close()
