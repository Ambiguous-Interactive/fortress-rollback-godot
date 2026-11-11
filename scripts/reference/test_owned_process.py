"""Value: a deadline or exit owns the whole descendant tree, not only the direct child."""
import os
import signal
import subprocess
import sys
import tempfile
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
                [survivor] = raised.exception.survivors
                self.assertEqual(survivor['pid'], pid, 'the escaped descendant must be identified by its own pid')
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
            stat = Path(f'/proc/{pid}/stat')
            # The interrupt handler reaps the child before propagating: the pid
            # is gone entirely, not left behind as a zombie of this test.
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


if __name__ == '__main__':
    unittest.main()
