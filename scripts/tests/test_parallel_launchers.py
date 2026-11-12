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
import os
import select
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
        # The runner's startup preflights must never reach the network from a test:
        # stub them for every case; a case can override with its own recorder.
        setup = unittest.mock.patch.object(parallel_launchers, 'setup_rust', return_value=('cargo', None))
        setup.start()
        self.addCleanup(setup.stop)
        sources = unittest.mock.patch.object(parallel_launchers, 'sources', return_value={})
        sources.start()
        self.addCleanup(sources.stop)
        prefetch = unittest.mock.patch.object(parallel_launchers, 'prefetch_oracle_crates', return_value=None)
        prefetch.start()
        self.addCleanup(prefetch.stop)

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
        registered = threading.Event()
        release = threading.Event()

        def fake(name, command, log_path, timeout):
            if name == 'alpha':
                # Deterministic ordering: alpha interrupts only after beta has
                # registered its group, so the fence always has a live target.
                registered.wait(10)
                raise KeyboardInterrupt('simulated interruption')
            if name == 'beta':
                # A still-running launcher whose group interruption must terminate.
                with parallel_launchers._active_lock:
                    parallel_launchers._active_handles.append({'pid': 4242})
                registered.set()
                try:
                    release.wait(10)
                finally:
                    with parallel_launchers._active_lock:
                        parallel_launchers._active_handles.remove({'pid': 4242})
            return {'name': name, 'seconds': 0.0, 'returncode': 0, 'timeout': False}

        def record_kill(pid):
            killed.append(pid)
            release.set()

        try:
            with unittest.mock.patch.dict(parallel_launchers.LAUNCHERS, table, clear=True), \
                    unittest.mock.patch.object(parallel_launchers, 'run_launcher', side_effect=fake), \
                    unittest.mock.patch.object(parallel_launchers, 'kill_group', side_effect=record_kill), \
                    unittest.mock.patch('sys.argv', ['parallel_launchers.py', '--godot', 'unused',
                                                     '--results', str(self.results), '--jobs', '2']), \
                    redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                with self.assertRaises(KeyboardInterrupt):
                    parallel_launchers.main()
        finally:
            registered.set()
            release.set()
            parallel_launchers._abort.clear()
        self.assertEqual(killed, [4242], 'interruption did not terminate the active launcher group')

    def test_a_fenced_run_launcher_refuses_to_launch(self):
        parallel_launchers._abort.set()
        self.addCleanup(parallel_launchers._abort.clear)
        log = self.results / 'launcher-refused.log'
        result = parallel_launchers.run_launcher('refused', ['sleep', '30'], log, 0)
        self.assertEqual(result['returncode'], 1, 'a fenced launcher is a failed launcher')
        self.assertFalse(log.exists(), 'a fenced launcher must not start its command')

    def test_sigterm_fences_and_exits_like_an_interrupt(self):
        real_kill = parallel_launchers.kill_group
        killed = []

        def record_and_kill(pid):
            killed.append(pid)
            real_kill(pid)

        script_path = write_script(self.root, 'sleeper.py', 'import time\ntime.sleep(30)\n')
        log = self.results / 'launcher-sigterm.log'
        began = time.monotonic()
        worker = threading.Thread(target=parallel_launchers.run_launcher,
                                  args=('sleeper', [sys.executable, str(script_path)], log, 0))
        try:
            worker.start()
            deadline = time.time() + 10
            while time.time() < deadline:
                with parallel_launchers._active_lock:
                    if any(handle['pid'] is not None for handle in parallel_launchers._active_handles):
                        break
                time.sleep(0.02)
            with parallel_launchers._active_lock:
                self.assertTrue(any(handle['pid'] is not None for handle in parallel_launchers._active_handles),
                                'the launcher must register its group before the fence runs')
            with unittest.mock.patch.object(parallel_launchers, 'kill_group', side_effect=record_and_kill):
                with self.assertRaises(SystemExit) as raised:
                    parallel_launchers._on_terminate(15, None)
            worker.join(10)
        finally:
            parallel_launchers._abort.clear()
        self.assertFalse(worker.is_alive(), 'the fenced launcher must end promptly after SIGTERM')
        self.assertEqual(raised.exception.code, 143, 'SIGTERM must exit like a terminated shell command')
        self.assertLess(time.monotonic() - began, 15, 'the SIGTERM fence must not wait out the engine')
        self.assertEqual(len(killed), 1, 'the SIGTERM fence must kill the registered group')

    def test_a_launcher_spawned_into_an_abort_kills_its_own_group(self):
        real_kill = parallel_launchers.kill_group
        killed = []
        # The descendant's death is witnessed by the pipe's write end: the
        # leader and its fork both hold it, so the read end returns EOF only
        # when every group member has exited. A /proc zombie poll cannot make
        # that distinction under reaping and pid-reuse races; a hosted runner
        # once reported a survivor for a group the kernel killed.
        witness_read, witness_write = os.pipe()

        def record_and_kill(pid):
            killed.append(pid)
            real_kill(pid)

        real_popen = parallel_launchers.subprocess.Popen

        def popen_then_abort(command, **kwargs):
            # Abort lands in the spawn-to-registration window the fence owns,
            # after the leader has forked its engine stand-in and recorded it.
            # The kill can interrupt a half-written pid file, so wait for the
            # recorded content, not the file's existence.
            kwargs['pass_fds'] = tuple(kwargs.get('pass_fds', ())) + (witness_write,)
            process = real_popen(command, **kwargs)
            deadline = time.time() + 5
            while time.time() < deadline:
                recorded = (self.root / 'engine-descendant-pid')
                if recorded.exists() and recorded.read_text().strip().isdigit():
                    break
                time.sleep(0.01)
            parallel_launchers._abort.set()
            return process

        leader_script = (
            "import os, time, pathlib\n"
            "child = os.fork()\n"
            "if child == 0:\n"
            "    time.sleep(30)\n"
            "    os._exit(0)\n"
            f"pathlib.Path({str(self.root / 'engine-descendant-pid')!r}).write_text(str(child))\n"
            "time.sleep(30)\n"
        )
        script_path = write_script(self.root, 'leader.py', leader_script)
        log = self.results / 'launcher-sleeper.log'

        def close_witness():
            for fd in (witness_write, witness_read):
                try:
                    os.close(fd)
                except OSError:
                    pass
        self.addCleanup(close_witness)
        try:
            with unittest.mock.patch.object(parallel_launchers.subprocess, 'Popen', side_effect=popen_then_abort), \
                    unittest.mock.patch.object(parallel_launchers, 'kill_group', side_effect=record_and_kill):
                began = time.monotonic()
                result = parallel_launchers.run_launcher('sleeper', [sys.executable, str(script_path)], log, 0)
        finally:
            parallel_launchers._abort.clear()
        os.close(witness_write)
        self.assertLess(time.monotonic() - began, 15, 'the spawned launcher must be killed, not waited out')
        self.assertEqual(result['returncode'], -9, 'SIGKILL to the launcher group must end the launcher')
        self.assertEqual(len(killed), 1, 'the spawn-window abort must kill its own group')
        # The group kill is what protects engine children: the leader's forked
        # descendant must die with the group, not only the leader itself. The
        # pipe read end unblocks with EOF exactly when the leader and the
        # fork have both exited; a survivor keeps it open past this bound.
        readable = select.select([witness_read], [], [], 10)[0]
        self.assertTrue(readable and os.read(witness_read, 1) == b'',
                        'a forked engine descendant survived the group kill: its pipe end is still open')

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

        def record_fetch(cargo, environment, manifest, version, log_path):
            calls.append('fetch')
            self.assertEqual(manifest.name, 'Cargo.toml')
            log_path.parent.mkdir(parents=True, exist_ok=True)
            log_path.write_text('fetch recorded\n')

        def record_launcher(name, command, log_path, timeout):
            calls.append('launcher:' + name)
            self.assertEqual(calls[:3], ['setup', 'sources', 'fetch'],
                             'a launcher started before the shared toolchain, sources and crates were prepared')
            return {'name': name, 'seconds': 0.0, 'returncode': 0, 'timeout': False}

        with unittest.mock.patch.dict(parallel_launchers.LAUNCHERS, table, clear=True), \
                unittest.mock.patch.object(parallel_launchers, 'load_manifest', return_value={'rust': {'version': '1.99.1'}}), \
                unittest.mock.patch.object(parallel_launchers, 'setup_rust', side_effect=record_setup), \
                unittest.mock.patch.object(parallel_launchers, 'sources', side_effect=record_sources), \
                unittest.mock.patch.object(parallel_launchers, 'prefetch_oracle_crates', side_effect=record_fetch), \
                unittest.mock.patch.object(parallel_launchers, 'run_launcher', side_effect=record_launcher), \
                unittest.mock.patch('sys.argv', ['parallel_launchers.py', '--godot', 'unused',
                                                 '--results', str(self.results), '--suffix', '4.3']), \
                redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            exit_code = parallel_launchers.main()
        self.assertEqual(exit_code, 0)
        for step in ('setup', 'sources', 'fetch'):
            self.assertEqual(calls.count(step), 1, step)
        self.assertEqual(calls[:3], ['setup', 'sources', 'fetch'])
        self.assertEqual(len(calls), 5)
        self.assertTrue((self.results / 'oracle-fetch-4.3.log').exists(),
                        'the preflight must keep its output log beside the launcher logs')


if __name__ == '__main__':
    unittest.main()
