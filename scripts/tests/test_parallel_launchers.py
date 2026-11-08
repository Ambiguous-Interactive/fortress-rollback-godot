"""Self-test: the parallel oracle-launcher runner must fail closed.

The runner replaces the serial launcher steps in CI, so its aggregation is the
gate. These tests pin:

* launchers that all pass exit zero and run once each against their own output;
* a failing launcher fails the whole run, surfaces its own output, and the
  run still joins every later launcher;
* a launcher exceeding the per-launcher timeout has its whole process group
  killed and fails the run as a timeout;
* a launcher script that cannot start fails the run;
* a worker exception is reported as a failed launcher, not a crashed run.

Each case exercises the real script end to end through temporary trees.
"""

import io
import shutil
import sys
import tempfile
import threading
import time
import unittest
import unittest.mock
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'oracle'))

import parallel_launchers

PASS_SCRIPT = """\
import sys
from pathlib import Path
args = sys.argv[1:]
assert '--godot' in args and '--output' in args, args
output = Path(args[args.index('--output') + 1])
output.mkdir(parents=True, exist_ok=True)
(output / 'receipt.json').write_text('{"passed": true}\\n')
(output / 'argv.txt').write_text('\\n'.join(args) + '\\n')
"""

FAIL_SCRIPT = """\
import sys
print('launcher controlled failure')
sys.exit(3)
"""

TIMEOUT_SCRIPT = """\
import subprocess, sys, time
from pathlib import Path
args = sys.argv[1:]
output = Path(args[args.index('--output') + 1])
output.mkdir(parents=True, exist_ok=True)
child = subprocess.Popen(['sh', '-c', 'sleep 2; touch "$1"', 'sh', str(output / 'late-child-marker')])
print('child started', flush=True)
time.sleep(30)
"""


def write_script(directory, name, text):
    path = directory / name
    path.write_text(text)
    path.chmod(0o755)
    return path


class ParallelLauncherRunnerTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='parallel-launchers-'))
        self.results = self.root / 'results'
        self.addCleanup(shutil.rmtree, self.root, True)

    def run_main(self, table, arguments):
        stdout = io.StringIO()
        stderr = io.StringIO()
        with unittest.mock.patch.dict(parallel_launchers.LAUNCHERS, table, clear=True), \
                unittest.mock.patch('sys.argv', ['parallel_launchers.py'] + arguments), \
                redirect_stdout(stdout), redirect_stderr(stderr):
            exit_code = parallel_launchers.main()
        return exit_code, stdout.getvalue(), stderr.getvalue()

    def test_passing_launchers_run_once_each_with_their_own_outputs(self):
        table = {'alpha': str(write_script(self.root, 'alpha.py', PASS_SCRIPT)),
                 'beta': str(write_script(self.root, 'beta.py', PASS_SCRIPT))}
        arguments = ['--godot', str(self.root / 'engine'), '--results', str(self.results), '--suffix', '4.3']
        exit_code, stdout, _ = self.run_main(table, arguments)
        self.assertEqual(exit_code, 0, stdout)
        for name in ('alpha', 'beta'):
            output = self.results / f'{name}-4.3'
            self.assertEqual(sorted(path.name for path in output.iterdir()), ['argv.txt', 'receipt.json'])
            self.assertIn('--godot', (output / 'argv.txt').read_text())
            self.assertTrue((self.results / f'launcher-4.3-{name}.log').exists())
        self.assertIn('2 launchers, 0 failed', stdout)
        self.assertIn('[2/2] pass', stdout)
        self.assertIn('pass beta', stdout)
        self.assertNotIn('FAIL', stdout)

    def test_failing_launcher_fails_run_and_later_launchers_still_join(self):
        table = {'alpha': str(write_script(self.root, 'alpha.py', PASS_SCRIPT)),
                 'beta': str(write_script(self.root, 'beta.py', FAIL_SCRIPT)),
                 'gamma': str(write_script(self.root, 'gamma.py', PASS_SCRIPT))}
        exit_code, stdout, _ = self.run_main(
            table, ['--godot', 'unused', '--results', str(self.results)])
        self.assertEqual(exit_code, 1)
        self.assertIn('--- beta exited 3 ---', stdout)
        self.assertIn('launcher controlled failure', stdout)
        self.assertIn(f'complete log: {self.results / "launcher-beta.log"}', stdout)
        self.assertIn('3 launchers, 1 failed', stdout)
        for name in ('alpha', 'beta', 'gamma'):
            self.assertTrue((self.results / f'launcher-{name}.log').exists(), name)
        for name in ('alpha', 'gamma'):
            self.assertTrue((self.results / name).is_dir(), name)

    def test_timeout_kills_the_launcher_process_group(self):
        table = {'sleeper': str(write_script(self.root, 'sleeper.py', TIMEOUT_SCRIPT))}
        started = time.monotonic()
        exit_code, stdout, _ = self.run_main(
            table, ['--godot', 'unused', '--results', str(self.results), '--timeout', '1.0'])
        self.assertEqual(exit_code, 1)
        self.assertLess(time.monotonic() - started, 15)
        self.assertIn('after exceeding the per-launcher timeout', stdout)
        self.assertIn('exited 124', stdout)
        # The detached child dies with its group, so the marker never appears.
        time.sleep(3)
        self.assertFalse((self.results / 'sleeper' / 'late-child-marker').exists(),
                         'orphaned launcher child survived the group kill')

    def test_interruption_fences_queued_launches_and_kills_active_groups(self):
        table = {'alpha': str(write_script(self.root, 'alpha.py', PASS_SCRIPT)),
                 'beta': str(write_script(self.root, 'beta.py', PASS_SCRIPT)),
                 'gamma': str(write_script(self.root, 'gamma.py', PASS_SCRIPT))}
        killed = []
        release = threading.Event()

        def fake(name, command, log_path, timeout):
            if name == 'alpha':
                raise KeyboardInterrupt('simulated interruption')
            if name == 'beta':
                # A still-running launcher whose group interruption must terminate.
                with parallel_launchers._active_lock:
                    parallel_launchers._active_groups.add(4242)
                try:
                    release.wait(10)
                finally:
                    with parallel_launchers._active_lock:
                        parallel_launchers._active_groups.discard(4242)
            return {'name': name, 'seconds': 0.0, 'returncode': 0, 'timeout': False}

        def record_kill(pid):
            killed.append(pid)
            release.set()

        try:
            with unittest.mock.patch.dict(parallel_launchers.LAUNCHERS, table, clear=True), \
                    unittest.mock.patch.object(parallel_launchers, 'run_launcher', side_effect=fake), \
                    unittest.mock.patch.object(parallel_launchers, 'kill_group', side_effect=record_kill), \
                    unittest.mock.patch('sys.argv', ['parallel_launchers.py', '--godot', 'unused',
                                                     '--results', str(self.results)]), \
                    redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                with self.assertRaises(KeyboardInterrupt):
                    parallel_launchers.main()
        finally:
            release.set()
        self.assertEqual(killed, [4242], 'interruption did not terminate the active launcher group')

    def test_missing_launcher_script_fails_the_run(self):
        table = {'ghost': str(self.root / 'absent.py')}
        exit_code, stdout, _ = self.run_main(
            table, ['--godot', 'unused', '--results', str(self.results)])
        self.assertEqual(exit_code, 1)
        self.assertIn('1 launchers, 1 failed', stdout)
        self.assertIn('--- ghost exited', stdout)

    def test_worker_exception_is_a_failed_launcher_not_a_crash(self):
        table = {'alpha': str(write_script(self.root, 'alpha.py', PASS_SCRIPT)),
                 'beta': str(write_script(self.root, 'beta.py', PASS_SCRIPT))}

        original = parallel_launchers.run_launcher

        def crashing(name, command, log_path, timeout):
            if name == 'beta':
                raise RuntimeError('worker exploded')
            return original(name, command, log_path, timeout)

        with unittest.mock.patch.dict(parallel_launchers.LAUNCHERS, table, clear=True), \
                unittest.mock.patch.object(parallel_launchers, 'run_launcher', side_effect=crashing), \
                unittest.mock.patch('sys.argv', ['parallel_launchers.py', '--godot', 'unused',
                                                 '--results', str(self.results)]), \
                redirect_stdout(io.StringIO()) as stdout, \
                redirect_stderr(io.StringIO()):
            exit_code = parallel_launchers.main()
        self.assertEqual(exit_code, 1)
        self.assertIn('RuntimeError: worker exploded', stdout.getvalue())
        self.assertIn('2 launchers, 1 failed', stdout.getvalue())
        self.assertIn('produced no log', stdout.getvalue())

    def test_provisions_the_toolchain_and_source_trees_once_before_any_launcher(self):
        table = {'alpha': str(write_script(self.root, 'alpha.py', PASS_SCRIPT)),
                 'beta': str(write_script(self.root, 'beta.py', PASS_SCRIPT))}
        calls = []

        def record_setup(manifest, offline):
            calls.append('setup')
            return 'cargo', None

        def record_sources(manifest, offline):
            calls.append('sources')
            return {}

        def record_launcher(name, command, log_path, timeout):
            calls.append('launcher:' + name)
            self.assertEqual(calls[:2], ['setup', 'sources'],
                             'a launcher started before the toolchain and source trees were prepared')
            return {'name': name, 'seconds': 0.0, 'returncode': 0, 'timeout': False}

        with unittest.mock.patch.dict(parallel_launchers.LAUNCHERS, table, clear=True), \
                unittest.mock.patch.object(parallel_launchers, 'load_manifest', return_value='manifest'), \
                unittest.mock.patch.object(parallel_launchers, 'setup_rust', side_effect=record_setup), \
                unittest.mock.patch.object(parallel_launchers, 'sources', side_effect=record_sources), \
                unittest.mock.patch.object(parallel_launchers, 'run_launcher', side_effect=record_launcher), \
                unittest.mock.patch('sys.argv', ['parallel_launchers.py', '--godot', 'unused',
                                                 '--results', str(self.results)]), \
                redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            exit_code = parallel_launchers.main()
        self.assertEqual(exit_code, 0)
        self.assertEqual(calls.count('setup'), 1)
        self.assertEqual(calls.count('sources'), 1)
        self.assertEqual(calls[:2], ['setup', 'sources'])
        self.assertEqual(len(calls), 4)


if __name__ == '__main__':
    unittest.main()
