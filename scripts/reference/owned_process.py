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

A caller that runs several owned commands concurrently — the browser witness
label waves, the native probe waves — can stop one running command from
outside its call through a CancelHandle: the handle pins the started process
group and token, and cancel() applies the same double-ownership sweep, the
pidfd-pinned kills and the once-only survivor naming the deadline and
interruption paths use. The owning call still reaps its own child and still
verifies the tree is gone; the handle only terminates it and keeps the
report, so a cancelled run raises Cancelled with the same evidence a timeout
leaves behind.
"""
import errno
import os
import select
import signal
import subprocess
import threading
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


def merged_survivors(members, survivors):
    """Merge the group and token sweeps, naming each terminated pid once.

    One process can be both a same-group member and a token carrier: a plain
    fork inherits the run token, so a descendant that stayed in the session is
    visible to both sweeps, and when it is still dying inside the SIGKILL
    delivery race the second sweep names it again. The merged report keeps the
    first sighting of every pid, group attribution first — a pid listed twice
    reads as two terminations and broke strict callers that unpack one entry
    per killed process (issue #381).
    """
    named = {item['pid'] for item in members}
    return members + [item for item in survivors if item['pid'] not in named]


def _leader_reaped(pinned):
    """Whether a pinned leader has been reaped; the pin never lies about a recycled id.

    A pidfd pinned while the leader lived keeps referring to that one
    process: after the owning call reaps it, signals to the pin fail instead
    of reaching whatever process later reused the numeric id.
    """
    try:
        signal.pidfd_send_signal(pinned, 0)
    except OSError:
        return True  # The pinned process is gone; existence checks fail on it alone.
    return False


def _signal_group(process, pinned):
    """SIGKILL one owned process group through its pinned leader when possible."""
    if pinned is not None:
        try:
            signal.pidfd_send_signal(pinned, signal.SIGKILL, None, 1)  # PIDFD_SIGNAL_PROCESS_GROUP
            return
        except OSError as error:
            if error.errno == errno.ESRCH:
                return  # The pinned leader is gone; a pid fallback could hit a recycled id.
        except AttributeError:
            pass  # Python without pidfd signal support falls back below.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except OSError:
        pass  # Everything the sweeps named is already dying or dead.


def _terminate_tree(process, token_value, pinned=None):
    """Stop one run's whole tree and name everything the termination reached.

    The sweeps run before and after the group kill: a scan-then-kill pass
    names and terminates the live members itself, the group kill catches the
    rest of the group, and the second pass catches anything that appeared in
    between. Killing first instead would let a fast-dying descendant die
    unnamed, so the same tree reads as an escape failure without the
    cancellation and as an unrecorded success with one beside it. The first
    passes are contained on their own, so one failing pass never skips the
    kill or discards the names earlier passes already earned; a persistent
    sweep anomaly resurfaces from the uncontained second pass, after the
    kill has landed. When a pinned leader is given, its liveness gates the
    group phases — after the owning call reaped the leader the group is no
    longer ours to name or kill, and the pidfd keeps the group signal off a
    recycled id. Merging the passes keeps every pid named exactly once
    (#381's class).
    """
    def group_phase(action):
        if pinned is not None and _leader_reaped(pinned):
            return []  # The owning call reaped the leader; the token sweep below still runs.
        return action()

    named = []
    for sweep in (lambda: group_phase(lambda: terminate_group(process.pid)), lambda: terminate(token_value)):
        try:
            named = merged_survivors(named, sweep())
        except Exception:
            continue  # The kill and the second sweep still run and name what remains.
    group_phase(lambda: _signal_group(process, pinned))
    named = merged_survivors(named, group_phase(lambda: terminate_group(process.pid)))
    return merged_survivors(named, terminate(token_value))


class _Deadline(Exception):
    """The direct child was still running when its deadline passed.

    The buffers drained before the deadline travel with it, because that
    partial output is the command's real evidence and must reach its log.
    """

    def __init__(self, buffers, stdout):
        super().__init__()
        self.buffers = buffers
        self.stdout = stdout


class Cancelled(RuntimeError):
    """The run's own cancellation handle stopped it before its deadline.

    The buffers drained before the cancellation travel with it, because that
    partial output is the command's real evidence; the survivor report and
    the CANCELLED marker land in the same log a timeout writes.
    """

    def __init__(self, output=''):
        super().__init__('owned run cancelled by its handle')
        self.output = output


class CancelHandle:
    """Bounded, thread-safe cancellation for one owned run in flight.

    run() pins its started process group and token on the handle it was
    given. cancel() then does from another thread exactly what the deadline
    path does from inside the call: sweep, kill and re-sweep the whole tree
    so everything the termination reached is named, with pidfd-pinned kills
    and one merged survivor report that names each pid at most once — a
    shared registry settles every sighting between the cancel and the owning
    call's own sweeps (#381's class). After the owning call reaped its child
    the cancel no longer touches the process group — a kill then could reach
    a recycled pid — but it still stops the run's own token carriers through
    the pidfd-pinned sweep, so a surviving carrier belongs to whichever side
    reached it, named exactly once. Every exit path publishes the report and
    the swept event, so an owning call waiting on the outcome finishes
    bounded. The owning call still reaps its child, verifies the tree is
    gone, writes the report into its log and raises Cancelled; a second
    cancel is refused because two reports could never both keep their
    once-only naming.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._process = None
        self._token = None
        self._named = set()
        self._report = []
        self._cancelled = False
        self._swept = threading.Event()

    def refuse_cancelled(self):
        """Refuse a caller reusing an already-cancelled handle before it starts anything."""
        with self._lock:
            if self._cancelled:
                raise ValueError('this handle already cancelled its run')

    def register(self, process, token_value):
        """Pin one starting run; False means the handle cannot pin it.

        False covers a handle that already cancelled and one that is already
        pinning another concurrent run: a handle carries one run at a time,
        and silently overwriting the pin would leave the earlier run
        uncancellable until its own deadline.
        """
        with self._lock:
            if self._cancelled or self._process is not None:
                return False
            self._process, self._token = process, token_value
            return True

    def unregister(self):
        """Release the pin; a later cancel then finds nothing left to stop."""
        with self._lock:
            self._process = self._token = None

    @property
    def cancelled(self):
        with self._lock:
            return self._cancelled

    def claim(self, candidates):
        """Name the not-yet-named candidates and mark every pid claimed exactly once."""
        with self._lock:
            fresh = []
            for item in candidates:
                if item['pid'] not in self._named:
                    self._named.add(item['pid'])
                    fresh.append(item)
            return fresh

    def cancel(self):
        """Stop the pinned tree once; a second cancel is refused.

        Returns the merged survivor report of the tree this cancel killed,
        naming each pid once. An empty handle — the run already finished and
        unpinned itself — cancels nothing and reports nothing. Every exit
        path publishes the report and the swept event, so an owning call
        waiting on the outcome always finishes bounded.
        """
        self.refuse_cancelled()
        with self._lock:
            if self._cancelled:
                raise ValueError('this run was already cancelled')
            self._cancelled = True
            process, token_value = self._process, self._token
            self._process = self._token = None
        fresh = []
        try:
            candidates = []
            if process is not None:
                # The leader's pidfd is pinned before anything can reap it, so
                # every group decision below is made against the process the
                # handle actually owned: after the owning call reaps its
                # child the group is no longer ours — a kill then could reach
                # a recycled id — and only the pidfd-pinned token sweep runs,
                # which can never misaddress.
                pinned = None
                try:
                    pinned = os.pidfd_open(process.pid)
                except (AttributeError, OSError):
                    pinned = None
                reaped = _leader_reaped(pinned) if pinned is not None else process.poll() is not None
                candidates = terminate(token_value) if reaped else _terminate_tree(process, token_value, pinned)
            fresh = self.claim(candidates)
        finally:
            with self._lock:
                self._report = fresh
            self._swept.set()
        return fresh

    def stopped_report(self):
        """Wait for an in-flight cancel's sweeps, then take its survivor report.

        Called by the owning run after it observed its own cancellation, so
        the report it writes into its log always covers the tree the cancel
        killed, whatever the sweep timing was.
        """
        self._swept.wait()
        with self._lock:
            report, self._report = self._report, []
            return report


def _owned_surface():
    """Whether this platform owns whole process groups through the kernel."""
    return hasattr(os, 'killpg') and Path('/proc').is_dir()


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
    after exit stops at EOF or the idle grace, whichever comes first. The
    returned parts keep stdout and stderr separate so a caller that parses
    the streams differently can join them in its own order.
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
    parts = {descriptor: bytes(data[:trusted[descriptor]]).decode('utf-8', errors='replace') for descriptor, data in buffers.items()}
    return process.returncode, parts, post_exit_bytes, group_alive


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


def _start(command, environment, cwd, input_text=False):
    """Start one process in its own session carrying a unique ownership token."""
    owned = dict(environment or os.environ)
    token_value = uuid.uuid4().hex
    owned[TOKEN_VARIABLE] = token_value
    process = subprocess.Popen(command, cwd=cwd, env=owned, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               stdin=subprocess.PIPE if input_text else subprocess.DEVNULL,
                               text=True, start_new_session=True)
    return process, token_value


def _feed_stdin(process, input_text, failures):
    """Write the stdin payload concurrently, so a full pipe cannot block.

    The write runs on its own thread while the collector drains the output
    pipes, mirroring the communicate() loop the previous subprocess.run shape
    used: a payload larger than the pipe buffer, or a child that never reads,
    can never stop the deadline from arming. A killed child surfaces as a
    write failure inside the thread and must not mask the real exit, and a
    failed write still owes the child its EOF. The feeder owns the stdin
    stream outright — it closes it on every exit path, because a close from
    the collector thread would flush through the feeder's buffered write and
    block on a full pipe that only the ownership sweeps can drain.
    """

    def feed():
        try:
            try:
                process.stdin.write(input_text)
            finally:
                try:
                    process.stdin.close()
                except (BrokenPipeError, OSError, ValueError):
                    pass  # The child died mid-write; the EOF it owes is already broken.
        except (BrokenPipeError, OSError, ValueError):
            pass
        except Exception as error:
            failures.append(error)  # Named in the log; the exit code stays the child's.

    threading.Thread(target=feed, daemon=True).start()


def _run_until_exit(process, token_value, log, timeout, cancel=None):
    """Collect one owned child, owning the deadline and interruption paths.

    Both public runners share this tail: a deadline kills the group, keeps the
    partial output and records the timeout marker; an interruption must not
    strand the tree either. A cancellation handle observed by either path
    claims its sightings first, so no survivor is named twice (#381's class).
    Returns the trusted per-stream parts and the exit bookkeeping, or raises
    with the log already written.
    """
    try:
        try:
            returncode, parts, post_exit_bytes, group_alive = _collect(process, time.monotonic() + timeout)
        except _Deadline as expired:
            if cancel is not None and cancel.cancelled:
                # The handle stopped this run; the deadline only won the poll
                # race. The tree is still verified here — a cancel whose kill
                # or sweeps failed stops nothing, so this branch sweeps,
                # names and reaps exactly like the natural exit, and a
                # carrier the run had to terminate itself is an escape, not a
                # silent cancellation.
                report = cancel.stopped_report()
                text = ''.join(data.decode('utf-8', errors='replace') for data in expired.buffers.values())
                text += _drain_after_kill(process) + '\n'
                fresh = cancel.claim(merged_survivors(terminate_group(process.pid), terminate(token_value)))
                named = merged_survivors(report, fresh)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    pass  # The sweeps already killed every group member and carrier.
                if named:
                    text += f'OWNED_PROCESSES: terminated {named}\n'
                text += 'CANCELLED: the owning handle stopped this command\n'
                log.write_text(text)
                if fresh:
                    raise EscapedDescendants(fresh) from None
                raise Cancelled(text) from None
            survivors = _terminate_tree(process, token_value)
            if cancel is not None:
                own = cancel.claim(survivors)
                # The flag is re-read after the claim: a cancel that flipped
                # mid-sweep claims its victims into its own report, and this
                # line must merge that report rather than the empty snapshot
                # an earlier read took.
                report = cancel.stopped_report() if cancel.cancelled else []
                survivors = merged_survivors(report, own)
            process.poll()
            text = ''.join(data.decode('utf-8', errors='replace') for data in expired.buffers.values())
            text += _drain_after_kill(process) + '\n'
            log.write_text(text + f'TIMEOUT: command exceeded {timeout} seconds\n'
                           + f'OWNED_PROCESSES: terminated {survivors}\n')
            raise subprocess.TimeoutExpired(process.args, timeout, output=text) from None
        except BaseException:
            # An interruption must not strand the tree either: the new session
            # never saw the terminal signal, so both ownership checks run, the
            # child is reaped, and no cleanup failure replaces the interrupt.
            try:
                named = cancel.stopped_report() if cancel is not None and cancel.cancelled else []
                candidates = _terminate_tree(process, token_value)
                if cancel is not None:
                    candidates = merged_survivors(named, cancel.claim(candidates))
                if candidates:
                    try:
                        log.write_text(f'OWNED_PROCESSES: terminated {candidates}\n')
                    except OSError:
                        pass  # A failing log sink must not replace the interrupt either.
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    pass
            except Exception as cleanup_failure:
                try:
                    log.write_text(f'OWNED_PROCESS_CLEANUP_FAILED: {cleanup_failure}\n')
                except OSError:
                    pass
            process.poll()
            raise
        return returncode, parts, post_exit_bytes, group_alive
    finally:
        if cancel is not None:
            cancel.unregister()
        # The feeder thread owns stdin: a close here would flush through its
        # buffered write and block on a full pipe that only the sweeps below
        # can drain. stdout and stderr are read ends from this side, so their
        # close can never block on a descendant.
        for stream in (process.stdout, process.stderr):
            if stream is not None:
                try:
                    stream.close()
                except OSError:
                    pass


def _refused_run(cancel, process, token_value, log):
    """Clean up a tree the handle could not pin, then refuse.

    The handle either already cancelled or already pins another concurrent
    run. The tree stop mirrors the deadline path — sweeps and kill run even
    when one pass raises, everything terminated is named, and the child is
    reaped — so the unpinnable tree strands nothing before the ValueError
    refuses the run.
    """
    try:
        try:
            candidates = _terminate_tree(process, token_value)
        except Exception:
            candidates = []  # The refusal is the caller-relevant outcome; the reap still runs.
        if cancel is not None:
            candidates = cancel.claim(candidates)
        if candidates:
            try:
                log.write_text(f'OWNED_PROCESSES: terminated {candidates}\n')
            except OSError:
                pass  # A failing log sink must not replace the refusal either.
    finally:
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass  # The sweeps already killed every group member and carrier.
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None:
                try:
                    stream.close()
                except OSError:
                    pass
        process.poll()
    if cancel is not None and cancel.cancelled:
        raise ValueError('this handle already cancelled its run; the started tree was cleaned up before refusing')
    raise ValueError('this handle already pins another concurrent run; the started tree was cleaned up before refusing')


def run(command, environment, log, timeout, cwd=None, input_text=None, cancel=None):
    """Run one bounded command whose entire descendant tree stays owned.

    The launcher writes the started command, any terminated survivors and a
    TIMEOUT or CANCELLED marker into the same log the caller already reads,
    so a rejected, escaped, expired or cancelled run keeps its diagnosis
    where the watchdog looks. The return value and the raised exceptions
    match the previous subprocess.run contract, including the partial output
    a deadline or a cancellation captured. A cancel handle stops the run
    from outside its call; an already-cancelled handle is refused before any
    process starts. A cancelled run raises Cancelled and carries the same
    evidence a timeout leaves behind — unless the command finished its own
    clean exit with nothing left to terminate inside the cancel race, in
    which case that verified-clean result stands without a marker.
    """
    if not _owned_surface():
        if cancel is not None:
            raise ValueError('cancellation requires the kernel ownership surface (process groups and /proc)')
        owned = dict(environment or os.environ)
        owned[TOKEN_VARIABLE] = uuid.uuid4().hex
        try:
            completed = subprocess.run(command, cwd=cwd, env=owned, capture_output=True, text=True, timeout=timeout,
                                       input=input_text)
        except subprocess.TimeoutExpired as error:
            output = error.output if isinstance(error.output, str) else (error.output or b'').decode('utf-8', errors='replace')
            log.write_text(output + f'\nTIMEOUT: command exceeded {timeout} seconds\n')
            raise
        return completed.returncode, completed.stdout + completed.stderr
    if cancel is not None:
        cancel.refuse_cancelled()
    process, token_value = _start(command, environment, cwd, input_text is not None)
    if cancel is not None and not cancel.register(process, token_value):
        _refused_run(cancel, process, token_value, log)
    feed_failures = []
    if input_text is not None:
        _feed_stdin(process, input_text, feed_failures)
    returncode, parts, post_exit_bytes, group_alive = _run_until_exit(process, token_value, log, timeout, cancel)
    output = ''.join(parts.values())
    if feed_failures:
        output += f'\nSTDIN_FEEDER_ERROR: {feed_failures[0]}\n'
    if post_exit_bytes:
        output += ('\nPOST_EXIT_OUTPUT: '
                   f'{post_exit_bytes} byte(s) arrived after the command exited and were withheld\n')
    # Both ownership checks always run before any escape raises: a command
    # can leave a same-group descendant and a setsid token carrier at once,
    # and reporting only the first would strand the second. A sighting the
    # cancellation already claimed comes back from its report, so no pid is
    # ever named twice — or named nowhere — across the cancel and the run's
    # own reports (#381's class).
    report = cancel.stopped_report() if cancel is not None and cancel.cancelled else []
    members = terminate_group(process.pid) if group_alive else []
    fresh = cancel.claim(merged_survivors(members, terminate(token_value))) if cancel is not None \
        else merged_survivors(members, terminate(token_value))
    candidates = merged_survivors(report, fresh)
    if candidates:
        output += f'OWNED_PROCESSES: terminated {candidates}\n'
        if cancel is not None and cancel.cancelled:
            output += 'CANCELLED: the owning handle stopped this command\n'
            log.write_text(output)
            if fresh:
                raise EscapedDescendants(candidates)
            raise Cancelled(output) from None
        log.write_text(output)
        raise EscapedDescendants(candidates)
    if cancel is not None and cancel.cancelled:
        if returncode != 0:
            text = output + 'CANCELLED: the owning handle stopped this command\n'
            log.write_text(text)
            raise Cancelled(text) from None
        # The command finished its own clean exit inside the cancel race and
        # nothing had to be terminated; its verified-clean result stands.
    if post_exit_bytes or feed_failures:
        log.write_text(output)
    return returncode, output


def run_split(command, environment, log, timeout, cwd=None, input_text=None, cancel=None):
    """Run one owned command and keep its streams separate for strict callers.

    Callers that parse stdout as data and refuse any stderr need the command's
    own streams without the diagnostic notes a merged run may append. The
    healthy path returns exactly the trusted stdout and stderr the child
    wrote; an escaped descendant raises EscapedDescendants instead of
    contaminating either stream, and the timeout and cancellation paths keep
    the merged partial output on the raised exception exactly like run().
    """
    if not _owned_surface():
        if cancel is not None:
            raise ValueError('cancellation requires the kernel ownership surface (process groups and /proc)')
        owned = dict(environment or os.environ)
        owned[TOKEN_VARIABLE] = uuid.uuid4().hex
        try:
            completed = subprocess.run(command, cwd=cwd, env=owned, capture_output=True, text=True, timeout=timeout,
                                       input=input_text)
        except subprocess.TimeoutExpired as error:
            output = error.output if isinstance(error.output, str) else (error.output or b'').decode('utf-8', errors='replace')
            log.write_text(output + f'\nTIMEOUT: command exceeded {timeout} seconds\n')
            raise
        return completed.returncode, completed.stdout, completed.stderr
    if cancel is not None:
        cancel.refuse_cancelled()
    process, token_value = _start(command, environment, cwd, input_text is not None)
    if cancel is not None and not cancel.register(process, token_value):
        _refused_run(cancel, process, token_value, log)
    stdout_descriptor = process.stdout.fileno()
    feed_failures = []
    if input_text is not None:
        _feed_stdin(process, input_text, feed_failures)
    returncode, parts, post_exit_bytes, group_alive = _run_until_exit(process, token_value, log, timeout, cancel)
    stderr = ''.join(data for descriptor, data in parts.items() if descriptor != stdout_descriptor)
    if feed_failures:
        stderr += f'\nSTDIN_FEEDER_ERROR: {feed_failures[0]}\n'
    members = terminate_group(process.pid) if group_alive else []
    report = cancel.stopped_report() if cancel is not None and cancel.cancelled else []
    fresh = cancel.claim(merged_survivors(members, terminate(token_value))) if cancel is not None \
        else merged_survivors(members, terminate(token_value))
    candidates = merged_survivors(report, fresh)
    if candidates:
        # The child's own trusted output stays in the log beside the note,
        # so an escaped or cancelled run keeps its diagnosis where the caller
        # looks, with every terminated pid named exactly once (#381's class).
        text = ''.join(parts.values()) + f'OWNED_PROCESSES: terminated {candidates}\n'
        if cancel is not None and cancel.cancelled:
            text += 'CANCELLED: the owning handle stopped this command\n'
            log.write_text(text)
            if fresh:
                raise EscapedDescendants(candidates)
            raise Cancelled(text) from None
        log.write_text(text)
        raise EscapedDescendants(candidates)
    if cancel is not None and cancel.cancelled:
        if returncode != 0:
            text = ''.join(parts.values()) + 'CANCELLED: the owning handle stopped this command\n'
            log.write_text(text)
            raise Cancelled(text) from None
    if post_exit_bytes:
        log.write_text(f'POST_EXIT_OUTPUT: {post_exit_bytes} byte(s) arrived after the command '
                       'exited and were withheld\n')
        stderr += (f'\nPOST_EXIT_OUTPUT: {post_exit_bytes} byte(s) arrived after the command '
                   'exited and were withheld\n')
    return returncode, parts[stdout_descriptor], stderr


def spawn(command, environment=None, stdout=None, stderr=None, cwd=None):
    """Start one caller-managed process in its own owned session.

    Long-lived companions such as a native engine host cannot go through run():
    their lifetime spans other owned commands. The caller receives the process
    and its token and must end the episode with finish(), which applies the
    same descendant-tree ownership checks run() applies to its own children.
    """
    owned = dict(environment if environment is not None else os.environ)
    token_value = uuid.uuid4().hex
    owned[TOKEN_VARIABLE] = token_value
    process = subprocess.Popen(command, cwd=cwd, env=owned, stdout=stdout, stderr=stderr, start_new_session=True)
    return process, token_value


def finish(process, token_value, grace=5.0):
    """Stop one spawned process and verify its whole descendant tree is gone.

    The direct child is asked to terminate first and is killed at the grace
    deadline, mirroring the previous host teardown; then both ownership checks
    run, so any surviving descendant is killed and named instead of being
    adopted by init. Returns once nothing owned is alive.
    """
    try:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=grace)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except OSError:
                    process.kill()
                process.wait(timeout=grace)
        members = terminate_group(process.pid)
        survivors = merged_survivors(members, terminate(token_value))
        if process.poll() is None:
            try:
                process.wait(timeout=grace)
            except subprocess.TimeoutExpired:
                pass  # The sweeps already killed every group member and carrier.
        if survivors:
            raise EscapedDescendants(survivors)
    finally:
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None:
                try:
                    stream.close()
                except OSError:
                    pass
