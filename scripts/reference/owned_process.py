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
leaves behind. The owning call consumes that report at one point — absorb()
waits out a cancel that has started and drains its names once — and after
emit() writes the run's final log, a cancel that names fresh sightings
appends them to the registered log itself under the same once-only registry,
so a terminated pid can never vanish from the log between the run's last
flag read and its write (#399). Post-reap ownership sweeps pass the child's
exit boundary in clock ticks, so a scan against a group id the kernel
already reissued to an unrelated new leader names nothing it does not own.
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
# /proc stat reports starttime in scheduler ticks since boot with one tick of
# granularity: a descendant forked in the same tick as its owner's exit reads
# as started on the boundary. One tick of slack keeps that descendant named;
# a recycled unrelated group leader must have started strictly after the exit.
START_TICK_SLACK = 1
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


def _named_all(survivors):
    """Every survivor named, with no cap.

    The cap exists for exception summaries; a run or cancellation log is the
    evidence a diagnosis reads, so a ninth terminated pid must reach it
    instead of disappearing behind "and 1 more" (issue #398 review).
    """
    return ', '.join(f"pid {item['pid']} ({item['name']})" for item in survivors)


def _append_log(log, named):
    """Append a terminated-survivors note to one log; a failing sink never breaks the stop."""
    if not named or log is None:
        return
    try:
        with log.open('a', encoding='utf-8') as sink:
            sink.write(f'OWNED_PROCESSES: terminated {_named_all(named)}\n')
    except Exception:
        pass  # The caller's return value still names them; a failing sink must not break the stop.


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


def group_members(group, proc=None, started_before=None, token_value=None):
    """Name the live members of one process group; zombies are already dead.

    A grandchild that exited before its parent is a zombie until init reaps
    it, and a zombie still holds its process group open. It cannot write,
    hold a pipe or come back, so it is skipped: naming it as a terminated
    survivor would record a dead process, and counting it would fail healthy
    runs whenever reap latency exceeds the drain grace.

    A scan that runs after the owning call reaped its child reads a group id
    the kernel may already have reissued to an unrelated new group leader.
    That leader started after our child died, so started_before carries an
    exit-or-teardown boundary in scheduler ticks since boot: members that
    started after it are named only when they carry the run token
    (token_value), because a tokened member is ours wherever it started,
    while a tokenless one that started after our tree's death can only be
    the recycled group. What remains unknowable from /proc is a descendant
    that forked after the boundary and scrubbed its environment before the
    scan — it is spared here, and containing that class needs the
    cgroup-backed ownership work in #290. A starttime that cannot be parsed
    counts as ours: naming biases toward killing what we own, never toward
    stranding it.
    """
    found = []
    marker = (TOKEN_VARIABLE + '=' + token_value).encode('utf-8') + b'\0' if token_value else None
    for entry in (proc or Path('/proc')).iterdir():
        if not entry.name.isdigit():
            continue
        try:
            fields = (entry / 'stat').read_text().rsplit(') ', 1)[-1].split()
        except OSError:
            continue
        if not fields or fields[0] in ('Z', 'X') or int(fields[2]) != group:
            continue
        if started_before is not None:
            try:
                started = int(fields[19])
            except (IndexError, ValueError):
                started = None  # A stat line without a parsable starttime is treated as ours below.
            if started is not None and started > started_before + START_TICK_SLACK:
                if marker is None or not _carries_token(entry, marker):
                    continue  # Started after the boundary without our token: a reissued group.
        found.append({'pid': int(entry.name), 'name': _name(entry)})
    return sorted(found, key=lambda item: item['pid'])


def _carries_token(entry, marker):
    """Whether one live process carries the ownership token in its environment."""
    try:
        return marker in (entry / 'environ').read_bytes()
    except OSError:
        return False  # An unreadable environment cannot be attributed to a run we started.


def _boot_ticks():
    """The boottime clock in scheduler ticks, the units /proc stat starttime uses.

    None means the platform offers no boottime clock or tick count, and the
    started-after-exit filter stays off rather than guessing a boundary.
    """
    try:
        ticks = os.sysconf('SC_CLK_TCK')
    except (AttributeError, ValueError, OSError):
        ticks = 100
    try:
        return int(time.clock_gettime(time.CLOCK_BOOTTIME) * ticks)
    except (AttributeError, OSError, ValueError):
        return None


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


def terminate_group(group, proc=None, started_before=None, token_value=None):
    """Kill every live member of one process group and return their identities.

    started_before bounds the scan the way group_members does; a post-reap
    caller passes the owned tree's exit-or-teardown boundary and its token,
    so a recycled group id names nothing it does not own while a forked
    descendant carrying the token is still named.
    """
    members = group_members(group, proc=proc, started_before=started_before, token_value=token_value)
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


def _leader_reaped(pinned, pid=None):
    """Whether a pinned leader has been reaped; the pin never lies about a recycled id.

    A pidfd pinned while the leader lived keeps referring to that one
    process: after the owning call reaps it, signals to the pin fail instead
    of reaching whatever process later reused the numeric id. The probe also
    fails for an exited-but-unreaped leader — a zombie has already released
    its signal state — so the /proc directory decides that case: a zombie's
    numeric id cannot be recycled until its owner reaps it, which makes the
    group kill safe, while a reaped leader is gone entirely and its id is
    free again (#398 review). Only a reaped leader therefore skips the group
    phases; a zombie still gets its surviving descendants named and killed.
    """
    try:
        signal.pidfd_send_signal(pinned, 0)
        return False  # The pinned process is alive; the group phases stay armed.
    except OSError:
        pass  # The pin names no live process: a zombie or a reaped leader.
    if pid is not None and Path(f'/proc/{pid}').exists():
        return False  # A zombie still owns its id; the group is still ours to kill.
    return True


def _signal_group(process, pinned):
    """SIGKILL one owned process group through its pinned leader when possible."""
    if pinned is not None:
        try:
            # PIDFD_SIGNAL_PROCESS_GROUP (4): signal the whole process group
            # behind the pinned leader. Value 1 would signal only the
            # leader's own thread group and leave same-group descendants to
            # the sweeps.
            signal.pidfd_send_signal(pinned, signal.SIGKILL, None, 4)
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
    cancellation and as an unrecorded success with one beside it. No pass
    ever skips a later one: the first passes are contained, the kill always
    runs, and a persistent sweep anomaly from the final passes comes back as
    the second element of the return after every sweep has run — a caller's
    reap, log and classification are never skipped by a sweep failure.
    When a pinned leader is given, its liveness gates the group phases —
    after the owning call reaped the leader the group is no longer ours to
    name or kill, and the pidfd keeps the group signal off a recycled id.
    Merging the passes keeps every pid named exactly once (#381's class).
    """
    def group_phase(action):
        if pinned is not None and _leader_reaped(pinned, process.pid):
            return []  # The owning call reaped the leader; the token sweep below still runs.
        return action()

    named = []
    for sweep in (lambda: group_phase(lambda: terminate_group(process.pid)), lambda: terminate(token_value)):
        try:
            named = merged_survivors(named, sweep())
        except Exception:
            continue  # The kill and the second sweep still run and name what remains.
    group_phase(lambda: _signal_group(process, pinned))
    anomaly = None
    try:
        named = merged_survivors(named, group_phase(lambda: terminate_group(process.pid)))
    except Exception as error:
        anomaly = error  # The final token sweep still runs before the anomaly resurfaces.
    try:
        named = merged_survivors(named, terminate(token_value))
    except Exception as error:
        anomaly = anomaly or error  # Every sweep ran; the first anomaly is the one reported.
    return named, anomaly


def _contained_sweeps(sweeps):
    """Run every ownership sweep, never letting one failure skip a later one.

    Returns the merged names and the first anomaly. A failing token scan must
    not skip the group scan, or the reverse: a token-scrubbed same-group
    descendant has to be named and killed even when the other sweep raises,
    and the anomaly surfaces only after both sweeps have run (#398 review).
    """
    named = []
    anomaly = None
    for sweep in sweeps:
        try:
            named = merged_survivors(named, sweep())
        except Exception as error:
            anomaly = anomaly if anomaly is not None else error
    return named, anomaly


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

    run() pins its started process group, token and log on the handle it
    was given. cancel() then does from another thread exactly what the
    deadline path does from inside the call: sweep, kill and re-sweep the
    whole tree so everything the termination reached is named, with
    pidfd-pinned kills and one merged survivor report that names each pid
    at most once. The report moves through one handoff: the cancel claims
    its sightings into the handle's report, the owning call's absorb() is
    the single point that waits out a started cancel and drains those
    names, and emit() writes the run's final log text and closes the
    handoff — a cancel that names fresh sightings after that close appends
    them to the registered log itself, so a terminated pid reaches the log
    the caller reads no matter which side of the write the sweeps landed
    on (#399). After the owning call reaped its child the cancel no longer
    touches the process group — a kill then could reach a recycled pid —
    but it still stops the run's own token carriers through the
    pidfd-pinned sweep, so a surviving carrier belongs to whichever side
    reached it, named exactly once. A second cancel is refused because two
    reports could never both keep their once-only naming.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._log_lock = threading.Lock()
        self._process = None
        self._token = None
        self._pinned = None
        self._log = None
        self._append_target = None
        self._named = set()
        self._report = []
        self._closed = False
        self._stopped_run = False
        self._cancelled = False
        self._reporting = False
        self._done = threading.Event()

    def refuse_cancelled(self):
        """Refuse a caller reusing an already-cancelled handle before it starts anything."""
        with self._lock:
            if self._cancelled:
                raise ValueError('this handle already cancelled its run')

    def register(self, process, token_value, log=None):
        """Pin one starting run; False means the handle cannot pin it.

        False covers a handle that already cancelled, one that is already
        pinning another concurrent run, and one whose earlier run has not
        finished its report phase: a handle carries one run at a time, and
        silently overwriting the pin would leave the earlier run
        uncancellable until its own deadline. The report phase runs from a
        successful register until the owning call's final write or settle
        closes the handoff — it spans the runners' final sweeps, where the
        owning call still emits and drains through this handle, so a second
        registration during it would give the first run's emit() the second
        run's log and its report stream (issue #398/#400 review). The
        leader's pidfd is opened here — the child was just started and
        nothing can have reaped it, so the pin can never capture a recycled
        id — and retained for the cancellation to signal through. The log is
        retained too: it is where the owning call writes its final text
        through emit(), and where this handle appends its own sightings when
        a cancel lands after that write closed the handoff.
        """
        with self._lock:
            if self._cancelled or self._process is not None or self._reporting:
                return False
            pinned = None
            try:
                pinned = os.pidfd_open(process.pid)
            except (AttributeError, OSError):
                pinned = None  # Without pidfd support the poll guard decides below.
            self._pinned = pinned
            self._process, self._token, self._log = process, token_value, log
            self._report = []
            self._closed = False
            self._reporting = True
            return True

    def unregister(self):
        """Release the pin; a later cancel then finds nothing left to stop."""
        with self._lock:
            self._process = self._token = None
            pinned, self._pinned = self._pinned, None
        if pinned is not None:
            try:
                os.close(pinned)
            except OSError:
                pass  # A closed pin is already the state the probe reads as reaped.

    @property
    def cancelled(self):
        with self._lock:
            return self._cancelled

    @property
    def stopped_run(self):
        """Whether this cancel actually stopped a run it had pinned.

        A cancel landing on an empty handle — the run already finished and
        unpinned itself — stopped nothing, so the owning call keeps its own
        completed result instead of reading as cancelled.
        """
        with self._lock:
            return self._stopped_run

    def claim(self, candidates):
        """Name the not-yet-named candidates and mark every pid claimed exactly once."""
        with self._lock:
            return self._claim_locked(candidates)

    def _claim_locked(self, candidates):
        fresh = []
        for item in candidates:
            if item['pid'] not in self._named:
                self._named.add(item['pid'])
                fresh.append(item)
        return fresh

    def absorb(self):
        """Wait out a cancel that has started and take its whole report once.

        This is the owning call's single consumption point for the handle's
        sightings: instead of re-reading flags around its own sweeps and
        merging whatever snapshot each read took, it waits here until a
        started cancel finishes sweeping, then drains its names. A cancel
        that never started costs one flag read, and a cancel that starts
        after this drained — or after emit() closed the handoff — still
        reaches the log through the handle's own append (#399).
        """
        with self._lock:
            started = self._cancelled
        if started:
            self._done.wait()
        with self._lock:
            report, self._report = self._report, []
            return report

    def settle(self):
        """Drain anything published since absorb() and close the sighting handoff.

        The owning call's writing exit paths close through emit(); the paths
        that end without a write — a verified-clean exit inside the cancel
        race, or a plain healthy return — close here instead, so a report
        published in the gap still comes back and can be named before the
        run ends. Closing also ends the report phase, so the handle accepts
        a later registration again. A cancel starting after this close
        appends its own sightings to the registered log itself.
        """
        with self._lock:
            report, self._report = self._report, []
            self._closed = True
            self._reporting = False
            return report

    def emit(self, text):
        """Write the run's final log text and close the sighting handoff.

        The log lock spans the close and the write: the close re-drains the
        report, so a cancel that published in the gap since the owning
        call's absorb() folds into this write, and a cancel publishing while
        the write runs appends strictly after it instead of losing its line
        to the write's truncation. The state lock never spans a log write,
        so a cancel starting now flips and sweeps immediately (#399). The
        report phase ends whether or not the write succeeds: the run is over
        either way, and a handle locked by a failed write would strand every
        later run on this handle behind the refusal.
        """
        with self._log_lock:
            try:
                with self._lock:
                    report, self._report = self._report, []
                    self._closed = True
                    if report:
                        text = (text or '') + f'OWNED_PROCESSES: terminated {_named_all(report)}\n'
                if text and self._log is not None:
                    self._log.write_text(text)
            finally:
                with self._lock:
                    self._reporting = False
        return text

    def _append_sightings(self, named):
        """Append this cancel's own sightings to the stopped run's log once.

        The target is the log captured at the flip — the run this cancel
        actually stopped — never the handle's current registration, which a
        later run may already own. The log lock orders the append after an
        emit() write that could still be running on the owning thread.
        """
        if not named:
            return
        with self._log_lock:
            _append_log(self._append_target, named)

    def _publish(self, candidates):
        """Claim the sweeps' sightings once and hand them to their one reader.

        The owning call drains the stored report through absorb(); after its
        emit() closed the handoff, this append is the only way a late
        sighting still reaches the log the caller reads. The state lock is
        released before the append runs, so the append's file work never
        delays a reader and emit's log-lock-then-state-lock order holds
        without a cycle.
        """
        with self._lock:
            fresh = self._claim_locked(candidates)
            closed = self._closed
            if not closed:
                self._report = fresh
        if closed:
            self._append_sightings(fresh)
        return fresh

    def cancel(self):
        """Stop the pinned tree once; a second cancel is refused.

        Returns the merged survivor report of the tree this cancel killed,
        naming each pid once. An empty handle — the run already finished and
        unpinned itself — cancels nothing and reports nothing. Every exit
        path publishes the claimed sightings through the one handoff and
        sets the done event, so an owning call absorbing the outcome always
        finishes bounded.
        """
        self.refuse_cancelled()
        with self._lock:
            if self._cancelled:
                raise ValueError('this run was already cancelled')
            self._cancelled = True
            process, token_value, pinned = self._process, self._token, self._pinned
            # Captured with the flip: every sighting this cancel publishes
            # after the owning call closed the handoff belongs to the run it
            # stopped, never to whatever registered later (#398/#400 review).
            self._append_target = self._log
            self._process = self._token = self._pinned = None
            # Stored under the lock with the flip, so a reader never sees one
            # flag without the other (#399 review round).
            self._stopped_run = process is not None
        fresh = []
        try:
            candidates = []
            if process is not None:
                # The leader's pidfd was pinned at registration, before
                # anything could reap it, so every group decision below is
                # made against the process the handle actually owned: after
                # the owning call reaps its child the group is no longer
                # ours — a kill then could reach a recycled id — and only
                # the pidfd-pinned token sweep runs, which can never
                # misaddress. Without pidfd support the poll guard decides.
                reaped = _leader_reaped(pinned, process.pid) if pinned is not None else process.poll() is not None
                if reaped:
                    candidates = terminate(token_value)
                else:
                    candidates, stop_anomaly = _terminate_tree(process, token_value, pinned)
                    if stop_anomaly is not None:
                        # The report is published before the anomaly resurfaces,
                        # so the names the sweeps earned are never discarded.
                        fresh = self._publish(candidates)
                        raise stop_anomaly
            fresh = self._publish(candidates)
        finally:
            if pinned is not None:
                try:
                    os.close(pinned)
                except OSError:
                    pass  # The pin's job is done; an unclosed fd would leak per cancel.
            self._done.set()
        return fresh


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
    exit_ticks = None
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
            exit_ticks = _boot_ticks()
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
    return process.returncode, parts, post_exit_bytes, group_alive, exit_ticks


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
    strand the tree either. The handle's report is consumed through absorb(),
    the one point that waits out a started cancel and drains its sightings,
    so no survivor depends on a flag snapshot taken around the sweeps (#381's
    class, #399's windows). Returns the trusted per-stream parts and the exit
    bookkeeping, or raises with the log already written.
    """
    try:
        try:
            returncode, parts, post_exit_bytes, group_alive, exit_ticks = _collect(process, time.monotonic() + timeout)
        except _Deadline as expired:
            if cancel is not None and cancel.cancelled and cancel.stopped_run:
                # The handle stopped this run; the deadline only won the poll
                # race. The tree is still verified here — a cancel whose kill
                # or sweeps failed stops nothing, so this branch sweeps,
                # names and reaps exactly like the natural exit, and a
                # carrier the run had to terminate itself is an escape, not a
                # silent cancellation.
                report = cancel.absorb()
                text = ''.join(data.decode('utf-8', errors='replace') for data in expired.buffers.values())
                text += _drain_after_kill(process) + '\n'
                # The verification sweeps come back contained: a failing pass
                # never skips the token sweep or the reap, so a carrier the
                # token sweep can still reach is named and stopped, and the
                # child is reaped, whatever the group pass did.
                fresh, sweep_anomaly = _terminate_tree(process, token_value)
                fresh = cancel.claim(fresh)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    pass  # The sweeps already killed every group member and carrier.
                named = merged_survivors(report, fresh)
                if named:
                    text += f'OWNED_PROCESSES: terminated {named}\n'
                text += 'CANCELLED: the owning handle stopped this command\n'
                if sweep_anomaly is not None:
                    text += f'OWNED_PROCESS_SWEEP_ANOMALY: {sweep_anomaly}\n'
                text = cancel.emit(text)
                if fresh:
                    raise EscapedDescendants(fresh) from None
                raise Cancelled(text) from None
            survivors, sweep_anomaly = _terminate_tree(process, token_value)
            # The report is consumed at one point after the sweeps: a cancel
            # that was mid-sweep finishes here and its names join the report,
            # and one starting after emit() wrote this log appends its own
            # sightings to the same file (#399's timeout window).
            report = cancel.absorb() if cancel is not None else []
            own = cancel.claim(survivors) if cancel is not None else survivors
            survivors = merged_survivors(report, own)
            process.poll()
            text = ''.join(data.decode('utf-8', errors='replace') for data in expired.buffers.values())
            text += _drain_after_kill(process) + '\n'
            text += f'TIMEOUT: command exceeded {timeout} seconds\n'
            text += f'OWNED_PROCESSES: terminated {survivors}\n'
            if sweep_anomaly is not None:
                text += f'OWNED_PROCESS_SWEEP_ANOMALY: {sweep_anomaly}\n'
            _write_final(log, cancel, text)
            raise subprocess.TimeoutExpired(process.args, timeout, output=text) from None
        except BaseException:
            # An interruption must not strand the tree either: the new session
            # never saw the terminal signal, so both ownership checks run, the
            # child is reaped, and no cleanup failure replaces the interrupt.
            try:
                named = cancel.absorb() if cancel is not None else []
                candidates, sweep_anomaly = _terminate_tree(process, token_value)
                late = []
                if cancel is not None:
                    candidates = merged_survivors(named, cancel.claim(candidates))
                    # The handoff closes here on every interruption: a report
                    # published since absorb() is named like any other, and
                    # the handle is released for its next run even when the
                    # note below never lands (#398/#400 review).
                    late = cancel.settle()
                    candidates = merged_survivors(candidates, late)
                if candidates or sweep_anomaly is not None:
                    note = f'OWNED_PROCESSES: terminated {candidates}\n' if candidates else ''
                    if sweep_anomaly is not None:
                        note += f'OWNED_PROCESS_SWEEP_ANOMALY: {sweep_anomaly}\n'
                    try:
                        _write_final(log, cancel, note)
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
            finally:
                if cancel is not None:
                    # A cleanup failure above can leave names drained but
                    # unwritten; they still reach the run's own log, after
                    # the handoff close, through the same append door a
                    # cancel uses.
                    _append_log(log, cancel.settle())
            process.poll()
            raise
        return returncode, parts, post_exit_bytes, group_alive, exit_ticks
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


def _write_final(log, cancel, text):
    """Write the run's final log text, closing the handle's handoff when one is pinned.

    With a handle, emit() owns the write and the handoff close in one step;
    without one, the log is the plain sink. An empty text writes nothing but
    still closes an open handoff.
    """
    if cancel is not None:
        return cancel.emit(text)
    if text:
        log.write_text(text)
    return text


def _refused_run(cancel, process, token_value, log):
    """Clean up a tree the handle could not pin, then refuse.

    The handle either already cancelled, already pins another concurrent
    run, or is still publishing an earlier run's report. The tree stop
    mirrors the deadline path — sweeps and kill run even when one pass
    raises, everything terminated is named, and the child is reaped — so
    the unpinnable tree strands nothing before the ValueError refuses the
    run. The diagnosis goes to this run's own log directly: the handle's
    registered log belongs to the run it is pinning, and closing that
    handoff here would corrupt the pinned run's report flow.
    """
    try:
        candidates, refused_anomaly = _terminate_tree(process, token_value)
        if refused_anomaly is not None and cancel is not None:
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
    if cancel is not None and cancel._reporting:
        raise ValueError('this handle is still publishing another run\'s report; the started tree '
                         'was cleaned up before refusing')
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
    if cancel is not None and not cancel.register(process, token_value, log):
        _refused_run(cancel, process, token_value, log)
    feed_failures = []
    if input_text is not None:
        _feed_stdin(process, input_text, feed_failures)
    returncode, parts, post_exit_bytes, group_alive, exit_ticks = _run_until_exit(process, token_value, log, timeout, cancel)
    output = ''.join(parts.values())
    if feed_failures:
        output += f'\nSTDIN_FEEDER_ERROR: {feed_failures[0]}\n'
    if post_exit_bytes:
        output += ('\nPOST_EXIT_OUTPUT: '
                   f'{post_exit_bytes} byte(s) arrived after the command exited and were withheld\n')
    # Both ownership checks always run before any escape raises: a command
    # can leave a same-group descendant and a setsid token carrier at once,
    # and reporting only the first would strand the second. The handle's
    # report is consumed through absorb() — the one point that waits out a
    # started cancel — before the sweeps, so the written report covers both
    # sides' kills and no pid is ever named twice, or named nowhere (#381's
    # class, #399's windows). The post-reap group scan carries the child's
    # exit boundary, so a group id the kernel reissued names nothing.
    report = cancel.absorb() if cancel is not None else []
    # Both sweeps are contained: a failing token scan must not skip the group
    # scan, so a token-scrubbed same-group descendant is named and killed even
    # when the scan raises, and the anomaly surfaces only after both ran
    # (#398 review). The group scan carries the child's exit boundary and the
    # token: post-exit forks carrying the token stay named, a recycled
    # tokenless group does not (#399).
    swept, tail_anomaly = _contained_sweeps([
        lambda: terminate(token_value),
        (lambda: terminate_group(process.pid, started_before=exit_ticks, token_value=token_value))
        if group_alive else (lambda: []),
    ])
    own = cancel.claim(swept) if cancel is not None else swept
    candidates = merged_survivors(report, own)
    stopped = cancel is not None and cancel.cancelled and cancel.stopped_run
    if candidates:
        output += f'OWNED_PROCESSES: terminated {candidates}\n'
        if tail_anomaly is not None:
            output += f'OWNED_PROCESS_SWEEP_ANOMALY: {tail_anomaly}\n'
        if stopped:
            output += 'CANCELLED: the owning handle stopped this command\n'
        text = _write_final(log, cancel, output)
        if own:
            raise EscapedDescendants(candidates)
        if stopped:
            raise Cancelled(text) from None
        raise EscapedDescendants(candidates)
    if stopped and returncode != 0:
        text = _write_final(log, cancel, output + 'CANCELLED: the owning handle stopped this command\n')
        raise Cancelled(text) from None
    # The no-write exits settle before returning: a report published since
    # absorb() comes back here and is named instead of sitting unconsumed in
    # the handle, and the handoff closes so any later cancel appends to the
    # registered log itself (#399).
    late = cancel.settle() if cancel is not None else []
    if late:
        stopped = stopped or (cancel is not None and cancel.cancelled and cancel.stopped_run)
        output += f'OWNED_PROCESSES: terminated {late}\n'
        if stopped:
            output += 'CANCELLED: the owning handle stopped this command\n'
        text = _write_final(log, cancel, output)
        raise Cancelled(text) from None
    if tail_anomaly is not None:
        # Every sweep ran; the anomaly is evidence, not a skip: the log keeps
        # the named survivors (none) beside it, then the tooling failure
        # propagates exactly as an uncontained sweep would have.
        _write_final(log, cancel, output + f'OWNED_PROCESS_SWEEP_ANOMALY: {tail_anomaly}\n')
        raise tail_anomaly
    if post_exit_bytes or feed_failures:
        _write_final(log, cancel, output)
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
    if cancel is not None and not cancel.register(process, token_value, log):
        _refused_run(cancel, process, token_value, log)
    stdout_descriptor = process.stdout.fileno()
    feed_failures = []
    if input_text is not None:
        _feed_stdin(process, input_text, feed_failures)
    returncode, parts, post_exit_bytes, group_alive, exit_ticks = _run_until_exit(process, token_value, log, timeout, cancel)
    stderr = ''.join(data for descriptor, data in parts.items() if descriptor != stdout_descriptor)
    if feed_failures:
        stderr += f'\nSTDIN_FEEDER_ERROR: {feed_failures[0]}\n'
    # The same report handoff, contained sweep pair and exit-bounded group
    # scan the merged runner uses (#381's class, #399's windows, #398 review).
    report = cancel.absorb() if cancel is not None else []
    swept, tail_anomaly = _contained_sweeps([
        lambda: terminate(token_value),
        (lambda: terminate_group(process.pid, started_before=exit_ticks, token_value=token_value))
        if group_alive else (lambda: []),
    ])
    own = cancel.claim(swept) if cancel is not None else swept
    candidates = merged_survivors(report, own)
    stopped = cancel is not None and cancel.cancelled and cancel.stopped_run
    if candidates:
        # The child's own trusted output stays in the log beside the note,
        # so an escaped or cancelled run keeps its diagnosis where the caller
        # looks, with every terminated pid named exactly once (#381's class).
        text = ''.join(parts.values()) + f'OWNED_PROCESSES: terminated {candidates}\n'
        if tail_anomaly is not None:
            text += f'OWNED_PROCESS_SWEEP_ANOMALY: {tail_anomaly}\n'
        if stopped:
            text += 'CANCELLED: the owning handle stopped this command\n'
        _write_final(log, cancel, text)
        if own:
            raise EscapedDescendants(candidates)
        if stopped:
            raise Cancelled(text) from None
        raise EscapedDescendants(candidates)
    if stopped and returncode != 0:
        text = ''.join(parts.values()) + 'CANCELLED: the owning handle stopped this command\n'
        _write_final(log, cancel, text)
        raise Cancelled(text) from None
    late = cancel.settle() if cancel is not None else []
    if late:
        stopped = stopped or (cancel is not None and cancel.cancelled and cancel.stopped_run)
        text = ''.join(parts.values()) + f'OWNED_PROCESSES: terminated {late}\n'
        if stopped:
            text += 'CANCELLED: the owning handle stopped this command\n'
        _write_final(log, cancel, text)
        raise Cancelled(text) from None
    if tail_anomaly is not None:
        _write_final(log, cancel, ''.join(parts.values()) + f'OWNED_PROCESS_SWEEP_ANOMALY: {tail_anomaly}\n')
        raise tail_anomaly
    if post_exit_bytes:
        note = (f'POST_EXIT_OUTPUT: {post_exit_bytes} byte(s) arrived after the command '
                'exited and were withheld\n')
        _write_final(log, cancel, note)
        stderr += f'\n{note}'
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
    deadline, mirroring the previous host teardown; then both ownership
    checks run, so any surviving descendant is killed and named instead of
    being adopted by init. The group scan runs with the teardown boundary
    sampled after the child is dead and the token in hand, so descendants
    forked during the teardown grace are still named while a group id the
    kernel reissued afterwards names nothing (#399). Returns once nothing
    owned is alive.
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
        boundary = _boot_ticks()
        # Both sweeps are contained, matching the runners' tails: a failing
        # token scan must never skip the group scan, so a token-scrubbed
        # same-group descendant is named and killed even when the scan
        # raises, and the anomaly surfaces only after both sweeps ran
        # (#398 review).
        survivors, sweep_anomaly = _contained_sweeps([
            lambda: terminate(token_value),
            lambda: terminate_group(process.pid, started_before=boundary, token_value=token_value),
        ])
        if process.poll() is None:
            try:
                process.wait(timeout=grace)
            except subprocess.TimeoutExpired:
                pass  # The sweeps already killed every group member and carrier.
        if survivors:
            raise EscapedDescendants(survivors)
        if sweep_anomaly is not None:
            # No survivor was found to raise instead: a sweep that could not
            # complete its scan is a tooling failure, never a clean teardown.
            raise sweep_anomaly
    finally:
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None:
                try:
                    stream.close()
                except OSError:
                    pass
