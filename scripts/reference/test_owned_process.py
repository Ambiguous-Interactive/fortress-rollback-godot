"""Value: a deadline or exit owns the whole descendant tree, not only the direct child."""
import errno
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from unittest import mock
import unittest

import owned_process
from run import capture

PYTHON = sys.executable


def start_token_process(token_value):
    """Start an out-of-band live process carrying one explicit token."""
    return subprocess.Popen([PYTHON, '-c', 'import time; time.sleep(60)'],
                            env={**os.environ, owned_process.TOKEN_VARIABLE: token_value},
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def terminated(pid):
    """Whether the pid exited: gone entirely, or a zombie this test cannot reap.

    A descendant whose parent died reparents to init, and a container init
    does not always reap promptly — a killed grandchild can stay a zombie
    answering kill(0). A zombie has taken SIGKILL, which is the contract
    under test; only a live process fails it. A /proc read error is never
    termination: the caller keeps probing instead of passing on a process
    that may still be alive (#403 review).
    """
    if not alive(pid):
        return True
    try:
        state = Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[-1].split()[0]
    except FileNotFoundError:
        return True  # gone from /proc: reaped between the probes
    except OSError:
        return False  # a transient read error proves nothing; keep probing
    return state == 'Z'


def escape_child(mode, marker):
    """A parent that exits as soon as its one long-lived descendant is live."""
    return f"""
import os, sys, time
pid = os.fork()
if pid == 0:
    {'os.setsid()' if mode == 'setsid' else 'pass'}
    open(sys.argv[1], 'w').write(str(os.getpid()))
    time.sleep(60)
while not os.path.exists(sys.argv[1]):
    time.sleep(0.01)
"""


class OwnedProcessTests(unittest.TestCase):
    def test_healthy_command_passes_with_output_and_without_survivors(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'healthy.log'
            log.write_text('')
            self.assertEqual(owned_process.run([PYTHON, '-c', "print('ok')"], {}, log, 10), (0, 'ok\n'))
            text = log.read_text()
            self.assertNotIn('OWNED_PROCESSES', text)
            self.assertNotIn('TIMEOUT', text)

    def test_deadline_kills_the_group_and_preserves_partial_output(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'timeout.log'
            log.write_text('')
            marker = Path(folder) / 'grandchild.pid'
            command = [PYTHON, '-c',
                       "import os, sys, time\n"
                       "pid = os.fork()\n"
                       "if pid == 0:\n    open(sys.argv[1], 'w').write(str(os.getpid()))\n    time.sleep(60)\n"
                       "print('started', flush=True)\ntime.sleep(60)",
                       str(marker)]
            with self.assertRaises(subprocess.TimeoutExpired) as raised:
                owned_process.run(command, {}, log, 2)
            self.assertIn('started', raised.exception.output)
            text = log.read_text()
            self.assertIn('TIMEOUT: command exceeded 2 seconds', text)
            # The group kill and the token sweep both terminate the tree; the
            # sweep may catch the grandchild in the SIGKILL delivery race and
            # name it, so only the bounded no-third-attempt contract is fixed.
            self.assertIn('OWNED_PROCESSES: terminated', text)
            pid = int(marker.read_text())
            deadline = time.monotonic() + 5
            while alive(pid) and time.monotonic() < deadline:
                time.sleep(0.1)
            self.assertFalse(alive(pid), 'a plain forked descendant must die with the group')

    def test_escaped_descendant_is_named_terminated_and_recorded(self):
        for mode in ('setsid', 'orphan'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as folder:
                log = Path(folder) / 'escaped.log'
                log.write_text('')
                marker = Path(folder) / 'escaped.pid'
                command = [PYTHON, '-c', escape_child(mode, marker), str(marker)]
                with self.assertRaises(owned_process.EscapedDescendants) as raised:
                    owned_process.run(command, {}, log, 10)
                pid = int(marker.read_text())
                # Both sweeps run before the escape raises. A descendant still
                # dying inside the SIGKILL delivery race is seen by both —
                # orphan mode stays in the group while carrying the run token —
                # and the merged report names that pid exactly once, which the
                # single-entry unpack below pins end to end.
                named = {item['pid'] for item in raised.exception.survivors}
                self.assertEqual(named, {pid}, 'the escaped descendant must be identified by its own pid')
                [survivor] = [item for item in raised.exception.survivors if item['pid'] == pid]
                self.assertTrue(survivor['name'], 'the escaped descendant must be named')
                text = log.read_text()
                self.assertIn(f'OWNED_PROCESSES: terminated [{{\'pid\': {pid}', text)
                deadline = time.monotonic() + 5
                while alive(pid) and time.monotonic() < deadline:
                    time.sleep(0.1)
                self.assertFalse(alive(pid), 'the after-run sweep must terminate the escaped descendant')

    def test_ownership_tokens_do_not_cross_run_boundaries(self):
        outside = start_token_process('session-171-outside')
        try:
            self.assertTrue(alive(outside.pid), 'the control only holds with a live out-of-band token carrier')
            with tempfile.TemporaryDirectory() as folder:
                log = Path(folder) / 'boundary.log'
                self.assertEqual(owned_process.run([PYTHON, '-c', "print('ok')"], {}, log, 10), (0, 'ok\n'))
            self.assertTrue(alive(outside.pid), 'a foreign token carrier must not be terminated')
        finally:
            terminated = owned_process.terminate('session-171-outside')
            [identity] = terminated
            self.assertEqual(identity['pid'], outside.pid)
            outside.wait(timeout=10)  # This test owns the process: reap the kill before checking liveness.
            self.assertFalse(alive(outside.pid))

    def test_high_volume_output_never_blocks_on_a_full_pipe(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'volume.log'
            log.write_text('')
            command = [PYTHON, '-c',
                       "import sys\ndata = 'x' * 65536 + '\\n'\n"
                       "sys.stdout.write(data * 4)\nsys.stderr.write(data)\nsys.stdout.flush()\n"
                       "print('done', flush=True)"]
            returncode, output = owned_process.run(command, {}, log, 15)
            self.assertEqual(returncode, 0)
            self.assertEqual(output.count('x' * 65536), 5, 'more than one pipe capacity must survive')
            self.assertIn('done\n', output)
            self.assertNotIn('POST_EXIT_OUTPUT', output)

    def test_environment_scrubbing_cannot_hide_a_same_session_descendant(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'scrubbed.log'
            log.write_text('')
            marker = Path(folder) / 'scrubbed.pid'
            command = [PYTHON, '-c', """
import os, sys, time
pid = os.fork()
if pid == 0:
    open(sys.argv[1], 'w').write(str(os.getpid()))
    os.execve('/bin/sleep', ['sleep', '30'], {'PATH': '/usr/bin:/bin'})
while not os.path.exists(sys.argv[1]):
    time.sleep(0.01)
""", str(marker)]
            with self.assertRaises(owned_process.EscapedDescendants) as raised:
                owned_process.run(command, {}, log, 10)
            pid = int(marker.read_text())
            self.assertEqual([item['pid'] for item in raised.exception.survivors], [pid],
                             'a scrubbed descendant must be named through its process group')
            deadline = time.monotonic() + 5
            while alive(pid) and time.monotonic() < deadline:
                time.sleep(0.1)
            self.assertFalse(alive(pid), 'the group check must terminate the scrubbed descendant')

    def test_descendant_bytes_after_exit_are_withheld_from_the_output(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'injected.log'
            log.write_text('')
            command = [PYTHON, '-c', """
import os, sys, time
pid = os.fork()
if pid == 0:
    os.setsid()
    time.sleep(0.3)
    print('test injected_case ... ok', flush=True)
print('test owned_case ... ok', flush=True)
"""]
            returncode, output = owned_process.run(command, {}, log, 10)
            self.assertEqual(returncode, 0)
            self.assertNotIn('injected_case', output.split('POST_EXIT_OUTPUT')[0],
                             'a descendant line must not enter the command output')
            self.assertIn('POST_EXIT_OUTPUT', output)
            self.assertIn('test owned_case ... ok', output)

    def test_unbounded_same_group_writer_cannot_hang_or_oom_the_sweep(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'writer.log'
            log.write_text('')
            marker = Path(folder) / 'writer.pid'
            command = [PYTHON, '-c', """
import os, sys, time
pid = os.fork()
if pid == 0:
    open(sys.argv[1], 'w').write(str(os.getpid()))
    while True:
        try:
            sys.stdout.write('y' * 65536 + '\\n')
            sys.stdout.flush()
        except OSError:
            pass
        time.sleep(0.01)
print('child exits', flush=True)
""", str(marker)]
            with self.assertRaises(owned_process.EscapedDescendants) as raised:
                owned_process.run(command, {}, log, 3)
            self.assertTrue(raised.exception.survivors, 'the writing escapee must be named and killed')
            pid = int(marker.read_text())
            self.assertIn(pid, [item['pid'] for item in raised.exception.survivors])
            deadline = time.monotonic() + 5
            while alive(pid) and time.monotonic() < deadline:
                time.sleep(0.1)
            self.assertFalse(alive(pid), 'the sweep must terminate the writing escapee')

    def test_unreaped_zombie_grandchild_is_not_a_survivor(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'zombie.log'
            log.write_text('')
            command = [PYTHON, '-c', """
import os, time
pid = os.fork()
if pid == 0:
    os._exit(0)
time.sleep(0.05)
print('done', flush=True)
"""]
            for attempt in range(3):
                with self.subTest(attempt=attempt):
                    returncode, output = owned_process.run(command, {}, log, 10)
                    self.assertEqual(returncode, 0)
                    self.assertEqual(output.strip(), 'done')
                    self.assertNotIn('OWNED_PROCESSES', log.read_text())

    # Value: protects=zombie filtering; fails_when=zombies or dead members are counted;
    # why_new=the process test can race init's reaper; seam=proc fixture
    def test_group_members_skips_zombies_and_dead_members(self):
        with tempfile.TemporaryDirectory() as folder:
            proc = Path(folder)
            for pid, state, name in (('70', 'Z', 'gone'), ('71', 'X', 'dead'), ('72', 'S', 'live')):
                entry = proc / pid
                entry.mkdir()
                (entry / 'stat').write_text(f'{pid} ({name}) {state} 1 77')
                if state == 'S':
                    (entry / 'cmdline').write_bytes(b'live\0')
            self.assertEqual(owned_process.group_members(77, proc=proc),
                             [{'pid': 72, 'name': 'live', 'start': None}])

    # Value: protects=the post-reap recycled-group boundary (#399);
    # fails_when=a member started after the owned exit is named or killed;
    # seam=proc fixture with full stat fields
    def test_group_members_filter_members_started_after_the_boundary(self):
        def stat_line(pid, name, start):
            # state(0) ppid pgrp session tty tpgid flags then twelve counters, then starttime(19).
            return f'{pid} ({name}) S 1 77 77 0 -1 4194304 ' + '0 ' * 12 + f'{start}'

        with tempfile.TemporaryDirectory() as folder:
            proc = Path(folder)
            rows = (('80', 'descendant', '5', False), ('81', 'recycled', '999', False),
                    ('82', 'late-carrier', '999', True))
            for pid, name, start, tokened in rows:
                entry = proc / pid
                entry.mkdir()
                (entry / 'stat').write_text(stat_line(pid, name, start))
                (entry / 'cmdline').write_bytes(f'{name}\0'.encode())
                if tokened:
                    (entry / 'environ').write_bytes(f'{owned_process.TOKEN_VARIABLE}=tok\0'.encode())
            self.assertEqual(owned_process.group_members(77, proc=proc, started_before=10),
                             [{'pid': 80, 'name': 'descendant', 'start': 5}],
                             'without a token the post-reap boundary spares every post-exit member')
            self.assertEqual(owned_process.group_members(77, proc=proc, started_before=10, token_value='tok'),
                             [{'pid': 80, 'name': 'descendant', 'start': 5},
                              {'pid': 82, 'name': 'late-carrier', 'start': 999}],
                             'the token tiebreak names the tokened post-boundary member and spares the tokenless one')
            self.assertEqual(owned_process.group_members(77, proc=proc, started_before=None),
                             [{'pid': 80, 'name': 'descendant', 'start': 5}, {'pid': 81, 'name': 'recycled', 'start': 999},
                              {'pid': 82, 'name': 'late-carrier', 'start': 999}],
                             'the pre-reap sweeps stay unbounded')
            unparseable = proc / '83'
            unparseable.mkdir()
            (unparseable / 'stat').write_text('83 (short) S 1 77')
            (unparseable / 'cmdline').write_bytes(b'short\0')
            self.assertIn({'pid': 83, 'name': 'short', 'start': None},
                          owned_process.group_members(77, proc=proc, started_before=10, token_value='tok'),
                          'a stat line without a parsable starttime is treated as ours, never spared')

    def test_terminate_group_spares_members_started_after_the_owned_exit(self):
        """A post-reap group scan against a recycled id must not kill an unrelated process."""
        token = 'recycle-check-token'
        process = subprocess.Popen([PYTHON, '-c', 'import time; time.sleep(30)'], start_new_session=True,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 5
            while process.poll() is not None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertIsNone(process.poll(), 'the control only holds with a live group member')
            spared = owned_process.terminate_group(process.pid, started_before=10)
            self.assertEqual(spared, [], 'a member started after the boundary is a reissued group, not ours')
            self.assertIsNone(process.poll(), 'the filter must leave the spared member alive and unharmed')
            named = owned_process.terminate_group(process.pid, started_before=10 ** 12)
            self.assertEqual([item['pid'] for item in named], [process.pid],
                             'the unbounded sweep still names the real member')
            self.assertIsNotNone(process.wait(timeout=10), 'the unbounded sweep still kills it')
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)

    def test_terminate_group_names_a_tokened_member_started_after_the_boundary(self):
        """A tokened fork is ours wherever it started; the boundary spares only tokenless groups."""
        token = 'late-fork-token'
        process = subprocess.Popen([PYTHON, '-c', 'import time; time.sleep(30)'], start_new_session=True,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   env={**os.environ, owned_process.TOKEN_VARIABLE: token})
        try:
            deadline = time.monotonic() + 5
            while process.poll() is not None and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertIsNone(process.poll(), 'the control only holds with a live tokened member')
            named = owned_process.terminate_group(process.pid, started_before=10, token_value=token)
            self.assertEqual([item['pid'] for item in named], [process.pid],
                             'a tokened member started after the boundary is ours and is named')
            self.assertIsNotNone(process.wait(timeout=10), 'the named member is killed')
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)

    # Value: protects=the merged survivor report names each killed pid once;
    # fails_when=a process both sweeps saw is reported as two terminations;
    # why_new=the orphan-mode escape race double-named one pid under load (#381);
    # seam=owned_process.merged_survivors
    def test_merged_survivors_keep_the_first_sighting_of_each_pid(self):
        group = [{'pid': 10, 'name': 'group-only'}, {'pid': 11, 'name': 'both'}]
        token = [{'pid': 11, 'name': 'again'}, {'pid': 12, 'name': 'token-only'}]
        self.assertEqual(owned_process.merged_survivors(group, token),
                         [{'pid': 10, 'name': 'group-only'}, {'pid': 11, 'name': 'both'},
                          {'pid': 12, 'name': 'token-only'}])
        self.assertEqual(owned_process.merged_survivors([], token), token)
        self.assertEqual(owned_process.merged_survivors(group, []), group)

    def test_interruption_terminates_the_tree_before_propagating(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'interrupt.log'
            log.write_text('')
            marker = Path(folder) / 'sleeper.pid'
            command = [PYTHON, '-c', """
import os, sys, time
open(sys.argv[1], 'w').write(str(os.getpid()))
print('ready', flush=True)
time.sleep(60)
""", str(marker)]
            def interrupting_collect(process, deadline, on_exit=None):
                deadline_marker = time.monotonic() + 5
                while not marker.exists() and time.monotonic() < deadline_marker:
                    time.sleep(0.01)
                raise KeyboardInterrupt

            with mock.patch.object(owned_process, '_collect', side_effect=interrupting_collect):
                with self.assertRaises(KeyboardInterrupt):
                    owned_process.run(command, {}, log, 30)
            pid = int(marker.read_text())
            deadline = time.monotonic() + 5
            while alive(pid) and time.monotonic() < deadline:
                time.sleep(0.1)
            self.assertFalse(alive(pid), 'an interrupted command must not strand its process tree')
            # The handler reaps before propagating: the pid is gone entirely,
            # never left behind as a zombie of this test. The waitpid probe
            # names the reap directly — a zombie child would still answer.
            stat = Path(f'/proc/{pid}/stat')
            if stat.exists():
                self.assertNotEqual(stat.read_text().rsplit(') ', 1)[-1].split()[0], 'Z')
            with self.assertRaises((ChildProcessError, ProcessLookupError),
                                   msg='the interrupt path must reap the direct child itself'):
                os.waitpid(pid, os.WNOHANG)
            # When SIGKILL delivery beats both sweeps, nothing survives to be
            # named and the log stays empty; the pid liveness check above is
            # the contract under test.

    def test_capture_keeps_output_and_survivor_diagnostics_in_one_log(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'capture.log'
            marker = Path(folder) / 'escaped.pid'
            self.assertEqual(capture([PYTHON, '-c', "print('quiet')"], {}, log, 10), (0, 'quiet\n'))
            self.assertIn('quiet', log.read_text())
            command = [PYTHON, '-c', escape_child('setsid', marker), str(marker)]
            with self.assertRaises(owned_process.EscapedDescendants):
                capture(command, {}, log, 10)
            text = log.read_text()
            self.assertIn('OWNED_PROCESSES: terminated', text)


class SplitStreamTests(unittest.TestCase):
    def test_split_keeps_stdout_stderr_and_stdin_separate(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'split.log'
            log.write_text('')
            code = "import sys\nsys.stdout.write('out')\nsys.stderr.write('err')\nprint(input())"
            returncode, stdout, stderr = owned_process.run_split([PYTHON, '-c', code], {}, log, 10,
                                                                 input_text='fed\n')
            self.assertEqual(returncode, 0)
            self.assertEqual(stdout, 'outfed\n')
            self.assertEqual(stderr, 'err')
            self.assertEqual(log.read_text(), '', 'a healthy split run leaves the log to its caller')

    def test_split_escaped_descendant_raises_without_stream_contamination(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'escape.log'
            marker = Path(folder) / 'escaped.pid'
            command = [PYTHON, '-c', escape_child('setsid', marker), str(marker)]
            with self.assertRaises(owned_process.EscapedDescendants):
                owned_process.run_split(command, {}, log, 10)
            pid = int(marker.read_text())
            deadline = time.monotonic() + 5
            while alive(pid) and time.monotonic() < deadline:
                time.sleep(0.1)
            self.assertFalse(alive(pid), 'the split sweep must terminate the escaped descendant')

    def test_split_timeout_records_partial_output_in_the_log(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'timeout.log'
            with self.assertRaises(subprocess.TimeoutExpired) as raised:
                owned_process.run_split([PYTHON, '-c', "import time; print('started', flush=True); time.sleep(60)"],
                                        {}, log, 2)
            self.assertIn('started', raised.exception.output)
            self.assertIn('TIMEOUT: command exceeded 2 seconds', log.read_text())


    def test_large_stdin_payload_reaches_the_child(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'volume-stdin.log'
            payload = 'x' * (200 * 1024)
            returncode, stdout, stderr = owned_process.run_split(
                [PYTHON, '-c', 'import sys; sys.stdout.write(sys.stdin.read())'], {}, log, 10, input_text=payload)
            self.assertEqual(returncode, 0)
            self.assertEqual(stdout, payload, 'a payload past the pipe buffer must still reach the child')

    def test_a_child_that_never_reads_stdin_still_meets_its_deadline(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'unread-stdin.log'
            marker = Path(folder) / 'grandchild.pid'
            command = [PYTHON, '-c',
                       "import os, sys, time\n"
                       "pid = os.fork()\n"
                       "if pid == 0:\n    open(sys.argv[1], 'w').write(str(os.getpid()))\n    time.sleep(60)\n"
                       "sys.stdin.read()\ntime.sleep(60)",
                       str(marker)]
            with self.assertRaises(subprocess.TimeoutExpired):
                owned_process.run_split(command, {}, log, 2, input_text='x' * (200 * 1024))
            self.assertIn('TIMEOUT: command exceeded 2 seconds', log.read_text())
            pid = int(marker.read_text())
            deadline = time.monotonic() + 5
            while alive(pid) and time.monotonic() < deadline:
                time.sleep(0.1)
            self.assertFalse(alive(pid), 'the deadline must own the whole tree, stdin or not')


class SpawnedProcessTests(unittest.TestCase):
    def test_finish_stops_a_running_host_and_verifies_its_tree(self):
        with tempfile.TemporaryDirectory() as folder:
            process, token = owned_process.spawn([PYTHON, '-c', 'import time; time.sleep(60)'],
                                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.assertTrue(alive(process.pid))
            owned_process.finish(process, token, grace=5)
            self.assertFalse(alive(process.pid), 'finish must stop the spawned host')

    def test_finish_terminates_an_escaped_descendant_of_the_host(self):
        with tempfile.TemporaryDirectory() as folder:
            marker = Path(folder) / 'escaped.pid'
            process, token = owned_process.spawn([PYTHON, '-c', escape_child('setsid', marker), str(marker)],
                                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 5
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                with self.assertRaises(owned_process.EscapedDescendants):
                    owned_process.finish(process, token, grace=5)
                pid = int(marker.read_text())
                deadline = time.monotonic() + 5
                while alive(pid) and time.monotonic() < deadline:
                    time.sleep(0.1)
                self.assertFalse(alive(pid), 'finish must terminate the escaped descendant')
            finally:
                process.wait(timeout=10)

    def test_finish_terminates_a_grandchild_forked_during_the_teardown(self):
        """A descendant forked while finish() tears the host down is still named (review round 1)."""
        with tempfile.TemporaryDirectory() as folder:
            marker = Path(folder) / 'late-fork.pid'
            # The host ignores SIGTERM, forks a token-scrubbed grandchild in the
            # same process group once the teardown is already running, then exits.
            # The grandchild records its own pid, so the test asserts the
            # descendant's recorded pid is gone — not the host's (#400 review).
            host, token = owned_process.spawn([PYTHON, '-c', f"""
import os, signal, sys, time
open(sys.argv[1] + '.tmp', 'w').write(str(os.getpid()))
os.rename(sys.argv[1] + '.tmp', sys.argv[1])
signal.signal(signal.SIGTERM, signal.SIG_IGN)
time.sleep(0.4)
pid = os.fork()
if pid == 0:
    open(sys.argv[1] + '.grand.tmp', 'w').write(str(os.getpid()))
    os.rename(sys.argv[1] + '.grand.tmp', sys.argv[1] + '.grand')
    scrubbed = {{k: v for k, v in os.environ.items() if k != {owned_process.TOKEN_VARIABLE!r}}}
    os.execve(sys.executable, [sys.executable, '-c', 'import time; time.sleep(30)'], scrubbed)
time.sleep(0.2)
""", str(marker)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 5
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                with self.assertRaises(owned_process.EscapedDescendants):
                    owned_process.finish(host, token, grace=5)
                pid = int(marker.read_text())
                deadline = time.monotonic() + 5
                while alive(pid) and time.monotonic() < deadline:
                    time.sleep(0.1)
                self.assertFalse(alive(pid),
                                 'a grandchild forked during the teardown grace must not outlive finish()')
                # The recorded grandchild, not the host pid, is the escape the
                # sweeps must have stopped (#400 review). Termination, not
                # reaping: the orphan can zombie under this container's init.
                deadline = time.monotonic() + 5
                while not Path(str(marker) + '.grand').exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                grand_pid = int(Path(str(marker) + '.grand').read_text())
                self.assertNotEqual(grand_pid, pid, 'the grandchild marker must not name the host')
                deadline = time.monotonic() + 5
                while not terminated(grand_pid) and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertTrue(terminated(grand_pid),
                                'the recorded grandchild pid must be terminated before finish() returns')
            finally:
                process = host
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=10)

    def test_finish_after_clean_exit_keeps_only_the_sweep_checks(self):
        with tempfile.TemporaryDirectory() as folder:
            process, token = owned_process.spawn([PYTHON, '-c', 'print("done")'],
                                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            process.wait(timeout=10)
            owned_process.finish(process, token, grace=5)
            self.assertEqual(process.returncode, 0, 'a clean host keeps its own exit code')

    # Value: protects=finish()'s cleanup from a failed pinned group signal (#404 review);
    # fails_when=an unsupported flag-4 on a SIGTERM-ignoring host skips the sweeps
    # and raises TimeoutExpired out of finish, stranding the host;
    # seam=owned_process.finish with the flag-4 call forced to fail
    def test_finish_stops_a_sigterm_ignoring_host_when_the_group_signal_fails(self):
        with tempfile.TemporaryDirectory() as folder:
            marker = Path(folder) / 'stubborn.pid'
            host, token = owned_process.spawn([PYTHON, '-c', """
import os, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
open(sys.argv[1], 'w').write(str(os.getpid()))
time.sleep(60)
""", str(marker)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 5
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                with mock.patch.object(owned_process.signal, 'pidfd_send_signal',
                                       side_effect=OSError(errno.EINVAL, 'flag unsupported')):
                    owned_process.finish(host, token, grace=2)
                self.assertIsNotNone(host.poll(), 'the stubborn host is stopped and reaped')
                self.assertTrue(terminated(host.pid),
                                'finish must stop the host itself, not raise past its sweeps')
            finally:
                if host.poll() is None:
                    host.kill()
                host.wait(timeout=10)

    def test_finish_survives_a_failing_token_scan_and_still_scans_the_group(self):
        """finish() must contain its sweeps like the runners' tails (#398 review)."""
        process, token_value = owned_process.spawn([PYTHON, '-c', 'import sys; sys.exit(0)'],
                                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            process.wait(timeout=10)
            with mock.patch.object(owned_process, 'terminate',
                                   side_effect=ValueError('finish token scan exploded')), \
                 mock.patch.object(owned_process, 'terminate_group',
                                   return_value=[]) as terminate_group:
                with self.assertRaises(ValueError):
                    owned_process.finish(process, token_value)
            self.assertGreater(terminate_group.call_count, 0,
                               'the group scan must run even though the token scan raised')
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=10)


class CancelHandleTests(unittest.TestCase):
    """Value: one running owned command can be cancelled from outside its call (#397)."""

    SLOW_TREE = """
import os, sys, time
print('started', flush=True)
marker = sys.argv[1] + '.tmp'
open(marker, 'w').write(str(os.getpid()))
os.rename(marker, sys.argv[1])
time.sleep(60)
"""

    ESCAPE_TREE = """
import os, sys, time
pid = os.fork()
if pid == 0:
    os.setsid()
    marker = sys.argv[1] + '.tmp'
    open(marker, 'w').write(str(os.getpid()))
    os.rename(marker, sys.argv[1])
    time.sleep(60)
print('started', flush=True)
time.sleep(60)
"""

    # The direct child arms a same-group escapee, exits zero shortly after,
    # and the cancel lands mid-drain: late enough to race the natural rc-0
    # exit, early enough that one side of the race owns the carrier. Both
    # outcomes must name the carrier exactly once; neither may read as an
    # unrecorded success. The descendant writes its own marker so the test
    # can assert its recorded pid, not the host's (#398 review).
    LATE_ESCAPE_TREE = """
import os, sys, time
pid = os.fork()
if pid == 0:
    open(sys.argv[1] + '.grand.tmp', 'w').write(str(os.getpid()))
    os.rename(sys.argv[1] + '.grand.tmp', sys.argv[1] + '.grand')
    time.sleep(60)
print('bye', flush=True)
marker = sys.argv[1] + '.tmp'
open(marker, 'w').write(str(os.getpid()))
os.rename(marker, sys.argv[1])
time.sleep(0.3)
"""

    # The child exits at once and leaves a setsid descendant that inherits
    # stdin and never reads it, so a large stdin payload blocks the feeder on
    # a full pipe that only the ownership sweeps can drain.
    STDIN_HOLDER_TREE = """
import os, sys, time
pid = os.fork()
if pid == 0:
    os.setsid()
    marker = sys.argv[1] + '.tmp'
    open(marker, 'w').write(str(os.getpid()))
    os.rename(marker, sys.argv[1])
    time.sleep(60)
print('child exits', flush=True)
"""

    def start_cancel_run(self, folder, entry, cancel, tree, timeout=30):
        """Run one slow owned command under the handle on a worker thread."""
        log = Path(folder) / f'{entry.__name__}.log'
        log.write_text('')
        marker = Path(folder) / f'{entry.__name__}.pid'
        command = [PYTHON, '-c', tree, str(marker)]
        outcome = {}

        def worker():
            try:
                outcome['result'] = entry(command, {}, log, timeout, cancel=cancel)
            except BaseException as error:  # the worker forwards whatever the run raised
                outcome['error'] = error

        thread = threading.Thread(target=worker)
        thread.start()
        pid = None
        deadline = time.monotonic() + 10
        # The cancel must land on a pinned run: under load the worker can stall
        # between _start() and register(), so the child's marker alone proves
        # nothing about registration — a cancel firing in that gap is refused
        # (ValueError) instead of raising Cancelled, which is production
        # behavior but not what these tests exercise (CI run 44377842214).
        while time.monotonic() < deadline:
            if pid is None and marker.exists():
                pid = int(marker.read_text())
            if pid is not None and cancel._process is not None:
                break
            time.sleep(0.05)
        return thread, outcome, log, pid

    def assert_tree_gone(self, pid):
        deadline = time.monotonic() + 5
        while alive(pid) and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertFalse(alive(pid), 'a cancelled tree must be reaped before the cancel returns its join')

    def assert_descendant_terminated(self, pid):
        """A forked orphan is terminated when it exited; this test cannot reap it.

        After its parent is reaped the descendant reparents to init, and this
        container's init does not always reap promptly — a killed orphan can
        stay a zombie answering kill(0). A zombie has taken SIGKILL, which is
        the contract under test; only a live process fails it.
        """
        deadline = time.monotonic() + 5
        while not terminated(pid) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(terminated(pid), f'the recorded descendant {pid} must be terminated')

    def test_cancel_stops_a_live_tree_once_and_refuses_a_double_cancel(self):
        with tempfile.TemporaryDirectory() as folder:
            handle = owned_process.CancelHandle()
            thread, outcome, log, pid = self.start_cancel_run(folder, owned_process.run, handle, self.SLOW_TREE)
            self.assertIsNotNone(pid, 'the control only holds with a live tree')
            began = time.monotonic()
            handle.cancel()
            with self.assertRaises(ValueError):
                handle.cancel()
            thread.join(timeout=15)
            self.assertFalse(thread.is_alive(), 'the cancelled run must finish long before its 30-second deadline')
            self.assertLess(time.monotonic() - began, 15, 'the cancel must not wait out the run own deadline')
            self.assertIsInstance(outcome.get('error'), owned_process.Cancelled,
                                  'the cancelled run must raise the cancellation, not a timeout')
            self.assertIn('started', getattr(outcome['error'], 'output', ''), 'partial output stays the evidence')
            self.assert_tree_gone(pid)
            self.assertIn('CANCELLED:', log.read_text(), 'the cancellation must leave its marker in the log the caller reads')

    def test_cancel_names_an_escaped_carrier_exactly_once(self):
        with tempfile.TemporaryDirectory() as folder:
            handle = owned_process.CancelHandle()
            thread, outcome, log, pid = self.start_cancel_run(folder, owned_process.run, handle, self.ESCAPE_TREE)
            self.assertIsNotNone(pid, 'the control only holds with a live escaped carrier')
            survivors = handle.cancel()
            named = [item['pid'] for item in survivors]
            self.assertEqual(named.count(pid), 1,
                             'the group kill cannot reach a setsid carrier, so the token sweep names it')
            self.assertLessEqual(len(survivors), 2, 'only the direct child may join the carrier in the report')
            thread.join(timeout=15)
            self.assertIsInstance(outcome.get('error'), owned_process.Cancelled)
            self.assert_tree_gone(pid)
            text = log.read_text()
            reports = [line for line in text.splitlines() if line.startswith('OWNED_PROCESSES:')]
            self.assertEqual(len(reports), 1, f'the survivor report must be written once, got {reports}')
            self.assertEqual(text.count(f"'pid': {pid}"), 1, 'the cancelled pid must be named exactly once (#381)')

    def test_a_deadline_during_a_failed_cancel_still_verifies_and_reaps(self):
        """F1 round two: the cancelled-deadline branch owns the tree when the cancel stopped nothing."""
        with tempfile.TemporaryDirectory() as folder:
            handle = owned_process.CancelHandle()
            thread, outcome, log, pid = self.start_cancel_run(folder, owned_process.run, handle, self.SLOW_TREE, timeout=5)
            self.assertIsNotNone(pid, 'the control only holds with a live tree')
            with mock.patch.object(owned_process, '_terminate_tree', side_effect=ValueError('stop exploded')):
                with self.assertRaises(ValueError):
                    handle.cancel()
            thread.join(timeout=15)
            self.assertFalse(thread.is_alive(), 'the run must resolve bounded even when the cancel stopped nothing')
            error = outcome.get('error')
            self.assertIsInstance(error, (owned_process.Cancelled, owned_process.EscapedDescendants),
                                  f'the cancelled deadline must resolve with evidence ({outcome.get("result")})')
            self.assert_tree_gone(pid)
            stat = Path(f'/proc/{pid}/stat')
            if stat.exists():
                self.assertNotEqual(stat.read_text().rsplit(') ', 1)[-1].split()[0], 'Z',
                                    'the killed child must be reaped, never left a zombie of this test')
            text = log.read_text()
            self.assertIn('CANCELLED:', text)
            self.assertIn('OWNED_PROCESSES: terminated', text,
                          'the verification sweep must name the tree it had to stop itself')

    def test_a_cancel_landing_mid_sweep_of_the_deadline_keeps_every_name(self):
        """F2 round two: a cancel claiming victims mid-handler cannot strip the timeout report."""
        with tempfile.TemporaryDirectory() as folder:
            handle = owned_process.CancelHandle()
            log = Path(folder) / 'flip.log'
            log.write_text('')
            marker = Path(folder) / 'flip.pid'
            command = [PYTHON, '-c', self.SLOW_TREE, str(marker)]
            real_group = owned_process.terminate_group

            def flipping_group(group_pid, started_before=None, token_value=None):
                if not handle.cancelled:
                    handle.cancel()  # the real cancel fires inside the deadline handler's own sweep
                return real_group(group_pid, started_before=started_before, token_value=token_value)

            with mock.patch.object(owned_process, 'terminate_group', flipping_group):
                with self.assertRaises(subprocess.TimeoutExpired):
                    owned_process.run(command, {}, log, 5, cancel=handle)
            pid = int(marker.read_text())
            self.assert_tree_gone(pid)
            stat = Path(f'/proc/{pid}/stat')
            if stat.exists():
                self.assertNotEqual(stat.read_text().rsplit(') ', 1)[-1].split()[0], 'Z')
            text = log.read_text()
            self.assertIn('TIMEOUT: command exceeded 5 seconds', text)
            self.assertIn(f"'pid': {pid}", text, 'the terminated pid must survive in the written report')
            self.assertLessEqual(text.count(f"'pid': {pid}"), 1, 'no pid may be named twice (#381)')

    def test_a_concurrent_cancel_claiming_mid_handler_reaches_the_timeout_report(self):
        """The consume inversion: a survivor the cancel claimed must still reach the written report."""
        with tempfile.TemporaryDirectory() as folder:
            handle = owned_process.CancelHandle()
            log = Path(folder) / 'mid.log'
            log.write_text('')
            process, token_value = owned_process._start([PYTHON, '-c', 'import time; time.sleep(30)'], {}, None, False)
            real_claim = handle.claim

            def claiming_mid_sweep(candidates):
                handle._cancelled = True  # the concurrent cancel wins the claim race here
                return real_claim(candidates)

            try:
                self.assertTrue(handle.register(process, token_value, log))
                with mock.patch.object(handle, 'claim', claiming_mid_sweep), \
                     mock.patch.object(handle, 'absorb',
                                       return_value=[{'pid': process.pid, 'name': 'swept'}]), \
                     mock.patch.object(owned_process, '_terminate_tree', return_value=([], None)):
                    with self.assertRaises(subprocess.TimeoutExpired):
                        owned_process._run_until_exit(process, token_value, log, 0.4, handle)
                self.assertIn(f"'pid': {process.pid}", log.read_text(),
                              'the concurrent cancel claimed survivor must reach the written timeout report')
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=10)

    def test_a_failing_verification_sweep_still_runs_the_token_sweep_and_reaps(self):
        """A failing group pass inside the cancelled-deadline branch strands nothing.

        Whether the stop's own anomaly resurfaces depends on a race this
        schedule cannot pin: after the cancel's group kill, the owning call
        can reap and unregister before the post-kill pass probes the leader,
        and a genuinely reaped leader skips its group scans (the id is free),
        leaving no anomaly to raise. Both outcomes are bounded and complete:
        the run still resolves to a classified cancellation, the token sweep
        names the tree in either outcome, and the child is reaped. The
        containment property itself — a raising sweep never discards names or
        skips the other sweep — is pinned deterministically by
        `test_the_final_token_sweep_survives_a_failing_group_pass`.
        """
        with tempfile.TemporaryDirectory() as folder:
            handle = owned_process.CancelHandle()
            thread, outcome, log, pid = self.start_cancel_run(folder, owned_process.run, handle, self.SLOW_TREE, timeout=5)
            self.assertIsNotNone(pid, 'the control only holds with a live tree')
            with mock.patch.object(owned_process, 'terminate_group', side_effect=ValueError('group pass exploded')), \
                 mock.patch.object(owned_process.os, 'killpg', side_effect=OSError(1, 'broken')):
                try:
                    handle.cancel()  # the stop's anomaly surfaces only when the passes still ran
                except ValueError:
                    pass
            thread.join(timeout=20)
            self.assertFalse(thread.is_alive(), 'the run must resolve bounded behind a failed verification sweep')
            error = outcome.get('error')
            self.assertIsInstance(error, (owned_process.Cancelled, owned_process.EscapedDescendants),
                                  f'the deadline branch must classify the run ({outcome.get("result")})')
            self.assertTrue(handle.stopped_run, 'the cancel must land while the run is still pinned')
            self.assert_tree_gone(pid)
            self.assertIn('OWNED_PROCESSES: terminated', log.read_text(),
                          'the token sweep must name the tree even with the group pass broken')

    def test_a_cancel_racing_a_natural_rc_zero_exit_never_reads_as_unrecorded_success(self):
        """The F1 shape: same-group carrier alive, child exiting zero, cancel mid-drain."""
        for delay in (0.05, 1.0):
            with self.subTest(cancel_after=delay), tempfile.TemporaryDirectory() as folder:
                handle = owned_process.CancelHandle()
                thread, outcome, log, pid = self.start_cancel_run(folder, owned_process.run, handle, self.LATE_ESCAPE_TREE)
                self.assertIsNotNone(pid, 'the control only holds with an armed tree')
                # The descendant writes its marker before the parent's, but a
                # slow scheduler could still delay the fork's write: wait for
                # the grand marker before cancelling, so a cancellation that
                # worked correctly can never fail the recorded-pid assertion
                # by killing an unready descendant (#403 review).
                grand_marker = Path(folder) / 'run.pid.grand'
                deadline_marker = time.monotonic() + 5
                while not grand_marker.exists() and time.monotonic() < deadline_marker:
                    time.sleep(0.02)
                self.assertTrue(grand_marker.exists(), 'the fixture must arm the descendant before the cancel')
                began = time.monotonic()
                while time.monotonic() - began < delay:
                    time.sleep(0.02)
                handle.cancel()
                thread.join(timeout=15)
                self.assertFalse(thread.is_alive(), 'the cancelled run must finish long before its 30-second deadline')
                self.assertLess(time.monotonic() - began, 15)
                error = outcome.get('error')
                self.assertIsInstance(error, (owned_process.Cancelled, owned_process.EscapedDescendants),
                                      'the tree must resolve to a named cancellation or a named escape, never a '
                                      f'plain return ({outcome.get("result")})')
                text = log.read_text()
                reports = [line for line in text.splitlines() if line.startswith('OWNED_PROCESSES:')]
                self.assertTrue(reports, 'a terminated carrier must be named, not silently buried')
                self.assertLessEqual(text.count(f"'pid': {pid}"), 1, 'no pid may be named twice (#381)')
                # The recorded descendant, not the host pid, must reach the
                # log exactly once and be gone before the call resolves
                # (#398 review): the marker file names the forked escapee.
                grand_marker = Path(folder) / 'run.pid.grand'
                deadline_marker = time.monotonic() + 5
                while not grand_marker.exists() and time.monotonic() < deadline_marker:
                    time.sleep(0.05)
                self.assertTrue(grand_marker.exists(), 'the fixture must record the descendant pid')
                grand_pid = int(grand_marker.read_text())
                self.assertNotEqual(grand_pid, pid, 'the descendant marker must not name the host')
                named_text = '\n'.join(reports)

                def occurrences(recorded):
                    # The run's merged report uses the dict repr; a late append uses pid N (name).
                    return named_text.count(f"'pid': {recorded}") + named_text.count(f'pid {recorded} ')

                self.assertGreaterEqual(occurrences(grand_pid), 1,
                                        f'the descendant pid {grand_pid} never reached the log ({text})')
                self.assertLessEqual(occurrences(grand_pid), 1, f'pid {grand_pid} named twice (#381)')
                self.assert_descendant_terminated(grand_pid)

    def test_a_cancel_whose_sweep_fails_still_publishes_its_outcome(self):
        """A sweep error inside cancel must never leave an owning run waiting forever."""
        for broken in ('identities', 'terminate_group'):
            with self.subTest(broken=broken), tempfile.TemporaryDirectory() as folder:
                handle = owned_process.CancelHandle()
                thread, outcome, log, pid = self.start_cancel_run(folder, owned_process.run, handle, self.SLOW_TREE)
                self.assertIsNotNone(pid, 'the control only holds with a live tree')
                with mock.patch.object(owned_process, broken, side_effect=ValueError('sweep exploded')):
                    with self.assertRaises(ValueError):
                        handle.cancel()
                thread.join(timeout=15)
                self.assertFalse(thread.is_alive(), 'the owning run must finish bounded after a failed cancel sweep')
                self.assertIsInstance(outcome.get('error'), owned_process.Cancelled,
                                      'the group kill landed, so the run still resolves to a cancellation')
                self.assert_tree_gone(pid)

    def test_a_stdin_holder_cannot_block_the_sweeps_behind_the_feeder(self):
        """A descendant holding stdin open must not stall the ownership sweeps behind a close."""
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'holder.log'
            log.write_text('')
            marker = Path(folder) / 'holder.pid'
            command = [PYTHON, '-c', self.STDIN_HOLDER_TREE, str(marker)]
            began = time.monotonic()
            with self.assertRaises(owned_process.EscapedDescendants) as raised:
                owned_process.run_split(command, {}, log, 10, input_text='x' * (200 * 1024))
            self.assertLess(time.monotonic() - began, 10,
                            'the feeder must not hold the cleanup hostage on a full pipe')
            pid = int(marker.read_text())
            self.assert_tree_gone(pid)
            named = [item['pid'] for item in raised.exception.survivors]
            self.assertEqual(named.count(pid), 1, 'the stdin holder must be named terminated exactly once')

    # Value: protects=the timeout window end to end (#399): a cancel that
    # starts at the owning call's log write — after its last consumption
    # point — must still leave the carrier named in the written log;
    # fails_when=the written log omits the carrier the late cancel killed;
    # seam=owned_process.identities call order and a log sink that starts the cancel
    def test_a_cancel_starting_at_the_log_write_still_names_its_carrier(self):
        with tempfile.TemporaryDirectory() as folder:
            handle = owned_process.CancelHandle()
            inner = Path(folder) / 'window.log'
            inner.write_text('')
            state = {'scans': 0, 'flipped': False}
            started = threading.Event()
            real_identities = owned_process.identities

            def rigged_identities(token_value):
                state['scans'] += 1
                if state['scans'] <= 2:
                    return []  # the deadline branch's own sweeps: the carrier has not appeared yet
                return real_identities(token_value)  # the cancel's sweep: names and kills it

            def canceling():
                started.set()
                handle.cancel()

            class WriteTriggerLog:
                """Starts the cancel thread at the owning call's write, then writes."""

                def write_text(self, text):
                    if not state['flipped']:
                        state['flipped'] = True
                        threading.Thread(target=canceling, daemon=True).start()
                        started.wait(timeout=10)
                    inner.write_text(text)

                def open(self, *args, **kwargs):
                    return inner.open(*args, **kwargs)

            racy_log = WriteTriggerLog()
            command = [PYTHON, '-c', """
import os, sys, time
pid = os.fork()
if pid == 0:
    os.setsid()
    time.sleep(60)
time.sleep(30)
"""]
            with mock.patch.object(owned_process, 'identities', rigged_identities):
                with self.assertRaises(subprocess.TimeoutExpired):
                    owned_process.run(command, {}, racy_log, 0.4, cancel=handle)
            deadline = time.monotonic() + 5
            while threading.active_count() > 1 and time.monotonic() < deadline:
                time.sleep(0.05)
            text = inner.read_text()
            self.assertIn('TIMEOUT:', text)
            self.assertTrue(handle._named,
                            'the forced schedule must arm at least one claimed kill for this test to bind')
            named = [line for line in text.splitlines() if line.startswith('OWNED_PROCESSES:')]
            self.assertTrue(named, 'a terminated carrier must be named, not silently buried')
            named_text = '\n'.join(named)

            def occurrences(pid):
                # The run's merged report uses the dict repr; a late append uses pid N (name).
                return named_text.count(f"'pid': {pid}") + named_text.count(f'pid {pid} ')

            for pid in sorted(handle._named):
                self.assertGreaterEqual(occurrences(pid), 1,
                                        f'killed pid {pid} never reached the written log ({text})')
                self.assertLessEqual(occurrences(pid), 1, f'pid {pid} named twice across reports (#381)')
                self.assert_descendant_terminated(pid)

    # Value: protects=the no-write exit paths' final report drain (#399);
    # fails_when=a report published after absorb sits unconsumed past a clean return;
    # seam=owned_process.terminate_group flipping into a pinned cancel
    def test_a_report_published_after_absorb_is_named_before_the_run_ends(self):
        with tempfile.TemporaryDirectory() as folder:
            handle = owned_process.CancelHandle()
            log = Path(folder) / 'settle.log'
            log.write_text('')
            marker = Path(folder) / 'settle.pid'
            # The child exits zero and leaves a same-group carrier alive, so the
            # tail's group sweep runs with the tree still owning a live member.
            command = [PYTHON, '-c', """
import os, sys, time
pid = os.fork()
if pid == 0:
    marker = sys.argv[1] + '.tmp'
    open(marker, 'w').write(str(os.getpid()))
    os.rename(marker, sys.argv[1])
    time.sleep(60)
time.sleep(0.05)
""", str(marker)]
            real_group = owned_process.terminate_group

            def flipping_group(group_pid, started_before=None, token_value=None):
                if not handle.cancelled:
                    handle.cancel()  # the cancel publishes after this run's absorb already returned
                return real_group(group_pid)

            with mock.patch.object(owned_process, 'terminate_group', flipping_group):
                with self.assertRaises((owned_process.Cancelled, owned_process.EscapedDescendants)):
                    owned_process.run(command, {}, log, 30, cancel=handle)
            pid = int(marker.read_text())
            self.assert_tree_gone(pid)
            text = log.read_text()
            self.assertIn(f"'pid': {pid}", text,
                          'the late-published report must be named before the run ends')
            self.assertLessEqual(text.count(f"'pid': {pid}"), 1, 'no pid may be named twice (#381)')

    # Value: protects=the refused run's diagnosis landing in its own log (review round 1, finding 1);
    # fails_when=the refusal's sweep note is routed through the pinned handle's emit into another run's log;
    # seam=owned_process._refused_run via a handle that already pins a live run
    def test_a_refused_run_names_its_sweep_in_its_own_log(self):
        with tempfile.TemporaryDirectory() as folder:
            handle = owned_process.CancelHandle()
            pinned_log = Path(folder) / 'pinned.log'
            pinned_log.write_text('')
            refused_log = Path(folder) / 'refused.log'
            refused_log.write_text('')
            pinned_command = [PYTHON, '-c', self.SLOW_TREE, str(Path(folder) / 'pinned.pid')]
            outcome = {}
            refused = {}
            real_start = owned_process._start

            def tracking_start(*args, **kwargs):
                process, token_value = real_start(*args, **kwargs)
                refused['process'] = process  # only the refused run starts under this patch
                return process, token_value

            def worker():
                try:
                    outcome['result'] = owned_process.run(pinned_command, {}, pinned_log, 30, cancel=handle)
                except BaseException as error:
                    outcome['error'] = error

            thread = threading.Thread(target=worker)
            thread.start()
            deadline = time.monotonic() + 10
            while not Path(folder, 'pinned.pid').exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            with mock.patch.object(owned_process, '_start', tracking_start):
                with self.assertRaises(ValueError):
                    owned_process.run([PYTHON, '-c', 'import time; time.sleep(60)'], {}, refused_log, 10,
                                      cancel=handle)
            handle.cancel()
            thread.join(timeout=15)
            self.assertIsInstance(outcome.get('error'), owned_process.Cancelled)
            refused_pid = refused['process'].pid
            self.assertIn(f"'pid': {refused_pid}", refused_log.read_text(),
                          'the refused run names the tree it had to stop in its own log')
            self.assertNotIn(f"'pid': {refused_pid}", pinned_log.read_text(),
                             'the pinned run log never carries another run sweep names')

    def test_split_cancel_shares_the_same_surface(self):
        with tempfile.TemporaryDirectory() as folder:
            handle = owned_process.CancelHandle()
            thread, outcome, log, pid = self.start_cancel_run(folder, owned_process.run_split, handle, self.SLOW_TREE)
            self.assertIsNotNone(pid, 'the control only holds with a live tree')
            handle.cancel()
            thread.join(timeout=15)
            self.assertIsInstance(outcome.get('error'), owned_process.Cancelled)
            self.assert_tree_gone(pid)
            self.assertIn('CANCELLED:', log.read_text())

    def test_a_tail_token_scan_failure_still_runs_the_group_sweep(self):
        """A raising token scan in the runners' tails must not skip the group scan (#398 review)."""
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'tail-anomaly.log'
            log.write_text('')
            # The child leaves a same-group descendant alive, so the tail's
            # group scan is armed (group_alive) and the raised token scan
            # must not skip it.
            command = [PYTHON, '-c', self.LATE_ESCAPE_TREE, str(Path(folder) / 'tail.pid')]
            try:
                with mock.patch.object(owned_process, 'terminate',
                                       side_effect=ValueError('token scan exploded')), \
                     mock.patch.object(owned_process, 'terminate_group',
                                       return_value=[]) as terminate_group:
                    with self.assertRaises(ValueError):
                        owned_process.run(command, {}, log, 10)
                self.assertGreater(terminate_group.call_count, 0,
                                   'the group scan must run even though the token scan raised')
                self.assertIn('OWNED_PROCESS_SWEEP_ANOMALY: token scan exploded', log.read_text(),
                              'the contained anomaly is recorded in the run log before the failure propagates')
            finally:
                self.kill_marker_tree(Path(folder) / 'tail.pid.grand')

    def kill_marker_tree(self, marker):
        """SIGKILL one marker-named straggler a mock spared; the test owns its cleanup."""
        try:
            os.kill(int(marker.read_text()), signal.SIGKILL)
        except (OSError, ValueError):
            pass

    def test_a_tail_token_scan_failure_in_split_still_runs_the_group_sweep(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'tail-anomaly-split.log'
            log.write_text('')
            command = [PYTHON, '-c', self.LATE_ESCAPE_TREE, str(Path(folder) / 'tail-split.pid')]
            try:
                with mock.patch.object(owned_process, 'terminate',
                                       side_effect=ValueError('token scan exploded')), \
                     mock.patch.object(owned_process, 'terminate_group',
                                       return_value=[]) as terminate_group:
                    with self.assertRaises(ValueError):
                        owned_process.run_split(command, {}, log, 10)
                self.assertGreater(terminate_group.call_count, 0,
                                   'the group scan must run even though the token scan raised')
                self.assertIn('OWNED_PROCESS_SWEEP_ANOMALY: token scan exploded', log.read_text())
            finally:
                self.kill_marker_tree(Path(folder) / 'tail-split.pid.grand')

    def test_a_deadline_sweep_anomaly_still_writes_the_timeout_log(self):
        """A failing deadline sweep must not replace the timeout with the anomaly."""
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'deadline-anomaly.log'
            log.write_text('')
            marker = Path(folder) / 'da.pid'
            command = [PYTHON, '-c', self.SLOW_TREE, str(marker)]
            with mock.patch.object(owned_process, '_terminate_tree',
                                   return_value=([], ValueError('deadline sweep exploded'))):
                with self.assertRaises(subprocess.TimeoutExpired):
                    owned_process.run(command, {}, log, 0.5)
            text = log.read_text()
            self.assertIn('TIMEOUT:', text, 'the deadline result must survive a sweep anomaly')
            self.assertIn('OWNED_PROCESS_SWEEP_ANOMALY: deadline sweep exploded', text)
            self.assertIn('OWNED_PROCESSES: terminated', text, 'the sweeps pass their (empty) names through')
            pid = int(marker.read_text())
            try:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)  # the mocked sweep cannot kill the real child; this test owns it
            except (ProcessLookupError, ChildProcessError):
                pass

    def test_a_cancelled_run_with_a_tail_anomaly_keeps_both_markers(self):
        """A cancellation winning the tail must not hide a sweep failure (#403 review).

        The child exits nonzero on its own and is reaped; the cancel flips
        after the collect (stopping nothing, still recording the run as
        stopped) and the tail's token scan raises with no survivors: the
        stopped branch writes the log, so the anomaly must already be in it
        beside the CANCELLED marker, never dropped.
        """
        with tempfile.TemporaryDirectory() as folder:
            handle = owned_process.CancelHandle()
            log = Path(folder) / 'cancel-anomaly.log'
            log.write_text('')
            real_collect = owned_process._collect
            real_terminate = owned_process.terminate
            flip_done = threading.Event()

            def flipping_collect(process, deadline, on_exit=None):
                result = real_collect(process, deadline, on_exit)  # the child exits and is reaped here
                handle.cancel()  # still pinned: the run reads as stopped, nothing named
                flip_done.set()
                return result

            def tail_exploding_terminate(token_value):
                # The cancel's own sweep ran before flip_done; only the run's
                # tail sweep raises.
                if flip_done.is_set():
                    raise ValueError('tail token scan exploded')
                return real_terminate(token_value)

            with mock.patch.object(owned_process, '_collect', side_effect=flipping_collect), \
                 mock.patch.object(owned_process, 'terminate', side_effect=tail_exploding_terminate), \
                 mock.patch.object(owned_process, 'terminate_group', return_value=[]):
                with self.assertRaises(owned_process.Cancelled):
                    owned_process.run([PYTHON, '-c', 'import sys; sys.exit(3)'], {}, log, 30,
                                      cancel=handle)
            self.assertTrue(handle.stopped_run, 'the schedule only binds with the run read as stopped')
            text = log.read_text()
            self.assertIn('CANCELLED:', text, 'the cancellation marker must stand')
            self.assertIn('OWNED_PROCESS_SWEEP_ANOMALY: tail token scan exploded', text,
                          'the tail sweep failure must not hide behind the cancellation marker')

    def test_a_post_settle_write_targets_the_owning_run_s_log(self):
        """A note written after the handoff closed must not steal a later run's log or report.

        The late/anomaly/post-exit branches settle, then write. If another
        run registered in that gap, an emit-shaped write would land the first
        run's note in the second run's log and drain the second run's report
        stream (#403 adversarial review round).
        """
        with tempfile.TemporaryDirectory() as folder:
            handle = owned_process.CancelHandle()
            own_log = Path(folder) / 'own.log'
            own_log.write_text('')
            later_log = Path(folder) / 'later.log'
            later_log.write_text('')
            real_settle = owned_process.CancelHandle.settle
            later_process, _ = owned_process._start([PYTHON, '-c', 'import time; time.sleep(60)'], {}, None, False)
            published = [{'pid': 424242, 'name': 'later-carrier'}]

            def settling_then_registering(handle_self):
                report = real_settle(handle_self)  # the phase closes and releases here
                # A later run registers on the released handle and its cancel
                # publishes a report before the owning call's final write.
                assert handle_self.register(later_process, 'token-b', later_log), \
                    'the control only holds with a released handle'
                handle_self._publish(published)
                return report

            def collected_without_leak(process, deadline, on_exit=None):
                deadline_wait = time.monotonic() + 5
                while process.poll() is None and time.monotonic() < deadline_wait:
                    time.sleep(0.02)  # poll reaps the exited child: no zombie leak
                process.poll()
                if on_exit is not None:
                    on_exit(0)
                return (0, {process.stdout.fileno(): 'out\n'}, 7, False, 0)

            try:
                with mock.patch.object(owned_process.CancelHandle, 'settle',
                                       settling_then_registering), \
                     mock.patch.object(owned_process, '_collect', side_effect=collected_without_leak):
                    returncode, output = owned_process.run(
                        [PYTHON, '-c', 'import sys; sys.exit(0)'], {}, own_log, 10, cancel=handle)
                self.assertEqual(returncode, 0)
                self.assertIn('POST_EXIT_OUTPUT', output, 'the control only binds with a post-settle write')
                self.assertIn('POST_EXIT_OUTPUT', own_log.read_text(),
                              "the owning run's note must land in its own log")
                self.assertEqual(later_log.read_text(), '',
                                 "a post-settle write must never reach a later run's log")
                self.assertEqual(handle.absorb(), published,
                                 "the later run's pending report stays its reader's")
            finally:
                handle.unregister()
                handle.settle()
                if later_process.poll() is None:
                    later_process.kill()
                later_process.wait(timeout=10)

    def test_a_handle_pins_exactly_one_run_and_refuses_a_second(self):
        with tempfile.TemporaryDirectory() as folder:
            handle = owned_process.CancelHandle()
            first, outcome, log, pid = self.start_cancel_run(folder, owned_process.run, handle, self.SLOW_TREE)
            self.assertIsNotNone(pid, 'the control only holds with a live pinned run')
            second_log = Path(folder) / 'second.log'
            second_log.write_text('')
            with self.assertRaises(ValueError):
                owned_process.run([PYTHON, '-c', 'import time; time.sleep(60)'], {}, second_log, 10, cancel=handle)
            handle.cancel()
            first.join(timeout=15)
            self.assertIsInstance(outcome.get('error'), owned_process.Cancelled,
                                  'the pinned run must still cancel normally — a silently overwritten pin '
                                  'would leave it running to its own deadline instead')
            self.assert_tree_gone(pid)

    def test_the_group_kill_survives_a_broken_killpg(self):
        with tempfile.TemporaryDirectory() as folder:
            handle = owned_process.CancelHandle()
            thread, outcome, log, pid = self.start_cancel_run(folder, owned_process.run, handle, self.SLOW_TREE)
            self.assertIsNotNone(pid, 'the control only holds with a live tree')
            with mock.patch.object(owned_process.os, 'killpg', side_effect=OSError(1, 'broken')):
                handle.cancel()
            thread.join(timeout=15)
            self.assertIsInstance(outcome.get('error'), owned_process.Cancelled,
                                  'the wave of sweeps and the pinned group signal must stop the tree anyway')
            self.assert_tree_gone(pid)
            self.assertIn('CANCELLED:', log.read_text())

    def test_a_cancel_arriving_after_completion_keeps_the_run_result(self):
        """A cancel landing on an empty handle must not relabel a completed run."""
        with tempfile.TemporaryDirectory() as folder:
            handle = owned_process.CancelHandle()
            log = Path(folder) / 'late.log'
            log.write_text('')
            real_terminate = owned_process.terminate

            def flipping_terminate(token_value):
                if not handle.cancelled:
                    handle.cancel()  # lands after unregister: nothing to stop
                return real_terminate(token_value)

            with mock.patch.object(owned_process, 'terminate', flipping_terminate):
                returncode, output = owned_process.run([PYTHON, '-c', 'import sys; sys.exit(3)'],
                                                       {}, log, 10, cancel=handle)
            self.assertEqual(returncode, 3, 'a completed run keeps its own return code')
            self.assertFalse(handle.stopped_run, 'the cancel stopped nothing and must not claim it did')
            self.assertNotIn('CANCELLED', log.read_text())

    def test_a_failed_emit_write_restores_its_drained_report(self):
        """A failing sink must not swallow the report emit() drained (#403 review).

        emit() takes the pending report before writing; a sink failure used
        to lose those names. The report comes back for the run's defensive
        settle, which appends it through the same door a cancel uses.
        """
        process, token_value = owned_process._start([PYTHON, '-c', 'import time; time.sleep(60)'], {}, None, False)
        try:
            handle = owned_process.CancelHandle()

            class FailingSink:
                def write_text(self, text):
                    raise OSError('sink exploded')

            self.assertTrue(handle.register(process, token_value, FailingSink()))
            handle._publish([{'pid': 999777, 'name': 'cancel-carrier'}])
            with self.assertRaises(OSError):
                handle.emit('run text\n')
            report = handle.settle()
            self.assertEqual([item['name'] for item in report], ['cancel-carrier'],
                             'the drained report must survive a failed write')
        finally:
            handle.unregister()
            handle.settle()
            if process.poll() is None:
                process.kill()
            process.wait(timeout=10)

    def test_registration_stays_refused_until_the_report_phase_closes(self):
        """A run finishing its report keeps the handle to itself (#398/#400 review).

        The window between unregister and the final emit/settle is where a
        second registration handed the first run's emit() the second run's
        log and its report stream. Registration must refuse through that
        whole phase and succeed again once the handoff closed.
        """
        first, _ = owned_process._start([PYTHON, '-c', 'import time; time.sleep(60)'], {}, None, False)
        second, _ = owned_process._start([PYTHON, '-c', 'import time; time.sleep(60)'], {}, None, False)
        try:
            handle = owned_process.CancelHandle()
            with tempfile.TemporaryDirectory() as folder:
                first_log = Path(folder) / 'first.log'
                second_log = Path(folder) / 'second.log'
                self.assertTrue(handle.register(first, 'token-a', first_log),
                                'the control only holds with an accepted registration')
                handle.unregister()  # the pin is released; the report phase is not
                self.assertFalse(handle.register(second, 'token-b', second_log),
                                 'a second registration during the report phase would hand the first '
                                 'run\'s emit() the second run\'s log')
                handle.settle()  # the first run's no-write exit closes and releases
                self.assertTrue(handle.register(second, 'token-b', second_log),
                                'the handle must accept a run again after the report phase closed')
                handle.unregister()
                handle.settle()
            self.assertFalse(handle._reporting, 'a released handle carries no open report phase')
        finally:
            for process in (first, second):
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=10)

    def test_the_run_log_names_every_survivor_beyond_the_cap(self):
        """The written report carries every claimed pid; the cap is for exception summaries only."""
        process, token_value = owned_process._start([PYTHON, '-c', 'import time; time.sleep(60)'], {}, None, False)
        try:
            handle = owned_process.CancelHandle()
            with tempfile.TemporaryDirectory() as folder:
                log = Path(folder) / 'capped.log'
                self.assertTrue(handle.register(process, token_value, log))
                survivors = [{'pid': 5000 + index, 'name': f'sweep{index}'} for index in range(9)]
                fresh = handle._publish(survivors)  # handoff open: the report waits for its one reader
                self.assertEqual(len(fresh), 9)
                text = handle.emit('run finished\n')
                handle.unregister()
                self.assertNotIn('and 1 more', text, 'the run log must not truncate a claimed pid')
                for survivor in survivors:
                    self.assertIn(f"pid {survivor['pid']} ({survivor['name']})", text,
                                  f"claimed pid {survivor['pid']} must reach the run log")
                self.assertIn(f"pid {survivors[-1]['pid']}", log.read_text(),
                              'the written log carries the complete report')
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=10)


    def test_the_final_token_sweep_survives_a_failing_group_pass(self):
        """A failing post-kill group pass must not skip the token sweep or discard collected names."""
        process, token_value = owned_process._start([PYTHON, '-c', 'import time; time.sleep(30)'], {}, None, False)
        group_results = iter([[{'pid': process.pid, 'name': 'leader'}], ValueError('group pass exploded')])
        try:
            def flaky_group(group_pid, started_before=None):
                result = next(group_results)
                if isinstance(result, Exception):
                    raise result
                return result

            with mock.patch.object(owned_process, 'terminate_group', flaky_group), \
                 mock.patch.object(owned_process, 'terminate',
                                   return_value=[{'pid': process.pid + 1, 'name': 'carrier'}]) as terminate:
                named, anomaly = owned_process._terminate_tree(process, token_value)
            self.assertEqual(terminate.call_count, 2,
                             'the final token sweep must run even when the post-kill group pass raises')
            self.assertIsInstance(anomaly, ValueError, 'the sweep anomaly must still resurface')
            self.assertEqual([item['name'] for item in named], ['leader', 'carrier'],
                             'the names both sweeps collected must come back beside the anomaly')
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=10)

    def test_cancel_closes_the_pinned_descriptor(self):
        with tempfile.TemporaryDirectory() as folder:
            opened_before = len(os.listdir('/proc/self/fd'))
            for index in range(10):
                iteration = Path(folder) / f'iter{index}'
                iteration.mkdir()
                handle = owned_process.CancelHandle()
                thread, outcome, log, pid = self.start_cancel_run(iteration, owned_process.run, handle, self.SLOW_TREE)
                self.assertIsNotNone(pid, 'the control only holds with a live tree')
                handle.cancel()
                thread.join(timeout=15)
                self.assertIsInstance(outcome.get('error'), owned_process.Cancelled)
            self.assertLessEqual(len(os.listdir('/proc/self/fd')), opened_before + 4,
                                 'each cancel must close its pinned descriptor, not leak one per run')

    def test_an_interrupt_survives_a_sweep_anomaly_and_still_reaps(self):
        """The interrupt path must unpack the tree result, keep the interrupt and reap."""
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'interrupt-anomaly.log'
            log.write_text('')
            marker = Path(folder) / 'ia.pid'
            command = [PYTHON, '-c', self.SLOW_TREE, str(marker)]

            def interrupting_collect(process, deadline, on_exit=None):
                deadline_marker = time.monotonic() + 5
                while not marker.exists() and time.monotonic() < deadline_marker:
                    time.sleep(0.01)
                raise KeyboardInterrupt

            with mock.patch.object(owned_process, '_collect', side_effect=interrupting_collect), \
                 mock.patch.object(owned_process, '_terminate_tree',
                                   return_value=([{'pid': 424242, 'name': 'swept'}], ValueError('sweep exploded'))):
                with self.assertRaises(KeyboardInterrupt):
                    owned_process.run(command, {}, log, 30)
            text = log.read_text()
            self.assertIn('OWNED_PROCESSES: terminated', text, 'the sweeps names survive the interrupt')
            self.assertIn('OWNED_PROCESS_SWEEP_ANOMALY', text, 'the sweep anomaly is recorded, never masking the interrupt')
            pid = int(marker.read_text())
            try:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)  # the seam's mocked sweep cannot kill the real child; this test owns it
            except (ProcessLookupError, ChildProcessError):
                pass

    def test_the_pinned_group_signal_targets_the_process_group(self):
        process, token_value = owned_process._start([PYTHON, '-c', 'import time; time.sleep(30)'], {}, None, False)
        pinned = os.pidfd_open(process.pid)
        try:
            with mock.patch.object(owned_process.signal, 'pidfd_send_signal') as pidfd, \
                 mock.patch.object(owned_process.os, 'killpg') as killpg:
                owned_process._signal_group(process, pinned)
            self.assertEqual(pidfd.call_count, 1, 'the pinned leader carries the group signal')
            arguments = pidfd.call_args.args
            self.assertEqual(arguments[0], pinned)
            self.assertEqual(arguments[1], signal.SIGKILL)
            self.assertEqual(arguments[3], 4, 'flags must select PIDFD_SIGNAL_PROCESS_GROUP (4), '
                                              'not the thread group (1) — a leader-only kill strands descendants')
            killpg.assert_not_called()
        finally:
            os.close(pinned)
            if process.poll() is None:
                process.kill()
            process.wait(timeout=10)

    # Value: protects=the pinned group kill's real reach (#398 review rounds
    # disagreed about the pidfd flag value); proves=the flag the module passes
    # reaches the whole process group through the pinned leader on this kernel;
    # seam=_signal_group against a live leader that owns its group.
    def test_the_pinned_group_signal_reaches_a_same_group_descendant(self):
        with tempfile.TemporaryDirectory() as folder:
            marker = Path(folder) / 'group-leader.pid'
            process, token_value = owned_process._start(
                [PYTHON, '-c', """
import os, sys, time
pid = os.fork()
if pid == 0:
    open(sys.argv[1] + '.grand.tmp', 'w').write(str(os.getpid()))
    os.rename(sys.argv[1] + '.grand.tmp', sys.argv[1] + '.grand')
    time.sleep(60)
open(sys.argv[1], 'w').write(str(os.getpid()))
time.sleep(60)
""", str(marker)], {}, None, False)
            deadline = time.monotonic() + 10
            while not (marker.exists() and Path(str(marker) + '.grand').exists()) and time.monotonic() < deadline:
                time.sleep(0.05)
            leader = int(marker.read_text())
            descendant = int(Path(str(marker) + '.grand').read_text())
            self.assertEqual(process.pid, leader, 'the direct child must own its group for this probe')
            pinned = os.pidfd_open(process.pid)
            try:
                owned_process._signal_group(process, pinned)
                deadline = time.monotonic() + 5
                while (not terminated(descendant) or process.poll() is None) and time.monotonic() < deadline:
                    time.sleep(0.05)
                process.wait(timeout=5)  # reap the killed leader; a zombie still answers kill(0)
                self.assertTrue(terminated(descendant),
                                'the pinned process-group signal must reach a same-group descendant')
                self.assertFalse(alive(leader), 'the pinned signal must stop the leader itself')
            finally:
                os.close(pinned)
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=10)

    def test_a_cancelled_handle_refuses_a_new_run_before_any_process_starts(self):
        handle = owned_process.CancelHandle()
        self.assertEqual(handle.cancel(), [], 'an empty handle has nothing to cancel')
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'refused.log'
            with mock.patch.object(owned_process, '_start') as start:
                with self.assertRaises(ValueError):
                    owned_process.run([PYTHON, '-c', 'print("no")'], {}, log, 10, cancel=handle)
                start.assert_not_called()

    def test_a_cancel_landing_between_start_and_registration_cleans_the_tree_up(self):
        handle = owned_process.CancelHandle()
        real_start = owned_process._start
        started = {}

        def racing_start(command, environment, cwd, input_text):
            process, token_value = real_start(command, environment, cwd, input_text)
            started['process'] = process
            handle.cancel()
            return process, token_value

        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'raced.log'
            log.write_text('')
            with mock.patch.object(owned_process, '_start', side_effect=racing_start):
                with self.assertRaises(ValueError):
                    owned_process.run([PYTHON, '-c', 'import time; time.sleep(60)'], {}, log, 10, cancel=handle)
            process = started['process']
            self.assert_tree_gone(process.pid)
            process.wait(timeout=10)  # the cleanup reaps before refusing, so nothing is left to this test
            named = [int(part.split("'pid': ")[1].split(',')[0]) for part in log.read_text().split('OWNED_PROCESSES:')[1:]]
            self.assertEqual([pid for pid in named if pid != process.pid], [],
                             'a tree killed before it could fork may name only its own direct child')

    def test_cancellation_requires_the_kernel_ownership_surface(self):
        handle = owned_process.CancelHandle()
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'surface.log'
            with mock.patch.object(owned_process, '_owned_surface', return_value=False):
                with mock.patch.object(owned_process.subprocess, 'run') as fallback:
                    with self.assertRaises(ValueError):
                        owned_process.run([PYTHON, '-c', 'print("no")'], {}, log, 10, cancel=handle)
                    fallback.assert_not_called()

    # Value: protects=the shared named-pid registry behind once-only survivor naming;
    # fails_when=the cancel path and the run path both name the same pid (#381's class);
    # seam=owned_process.CancelHandle.claim
    def test_claim_names_each_pid_exactly_once(self):
        handle = owned_process.CancelHandle()
        first = handle.claim([{'pid': 5, 'name': 'a'}, {'pid': 5, 'name': 'a-again'}, {'pid': 6, 'name': 'b'}])
        self.assertEqual([item['pid'] for item in first], [5, 6], 'a duplicated candidate is named on first sight only')
        self.assertEqual(handle.claim([{'pid': 5, 'name': 'a'}, {'pid': 7, 'name': 'c'}]), [{'pid': 7, 'name': 'c'}])

    # Value: protects=the owning call's single report consumption point (#399, window A);
    # fails_when=absorb returns while a cancel is still sweeping and its names stay unconsumed;
    # seam=owned_process.identities gated mid-sweep
    def test_absorb_waits_out_a_cancel_in_flight_and_drains_its_report_once(self):
        handle = owned_process.CancelHandle()
        real_identities = owned_process.identities
        gate = threading.Event()

        def gated_identities(token_value):
            gate.wait(timeout=10)  # hold the cancel mid-sweep until the owning call absorbs
            return real_identities(token_value)

        process, token_value = owned_process._start([PYTHON, '-c', 'import time; time.sleep(30)'], {}, None, False)
        try:
            outcome = {}

            def canceling():
                outcome['named'] = handle.cancel()

            self.assertTrue(handle.register(process, token_value, None))
            with mock.patch.object(owned_process, 'identities', gated_identities):
                thread = threading.Thread(target=canceling)
                thread.start()
                deadline = time.monotonic() + 5
                while not handle.cancelled and time.monotonic() < deadline:
                    time.sleep(0.01)
                consumed = handle.absorb()  # must wait out the gated sweeps, not return an empty snapshot
            gate.set()
            thread.join(timeout=10)
            self.assertFalse(thread.is_alive(), 'the cancel must finish once its gate opens')
            self.assertEqual([item['pid'] for item in consumed], [process.pid],
                             'absorb carries the in-flight cancel survivor, never an empty race snapshot')
            exit_code = process.wait(timeout=10)
            self.assertNotEqual(exit_code, 0, 'the gated cancel still killed the tree')
            self.assertEqual(handle.absorb(), [], 'the report drains once')
        finally:
            gate.set()
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)

    # Value: protects=the log handoff after the owning call's final write (#399, both windows);
    # fails_when=a cancel naming a survivor after emit() leaves the log without the name;
    # seam=owned_process.CancelHandle.emit and the append door
    def test_a_cancel_after_the_final_write_appends_its_sightings_to_the_log(self):
        with tempfile.TemporaryDirectory() as folder:
            handle = owned_process.CancelHandle()
            log = Path(folder) / 'late-append.log'
            log.write_text('')
            process, token_value = owned_process._start([PYTHON, '-c', 'import time; time.sleep(30)'], {}, None, False)
            try:
                self.assertTrue(handle.register(process, token_value, log))
                handle.emit('TIMEOUT: the owning call already wrote its final log\n')
                survivors = handle.cancel()  # starts after the close: its names may not travel by report
                self.assertEqual([item['pid'] for item in survivors], [process.pid])
                process.wait(timeout=10)
                text = log.read_text()
                self.assertIn('TIMEOUT:', text, 'the owning call written text stays intact beside the append')
                self.assertIn(f'OWNED_PROCESSES: terminated pid {process.pid}', text,
                              'the late cancel sighting reaches the log through the append door')
                self.assertLessEqual(text.count(f'pid {process.pid} '), 1, 'no pid may be named twice (#381)')
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=10)

    # Value: protects=the post-reap group sweep armed by the registration pin (#404);
    # fails_when=a cancel landing after the owner reaped strands a token-scrubbed
    # same-group member, or names/kills a recycled group instead;
    # seam=owned_process.CancelHandle.cancel against a reaped leader
    def test_a_cancel_after_the_owner_reaped_still_sweeps_the_group_under_the_pin(self):
        with tempfile.TemporaryDirectory() as folder:
            marker = Path(folder) / 'member.pid'
            log = Path(folder) / 'reaped-cancel.log'
            log.write_text('')
            process, token_value = owned_process._start([PYTHON, '-c', f"""
import os, subprocess, sys, time
scrubbed = {{k: v for k, v in os.environ.items() if k != {owned_process.TOKEN_VARIABLE!r}}}
member = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], env=scrubbed)
open(sys.argv[1] + '.tmp', 'w').write(str(member.pid))
os.rename(sys.argv[1] + '.tmp', sys.argv[1])
time.sleep(0.2)
""", str(marker)], {}, None, False)
            handle = owned_process.CancelHandle()
            self.assertTrue(handle.register(process, token_value, log))
            try:
                deadline = time.monotonic() + 5
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                member_pid = int(marker.read_text())
                process.wait(timeout=10)  # the owning call reaps before the cancel lands
                fresh = handle.cancel()
                self.assertIn(member_pid, [item['pid'] for item in fresh],
                              'the post-reap group sweep must name the token-scrubbed member')
                deadline = time.monotonic() + 10
                while not terminated(member_pid) and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertTrue(terminated(member_pid), 'the named member must be terminated')
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=10)
                if not terminated(member_pid):
                    # The escape assertion may have failed before the sweep
                    # stopped the member: no stray 30s sleeper on a red run.
                    try:
                        os.kill(member_pid, signal.SIGKILL)
                    except OSError:
                        pass
                handle.unregister()

    # Value: protects=the exit boundary a cancel inherits from the owning call (#404 review);
    # fails_when=a post-reap cancel scans the numeric group id unbounded after
    # the owning call already observed and published the exit tick;
    # seam=CancelHandle.publish_exit_boundary through a recorded _terminate_tree
    def test_a_cancel_scans_with_the_published_exit_boundary(self):
        process, token_value = owned_process._start([PYTHON, '-c', 'import time; time.sleep(30)'], {}, None, False)
        handle = owned_process.CancelHandle()
        try:
            self.assertTrue(handle.register(process, token_value, None))
            handle.publish_exit_boundary(123456)
            observed = {}

            def recording_tree(process_arg, token_arg, pinned_arg, boundary=None):
                observed['boundary'] = boundary
                return [], None

            with mock.patch.object(owned_process, '_terminate_tree', recording_tree):
                handle.cancel()
            self.assertEqual(observed['boundary'], 123456,
                             'the cancel bounds its post-reap scans with the published exit tick')
            self.assertTrue(handle.stopped_run, 'the control only binds when the cancel stopped the run')
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)
            handle.unregister()


class LeaderPinTests(unittest.TestCase):
    """Value: the leader pidfd is the recycle-proof signal identity (#404).

    The pin is opened before anything can reap the leader and held past
    the final sweep. It makes the flag-4 group signal recycle-proof: the
    kernel resolves the process group through the pinned struct pid,
    which stays valid in every leader state. It does not reserve the
    numeric group id — the kernel frees the id for reissue when the last
    task link detaches, measured across a full allocator cycle
    (pid_max=99999) during the #404 review — so the numeric scans keep
    their exit boundary, and these witnesses bind only the signal
    contract. The 2026-11-18 matrix on kernel 6.12.76 measured flag-4
    group signaling valid through alive, zombie and reaped leaders with
    a surviving member killed in every state.
    """

    # Value: protects=the kernel contract the pin semantics lean on (#404);
    # fails_when=the production tail claims a delivered group signal the
    # kernel did not perform, whatever this kernel's flag-4 semantics are;
    # seam=real pidfd_send_signal against a reaped leader's surviving member,
    # measured through the verified tail
    def test_pinned_group_signal_reaches_members_after_the_leader_is_reaped(self):
        # The matrix so far: kernel 6.12.76 delivers flag-4 through a reaped
        # leader's pin (2026-11-18, #404); a 2026-11-19 Gate runner accepted
        # the same send without stopping the member, which is the kernel class
        # the send-time verification exists for. The witness no longer pins
        # one kernel's semantics — unpinned runner kernels change under the
        # gate — it pins that the tail's verdict always matches what the
        # kernel actually did: delivered exactly when the member died, the
        # failed-cleanup note with an error exactly when it did not.
        with tempfile.TemporaryDirectory() as folder:
            member_marker = Path(folder) / 'member.pid'
            leader = subprocess.Popen([PYTHON, '-c', """
import os, subprocess, sys, time
member = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
open(sys.argv[1] + '.tmp', 'w').write(str(member.pid))
os.rename(sys.argv[1] + '.tmp', sys.argv[1])
time.sleep(60)
""", str(member_marker)], start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            pinned = os.pidfd_open(leader.pid)
            member_pid = None
            try:
                deadline = time.monotonic() + 5
                while not member_marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                member_pid = int(member_marker.read_text())
                leader.kill()
                leader.wait(timeout=10)  # reaped: only the pin still references its identity
                probe = type('ReapedLeader', (), {'pid': leader.pid, 'poll': lambda self: 0})()
                with mock.patch.object(owned_process, 'GROUP_SIGNAL_VERIFY_SECONDS', 5.0):
                    note, error = owned_process._tail_group_signal(
                        probe, pinned, True,
                        verify=lambda started_before: owned_process.group_members(
                            leader.pid, started_before=started_before))
                deadline = time.monotonic() + 10
                while not terminated(member_pid) and time.monotonic() < deadline:
                    time.sleep(0.05)
                if terminated(member_pid):
                    self.assertRegex(note or '', r'OWNED_PROCESS_GROUP_SIGNAL:')
                    self.assertIsNone(error,
                                      'a delivered signal is a completed cleanup')
                else:
                    self.assertRegex(note or '', r'OWNED_PROCESS_GROUP_SIGNAL_FAILED:')
                    self.assertIsNotNone(error,
                                         'a kernel that accepted the send without stopping '
                                         'the member must never read as a clean teardown')
            finally:
                os.close(pinned)
                for pid in (member_pid,):
                    if pid is not None and not terminated(pid):
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except OSError:
                            pass
                if leader.poll() is None:
                    leader.kill()
                leader.wait(timeout=10)

    # Value: protects=the kill-time attribution recheck (#404);
    # fails_when=a recycled pid receives a signal the scan meant for an owned tree;
    # seam=owned_process._send_kill with a belongs recheck
    def test_send_kill_skips_an_identity_that_stopped_matching(self):
        delivered = []
        with mock.patch.object(owned_process.os, 'kill', side_effect=lambda pid, sig: delivered.append((pid, sig))), \
                mock.patch.object(owned_process.os, 'pidfd_open', side_effect=OSError(errno.EMFILE, 'no descriptors')):
            self.assertFalse(owned_process._send_kill(4242, belongs=lambda pid: False),
                             'a stale attribution must skip the kill')
            self.assertEqual(delivered, [], 'the skipped kill must not signal anyone')
            self.assertTrue(owned_process._send_kill(4242, belongs=lambda pid: True),
                            'a matching attribution still kills')
            self.assertEqual(delivered, [(4242, signal.SIGKILL)])

    # Value: protects=the ESRCH short-circuit of the kill path (#404 review);
    # fails_when=a numeric kill fires after pidfd_open proved the process gone,
    # where a pid recycled inside that window could receive it;
    # seam=owned_process._send_kill with an ESRCH pidfd_open
    def test_send_kill_names_a_verifiably_gone_process_without_a_numeric_kill(self):
        delivered = []
        with mock.patch.object(owned_process.os, 'kill', side_effect=lambda pid, sig: delivered.append((pid, sig))), \
                mock.patch.object(owned_process.os, 'pidfd_open', side_effect=OSError(errno.ESRCH, 'no process')):
            self.assertTrue(owned_process._send_kill(4242, belongs=None),
                            'a verifiably gone carrier stays named as self-terminated')
            self.assertEqual(delivered, [], 'no numeric kill may follow a proven-gone open')

    # Value: protects=the kill-time identity recheck (#404 review);
    # fails_when=a recycled pid receives a signal meant for an owned tree, or a
    # scrubbed/execing carrier is skipped and stranded;
    # seam=owned_process._identity_check against a fake /proc root
    def test_the_identity_recheck_keeps_carriers_and_skips_recycled_pids(self):
        with tempfile.TemporaryDirectory() as folder:
            proc = Path(folder)
            for pid, start in (('610', '5'), ('611', '999')):
                entry = proc / pid
                entry.mkdir()
                # state pgrp session ... starttime(19): a full stat shape per pid.
                (entry / 'stat').write_text(f'{pid} (x) S 1 77 77 0 -1 4194304 ' + '0 ' * 12 + f'{start}')
            unreadable = proc / '612'
            unreadable.mkdir()  # no stat file: the kill-time read fails
            belongs = owned_process._identity_check(5, proc=proc)
            self.assertTrue(belongs(610), 'a matching starttime is the scanned process: execs and scrubs keep it')
            self.assertFalse(belongs(611), 'a different starttime is a recycled pid: skip the kill')
            self.assertTrue(belongs(612), 'an unreadable entry keeps the kill (bias toward the scan)')
            self.assertTrue(owned_process._identity_check(None, proc=proc)(610),
                            'a scan without a starttime keeps the kill')
            self.assertTrue(owned_process._identity_check(5, proc=proc)(613),
                            'a vanished pid cannot be re-checked; the scan owned it')

    # Value: protects=the exit-bounded post-exit group scan seam (#404 review);
    # fails_when=a scan drops the exit boundary — the pin does not reserve the
    # numeric group id, so an unbounded scan could name a recycled group;
    # seam=owned_process._post_exit_group_sweep with a recorded terminate_group
    def test_the_post_exit_group_sweep_keeps_the_boundary(self):
        with mock.patch.object(owned_process, 'terminate_group', return_value=[]) as sweep:
            owned_process._post_exit_group_sweep(77, boundary=10, token_value='tok')
        self.assertEqual(sweep.call_args.kwargs, {'started_before': 10, 'token_value': 'tok'},
                         'the pin does not reserve the id: the scan keeps the boundary')

    # Value: protects=the numeric fallback gate of the pinned group signal (#404 review);
    # fails_when=a pidfd error on a reaped child falls back to a numeric killpg
    # that a recycled group could receive, or an unreaped child loses its fallback;
    # seam=owned_process._signal_group with a recorded os.killpg
    def test_the_group_signal_refuses_the_numeric_fallback_on_a_reaped_child(self):
        class Process:
            def __init__(self, reaped, pid=424242):
                self._reaped = reaped
                self.pid = pid

            def poll(self):
                return 0 if self._reaped else None

        refused = Process(reaped=True)
        killpg_calls = []
        with mock.patch.object(owned_process.signal, 'pidfd_send_signal',
                               side_effect=OSError(errno.ESRCH, 'no process')), \
                mock.patch.object(owned_process.os, 'killpg',
                                  side_effect=lambda pid, sig: killpg_calls.append(pid)):
            owned_process._signal_group(refused, pinned=9)
            self.assertEqual(killpg_calls, [], 'ESRCH through the pin must not degrade to a numeric killpg')
            # A pinned group signal never falls back numerically: the owner can
            # reap the child between any liveness check and the call, so the
            # per-pid pinned sweeps beside this pass are the only stops.
            unreaped = Process(reaped=False)
            owned_process._signal_group(unreaped, pinned=9)
            with mock.patch.object(owned_process.signal, 'pidfd_send_signal',
                                   side_effect=AttributeError('no pidfd_send_signal')):
                owned_process._signal_group(refused, pinned=9)
                owned_process._signal_group(unreaped, pinned=9)
            self.assertEqual(killpg_calls, [],
                             'a pinned group signal never degrades to a numeric killpg')
        # Without pidfd support at all, the numeric kill stays gated on an
        # unreaped child, whose id the zombie or the live members still hold.
        pinless_alive = Process(reaped=False)
        pinless_gone = Process(reaped=True)
        delivered = []
        with mock.patch.object(owned_process.os, 'killpg',
                               side_effect=lambda pid, sig: delivered.append(pid)) as killpg:
            owned_process._signal_group(pinless_alive, pinned=None)
            owned_process._signal_group(pinless_gone, pinned=None)
            self.assertEqual(delivered, [pinless_alive.pid],
                             'the pinless numeric kill runs only while the child is unreaped')

    # Value: protects=the tail's spared-member cleanup and its honest outcome (#404 review);
    # fails_when=a tokenless member forked after the boundary survives the run
    # unnamed, a healthy exit runs the group signal needlessly, or a failed
    # signal lets the run report clean while a spared member survives;
    # seam=_tail_group_signal with recorded and failing _signal_group shapes
    def test_the_tail_group_signal_reports_its_outcome(self):
        process = type('Probe', (), {'pid': 424242, 'poll': lambda self: 0})()
        with mock.patch.object(owned_process, '_signal_group', return_value='delivered') as signal_mock:
            note, error = owned_process._tail_group_signal(process, 9, True)
            self.assertRegex(note or '', r'OWNED_PROCESS_GROUP_SIGNAL:')
            self.assertIsNone(error, 'a delivered signal is a completed cleanup')
            self.assertEqual(signal_mock.call_count, 1)
        with mock.patch.object(owned_process, '_signal_group', return_value='empty') as signal_mock:
            note, error = owned_process._tail_group_signal(process, 9, True)
            self.assertIsNone(note, 'an emptied group is an ESRCH no-op, not a stop')
            self.assertIsNone(error)
            self.assertEqual(signal_mock.call_count, 1)
        with mock.patch.object(owned_process, '_signal_group', return_value='failed'):
            note, error = owned_process._tail_group_signal(process, 9, True)
            self.assertRegex(note or '', r'OWNED_PROCESS_GROUP_SIGNAL_FAILED:')
            self.assertIsNotNone(error, 'a failed signal must never read as a clean teardown')
        with mock.patch.object(owned_process, '_signal_group',
                               side_effect=AssertionError('must not run without members or a pin')) as signal_mock:
            note, error = owned_process._tail_group_signal(process, None, True)
            self.assertIsNone(note)
            self.assertIsNone(error)
            self.assertEqual(signal_mock.call_count, 0, 'no pin: the numeric tail signal stays off')
            note, error = owned_process._tail_group_signal(process, 9, False)
            self.assertIsNone(note)
            self.assertIsNone(error)
            self.assertEqual(signal_mock.call_count, 0, 'no members at exit: no signal')

    # Value: protects=the send-time verification of the pinned group signal (#404);
    # fails_when=a kernel that accepts the flag-4 send without stopping the group
    # reads as a delivered cleanup, or a slow-to-die member reads as undelivered;
    # seam=_tail_group_signal with recorded _signal_group outcomes and a scan stub
    def test_the_tail_group_signal_verifies_the_send_before_claiming_a_stop(self):
        process = type('Probe', (), {'pid': 424242, 'poll': lambda self: 0})()
        survivor = {'pid': 4243, 'name': 'member', 'start': 5}
        # A member that dies within the verify grace keeps the delivered
        # verdict: SIGKILL delivery waits for the member to be scheduled, and
        # the grace is exactly that latency budget.
        scans = []
        with mock.patch.object(owned_process, '_signal_group', return_value='delivered'):
            def dying_member(boundary):
                scans.append(boundary)
                return [survivor] if len(scans) == 1 else []

            note, error = owned_process._tail_group_signal(process, 9, True, verify=dying_member)
            self.assertRegex(note or '', r'OWNED_PROCESS_GROUP_SIGNAL:')
            self.assertIsNone(error)
            self.assertEqual(len(scans), 2, 'one empty scan ends the grace')
        # The ESRCH no-op is measured too: a kernel can answer ESRCH through a
        # reaped leader's pin while members still live.
        with mock.patch.object(owned_process, '_signal_group', return_value='empty'), \
                mock.patch.object(owned_process.time, 'monotonic', side_effect=[0.0, 10.0]):
            note, error = owned_process._tail_group_signal(process, 9, True, verify=lambda boundary: [survivor])
            self.assertRegex(note or '', r'OWNED_PROCESS_GROUP_SIGNAL_FAILED:')
            self.assertIsNotNone(error)
        with mock.patch.object(owned_process, '_signal_group', return_value='empty'):
            note, error = owned_process._tail_group_signal(process, 9, True, verify=lambda boundary: [])
            self.assertIsNone(note, 'a measured-empty group stays the honest no-op')
            self.assertIsNone(error)
        # An unreadable scan is never evidence of a stop: it polls to the
        # deadline and then fails exactly like a measured survivor.
        with mock.patch.object(owned_process, '_signal_group', return_value='delivered'), \
                mock.patch.object(owned_process.time, 'monotonic', side_effect=[0.0, 10.0]):
            def unreadable(boundary):
                raise OSError(errno.EACCES, 'proc walk refused')

            note, error = owned_process._tail_group_signal(process, 9, True, verify=unreadable)
            self.assertRegex(note or '', r'OWNED_PROCESS_GROUP_SIGNAL_FAILED:')
            self.assertIsNotNone(error)
        # The failed send keeps its own note and skips the verification: there
        # is nothing delivered to verify.
        with mock.patch.object(owned_process, '_signal_group', return_value='failed') as signal_mock:
            note, error = owned_process._tail_group_signal(process, 9, True, verify=lambda boundary: [])
            self.assertRegex(note or '', r'OWNED_PROCESS_GROUP_SIGNAL_FAILED:')
            self.assertIsNotNone(error)
            self.assertEqual(signal_mock.call_count, 1)
        # The boundaries the scans receive are the caller's concern; the tail
        # passes the send-time boundary through unchanged.
        with mock.patch.object(owned_process, '_signal_group', return_value='delivered'):
            seen = []
            owned_process._tail_group_signal(process, 9, True, verify=lambda boundary: seen.append(boundary))
            self.assertEqual(len(seen), 1, 'the verify callable receives the send-time boundary')

    # Value: protects=the containment of survivors an accepted-but-undelivered signal left (#404 review);
    # fails_when=the tail reports undelivery while the surviving member keeps running after cleanup,
    # or a slow-to-die member reads as an undelivered signal before its grace expires;
    # seam=_tail_group_signal with a recorded contain sweep behind the verify scan
    def test_the_tail_group_signal_contains_the_survivors_it_reports(self):
        process = type('Probe', (), {'pid': 424242, 'poll': lambda self: 0})()
        survivor = {'pid': 4243, 'name': 'member', 'start': 5}
        # A member that dies within the verify grace keeps the delivered
        # verdict and never reaches containment: SIGKILL delivery waits for
        # the member to be scheduled, so the grace comes first.
        scans = []
        sweeps = []
        with mock.patch.object(owned_process, '_signal_group', return_value='delivered'), \
                mock.patch.object(owned_process.time, 'monotonic', side_effect=[0.0, 0.2]) as ticks:
            def dying_member(boundary):
                scans.append(boundary)
                return [survivor] if len(scans) == 1 else []

            note, error = owned_process._tail_group_signal(
                process, 9, True, verify=dying_member,
                contain=lambda boundary: sweeps.append(boundary) or [survivor])
            self.assertRegex(note or '', r'OWNED_PROCESS_GROUP_SIGNAL:')
            self.assertIsNone(error, 'a member that dies inside the grace is a delivered signal')
            self.assertEqual(len(scans), 2, 'an emptied scan ends the grace without containment')
            self.assertEqual(sweeps, [], 'containment never runs inside the grace')
        # A member that survives the whole grace is contained once, and the
        # scan must confirm the group empty before the wording claims a stop;
        # the kernel breach itself stays a visible tooling error.
        scans = []
        sweeps = []
        with mock.patch.object(owned_process, '_signal_group', return_value='delivered'), \
                mock.patch.object(owned_process.time, 'monotonic',
                                  side_effect=[0.0, 10.0, 0.0, 0.2, 10.0]):
            def persisting_member(boundary):
                scans.append(boundary)
                return [survivor] if len(scans) <= 2 else []

            def contain(boundary):
                sweeps.append(boundary)
                return [survivor]

            note, error = owned_process._tail_group_signal(process, 9, True, verify=persisting_member, contain=contain)
        self.assertEqual(sweeps, [scans[0]], 'containment runs once, at the send boundary, after the grace')
        self.assertRegex(note or '', r'OWNED_PROCESS_GROUP_SIGNAL_FAILED:')
        self.assertIn('the boundary sweep stopped and named them', note)
        self.assertIn('4243', note, 'the contained member is named in the note')
        self.assertIsNotNone(error, 'the kernel breach stays visible even with the sweep contained it')
        # Containment's names are attempted stops, not proof: a member that
        # survives the containment grace keeps the may-survive wording.
        scans = []
        with mock.patch.object(owned_process, '_signal_group', return_value='delivered'), \
                mock.patch.object(owned_process.time, 'monotonic', side_effect=[0.0, 10.0, 0.0, 10.0]):
            note, error = owned_process._tail_group_signal(
                process, 9, True,
                verify=lambda boundary: scans.append(boundary) or [survivor],
                contain=lambda boundary: [survivor])
            self.assertIn('may survive', note, 'an unconfirmed containment never claims a stop')
            self.assertIn('the boundary sweep reached', note, 'the attempted sweep is still named')
            self.assertIsNotNone(error)
        # The no-containment deadline keeps the original may-survive wording.
        with mock.patch.object(owned_process, '_signal_group', return_value='delivered'), \
                mock.patch.object(owned_process.time, 'monotonic', side_effect=[0.0, 10.0]):
            note, error = owned_process._tail_group_signal(process, 9, True, verify=lambda boundary: [survivor])
            self.assertIn('may survive', note)
            self.assertIsNotNone(error)
        # A member that exits between the grace expiry and the containment
        # sweep does not turn an expired grace into a delivered signal: the
        # first verification measured the group non-empty past the window,
        # and that fact survives the later empty scan.
        scans = []
        with mock.patch.object(owned_process, '_signal_group', return_value='delivered'), \
                mock.patch.object(owned_process.time, 'monotonic', side_effect=[0.0, 10.0, 0.0]):
            def exits_early(boundary):
                scans.append(boundary)
                return [survivor] if len(scans) == 1 else []

            note, error = owned_process._tail_group_signal(
                process, 9, True, verify=exits_early, contain=lambda boundary: [])
            self.assertRegex(note or '', r'OWNED_PROCESS_GROUP_SIGNAL_FAILED:',
                             'an expired grace never reads as a delivered signal')
            self.assertIsNotNone(error)
        # The scan boundary follows the outcome: a delivered outcome proved
        # the kernel resolved this group at the send, so the scans may use the
        # send boundary; an emptied group keeps the caller's exit boundary,
        # because a reissued foreign group can hold tokenless members started
        # after the exit that the later send boundary would wrongly admit.
        seen = []
        with mock.patch.object(owned_process, '_signal_group', return_value='delivered'), \
                mock.patch.object(owned_process, '_boot_ticks', return_value=777):
            owned_process._tail_group_signal(process, 9, True, boundary=10,
                                             verify=lambda started_before: seen.append(started_before) or [])
            self.assertEqual(seen, [777], 'a delivered outcome scans at the send boundary')
        seen = []
        with mock.patch.object(owned_process, '_signal_group', return_value='empty'), \
                mock.patch.object(owned_process, '_boot_ticks', return_value=777):
            owned_process._tail_group_signal(process, 9, True, boundary=10,
                                             verify=lambda started_before: seen.append(started_before) or [])
            self.assertEqual(seen, [10], 'an emptied group scans at the caller\'s exit boundary')

    # Value: protects=the tree stop's containment of an undelivered pinned signal (#404);
    # fails_when=a kernel that accepted the send without delivering leaves the
    # spared class unnamed after the tree stop;
    # seam=_terminate_tree with a recorded terminate_group and pinned signal
    def test_the_tree_stop_sweeps_what_an_undelivered_pinned_signal_spared(self):
        process = type('Probe', (), {'pid': 424242, 'poll': lambda self: None})()
        survivor = {'pid': 4243, 'name': 'member', 'start': 5}
        boundaries = []
        tokens = []

        def fake_terminate_group(group, proc=None, started_before=None, token_value=None):
            boundaries.append(started_before)
            tokens.append(token_value)
            return [survivor] if started_before == 777 else []

        with mock.patch.object(owned_process, '_signal_group', return_value='delivered'), \
                mock.patch.object(owned_process, 'terminate_group', side_effect=fake_terminate_group), \
                mock.patch.object(owned_process, 'terminate', return_value=[]), \
                mock.patch.object(owned_process, '_boot_ticks', return_value=777):
            named, anomaly = owned_process._terminate_tree(process, 'token', pinned=9, boundary=10)
        self.assertEqual(boundaries, [10, 10, 777],
                         'the send-boundary sweep runs after the kill and the boundary sweeps')
        self.assertEqual(tokens[2], 'token',
                         'the send-boundary sweep keeps the token union, so a member forked '
                         'between the sample and the send is still named')
        self.assertEqual(named, [survivor], 'the spared member is stopped and named, not lost')
        self.assertIsNone(anomaly, 'a contained member is named in the report, not raised as an anomaly')
        with mock.patch.object(owned_process, '_signal_group', return_value='empty'), \
                mock.patch.object(owned_process, 'terminate_group', side_effect=fake_terminate_group), \
                mock.patch.object(owned_process, 'terminate', return_value=[]), \
                mock.patch.object(owned_process, '_boot_ticks', return_value=777):
            owned_process._terminate_tree(process, 'token', pinned=9, boundary=10)
            self.assertEqual(boundaries[-1], 10,
                             'an emptied group keeps the caller boundary: a reissued foreign '
                             'group can hold tokenless members the send boundary would admit')
        with mock.patch.object(owned_process, '_signal_group', return_value='failed'), \
                mock.patch.object(owned_process, 'terminate_group', side_effect=fake_terminate_group), \
                mock.patch.object(owned_process, 'terminate', return_value=[]), \
                mock.patch.object(owned_process, '_boot_ticks', return_value=777):
            named, anomaly = owned_process._terminate_tree(process, 'token', pinned=9, boundary=10)
        self.assertIsNotNone(anomaly, 'a failed send keeps its tooling-failure anomaly')
        with mock.patch.object(owned_process, '_signal_group', return_value='empty') as signal_mock, \
                mock.patch.object(owned_process, 'terminate_group', side_effect=fake_terminate_group), \
                mock.patch.object(owned_process, 'terminate', return_value=[]), \
                mock.patch.object(owned_process, '_boot_ticks', return_value=777) as ticks:
            named, anomaly = owned_process._terminate_tree(process, 'token', pinned=None, boundary=10)
            self.assertEqual(signal_mock.call_count, 1, 'the pinless decision stays inside _signal_group')
            self.assertEqual(boundaries[-1], 10, 'a pinless stop keeps its original sweep set')
            self.assertEqual(ticks.call_count, 0, 'a pinless stop never samples a send boundary')

    # Value: protects=the tail's spared-member cleanup end to end (#404 review);
    # fails_when=a tokenless member forked after the boundary survives the run
    # unnamed, or a healthy exit runs the group signal needlessly;
    # seam=the runners' tails with a recorded _signal_group
    def test_the_tail_runs_the_pinned_group_signal_only_for_escaped_members(self):
        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'tail-signal.log'
            log.write_text('')
            marker = Path(folder) / 'same-group.pid'
            command = [PYTHON, '-c', """
import os, subprocess, sys
scrubbed = {k: v for k, v in os.environ.items() if k != 'FORTRESS_OWNED_RUN'}
member = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'], env=scrubbed)
open(sys.argv[1] + '.tmp', 'w').write(str(member.pid))
os.rename(sys.argv[1] + '.tmp', sys.argv[1])
""", str(marker)]
            handle = owned_process.CancelHandle()
            deliveries = []
            with mock.patch.object(owned_process, '_signal_group',
                                   side_effect=lambda process_arg, pinned_arg: deliveries.append(pinned_arg) or 'delivered'):
                with self.assertRaises(owned_process.EscapedDescendants):
                    owned_process.run(command, {}, log, 20, cancel=handle)
            self.assertEqual(len(deliveries), 1,
                             'the tail stops what the bounded scans had to spare through the pinned signal')
            self.assertIn('OWNED_PROCESS_GROUP_SIGNAL:', log.read_text(),
                          'the delivered group signal reaches the run log')
            member_pid = int(marker.read_text())
            deadline = time.monotonic() + 10
            while not terminated(member_pid) and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertTrue(terminated(member_pid),
                            'the spared member must not outlive the run')
            healthy_log = Path(folder) / 'tail-clean.log'
            healthy_log.write_text('')
            with mock.patch.object(owned_process, '_signal_group',
                                   side_effect=lambda process_arg, pinned_arg: deliveries.append(pinned_arg) or 'delivered'):
                owned_process.run([PYTHON, '-c', 'import sys; sys.exit(0)'], {}, healthy_log, 10, cancel=handle)
            self.assertEqual(len(deliveries), 1,
                             'a healthy exit with no survivors never runs the group signal')
            self.assertNotIn('OWNED_PROCESS_GROUP_SIGNAL', healthy_log.read_text())
            failed_log = Path(folder) / 'tail-failed.log'
            failed_log.write_text('')
            with mock.patch.object(owned_process, '_signal_group', return_value='failed'):
                with self.assertRaises(owned_process.EscapedDescendants):
                    owned_process.run(command, {}, failed_log, 20, cancel=handle)
            self.assertIn('OWNED_PROCESS_GROUP_SIGNAL_FAILED:', failed_log.read_text(),
                          'a failed group signal is surfaced as an incomplete-cleanup diagnostic')

    # Value: protects=the pin lifecycle of every owned run (#404);
    # fails_when=a run never pins its leader, or leaves the pin descriptor open;
    # seam=owned_process.run with a recording pidfd_open
    def test_the_run_pin_spans_spawn_to_the_final_sweep(self):
        real_open = os.pidfd_open
        opened = []

        def recording_open(pid, *args):
            descriptor = real_open(pid, *args)
            opened.append((pid, descriptor))
            return descriptor

        with tempfile.TemporaryDirectory() as folder:
            log = Path(folder) / 'pin.log'
            log.write_text('')
            with mock.patch('os.pidfd_open', recording_open):
                returncode, output = owned_process.run([PYTHON, '-c', 'import sys; sys.exit(0)'], {}, log, 10)
        self.assertEqual(returncode, 0, 'the control only binds on a healthy run')
        child_pins = [pid for pid, _ in opened]
        self.assertEqual(len(child_pins), 1, 'the run pins its leader exactly once')
        for _, descriptor in opened:
            self.assertFalse(Path(f'/proc/self/fd/{descriptor}').exists(),
                             'the pin is released once the final sweep is done')


if __name__ == '__main__':
    unittest.main()
