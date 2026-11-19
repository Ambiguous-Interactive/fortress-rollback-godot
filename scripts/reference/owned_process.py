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
signal meant for an owned process. Since #404, every owned launch also pins
its group leader with a pidfd from before the first wait until after the
final sweep: the pin makes the flag-4 group signal recycle-proof — the
kernel resolves the process group through the pinned struct pid, which
stays valid in every leader state — but it does not reserve the numeric
group id (the kernel frees the id for reissue when the last task link
detaches, measured across a full allocator cycle). So the numeric group
scans keep the exit boundary and the token tiebreak as their guards, while
the signal needs no gate. The known residual hole is stated plainly: a
descendant that both setsid's away and scrubs the token leaves no kernel
marker this module can see; containing that case needs cgroup-backed
ownership and remains open work in issue #411.

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
flag read and its write (#399). Post-reap ownership sweeps keep the exit
boundary for the numeric group scans — the pin makes the group signal
recycle-proof, not the number (#404) — and the tree stop stays armed in
every leader state instead of degrading after a reap. Since #408, an
'empty' group-signal outcome is never trusted blind: the first one
triggers a one-time probe that measures whether this kernel's flag-4
send stops live members through a reaped leader's pin, and a kernel
that cannot prove an emptied group fails the verdict closed instead of
reporting a clean teardown.
"""
import errno
import os
import select
import signal
import subprocess
import sys
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
# The idle grace alone cannot bound the deadline path's post-kill drain: a
# surviving carrier the sweeps could not stop keeps writing continuously, so
# every select call returns inside the idle grace and the loop never ends —
# the deadline branch then never reaches its verification sweeps, the reap
# or the TimeoutExpired raise, defeating the deadline it serves. A killed
# command's own flush is kernel-buffered and completes in milliseconds, so
# this total cap only ever engages for a live writer. Its bytes are escapee
# diagnostics: they reach the run's log text, but never the trusted output
# snapshot, so truncating them loses evidence, never the command's real
# result.
DRAIN_TOTAL_SECONDS = 2.0
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
# A pinned group signal is verified, not trusted: kernels whose flag-4
# semantics predate recycle-proof delivery accept the send without stopping
# the group, so the caller's scan must empty within this bounded poll.
GROUP_SIGNAL_VERIFY_SECONDS = 1.0
GROUP_SIGNAL_VERIFY_POLL = 0.1
# The kernel class behind an 'empty' group-signal outcome is measured once per
# process (#408): three throwaway processes (one leader, two members) and a
# bounded wait buy every later
# 'empty' verdict a proven reading instead of a kernel-ambiguous one.
KERNEL_PROBE_START_SECONDS = 5.0  # member fork plus leader exit, before the shape is broken
KERNEL_PROBE_VERIFY_SECONDS = 1.5  # the member-death observation window after the send
KERNEL_PROBE_POLL = 0.02
# The measured classes (#408). 'delivers': the flag-4 send stops a live member
# through a reaped leader's pin, so an 'empty' outcome honestly names an
# emptied group. 'spares': the send answers ESRCH beside live members or is
# accepted without stopping them, so an 'empty' outcome cannot prove anything.
# 'unknown': unmeasured or unmeasurable — verdicts keep the pre-probe behavior.
KERNEL_CLASS_DELIVERS = 'delivers'
KERNEL_CLASS_SPARES = 'spares'
KERNEL_CLASS_UNKNOWN = 'unknown'
# None reads "not probed yet"; KERNEL_CLASS_UNKNOWN reads "probed, could not
# be classified" — an unknown class is cached and never re-measured on the
# error paths; only a BaseException interrupt (which cleanup still covers)
# leaves the class unmeasured for a later attempt.
_kernel_class = None
_kernel_probe_note = None
_KERNEL_PROBE_LOCK = threading.Lock()


def _undelivered_outcome(contained, confirmed):
    """The failed-cleanup verdict for a pinned signal the kernel accepted without honoring.

    The sweep's names are attempted stops, not proof: only a scan that
    observed the group empty afterwards confirms the wording, and either way
    the breach itself stays a tooling error, because a pinned kernel that
    accepted the send without delivering it is exactly the regression the
    verification exists to catch.
    """
    if contained and confirmed:
        suffix = f'the boundary sweep stopped and named them: {contained}\n'
    else:
        suffix = 'a same-group member the bounded scans spared may survive\n'
        if contained:
            suffix = f'the boundary sweep reached: {contained}; ' + suffix[0].lower() + suffix[1:]
    return (f'OWNED_PROCESS_GROUP_SIGNAL_FAILED: the kernel accepted the pinned group signal '
            f'without stopping the members it resolved; {suffix}',
            RuntimeError('the pinned group signal did not stop the surviving group members'))


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
    """Name every live process carrying the run token, bounded and redacted.

    Each entry carries the carrier's starttime in scheduler ticks ('start'),
    the stable identity the kill-time recheck compares: a starttime survives
    execs and environment scrubs, while a recycled pid always reads a new
    one (#404 review). None means the stat line had no parsable starttime,
    and the recheck then biases toward the scan's attribution. The starttime
    is read before the environment and confirmed after it: a candidate is
    discarded only when both reads are available and differ — a pid that
    changed identity between the reads would otherwise pass the kill-time
    check under a starttime it was never scanned under (#404 review) —
    while a one-sided unreadable read keeps the candidate, matching the
    bias toward what the scan owned.
    """
    marker = (TOKEN_VARIABLE + '=' + token_value).encode('utf-8') + b'\0'
    found = []
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        if len(found) > MAX_PROCESSES:
            raise ValueError('owned process scan exceeded its process bound')
        start = _start_ticks(entry)
        try:
            environment = (entry / 'environ').read_bytes()
        except OSError:
            continue
        if marker not in environment:
            continue
        confirmed = _start_ticks(entry)
        if start is not None and confirmed is not None and confirmed != start:
            continue  # The pid changed identity between the reads: not the carrier we observed.
        found.append({'pid': int(entry.name), 'name': _name(entry), 'start': start})
    return sorted(found, key=lambda item: item['pid'])


def _start_ticks(entry):
    """One /proc entry's starttime in scheduler ticks; None when unreadable."""
    try:
        fields = (entry / 'stat').read_text().rsplit(') ', 1)[-1].split()
        return int(fields[19])
    except (OSError, IndexError, ValueError):
        return None  # A stat line without a parsable starttime is treated as ours at kill time.


def group_members(group, proc=None, started_before=None, token_value=None):
    """Name the live members of one process group; zombies are already dead.

    A grandchild that exited before its parent is a zombie until init reaps
    it, and a zombie still holds its process group open. It cannot write,
    hold a pipe or come back, so it is skipped: naming it as a terminated
    survivor would record a dead process, and counting it would fail healthy
    runs whenever reap latency exceeds the drain grace.

    A scan that runs after the owning call reaped its child can read a
    group id the kernel has reissued to an unrelated new group leader:
    the leader pin makes the flag-4 group signal recycle-proof, but the
    numeric id stays reissuable once the last group member detaches
    (#404, measured across a full allocator cycle). So every post-exit
    numeric scan passes started_before, the exit-or-teardown boundary in
    scheduler ticks since boot. Members that
    started after it are named only when they carry the run token
    (token_value), because a tokened member is ours wherever it started,
    while a tokenless one that started after our tree's death can only be
    the recycled group. Each named member carries its starttime ('start'),
    the stable identity the kill-time recheck compares: a starttime
    survives execs, group changes and environment scrubs, while a recycled
    pid always reads a new one. What remains unknowable from /proc is a
    descendant
    that forked after the boundary and scrubbed its environment before the
    scan — it is spared here, and fully containing that class needs the
    cgroup-backed ownership work in #411. The boundary also cannot reject
    a group id reissued inside the window between the last member
    detaching and the boundary sample itself: such members started at or
    before the boundary and read as ours, so a pre-boundary-window
    reissue is the remaining scan-level residual the cgroup work owns.
    A starttime that cannot be parsed
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
        try:
            started = int(fields[19])
        except (IndexError, ValueError):
            started = None  # A stat line without a parsable starttime is treated as ours below.
        if started_before is not None:
            if started is not None and started > started_before + START_TICK_SLACK:
                if marker is None or not _carries_token(entry, marker):
                    continue  # Started after the boundary without our token: a reissued group.
        found.append({'pid': int(entry.name), 'name': _name(entry), 'start': started})
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


def _send_kill(pid, belongs=None):
    """SIGKILL one pinned pid; the pidfd keeps the signal off a recycled pid.

    belongs re-checks the scan's attribution through /proc after the pidfd is
    pinned: a scan that observed pid P can only lose that pid to a recycle
    before the signal call, and a mismatched identity means the scan's
    attribution is stale — the process is skipped instead of receiving a
    signal meant for an owned tree (#404). Unreadable identity state keeps
    the kill: naming and killing bias toward what the scan owned. None keeps
    the unconditional kill for callers that bounded the scan themselves. A
    pidfd_open that raises ESRCH means the scanned process is verifiably
    gone between the scan and the open — nothing is killed (a numeric kill
    there could reach a pid recycled inside that window, #404 review) and
    the carrier stays named as self-terminated. Any other open failure, or
    no pidfd support at all, keeps the biased numeric kill, which carries
    the same documented recycle race as the pinless path.
    """
    try:
        descriptor = os.pidfd_open(pid)
    except AttributeError:
        descriptor = None  # No pidfd support at all: the gated numeric kill below decides.
    except OSError as error:
        if error.errno == errno.ESRCH:
            return True  # Verifiably gone between the scan and the open: nothing to kill; keep it named.
        descriptor = None  # A transient open failure keeps the biased numeric kill, with the documented race.
    if descriptor is None:
        if belongs is not None and not belongs(pid):
            return False
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        return True
    try:
        if belongs is not None and not belongs(pid):
            return False  # Stale attribution: the pinned process is not the one the scan owned.
        signal.pidfd_send_signal(descriptor, signal.SIGKILL)
    except (AttributeError, OSError):
        pass
    finally:
        os.close(descriptor)
    return True


def _identity_check(start, proc=None):
    """A kill-time recheck that the pid is still the process the scan owned (#404 review).

    The scan captured each pid's starttime; a matching starttime after the
    pidfd is pinned proves the same process — it survives execs, process
    group changes and environment scrubs — while a recycled pid reads a
    different one. The signal goes through the pin opened at kill time, so
    a recycle after the pin can never receive it; the residual sliver is
    the microseconds between the /proc read and the pin where a recycle
    could land in the same scheduler tick as the scanned process's own
    start, which no /proc-scanning design can distinguish and the
    cgroup-backed ownership work in #411 owns. An unreadable starttime at
    either end biases toward the scan's attribution: naming and killing
    bias toward what the scan owned, never toward stranding a live carrier.
    """
    root = proc if proc is not None else Path('/proc')

    def belongs(pid):
        if start is None:
            return True  # The scan could not read a starttime; keep the kill.
        try:
            current = (root / str(pid) / 'stat').read_text().rsplit(') ', 1)[-1].split()
            return bool(current) and int(current[19]) == start
        except (OSError, IndexError, ValueError):
            return True  # Unreadable stat: bias toward the scan's attribution.
    return belongs


def _strip_starts(members):
    """Project scanned entries back to the pid+name shape callers store."""
    return [{'pid': item['pid'], 'name': item['name']} for item in members]


def terminate(token_value):
    """Kill every live token carrier and return their terminal identities."""
    survivors = identities(token_value)
    belongs = {_item['pid']: _identity_check(_item['start']) for _item in survivors}
    named = [item for item in survivors if _send_kill(item['pid'], belongs[item['pid']])]
    return _strip_starts(named)


def terminate_group(group, proc=None, started_before=None, token_value=None):
    """Kill every live member of one process group and return their identities.

    started_before bounds the scan on every post-exit caller, the way
    group_members does: a post-reap caller passes the owned tree's
    exit-or-teardown boundary and its token, so a recycled group id names
    nothing it does not own. Kills re-verify each member's scan-captured
    starttime after pinning it, so a member that died and lost its pid
    between the scan and the kill cannot hand the signal to a recycled
    pid — a starttime survives execs, group changes and environment
    scrubs; a recycled pid always reads a new one (#404 review).
    """
    members = group_members(group, proc=proc, started_before=started_before, token_value=token_value)
    belongs = {_item['pid']: _identity_check(_item['start'], proc) for _item in members}
    named = [item for item in members if _send_kill(item['pid'], belongs[item['pid']])]
    return _strip_starts(named)


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


def _pin_leader(process):
    """Open the group leader's pidfd before anything can reap or fork it (#404).

    The pin makes the flag-4 group signal recycle-proof: the kernel keeps
    the pinned struct pid — the process group's id object — valid in every
    leader state, so signaling through it resolves only the true group. It
    does not reserve the numeric id (freed for reissue when the last group
    member detaches), which is why the numeric scans keep their boundary.
    None means the platform offers no pidfd support, and the numeric
    fallbacks keep the boundary-gated scans and poll guards.
    """
    try:
        return os.pidfd_open(process.pid)
    except (AttributeError, OSError):
        return None  # Without pidfd support the boundary-gated scans decide below.


def _close_pin(pinned):
    """Release a leader pin; a failing close is already the released state."""
    if pinned is None:
        return
    try:
        os.close(pinned)
    except OSError:
        pass  # An already-closed pin is the state every probe reads as released.


def _post_exit_group_sweep(group, boundary, token_value):
    """One post-exit group scan, bounded by the exit boundary (#404).

    The pin does not reserve the numeric group id — it is reissuable once
    the last group member detaches, with or without a held pin (measured
    across a full allocator cycle) — so the scan stays bounded by the
    child's exit boundary with the token tiebreak in every case. The
    pin's contribution is the recycle-proof flag-4 group signal beside
    this scan and the pinned per-pid kills.
    """
    return terminate_group(group, started_before=boundary, token_value=token_value)


def _signal_group(process, pinned):
    """SIGKILL one owned process group through its pinned leader when possible.

    The flag-4 group signal stays valid through a zombie and a reaped leader
    on the pinned kernels: the kernel resolves the group through the pinned
    struct pid, whose object the pin keeps valid (#404). Kernels whose
    flag-4 semantics predate that delivery accept the same call without
    stopping the group — the send cannot be trusted as proof of a stop, so
    every caller that claims a cleanup verifies it (see
    ``_tail_group_signal`` and ``_terminate_tree``). With a pin, this is
    the only group signal: a failed attempt never degrades to a numeric
    killpg, because the child can exit and be reaped by its owner between
    the liveness check and the call, and a post-reap killpg by number could
    reach a recycled group (#404 review) — the per-pid sweeps beside it
    already stop every member through recycle-proof scan pins. Without
    pidfd support at all, the numeric kill stays gated on an unreaped
    child, whose id is still reserved by the zombie or the live members.
    Returns the outcome: 'delivered' (a signal landed on the group),
    'empty' (ESRCH — an honestly emptied group on a delivering kernel, or
    an ambiguous answer beside live members on a mid-band one; the tail
    classifies before trusting it, see ``_empty_outcome_verdict``),
    or 'failed' (unsupported here or the call failed — the caller must
    never claim a termination that did not happen).
    """
    if pinned is not None:
        try:
            # PIDFD_SIGNAL_PROCESS_GROUP (4): signal the whole process group
            # behind the pinned leader. Value 1 would signal only the
            # leader's own thread group and leave same-group descendants to
            # the sweeps.
            signal.pidfd_send_signal(pinned, signal.SIGKILL, None, 4)
            return 'delivered'
        except OSError as error:
            if error.errno == errno.ESRCH:
                return 'empty'
            return 'failed'
        except AttributeError:
            return 'failed'
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
            return 'delivered'
        except OSError as error:
            return 'empty' if error.errno == errno.ESRCH else 'failed'
    return 'empty'


def _tail_group_signal(process, pinned, group_alive, verify=None, contain=None, boundary=None):
    """One tail cleanup pass: stop what the bounded scans had to spare.

    The post-exit group scan spares a tokenless member that forked after
    the boundary; while the run's leader pin is still open, the flag-4
    group signal stops that class recycle-proof. Runs whenever members
    existed at the child's exit — with named escapees or without, because
    the spared member is exactly the one the scans cannot name. Returns
    (note, error): a delivered signal produces the group-signal note; an
    emptied group is classified before it is trusted (#408) — on a kernel
    the one-time probe measured as delivering, it stays the ESRCH no-op
    that leaves the exit clean, on a mid-band kernel it reads as the
    may-survive failure, and an unmeasurable kernel keeps the pre-probe
    clean verdict with the probe's named note; a failed
    or unsupported signal produces the failed-cleanup note and an error,
    so the tail never reports a clean teardown while a spared member may
    survive (#404 review). A pinless platform has no flag-4 capability at
    all and keeps main's behavior — the spared member survives unnamed,
    which is why `(None, None)` there is honest: the boundary-guard
    residual this whole design narrows is #411's to close.

    ``verify`` is a callable receiving one starttime boundary (scheduler
    ticks since boot, sampled immediately before the send) and returning
    the live members of the group the signal was meant to stop. Kernels
    whose flag-4 semantics predate recycle-proof delivery accept the send
    through a reaped leader's pin without stopping anyone — a 2026-11-19
    Gate runner measured exactly that shape while kernel 6.12.76 delivered
    — so a claimed cleanup is measured, not trusted: the scan must empty
    within a bounded poll or the tail reports the failed-cleanup note and
    error. The boundary names every member alive at the send (the spared
    class all started before it), and the caller's token union keeps the
    window honest in both directions: a member forked between the boundary
    sample and the send carries the run token and is named by the token
    branch, while a group the kernel reissued after the send holds only
    tokenless members started after the boundary, which stay excluded.
    Only a descendant that both forked in that window and scrubbed its
    environment escapes the scan — the same scrubbing residual the cgroup
    work in #411 owns everywhere else.

    That token-union rule leans on the send actually resolving the group.
    When the outcome is ``'empty'`` — the kernel resolved nothing at the
    send, which on the mid-band kernels happens beside live members, but
    on a healthy kernel also happens when the group truly emptied — the
    numeric id may already have been reissued to a foreign group whose
    members started after the exit boundary, so the later send boundary
    must not admit tokenless strangers: the scan then keeps the caller's
    original exit boundary (``boundary``), staying with the members the
    exit scans already owned plus the run token, and a spared tokenless
    member it cannot see reads as the honest may-survive failure. Only a
    delivered outcome proves the kernel resolved this group at the send,
    which is what makes the later send boundary safe there.
    ``contain`` is a callable with the same boundary argument that stops and
    names the survivors the scan keeps finding — one send-boundary sweep with
    the same token union the caller's verify uses. The grace comes first:
    SIGKILL delivery is only visible after the member is scheduled, so a
    member that dies within the verify window keeps the delivered verdict
    and containment never runs. Only a member that survives the whole
    window is contained, and the scan must then confirm the group empty —
    the sweep's names are attempted stops, not proof, so unconfirmed
    containment keeps the may-survive wording — while the breach itself
    reports as the failed-cleanup error either way, because the pinned
    signal did not do what the pinned kernels deliver and a regression
    there must stay visible even when the sweep contained it. With no
    contain callable the expiry keeps the original may-survive wording.
    """
    if not group_alive or pinned is None:
        return None, None
    send_boundary = _boot_ticks()
    outcome = _signal_group(process, pinned)
    # The scan boundary the verification and containment use: the send-time
    # boundary only after a delivered outcome proved the kernel resolved this
    # group at the send; an emptied group keeps the caller's exit boundary,
    # because a reissued foreign group can hold members started after the
    # exit that the later send boundary would wrongly admit.
    scan_boundary = send_boundary if outcome == 'delivered' else boundary
    contained = None
    confirmed = False
    grace_expired = False
    if outcome in ('delivered', 'empty') and verify is not None:
        # The grace: SIGKILL delivery waits for the member to be scheduled,
        # so the scan polls the whole window before anything else reacts.
        deadline = time.monotonic() + GROUP_SIGNAL_VERIFY_SECONDS
        while True:
            try:
                remaining = verify(scan_boundary)
            except OSError:
                remaining = [object()]  # An unreadable scan is not evidence of a stop.
            if not remaining:
                confirmed = True
                break
            if time.monotonic() >= deadline:
                grace_expired = True
                break
            time.sleep(GROUP_SIGNAL_VERIFY_POLL)
        if not confirmed and contain is not None:
            # The accepted signal did not stop these members: one send-boundary
            # sweep stops and names them, then the scan confirms the outcome.
            try:
                contained = contain(scan_boundary)
            except OSError:
                contained = None  # The failure verdict continues without the sweep.
            deadline = time.monotonic() + GROUP_SIGNAL_VERIFY_SECONDS
            while not confirmed:
                try:
                    remaining = verify(send_boundary)
                except OSError:
                    remaining = [object()]
                if not remaining:
                    confirmed = True
                    break
                if time.monotonic() >= deadline:
                    break
                time.sleep(GROUP_SIGNAL_VERIFY_POLL)
        if contained:
            # The sweep's names travel with the verdict; confirmation only
            # decides whether the wording may claim a completed stop.
            return _undelivered_outcome(contained, confirmed)
        if not confirmed or grace_expired:
            # An expired grace is a measured fact: the group stayed non-empty
            # a full window past an accepted send, and a member that exits
            # just before the sweep does not turn that into a delivered
            # signal. Without containment, the members may still be running.
            return _undelivered_outcome(contained, confirmed)
    if outcome == 'delivered':
        return ('OWNED_PROCESS_GROUP_SIGNAL: the pinned group signal stopped members the bounded scans had to spare\n',
                None)
    if outcome == 'empty':
        return _empty_outcome_verdict()
    return ('OWNED_PROCESS_GROUP_SIGNAL_FAILED: the pinned group signal could not run; '
            'a same-group member the bounded scans spared may survive\n',
            RuntimeError('the pinned group signal failed; a spared same-group member may survive'))


class _ProbeShape(Exception):
    """A probe step could not arrange the measured shape; its message names which (#408)."""


_PROBE_LEADER_CODE = (
    'import os, time\n'
    'first = os.fork()\n'
    'if first == 0:\n'
    '    time.sleep(120)\n'
    '    os._exit(0)\n'  # a first child cleanup failed to stop never forks a second sleeper
    'second = os.fork()\n'
    'if second == 0:\n'
    '    time.sleep(120)\n'
    '    os._exit(0)\n'
    'os._exit(0)\n'  # the leader exits at once, leaving both same-group members behind
)


def _probe_member_alive(member_pid, member_pin, member_start, proc=None):
    """Whether the pinned probe member is still a live task (#408).

    The sig-0 send through the member's own pin is recycle-proof: ESRCH
    names a fully terminated task even though the held pin still references
    its struct pid, and a missing stat entry is the other observation read
    as termination — those two are the only errors that report a death,
    because a success can still hide a stop: a zombie cannot run and come
    back, and a recycled pid reads a different starttime, so the /proc
    state decides (zombie, exit state or a missing entry is dead, a changed
    starttime is a recycled pid, dead, and an unreadable starttime biases
    toward alive, which can only keep the probe waiting, never fake a
    death). Every other read error propagates: a failed observation is
    never evidence of a death. The sig-0 success also proves the pid cannot
    be recycled while it is read: the original task still holds it.
    """
    try:
        signal.pidfd_send_signal(member_pin, 0)
    except ProcessLookupError:
        return False
    root = proc if proc is not None else Path('/proc')
    try:
        fields = (root / str(member_pid) / 'stat').read_text().rsplit(') ', 1)[-1].split()
    except FileNotFoundError:
        return False  # Gone between the sig-0 probe and the read: it was dying.
    if not fields or fields[0] in ('Z', 'X'):
        return False
    try:
        return member_start is None or int(fields[19]) == member_start
    except (IndexError, ValueError):
        return True


def _measure_group_signal_kernel():
    """Measure the flag-4 delivery class against one throwaway tree (#408).

    The shape is the ambiguous one the 2026-11-19 Gate runner measured: the
    spawn-time leader pin is the only reference left to a leader that forked
    two same-group members and exited, and both members are alive when the
    flag-4 send resolves the pin. What the kernel answers beside those
    members is the class. One observed death cannot establish that the send
    caused it — an external kill (an OOM event on a pressured runner) could
    stop one sleeper inside the observation window and a kernel that
    accepted the send without stopping anyone would read as delivering — so
    causation is structural: the send must stop **both** members within the
    bounded window to classify ``KERNEL_CLASS_DELIVERS`` (two independent
    external kills in one window is the residue, not one); any member
    surviving a delivered or ESRCH send makes every outcome unprovable and
    reads ``KERNEL_CLASS_SPARES``; an ESRCH beside dead members is the
    contradictory shape (the send resolved nothing, so it caused nothing)
    and reads ``KERNEL_CLASS_UNKNOWN``. A send the kernel rejects outright,
    a shape that cannot be arranged (a missing member, a leader that will
    not exit, a member dead before the send, a missing leader pin, a member
    whose starttime the scan could not read, or a pin whose stat entry could
    not be verified against that scan — the identity guard must bind every
    pin before anything is signaled) or any probe error reads
    ``KERNEL_CLASS_UNKNOWN`` with a
    named note: verdicts keep the pre-probe behavior there, and a rejecting
    kernel never reaches the ambiguous verdict with a pin anyway — its
    sends fail closed already.

    The probe never raises; it returns ``(classification, note)`` with a
    None note exactly for a measured class. Its own processes go through the
    owned spawn/finish surface, never the runners, because a runner-shaped
    probe would recurse into the very tail that is asking. Cleanup stops
    every surviving member through its own pin — recycle-proof, no numeric
    race, fired only behind a verified identity — waits out each kill's
    scheduling grace while the pin is still open so mid-death members are
    never named as survivors, and then finish() runs the token and group
    sweeps that verify the tree is gone and release the leader pin; the
    members carry the run token in their forked environment, so a pin kill
    that could not run is still named and stopped by the token sweep. A
    cleanup that cannot prove an empty tree downgrades any verdict to
    ``KERNEL_CLASS_UNKNOWN`` with the failure named, because the verdict
    machine must never rest on a probe that leaked its own processes. An
    liveness observation error other than a termination (ESRCH, a missing
    entry) propagates out of the measurement and reads
    ``KERNEL_CLASS_UNKNOWN`` with the error named: a failed read is never
    evidence of a death, so a kernel can never be classified from an
    observation it did not complete.
    """
    verdict = {'class': KERNEL_CLASS_UNKNOWN, 'note': None}
    process = None
    token_value = None
    members = []  # {'pid', 'start', 'pin'} — each pin opens only behind a verified identity
    try:
        if not hasattr(os, 'pidfd_open') or not hasattr(signal, 'pidfd_send_signal'):
            raise _ProbeShape('no pidfd support; nothing to measure')
        process, token_value = spawn([sys.executable, '-c', _PROBE_LEADER_CODE],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if process.owned_pin is None:
            raise _ProbeShape('the probe leader could not be pinned')
        deadline = time.monotonic() + KERNEL_PROBE_START_SECONDS
        while time.monotonic() < deadline:
            known = {member['pid'] for member in members}
            for entry in group_members(process.pid):
                if entry['pid'] != process.pid and entry['pid'] not in known:
                    members.append({'pid': entry['pid'], 'start': entry['start'], 'pin': None})
            if len(members) == 2 and process.poll() is not None:
                break
            time.sleep(KERNEL_PROBE_POLL)
        if len(members) < 2:
            raise _ProbeShape(f'only {len(members)} of the two probe members forked')
        if process.poll() is None:
            raise _ProbeShape('the probe leader would not exit')
        for member in members:
            if member['start'] is None:
                # The identity guard needs the scan's starttime: without it a
                # recycled pid cannot be told from the scanned member, and
                # the cleanup pin kill could reach an unrelated process. The
                # shape is refused before any pin exists; finish()'s token
                # sweep, the recycle-safe killer, still covers the real
                # members below.
                raise _ProbeShape('the scan could not read a member starttime')
        for member in members:
            member['pin'] = os.pidfd_open(member['pid'])
            try:
                pinned_fields = (Path('/proc') / str(member['pid']) / 'stat').read_text().rsplit(') ', 1)[-1].split()
                pinned_start = int(pinned_fields[19]) if len(pinned_fields) > 19 else None
            except (OSError, IndexError, ValueError):
                pinned_start = None
            if pinned_start != member['start']:
                # The pinned task's identity could not be verified against
                # the scan — its stat entry is missing, unreadable or
                # malformed, or a recycled pid reads a different starttime.
                # The pin is never accepted, and nothing is signaled from a
                # pin the scan could not bind.
                raise _ProbeShape('a probe pin could not be verified against the scan')
        deadline = time.monotonic() + KERNEL_PROBE_VERIFY_SECONDS
        while any(not _probe_member_alive(member['pid'], member['pin'], member['start'])
                  for member in members) and time.monotonic() < deadline:
            time.sleep(KERNEL_PROBE_POLL)
        if any(not _probe_member_alive(member['pid'], member['pin'], member['start'])
               for member in members):
            raise _ProbeShape('a probe member died before the send')
        outcome = _signal_group(process, process.owned_pin)
        all_dead = False
        deadline = time.monotonic() + KERNEL_PROBE_VERIFY_SECONDS
        while time.monotonic() < deadline:
            if all(not _probe_member_alive(member['pid'], member['pin'], member['start'])
                   for member in members):
                all_dead = True
                break
            time.sleep(KERNEL_PROBE_POLL)
        if outcome == 'delivered':
            # Both members stopping together is the send's work: a healthy
            # kernel delivers to the whole group. One survivor beside a
            # delivered send — an external kill that stopped only its
            # sibling, or the accepted-but-not-stopping mid-band shape —
            # leaves the outcome unprovable, and unprovable reads spares.
            verdict['class'] = KERNEL_CLASS_DELIVERS if all_dead else KERNEL_CLASS_SPARES
            verdict['note'] = None
        elif outcome == 'empty':
            if all_dead:
                # ESRCH resolves nothing, so the send cannot have caused the
                # deaths: the shape says nothing about this kernel's delivery.
                raise _ProbeShape('the send answered ESRCH and the members died anyway')
            # ESRCH beside live members: the measured mid-band shape.
            verdict['class'] = KERNEL_CLASS_SPARES
            verdict['note'] = None
        else:
            raise _ProbeShape('the kernel rejected the flag-4 send')
    except _ProbeShape as shape:
        verdict['class'], verdict['note'] = KERNEL_CLASS_UNKNOWN, str(shape)
    except Exception as error:
        verdict['class'], verdict['note'] = KERNEL_CLASS_UNKNOWN, f'{error.__class__.__name__}: {error}'
    finally:
        # Finalization runs under every exit, including a BaseException
        # interrupt landing inside a kill's wait: the interrupt is recorded,
        # the remaining teardown still closes every pin and verifies the
        # tree through finish()'s recycle-safe sweeps, and only then does it
        # propagate — the cache stays unset for a later attempt, and the
        # throwaway tree never leaks.
        interrupt = None
        try:
            for member in members:
                if member['pin'] is None or member['start'] is None:
                    # No pin, or no verified identity to bind it: nothing
                    # may be signaled — finish()'s recycle-safe token sweep
                    # stops the real member instead.
                    continue
                try:
                    if _probe_member_alive(member['pid'], member['pin'], member['start']):
                        signal.pidfd_send_signal(member['pin'], signal.SIGKILL)
                        # The kill is not delivery: wait out the scheduling grace
                        # before finish() scans, so a mid-death member is not
                        # named as a survivor and the measured verdict is not
                        # replaced by a cleanup downgrade. A member that survives
                        # the whole window still reaches finish(), which names
                        # and stops it and triggers the honest downgrade.
                        deadline = time.monotonic() + KERNEL_PROBE_VERIFY_SECONDS
                        while _probe_member_alive(member['pid'], member['pin'], member['start']) \
                                and time.monotonic() < deadline:
                            time.sleep(KERNEL_PROBE_POLL)
                except (AttributeError, OSError):
                    pass  # finish()'s token sweep below still names and stops the carrier.
        except BaseException as caught:
            interrupt = caught
        for member in members:
            if member['pin'] is not None:
                try:
                    os.close(member['pin'])
                except OSError:
                    pass
        try:
            if process is not None:
                try:
                    finish(process, token_value)
                except Exception as error:
                    verdict['class'] = KERNEL_CLASS_UNKNOWN
                    verdict['note'] = (f'the probe cleanup could not verify an empty tree: '
                                       f'{error.__class__.__name__}: {error}')
        except BaseException as caught:
            interrupt = interrupt or caught
        if interrupt is not None:
            raise interrupt
    return verdict['class'], verdict['note']


def _group_signal_kernel_class():
    """The kernel's measured flag-4 class, probed once per process (#408).

    Concurrent tails share one probe: the lock admits the first 'empty'
    verdict's classification and every later reader takes the cached answer,
    so a wave of owned runs pays the three-process cost once — the first
    verifier blocks for one probe's bounded worst case, about
    KERNEL_PROBE_START_SECONDS for the fork plus one KERNEL_PROBE_VERIFY_
    SECONDS window before the send, one after it, and one cleanup grace per
    surviving member, before finish()'s sweeps; the cached note travels
    beside a cached 'unknown' so every fallback verdict names why it is
    unclassified.
    """
    global _kernel_class, _kernel_probe_note
    if _kernel_class is not None:
        return _kernel_class
    with _KERNEL_PROBE_LOCK:
        if _kernel_class is not None:
            return _kernel_class
        measured_class, measured_note = _measure_group_signal_kernel()
        # The note lands first: a reader that sees the class never reads a
        # stale note beside it.
        _kernel_probe_note = measured_note
        _kernel_class = measured_class
        return _kernel_class


def _empty_outcome_verdict():
    """The tail's verdict for an 'empty' group-signal outcome, after classification (#408).

    The ESRCH answer is kernel-ambiguous: on a kernel whose flag-4 semantics
    predate recycle-proof delivery it happens beside live members, while on
    a delivering kernel it honestly names an emptied group. The one-time
    probe decides which kernel is running before this verdict lands.
    'delivers' keeps the clean no-op the verdict has always been. 'spares' —
    a measured mid-band kernel — fails the verdict closed, because a spared
    tokenless member is exactly the shape this send exists to stop and the
    kernel cannot prove there is none. 'unknown' falls back to the pre-probe
    clean verdict with the probe's named note, never claiming a
    classification it does not have.
    """
    kernel_class = _group_signal_kernel_class()
    if kernel_class == KERNEL_CLASS_DELIVERS:
        return None, None
    if kernel_class == KERNEL_CLASS_SPARES:
        return ('OWNED_PROCESS_GROUP_SIGNAL_FAILED: this kernel\'s flag-4 send is not recycle-proof delivery '
                '(it answers ESRCH beside live members or is accepted without stopping them), so the '
                'emptied-group outcome cannot prove the scans spared nothing; '
                'a same-group member the bounded scans spared may survive\n',
                RuntimeError('the pinned group signal reported an emptied group on a kernel that cannot prove it'))
    note = _kernel_probe_note or 'the kernel class was not measured'
    return (f'OWNED_PROCESS_KERNEL_PROBE_FAILED: {note}; the emptied-group verdict keeps the may-survive residual\n',
            None)


def _terminate_tree(process, token_value, pinned=None, boundary=None):
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
    The group kill goes through the caller's held leader pin (#404): the
    flag-4 signal stays recycle-proof in every leader state, and the
    numeric fallback stays gated on an unreaped child. Callers whose
    handler can run after a reap without a pin pass an entry-tick
    boundary that bounds the numeric scans (see the interrupt path).
    The group scans here are otherwise unbounded, matching their callers:
    they run while the child
    is unreaped (deadline, interrupt, refusal, abandonment — its id is
    still reserved by the zombie or by the live members), or through a
    cancel whose tree still has live members holding the group open. The
    same trade as main, stated plainly: a recycled group forming after the
    last member died and before a scan reads the numeric id could be
    misnamed, and the pin cannot close that class — the cgroup-backed
    ownership work in #411 owns it.
    Merging the passes keeps every pid named exactly once (#381's class).
    """
    named = []
    for sweep in (lambda: terminate_group(process.pid, started_before=boundary), lambda: terminate(token_value)):
        try:
            named = merged_survivors(named, sweep())
        except Exception:
            continue  # The kill and the second sweep still run and name what remains.
    send_boundary = _boot_ticks() if pinned is not None else None
    signal_outcome = _signal_group(process, pinned)
    anomaly = None
    try:
        named = merged_survivors(named, terminate_group(process.pid, started_before=boundary))
    except Exception as error:
        anomaly = error  # The final token sweep still runs before the anomaly resurfaces.
    try:
        named = merged_survivors(named, terminate(token_value))
    except Exception as error:
        anomaly = anomaly or error  # Every sweep ran; the first anomaly is the one reported.
    if pinned is not None and signal_outcome in ('delivered', 'empty'):
        # The kernel accepted the pinned signal, and kernels whose flag-4
        # semantics predate recycle-proof delivery can leave the class the
        # bounded scans spared. One boundary sweep stops and names them: a
        # delivered outcome proves the kernel resolved this group at the
        # send, so the send boundary admits the members alive at the send;
        # an emptied group keeps the caller's exit boundary, because a
        # reissued foreign group can hold members started after the exit
        # that the later send boundary would wrongly admit. The child is
        # unreaped here, so the numeric id is still reserved.
        try:
            named = merged_survivors(named, terminate_group(process.pid, token_value=token_value,
                                                            started_before=send_boundary if signal_outcome == 'delivered' else boundary))
        except Exception as error:
            anomaly = anomaly or error
    if signal_outcome == 'failed' and anomaly is None:
        # A failed pinned group signal during the tree stop is a tooling
        # failure, never a clean teardown: a same-group member born after the
        # final scan survives it unnamed (#404 review).
        anomaly = RuntimeError('the pinned group signal failed during tree termination')
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


class _Registration:
    """One successful registration's unique identity.

    Log objects are not identity enough — two runs may share one sink — and
    process objects die at unregister, so the owning call's defensive settle
    compares against the handle's current registration identity instead,
    under the same lock hold as the drain (#403 review).
    """


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
    on (#399). The registration holds the leader's pidfd, so even a cancel
    landing after the owning call reaped its child keeps the whole tree
    stop armed: the flag-4 group signal through the open pin resolves the
    true group in every leader state, and the scans lean on live members
    holding the group open (#404). A second cancel is refused because two
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
        self._registration = None
        self._exit_boundary = None
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
        through emit(), where this handle appends its own sightings when a
        cancel lands after that write closed the handoff, and where the
        owning call's post-settle notes land through write_final().
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
            # The once-only registry serves one run's cancel-versus-owner
            # pair; a later run on this handle must name its own pids, even
            # when one recycled an earlier run's named id (#403 re-review).
            self._named = set()
            self._closed = False
            self._reporting = True
            self._registration = _Registration()
            self._exit_boundary = None  # A later run publishes its own exit boundary.
            return self._registration

    def publish_exit_boundary(self, ticks):
        """Publish the owning call's exit-observation boundary for a later cancel.

        A cancel that lands after the owning call reaped its child cannot
        sample an exit boundary itself — /proc no longer holds the leader —
        and its numeric group scans then lean on live members holding the
        group open. The owning call publishes the tick it observed the exit
        at, and the cancel bounds those scans with it, so a group id the
        kernel reissued names nothing (#404 review). Unpublished paths (a
        deadline or interrupt with no observed exit) keep the documented
        unbounded trade.
        """
        with self._lock:
            self._exit_boundary = ticks

    def refusal_reason(self):
        """Why the last register refusal happened, read under the lock."""
        with self._lock:
            if self._cancelled:
                return 'this handle already cancelled its run'
            if self._reporting:
                return ("this handle is still publishing another run's report")
            return 'this handle already pins another concurrent run'

    def settle_if_owned(self, registration):
        """Settle only while the open phase still belongs to this registration.

        The ownership check and the drain happen under one lock hold, so a
        run registering in the gap cannot have its phase closed or its
        pending report drained by this run's cleanup (#403 review).
        """
        with self._lock:
            if self._registration is not registration:
                return []
            report, self._report = self._report, []
            self._closed = True
            self._reporting = False
            return report

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
            except OSError:
                # A failed write must not swallow the report it drained: put
                # it back so the run's defensive settle still appends the
                # names instead of losing them with the sink (#403 review).
                with self._lock:
                    self._report = merged_survivors(self._report, report)
                raise
            finally:
                with self._lock:
                    self._reporting = False
        return text

    def write_final(self, log, text):
        """Write one owning run's note to the log the caller owns, after its handoff closed.

        The target is passed by the owning call — its own registration log —
        never read from the handle, whose registration a later run may
        already own. The report stream is untouched: a report published for
        the next run stays its reader's. The log lock serializes the
        truncate write against the cancel-side append door on the same file.
        Like emit(), a sink failure propagates: the caller's outcome path
        owns the decision.
        """
        with self._log_lock:
            if text and log is not None:
                log.write_text(text)
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
            # The owning call's exit boundary rides with the flip: the cancel
            # bounds its post-reap numeric scans with the tick the owning call
            # observed the exit at (#404 review).
            boundary = self._exit_boundary
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
                # A cancel flipping before the owning call observed an exit
                # reads no boundary — and at that point the child is alive or
                # an unreaped zombie, whose id the zombie still reserves, so
                # no recycled group can hold the numeric id yet. Sampling the
                # entry tick unconditionally then bounds both scans for the
                # whole cleanup: a group id the owner's later reap frees and
                # reissues names nothing, because its members started after
                # the sampled tick (#404 review). The one corner that stays
                # unbounded by construction: a cancel that stops the tree
                # itself frees the group id during its own kill sequence, so
                # no valid boundary exists for the scans that straddle it —
                # that residual is `_terminate_tree`'s documented trade, and
                # the cgroup-backed identity work in #411 owns the mechanism
                # that closes it.
                if boundary is None and pinned is not None:
                    # A cancel flipping before the owning call observed an exit
                    # reads no boundary — and at that point the child is alive
                    # or gone, one sample either way (#399 review).
                    boundary = _boot_ticks()
                if pinned is not None or process.poll() is None:
                    candidates, stop_anomaly = _terminate_tree(process, token_value, pinned, boundary)
                    if stop_anomaly is not None:
                        # The report is published before the anomaly resurfaces,
                        # so the names the sweeps earned are never discarded.
                        fresh = self._publish(candidates)
                        raise stop_anomaly
                else:
                    candidates = terminate(token_value)
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


def _collect(process, deadline, on_exit=None):
    """Wait for the direct child while concurrently draining both pipes.

    Draining runs alongside the wait, so a command that writes more than the
    pipe capacity still finishes inside its deadline instead of blocking on a
    full pipe. Once the child has exited, one immediate read pass captures
    everything it had already written; later bytes can only come from an
    escaped descendant and are withheld from the returned output. Draining
    after exit stops at EOF or the idle grace, whichever comes first. The
    returned parts keep stdout and stderr separate so a caller that parses
    the streams differently can join them in its own order. on_exit runs at
    the exit observation with the sampled boundary tick — before the reap —
    so a cancel inherits the exit boundary the moment it exists (#404
    review).
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
            if on_exit is not None:
                on_exit(exit_ticks)
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
    """Collect whatever a killed command flushed, bounded by the idle and total graces.

    The idle grace stops a drain waiting for an EOF a surviving carrier will
    never send; the total grace stops a carrier that writes continuously, so
    the deadline path always reaches its verification sweeps, the reap and
    the TimeoutExpired raise (#398 review). Each select wait is capped by the
    remaining total budget, so a wait that starts just before the deadline
    cannot overshoot the cap by one idle grace."""
    streams = {process.stdout.fileno(): bytearray(), process.stderr.fileno(): bytearray()}
    buffers = {descriptor: bytearray() for descriptor in streams}
    total_deadline = time.monotonic() + DRAIN_TOTAL_SECONDS
    while streams:
        remaining = total_deadline - time.monotonic()
        if remaining <= 0:
            break  # The total cap: a live writer cannot hold the deadline path past this.
        if not _wait_readable(streams, min(DRAIN_IDLE_SECONDS, remaining)):
            break  # The idle grace: nothing more arrived from a killed command.
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


def _run_until_exit(process, token_value, log, timeout, cancel=None, registration=None, pinned=None):
    """Collect one owned child, owning the deadline and interruption paths.

    Both public runners share this tail: a deadline kills the group, keeps the
    partial output and records the timeout marker; an interruption must not
    strand the tree either. The handle's report is consumed through absorb(),
    the one point that waits out a started cancel and drains its sightings,
    so no survivor depends on a flag snapshot taken around the sweeps (#381's
    class, #399's windows). Every tree termination runs under the caller's
    held leader pin, whose pidfd keeps the group id referenced across the
    sweeps (#404). Returns the trusted per-stream parts and the exit
    bookkeeping, or raises with the log already written.
    """
    try:
        try:
            on_exit = cancel.publish_exit_boundary if cancel is not None else None
            returncode, parts, post_exit_bytes, group_alive, exit_ticks = _collect(process, time.monotonic() + timeout,
                                                                                   on_exit)
        except _Deadline as expired:
            # The whole deadline body releases the reservation on any exit: an
            # interrupt landing inside it must not lock the handle forever, and
            # a report published mid-body still reaches the run's own log
            # through the append door (#403 review).
            try:
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
                    fresh, sweep_anomaly = _terminate_tree(process, token_value, pinned)
                    fresh = cancel.claim(fresh)
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        pass  # The sweeps already killed every group member and carrier.
                    named = merged_survivors(report, fresh)
                    if named:
                        text += f'OWNED_PROCESSES: terminated {named}\n'
                    if sweep_anomaly is not None:
                        # Same invariant as the runners' tails: the anomaly line
                        # lands before any classified marker.
                        text += f'OWNED_PROCESS_SWEEP_ANOMALY: {sweep_anomaly}\n'
                    text += 'CANCELLED: the owning handle stopped this command\n'
                    text = cancel.emit(text)
                    if fresh:
                        raise EscapedDescendants(fresh) from None
                    raise Cancelled(text) from None
                survivors, sweep_anomaly = _terminate_tree(process, token_value, pinned)
                # The report is consumed at one point after the sweeps: a cancel
                # that was mid-sweep finishes here and its names join the report,
                # and one starting after emit() wrote this log appends its own
                # sightings to the same file (#399's timeout window).
                report = cancel.absorb() if cancel is not None else []
                own = cancel.claim(survivors) if cancel is not None else survivors
                survivors = merged_survivors(report, own)
                # The sweeps killed the tree; the reap waits for the kill
                # delivery instead of racing it with one poll: a killed child
                # must never stay a zombie of this process (#404 review).
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    pass
                text = ''.join(data.decode('utf-8', errors='replace') for data in expired.buffers.values())
                text += _drain_after_kill(process) + '\n'
                text += f'TIMEOUT: command exceeded {timeout} seconds\n'
                text += f'OWNED_PROCESSES: terminated {survivors}\n'
                if sweep_anomaly is not None:
                    text += f'OWNED_PROCESS_SWEEP_ANOMALY: {sweep_anomaly}\n'
                _write_final(log, cancel, text)
                raise subprocess.TimeoutExpired(process.args, timeout, output=text) from None
            finally:
                if cancel is not None:
                    # Idempotent on every path that already closed through
                    # emit(): a mid-body interrupt drains and appends whatever
                    # a concurrent cancel published instead of locking the
                    # handle behind the report phase. Skipped when a later run
                    # already owns the phase — its report stream is not ours.
                    _append_log(log, cancel.settle_if_owned(registration))
        except BaseException:
            # An interruption must not strand the tree either: the new session
            # never saw the terminal signal, so both ownership checks run, the
            # child is reaped, and no cleanup failure replaces the interrupt.
            try:
                named = cancel.absorb() if cancel is not None else []
                # Without a pin this handler can run after _collect already
                # reaped the child (an interrupt landing between the reap and
                # the return): the numeric group id is then reissuable, so the
                # handler bounds its scans at its own entry tick whenever the
                # child is already reaped (#404 review). Unreaped children
                # keep unbounded scans — their id cannot be recycled until a
                # owner reaps it.
                interrupt_boundary = _boot_ticks() if process.poll() is not None else None
                candidates, sweep_anomaly = _terminate_tree(process, token_value, pinned, interrupt_boundary)
                if cancel is not None:
                    candidates = merged_survivors(named, cancel.claim(candidates))
                if candidates or sweep_anomaly is not None:
                    note = f'OWNED_PROCESSES: terminated {candidates}\n' if candidates else ''
                    if sweep_anomaly is not None:
                        note += f'OWNED_PROCESS_SWEEP_ANOMALY: {sweep_anomaly}\n'
                    try:
                        # emit() drains anything published since absorb() into
                        # this write and closes the handoff under the log lock,
                        # so a concurrent cancel's append serializes after the
                        # write instead of being truncated by it (#403 review).
                        _write_final(log, cancel, note)
                    except OSError:
                        # One smaller append keeps the drained names reachable
                        # even when the full-note write failed; the handle's
                        # release below no longer depends on the sink.
                        _append_log(log, candidates)
                elif cancel is not None:
                    # No write remains: close, release, and append whatever a
                    # concurrent cancel published — draining without writing
                    # would discard it (#403 review).
                    _append_log(log, cancel.settle_if_owned(registration))
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
                    # Releases the reservation whatever happened above (emit
                    # closed already on the note path); a cleanup failure that
                    # skipped both writes still drains and appends whatever a
                    # concurrent cancel published. Skipped when a later run
                    # already owns the phase.
                    _append_log(log, cancel.settle_if_owned(registration))
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
    still closes an open handoff. Only for pre-settle contexts: after the
    handoff closed, use `_note_final` so the note targets the owning run's
    own log instead of whatever registered since.
    """
    if cancel is not None:
        return cancel.emit(text)
    if text:
        log.write_text(text)
    return text


def _note_final(log, cancel, text):
    """Write a post-settle note: the owning run's log, never the current registration.

    The handoff is closed here, so the handle's report stream belongs to
    whatever registered after the release — a drain here would steal it and
    an emit() here would write into that run's log. The target is the
    owning call's own log argument; the handle contributes only its log
    lock.
    """
    if cancel is not None:
        return cancel.write_final(log, text)
    if text:
        log.write_text(text)
    return text


def _refused_run(cancel, process, token_value, log, pinned=None):
    """Clean up a tree the handle could not pin, then refuse.

    The handle either already cancelled, already pins another concurrent
    run, or is still publishing an earlier run's report; the reason is read
    under the lock before the teardown so the message cannot be misattributed
    by a state change during the sweeps. The tree stop mirrors the deadline
    path — sweeps and kill run even when one pass raises, everything
    terminated is named, and the child is reaped — so the unpinnable tree
    strands nothing before the ValueError refuses the run. The sweeps run
    under the run's own leader pin (#404). The diagnosis
    goes to this run's own log directly: the handle's registered log belongs
    to the run it is pinning, and closing that handoff here would corrupt
    the pinned run's report flow.
    """
    refusal = cancel.refusal_reason() if cancel is not None else 'refused without a handle'
    try:
        candidates, refused_anomaly = _terminate_tree(process, token_value, pinned)
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
    raise ValueError(f'{refusal}; the started tree was cleaned up before refusing')


def _abandon_started_run(cancel, process, token_value, log, registration, pinned=None):
    """Stop a started tree whose registration can no longer be served, then release.

    A feeder failure or any escape before the runners' cleanup guards leaves
    the child running, the pin held and the report phase open: the tree is
    swept and reaped exactly like a refusal — under the run's own leader pin
    (#404) — a note lands in the run's own log, and the registration releases
    (pin included) through the ownership-checked settle — the caller
    re-raises its original exception either way.
    """
    try:
        candidates, sweep_anomaly = _terminate_tree(process, token_value, pinned)
        note = f'OWNED_PROCESS_SETUP_FAILED: {sweep_anomaly}\n' if sweep_anomaly is not None else ''
        if candidates:
            note = f'OWNED_PROCESSES: terminated {candidates}\n' + note
        if note:
            try:
                log.write_text(note)
            except OSError:
                pass  # A failing sink must not replace the original failure.
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass  # The sweeps already killed every group member and carrier.
    finally:
        if cancel is not None:
            _append_log(log, cancel.settle_if_owned(registration))
            cancel.unregister()  # the pin and its descriptor belong to the abandoned run
    process.poll()


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
    # The run's own leader pin: opened before anything can reap the child or
    # fork inside its group, released only after the run's final sweep
    # (#404). The handle's registration pin is separate — cancel() and the
    # run tail each close the pin they own.
    pinned = _pin_leader(process)
    try:
        return _run_pinned(process, token_value, pinned, log, timeout, input_text, cancel)
    finally:
        _close_pin(pinned)


def _run_pinned(process, token_value, pinned, log, timeout, input_text, cancel):
    """The merged runner's whole episode under an already-pinned leader (#404).

    run() delegates here after pinning the leader, so registration, feeding,
    the collect loop and every sweep run against the one pin opened at
    spawn: the group's numeric id cannot be reissued at any point in the
    episode (#404). run_split() shares the shape with its own tail.
    """
    registration = cancel.register(process, token_value, log) if cancel is not None else True
    if cancel is not None and not registration:
        _refused_run(cancel, process, token_value, log, pinned)
    feed_failures = []
    try:
        if input_text is not None:
            _feed_stdin(process, input_text, feed_failures)
    except BaseException:
        # A feeder failure must not strand the started tree or the handle's
        # reservation: the tree is stopped and reaped, the phase releases,
        # and the original failure propagates (#403 review).
        _abandon_started_run(cancel, process, token_value, log, registration, pinned)
        raise
    try:
        returncode, parts, post_exit_bytes, group_alive, exit_ticks = _run_until_exit(
            process, token_value, log, timeout, cancel, registration, pinned)
        # Both ownership checks always run before any escape raises: a command
        # can leave a same-group descendant and a setsid token carrier at once,
        # and reporting only the first would strand the second. The handle's
        # report is consumed through absorb() — the one point that waits out a
        # started cancel — before the sweeps, so the written report covers both
        # sides' kills and no pid is ever named twice, or named nowhere (#381's
        # class, #399's windows). The pin makes the flag-4 group signal
        # recycle-proof (#404); the numeric id stays reissuable once the
        # last member detaches, so the post-exit group scan keeps the
        # child's exit boundary and the token tiebreak as its guards in
        # every case. The whole tail — output assembly included —
        # releases the reservation on any exit: an interrupt landing here
        # must not lock the handle behind the report phase, and a report
        # published after a classified raise still reaches the run's own log
        # through the append door (#403 review).
        output = ''.join(parts.values())
        if feed_failures:
            output += f'\nSTDIN_FEEDER_ERROR: {feed_failures[0]}\n'
        if post_exit_bytes:
            output += ('\nPOST_EXIT_OUTPUT: '
                       f'{post_exit_bytes} byte(s) arrived after the command exited and were withheld\n')
        report = cancel.absorb() if cancel is not None else []
        # Both sweeps are contained: a failing token scan must not skip the group
        # scan, so a token-scrubbed same-group descendant is named and killed even
        # when the scan raises, and the anomaly surfaces only after both ran
        # (#398 review).
        swept, tail_anomaly = _contained_sweeps([
            lambda: terminate(token_value),
            (lambda: _post_exit_group_sweep(process.pid, exit_ticks, token_value))
            if group_alive else (lambda: []),
        ])
        own = cancel.claim(swept) if cancel is not None else swept
        candidates = merged_survivors(report, own)
        group_note, group_error = _tail_group_signal(
            process, pinned, group_alive, boundary=exit_ticks,
            verify=lambda started_before: group_members(process.pid, started_before=started_before,
                                                        token_value=token_value),
            contain=lambda started_before: terminate_group(process.pid, started_before=started_before,
                                                           token_value=token_value))
        if group_note:
            output += group_note
        if group_error is not None and tail_anomaly is None:
            tail_anomaly = group_error  # A failed cleanup signal is a tooling failure, never a clean exit.
        stopped = cancel is not None and cancel.cancelled and cancel.stopped_run
        if tail_anomaly is not None:
            # The anomaly line lands before any classified raise: a cancellation
            # or escape that wins this tail must not hide the tooling failure
            # behind its own marker.
            output += f'OWNED_PROCESS_SWEEP_ANOMALY: {tail_anomaly}\n'
        if candidates:
            output += f'OWNED_PROCESSES: terminated {candidates}\n'
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
            text = _note_final(log, cancel, output)
            raise Cancelled(text) from None
        if tail_anomaly is not None:
            # Every sweep ran and the anomaly line is already in `output`; no
            # classified outcome won, so the tooling failure propagates with its
            # evidence written.
            _note_final(log, cancel, output)
            raise tail_anomaly
        if post_exit_bytes or feed_failures or group_note:
            _note_final(log, cancel, output)
        return returncode, output
    finally:
        if cancel is not None:
            # Idempotent on every path that already settled or closed through
            # emit(): a mid-tail interrupt drains and appends whatever a
            # concurrent cancel published instead of locking the handle.
            # Skipped when a later run already owns the phase.
            _append_log(log, cancel.settle_if_owned(registration))


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
    pinned = _pin_leader(process)  # Same run-owned pin the merged runner opens (#404).
    try:
        return _run_split_pinned(process, token_value, pinned, log, timeout, input_text, cancel)
    finally:
        _close_pin(pinned)


def _run_split_pinned(process, token_value, pinned, log, timeout, input_text, cancel):
    """The split runner's whole episode under an already-pinned leader (#404)."""
    registration = cancel.register(process, token_value, log) if cancel is not None else True
    if cancel is not None and not registration:
        _refused_run(cancel, process, token_value, log, pinned)
    stdout_descriptor = process.stdout.fileno()
    feed_failures = []
    try:
        if input_text is not None:
            _feed_stdin(process, input_text, feed_failures)
    except BaseException:
        # A feeder failure must not strand the started tree or the handle's
        # reservation: the tree is stopped and reaped, the phase releases,
        # and the original failure propagates (#403 review).
        _abandon_started_run(cancel, process, token_value, log, registration, pinned)
        raise
    try:
        returncode, parts, post_exit_bytes, group_alive, exit_ticks = _run_until_exit(
            process, token_value, log, timeout, cancel, registration, pinned)
        # The same report handoff and contained sweep pair the merged runner
        # uses (#381's class, #399's windows, #398 review), with the same
        # exit-bounded post-exit group scan and the recycle-proof pinned
        # signal (#404). The whole tail — output assembly included — releases the reservation on
        # any exit, exactly like the merged runner's (#403 review).
        stderr = ''.join(data for descriptor, data in parts.items() if descriptor != stdout_descriptor)
        if feed_failures:
            stderr += f'\nSTDIN_FEEDER_ERROR: {feed_failures[0]}\n'
        report = cancel.absorb() if cancel is not None else []
        swept, tail_anomaly = _contained_sweeps([
            lambda: terminate(token_value),
            (lambda: _post_exit_group_sweep(process.pid, exit_ticks, token_value))
            if group_alive else (lambda: []),
        ])
        own = cancel.claim(swept) if cancel is not None else swept
        candidates = merged_survivors(report, own)
        stopped = cancel is not None and cancel.cancelled and cancel.stopped_run
        # The anomaly line lands before any classified raise: a cancellation or
        # escape that wins this tail must not hide the tooling failure behind
        # its own marker.
        anomaly_note = f'OWNED_PROCESS_SWEEP_ANOMALY: {tail_anomaly}\n' if tail_anomaly is not None else ''
        group_note, group_error = _tail_group_signal(
            process, pinned, group_alive, boundary=exit_ticks,
            verify=lambda started_before: group_members(process.pid, started_before=started_before,
                                                        token_value=token_value),
            contain=lambda started_before: terminate_group(process.pid, started_before=started_before,
                                                           token_value=token_value))
        if group_note:
            anomaly_note += group_note
        if group_error is not None and tail_anomaly is None:
            tail_anomaly = group_error  # A failed cleanup signal is a tooling failure, never a clean exit.
        if candidates:
            # The child's own trusted output stays in the log beside the note,
            # so an escaped or cancelled run keeps its diagnosis where the caller
            # looks, with every terminated pid named exactly once (#381's class).
            text = ''.join(parts.values()) + f'OWNED_PROCESSES: terminated {candidates}\n' + anomaly_note
            if stopped:
                text += 'CANCELLED: the owning handle stopped this command\n'
            _write_final(log, cancel, text)
            if own:
                raise EscapedDescendants(candidates)
            if stopped:
                raise Cancelled(text) from None
            raise EscapedDescendants(candidates)
        if stopped and returncode != 0:
            text = ''.join(parts.values()) + anomaly_note + 'CANCELLED: the owning handle stopped this command\n'
            _write_final(log, cancel, text)
            raise Cancelled(text) from None
        late = cancel.settle() if cancel is not None else []
        if late:
            stopped = stopped or (cancel is not None and cancel.cancelled and cancel.stopped_run)
            text = ''.join(parts.values()) + f'OWNED_PROCESSES: terminated {late}\n' + anomaly_note
            if stopped:
                text += 'CANCELLED: the owning handle stopped this command\n'
            _note_final(log, cancel, text)
            raise Cancelled(text) from None
        if tail_anomaly is not None:
            _note_final(log, cancel, ''.join(parts.values()) + anomaly_note)
            raise tail_anomaly
        if post_exit_bytes or group_note:
            note = ''
            if post_exit_bytes:
                note += (f'POST_EXIT_OUTPUT: {post_exit_bytes} byte(s) arrived after the command '
                         'exited and were withheld\n')
            if group_note:
                note += group_note
            _note_final(log, cancel, note)
            stderr += f'\n{note}'
        return returncode, parts[stdout_descriptor], stderr
    finally:
        if cancel is not None:
            # Idempotent on every path that already settled or closed through
            # emit(): a mid-tail interrupt drains and appends whatever a
            # concurrent cancel published instead of locking the handle.
            # Skipped when a later run already owns the phase.
            _append_log(log, cancel.settle_if_owned(registration))


def spawn(command, environment=None, stdout=None, stderr=None, cwd=None):
    """Start one caller-managed process in its own owned session.

    Long-lived companions such as a native engine host cannot go through run():
    their lifetime spans other owned commands. The caller receives the process
    and its token and must end the episode with finish(), which applies the
    same descendant-tree ownership checks run() applies to its own children.
    spawn() pins the leader immediately: the pin rides on the process object
    as ``owned_pin`` and stays open — making the flag-4 group signal
    recycle-proof for the whole episode (#404) — until finish() releases it
    after its final sweep. That pin is a kernel descriptor: a caller that
    abandons a spawned process without finish() leaks one fd per spawn, the
    same contract as abandoning the process itself.
    """
    owned = dict(environment if environment is not None else os.environ)
    token_value = uuid.uuid4().hex
    owned[TOKEN_VARIABLE] = token_value
    process = subprocess.Popen(command, cwd=cwd, env=owned, stdout=stdout, stderr=stderr, start_new_session=True)
    process.owned_pin = _pin_leader(process)
    return process, token_value


def finish(process, token_value, grace=5.0):
    """Stop one spawned process and verify its whole descendant tree is gone.

    The direct child is asked to terminate first and is killed at the grace
    deadline, mirroring the previous host teardown; then both ownership
    checks run, so any surviving descendant is killed and named instead of
    being adopted by init. The spawn-time leader pin (#404) makes the
    grace group kill recycle-proof through the flag-4 signal in every
    leader state; it does not reserve the numeric group id, so the group
    scan keeps the teardown boundary
    sampled after the child is dead and the token in hand, so descendants
    forked during the teardown grace are still named while a group id the
    kernel reissued afterwards names nothing (#399). Returns once nothing
    owned is alive and releases the spawn's pin exactly once, even if a
    caller finishes the same process twice.
    """
    pinned = getattr(process, 'owned_pin', None)
    process.owned_pin = None  # First finish owns the close: a repeated finish must not re-close the fd.
    try:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=grace)
            except subprocess.TimeoutExpired:
                if pinned is not None:
                    _signal_group(process, pinned)
                else:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except OSError:
                        process.kill()
                if process.poll() is None:
                    # The pinned group signal failed or is unsupported on
                    # this kernel, so nothing above stopped the host: the
                    # direct child is still unreaped — its id is reserved by
                    # the zombie — and a direct SIGKILL through the Popen
                    # handle is safe (#404 review).
                    process.kill()
                try:
                    process.wait(timeout=grace)
                except subprocess.TimeoutExpired:
                    pass  # The ownership sweeps below name what remains.
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
            # The escape is the stronger outcome, and the anomaly rides as its
            # cause: a caller that sees survivors must still learn the scan
            # was incomplete (#403 review).
            raise EscapedDescendants(survivors) from sweep_anomaly
        if sweep_anomaly is not None:
            # No survivor was found to raise instead: a sweep that could not
            # complete its scan is a tooling failure, never a clean teardown.
            raise sweep_anomaly
    finally:
        _close_pin(pinned)
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None:
                try:
                    stream.close()
                except OSError:
                    pass
