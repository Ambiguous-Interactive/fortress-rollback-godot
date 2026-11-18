"""Value: a deadline or exit owns the whole descendant tree, not only the direct child."""
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
            self.assertEqual(owned_process.group_members(77, proc=proc), [{'pid': 72, 'name': 'live'}])

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
            def interrupting_collect(process, deadline):
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
            # never left behind as a zombie of this test.
            stat = Path(f'/proc/{pid}/stat')
            if stat.exists():
                self.assertNotEqual(stat.read_text().rsplit(') ', 1)[-1].split()[0], 'Z')
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

    def test_finish_after_clean_exit_keeps_only_the_sweep_checks(self):
        with tempfile.TemporaryDirectory() as folder:
            process, token = owned_process.spawn([PYTHON, '-c', 'print("done")'],
                                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            process.wait(timeout=10)
            owned_process.finish(process, token, grace=5)
            self.assertEqual(process.returncode, 0, 'a clean host keeps its own exit code')

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
    # unrecorded success.
    LATE_ESCAPE_TREE = """
import os, sys, time
pid = os.fork()
if pid == 0:
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
        while pid is None and time.monotonic() < deadline:
            if marker.exists():
                pid = int(marker.read_text())
            else:
                time.sleep(0.05)
        return thread, outcome, log, pid

    def assert_tree_gone(self, pid):
        deadline = time.monotonic() + 5
        while alive(pid) and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertFalse(alive(pid), 'a cancelled tree must be reaped before the cancel returns its join')

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
            thread, outcome, log, pid = self.start_cancel_run(folder, owned_process.run, handle, self.SLOW_TREE, timeout=1)
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

            def flipping_group(group_pid):
                if not handle.cancelled:
                    handle.cancel()  # the real cancel fires inside the deadline handler's own sweep
                return real_group(group_pid)

            with mock.patch.object(owned_process, 'terminate_group', flipping_group):
                with self.assertRaises(subprocess.TimeoutExpired):
                    owned_process.run(command, {}, log, 1, cancel=handle)
            pid = int(marker.read_text())
            self.assertFalse(alive(pid))
            stat = Path(f'/proc/{pid}/stat')
            if stat.exists():
                self.assertNotEqual(stat.read_text().rsplit(') ', 1)[-1].split()[0], 'Z')
            text = log.read_text()
            self.assertIn('TIMEOUT: command exceeded 1 seconds', text)
            self.assertIn(f"'pid': {pid}", text, 'the terminated pid must survive in the written report')
            self.assertLessEqual(text.count(f"'pid': {pid}"), 1, 'no pid may be named twice (#381)')

    def test_a_concurrent_cancel_claiming_mid_handler_reaches_the_timeout_report(self):
        """The claim/read inversion: a survivor the cancel claimed must still reach the written report."""
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
                with mock.patch.object(handle, 'claim', claiming_mid_sweep), \
                     mock.patch.object(handle, 'stopped_report',
                                       return_value=[{'pid': process.pid, 'name': 'swept'}]), \
                     mock.patch.object(owned_process, '_terminate_tree', return_value=[]):
                    with self.assertRaises(subprocess.TimeoutExpired):
                        owned_process._run_until_exit(process, token_value, log, 0.4, handle)
                self.assertIn(f"'pid': {process.pid}", log.read_text(),
                              'the concurrent cancel claimed survivor must reach the written timeout report')
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=10)

    def test_a_cancel_racing_a_natural_rc_zero_exit_never_reads_as_unrecorded_success(self):
        """The F1 shape: same-group carrier alive, child exiting zero, cancel mid-drain."""
        for delay in (0.05, 1.0):
            with self.subTest(cancel_after=delay), tempfile.TemporaryDirectory() as folder:
                handle = owned_process.CancelHandle()
                thread, outcome, log, pid = self.start_cancel_run(folder, owned_process.run, handle, self.LATE_ESCAPE_TREE)
                self.assertIsNotNone(pid, 'the control only holds with an armed tree')
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

    def test_the_pinned_leader_probe_never_lies_about_a_reaped_pid(self):
        process, token_value = owned_process._start([PYTHON, '-c', 'import time; time.sleep(30)'], {}, None, False)
        pinned = os.pidfd_open(process.pid)
        try:
            self.assertFalse(owned_process._leader_reaped(pinned), 'a live pinned leader reads unreaped')
            process.kill()
            process.wait(timeout=10)
            self.assertTrue(owned_process._leader_reaped(pinned),
                            'once the owner reaps, the pin must read reaped — a recycled id can never fool it')
        finally:
            os.close(pinned)

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

    def test_the_final_token_sweep_survives_a_failing_group_pass(self):
        """A failing post-kill group pass must not skip the token sweep or discard collected names."""
        process, token_value = owned_process._start([PYTHON, '-c', 'import time; time.sleep(30)'], {}, None, False)
        group_results = iter([[{'pid': process.pid, 'name': 'leader'}], ValueError('group pass exploded')])
        try:
            def flaky_group(group_pid):
                result = next(group_results)
                if isinstance(result, Exception):
                    raise result
                return result

            with mock.patch.object(owned_process, 'terminate_group', flaky_group), \
                 mock.patch.object(owned_process, 'terminate',
                                   return_value=[{'pid': process.pid + 1, 'name': 'carrier'}]) as terminate:
                with self.assertRaises(ValueError):
                    owned_process._terminate_tree(process, token_value)
            self.assertEqual(terminate.call_count, 2,
                             'the final token sweep must run even when the post-kill group pass raises')
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
            self.assertLessEqual(len(os.listdir('/proc/self/fd')), opened_before + 2,
                                 'each cancel must close its pinned descriptor, not leak one per run')

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


if __name__ == '__main__':
    unittest.main()
